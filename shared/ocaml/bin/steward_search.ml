(** steward-search: Search Claude Code transcripts by semantic similarity

    Usage: steward-search [OPTIONS] <query>

    Options:
      --limit N        Maximum results (default: 10)
      --project PATH   Filter by project path
      --json           Output as JSON
      --threshold F    Minimum similarity score (0.0-1.0)

    Examples:
      steward-search "state machine"
      steward-search --limit 5 "error handling"
      steward-search --json "database query"
*)

open Steward.Types

(** Parse command line arguments *)
type cli_args = {
  query : string;
  limit : int;
  project_filter : string option;
  json_output : bool;
  score_threshold : float option;
}

let default_args = {
  query = "";
  limit = 10;
  project_filter = None;
  json_output = false;
  score_threshold = None;
}

let usage () =
  Printf.eprintf "Usage: steward-search [OPTIONS] <query>\n";
  Printf.eprintf "\nOptions:\n";
  Printf.eprintf "  --limit N        Maximum results (default: 10)\n";
  Printf.eprintf "  --project PATH   Filter by project path\n";
  Printf.eprintf "  --json           Output as JSON\n";
  Printf.eprintf "  --threshold F    Minimum similarity score (0.0-1.0)\n";
  exit 1

let parse_args () =
  let args = Array.to_list Sys.argv |> List.tl in
  let rec parse acc = function
    | [] -> acc
    | "--limit" :: n :: rest ->
        (try parse { acc with limit = int_of_string n } rest
         with _ -> Printf.eprintf "Error: --limit requires an integer\n"; exit 1)
    | "--project" :: path :: rest ->
        parse { acc with project_filter = Some path } rest
    | "--json" :: rest ->
        parse { acc with json_output = true } rest
    | "--threshold" :: f :: rest ->
        (try parse { acc with score_threshold = Some (float_of_string f) } rest
         with _ -> Printf.eprintf "Error: --threshold requires a float\n"; exit 1)
    | "--help" :: _ | "-h" :: _ -> usage ()
    | arg :: _rest when String.length arg > 0 && arg.[0] = '-' ->
        Printf.eprintf "Error: Unknown option: %s\n" arg; exit 1
    | query :: rest ->
        parse { acc with query = acc.query ^ (if acc.query = "" then "" else " ") ^ query } rest
  in
  let args = parse default_args args in
  if args.query = "" then usage ();
  args

(** Truncate string with ellipsis *)
let truncate ?(max_len=100) s =
  if String.length s <= max_len then s
  else String.sub s 0 max_len ^ "..."

(** Format a single result for human output *)
let format_result (r : search_result) : string =
  Printf.sprintf "%.2f │ %s │ %s\n     %s"
    r.sr_score
    (truncate ~max_len:20 (string_of_session_id r.sr_session_id))
    r.sr_project_path
    (truncate ~max_len:80 (String.map (fun c -> if c = '\n' then ' ' else c) r.sr_content))

(** Convert result to JSON *)
let result_to_json (r : search_result) : Yojson.Safe.t =
  `Assoc [
    ("chunk_id", `String (string_of_chunk_id r.sr_chunk_id));
    ("session_id", `String (string_of_session_id r.sr_session_id));
    ("project_path", `String r.sr_project_path);
    ("timestamp", `String r.sr_timestamp);
    ("content", `String r.sr_content);
    ("context", match r.sr_context with Some c -> `String c | None -> `Null);
    ("score", `Float r.sr_score);
  ]

let () =
  let args = parse_args () in

  (* Initialize configs *)
  let qdrant_config = Steward.Qdrant.default_config in
  let embed_config = Steward.Embed.default_config in

  (* Build search options *)
  let options : search_options = {
    so_limit = args.limit;
    so_project_filter = args.project_filter;
    so_score_threshold = args.score_threshold;
  } in

  (* Perform search *)
  match Steward.Qdrant.search qdrant_config embed_config args.query options with
  | Error msg ->
      Printf.eprintf "Error: %s\n" msg;
      exit 1
  | Ok results ->
      if args.json_output then begin
        let json = `List (List.map result_to_json results) in
        print_endline (Yojson.Safe.pretty_to_string json)
      end else begin
        if results = [] then
          print_endline "No results found."
        else begin
          Printf.printf "Found %d results for: %s\n\n" (List.length results) args.query;
          Printf.printf "Score │ Session              │ Project\n";
          Printf.printf "──────┼──────────────────────┼────────────────────────────────────\n";
          List.iter (fun r -> print_endline (format_result r); print_newline ()) results
        end
      end
