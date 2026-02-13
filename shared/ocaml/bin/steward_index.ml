(** steward-index: Index Claude Code transcripts for semantic search

    Usage: steward-index [OPTIONS]

    Options:
      --parallel N       Number of parallel embedding workers (default: 4)
      --project PATH     Only index transcripts for this project
      --dry-run          Show plan without executing
      --batch N          Qdrant write batch size (default: 50)
      --errors-file PATH Write embedding errors to JSONL file

    Examples:
      steward-index                              # Index all transcripts
      steward-index --dry-run                    # Show what would be indexed
      steward-index --parallel 8                 # Use 8 embedding workers
      steward-index --project /path              # Only index one project
      steward-index --errors-file errors.jsonl   # Save errors for analysis
*)

open Steward.Types

(** Parse command line arguments *)
let parse_args () : index_options =
  let opts = ref Steward.Indexer.default_options in
  let args = Array.to_list Sys.argv |> List.tl in
  let rec parse = function
    | [] -> ()
    | "--parallel" :: n :: rest ->
        (try opts := { !opts with io_parallel = int_of_string n }
         with _ -> Printf.eprintf "Error: --parallel requires an integer\n"; exit 1);
        parse rest
    | "--project" :: path :: rest ->
        opts := { !opts with io_project_filter = Some path };
        parse rest
    | "--dry-run" :: rest ->
        opts := { !opts with io_dry_run = true };
        parse rest
    | "--batch" :: n :: rest ->
        (try opts := { !opts with io_batch_size = int_of_string n }
         with _ -> Printf.eprintf "Error: --batch requires an integer\n"; exit 1);
        parse rest
    | "--errors-file" :: path :: rest ->
        opts := { !opts with io_errors_file = Some path };
        parse rest
    | "--help" :: _ | "-h" :: _ ->
        Printf.printf "Usage: steward-index [OPTIONS]\n\n";
        Printf.printf "Options:\n";
        Printf.printf "  --parallel N       Parallel embedding workers (default: 4)\n";
        Printf.printf "  --project PATH     Only index this project\n";
        Printf.printf "  --dry-run          Show plan without executing\n";
        Printf.printf "  --batch N          Qdrant write batch size (default: 50)\n";
        Printf.printf "  --errors-file PATH Write errors to JSONL file\n";
        exit 0
    | arg :: _ ->
        Printf.eprintf "Error: Unknown option: %s\n" arg;
        exit 1
  in
  parse args;
  !opts

(** Progress reporter *)
let report_progress (p : index_progress) =
  Printf.eprintf "\r%s%!" (Steward.Indexer.format_progress p)

(** Serialize a chunk error to JSON *)
let error_to_json ((chunk, error) : index_chunk * string) : Yojson.Safe.t =
  let content_preview =
    let len = String.length chunk.chunk_content in
    if len <= 200 then chunk.chunk_content
    else String.sub chunk.chunk_content 0 200 ^ "..."
  in
  `Assoc [
    ("chunk_id", `String (string_of_chunk_id chunk.chunk_id));
    ("session_id", `String (string_of_session_id chunk.chunk_session_id));
    ("project_path", `String chunk.chunk_project_path);
    ("error", `String error);
    ("content_length", `Int (String.length chunk.chunk_content));
    ("content_preview", `String content_preview);
  ]

(** Write errors to JSONL file *)
let write_errors_jsonl (path : string) (errors : (index_chunk * string) list) =
  let oc = open_out path in
  List.iter (fun err ->
    let json = error_to_json err in
    output_string oc (Yojson.Safe.to_string json);
    output_char oc '\n'
  ) errors;
  close_out oc

(** Main indexing logic *)
let run_index (opts : index_options) =
  let start_time = Unix.gettimeofday () in

  (* Step 1: Discover files *)
  Printf.eprintf "Discovering transcript files...\n%!";
  let projects_dir = Steward.Discover.default_projects_dir () in
  let all_files = Steward.Discover.discover_files projects_dir in
  let files = match opts.io_project_filter with
    | Some path -> Steward.Discover.filter_by_project path all_files
    | None -> all_files
  in
  Printf.eprintf "Found %d transcript files (%d MB)\n%!"
    (List.length files)
    (Steward.Discover.total_size files / 1024 / 1024);

  (* Step 2: Parse all files into chunks *)
  Printf.eprintf "Parsing transcripts into turns...\n%!";
  let all_chunks = List.concat_map (fun (fi : file_info) ->
    try
      let ic = open_in fi.fi_path in
      let rec read_lines acc =
        match In_channel.input_line ic with
        | None -> List.rev acc
        | Some line ->
            let chunk = try
              let json = Yojson.Safe.from_string line in
              Steward.Transcript.parse_message json
            with _ -> None
            in
            read_lines (chunk :: acc)
      in
      let messages = read_lines [] |> List.filter_map Fun.id in
      close_in ic;
      let turns = Steward.Transcript.pair_into_turns messages fi.fi_path in
      List.concat_map Steward.Embed.turn_to_chunks turns
    with _ -> []
  ) files in
  Printf.eprintf "Parsed %d turns from transcripts\n%!" (List.length all_chunks);

  (* Step 3: Query Qdrant for existing chunk IDs *)
  Printf.eprintf "Checking Qdrant for existing chunks...\n%!";
  let qdrant_config = Steward.Qdrant.default_config in
  let existing_ids = match Steward.Qdrant.scroll_all_chunk_ids qdrant_config with
    | Ok ids -> ids
    | Error msg ->
        Printf.eprintf "Warning: Could not query Qdrant: %s\n%!" msg;
        []
  in
  Printf.eprintf "Found %d existing chunks in Qdrant\n%!" (List.length existing_ids);

  (* Step 4: Compute plan *)
  let plan, new_chunks = Steward.Indexer.plan_indexing
    ~total_files:(List.length files)
    ~all_chunks
    ~existing_ids
  in
  Printf.eprintf "\n%s\n\n%!" (Steward.Indexer.format_plan plan);

  if opts.io_dry_run then begin
    Printf.printf "Dry run complete. Would index %d new chunks.\n" plan.ip_new_chunks;
    exit 0
  end;

  if plan.ip_new_chunks = 0 then begin
    Printf.printf "Nothing to index. All chunks already in Qdrant.\n";
    exit 0
  end;

  (* Step 5: Embed and write in batches *)
  Printf.eprintf "Indexing %d new chunks with %d parallel workers...\n%!"
    plan.ip_new_chunks opts.io_parallel;

  let pool_config : embed_pool_config = {
    epc_workers = opts.io_parallel;
    epc_embed_config = Steward.Embed.default_config;
  } in

  let batches = Steward.Indexer.batch opts.io_batch_size new_chunks in
  let progress = ref (Steward.Indexer.init_progress plan.ip_new_chunks) in
  let total_errors = ref [] in

  List.iter (fun batch ->
    (* Embed batch *)
    let successes, errors = Steward.Async_embed.embed_sync pool_config batch in
    progress := Steward.Indexer.progress_embedded !progress (List.length successes);
    total_errors := !total_errors @ errors;

    (* Write to Qdrant *)
    if successes <> [] then begin
      match Steward.Qdrant.upsert_points qdrant_config successes with
      | Steward.Qdrant.Qd_ok ->
          progress := Steward.Indexer.progress_written !progress (List.length successes)
      | Steward.Qdrant.Qd_error msg ->
          Printf.eprintf "\nQdrant write error: %s\n%!" msg;
          List.iter (fun ec ->
            progress := Steward.Indexer.progress_error !progress;
            total_errors := (ec.ec_chunk, msg) :: !total_errors
          ) successes
    end;
    report_progress !progress
  ) batches;

  let elapsed = Unix.gettimeofday () -. start_time in
  Printf.eprintf "\n\n";

  (* Report results *)
  if !total_errors = [] then begin
    Printf.printf "Success! Indexed %d chunks in %.1f seconds.\n"
      (!progress).ipg_written elapsed;
    Printf.printf "Rate: %.1f chunks/sec\n"
      (float_of_int (!progress).ipg_written /. elapsed)
  end else begin
    Printf.printf "Completed with %d errors.\n" (List.length !total_errors);
    Printf.printf "Indexed: %d, Errors: %d\n"
      (!progress).ipg_written (List.length !total_errors);
    (* Write errors to file if requested *)
    (match opts.io_errors_file with
    | Some path ->
        write_errors_jsonl path !total_errors;
        Printf.printf "Errors written to: %s\n" path
    | None ->
        Printf.printf "Use --errors-file PATH to save full error details.\n";
        Printf.printf "Sample errors (first 10):\n";
        List.iter (fun (chunk, err) ->
          Printf.eprintf "  %s: %s\n" (string_of_chunk_id chunk.chunk_id) err
        ) (List.rev !total_errors |> List.filteri (fun i _ -> i < 10)))
  end

let () =
  let opts = parse_args () in
  run_index opts
