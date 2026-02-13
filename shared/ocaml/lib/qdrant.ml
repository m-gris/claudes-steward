(** Qdrant vector database client for transcript search *)

open Types

(** Qdrant configuration *)
type qdrant_config = {
  qd_base_url : string;      (** e.g., "http://localhost:6333" *)
  qd_collection : string;    (** Collection name, e.g., "transcripts" *)
}

(** Default configuration *)
let default_config : qdrant_config = {
  qd_base_url = "http://localhost:6333";
  qd_collection = "transcripts";
}

(** Result type for Qdrant operations *)
type qdrant_result =
  | Qd_ok
  | Qd_error of string

(** Generate a deterministic numeric ID from a string (for Qdrant point IDs).
    Uses a simple hash to convert UUID-style IDs to positive integers. *)
let string_to_point_id (s : string) : int =
  (* Simple FNV-1a hash, masked to positive int *)
  let hash = ref 2166136261 in
  String.iter (fun c ->
    hash := !hash lxor (Char.code c);
    hash := !hash * 16777619;
  ) s;
  abs (!hash)

(** Convert an embedded chunk to Qdrant point JSON *)
let chunk_to_point (ec : embedded_chunk) : Yojson.Safe.t =
  let chunk = ec.ec_chunk in
  let cid = string_of_chunk_id chunk.chunk_id in
  let sid = string_of_session_id chunk.chunk_session_id in
  let vector_list = Array.to_list ec.ec_vector |> List.map (fun f -> `Float f) in
  `Assoc [
    ("id", `Int (string_to_point_id cid));
    ("vector", `Assoc [("dense", `List vector_list)]);
    ("payload", `Assoc [
      ("chunk_id", `String cid);
      ("session_id", `String sid);
      ("project_path", `String chunk.chunk_project_path);
      ("timestamp", `String chunk.chunk_timestamp);
      ("content", `String chunk.chunk_content);
      ("context", match chunk.chunk_context with
        | Some ctx -> `String ctx
        | None -> `Null);
    ]);
  ]

(** Upsert points to Qdrant (batch).
    Uses PUT /collections/{collection}/points with upsert semantics. *)
let upsert_points (config : qdrant_config) (chunks : embedded_chunk list) : qdrant_result =
  if chunks = [] then Qd_ok
  else
    let points = List.map chunk_to_point chunks in
    let payload = `Assoc [("points", `List points)] in
    let payload_str = Yojson.Safe.to_string payload in

    (* Build curl command - write payload to temp file to avoid shell escaping issues *)
    let temp_file = Filename.temp_file "qdrant_" ".json" in
    let oc = open_out temp_file in
    output_string oc payload_str;
    close_out oc;

    let url = Printf.sprintf "%s/collections/%s/points?wait=true"
      config.qd_base_url config.qd_collection in
    let cmd = Printf.sprintf
      "curl -s -X PUT '%s' -H 'Content-Type: application/json' -d @'%s'"
      url temp_file
    in

    let ic = Unix.open_process_in cmd in
    let output = In_channel.input_all ic in
    let status = Unix.close_process_in ic in

    (* Clean up temp file *)
    (try Sys.remove temp_file with _ -> ());

    match status with
    | Unix.WEXITED 0 ->
        (try
          let json = Yojson.Safe.from_string output in
          let open Yojson.Safe.Util in
          let status = json |> member "status" |> to_string_option in
          match status with
          | Some "ok" -> Qd_ok
          | Some s -> Qd_error (Printf.sprintf "Qdrant returned status: %s" s)
          | None ->
              (* Check for result.status *)
              let result_status = json |> member "result" |> member "status" |> to_string_option in
              (match result_status with
              | Some "completed" -> Qd_ok
              | _ -> Qd_error (Printf.sprintf "Unexpected response: %s" output))
        with
        | Yojson.Json_error msg -> Qd_error ("JSON parse error: " ^ msg)
        | Yojson.Safe.Util.Type_error (msg, _) -> Qd_error ("JSON type error: " ^ msg))
    | Unix.WEXITED code -> Qd_error (Printf.sprintf "curl exited with code %d: %s" code output)
    | Unix.WSIGNALED _ -> Qd_error "curl killed by signal"
    | Unix.WSTOPPED _ -> Qd_error "curl stopped"

(** Index multiple chunks in batches for progress tracking.
    Returns (indexed_count, error_messages). *)
let index_chunks ?(batch_size=100) ?(on_progress=fun _ _ -> ())
    (config : qdrant_config) (chunks : embedded_chunk list)
    : int * string list =
  let total = List.length chunks in
  let rec process_batches acc_count acc_errors remaining =
    match remaining with
    | [] -> (acc_count, List.rev acc_errors)
    | _ ->
        let batch, rest =
          let rec take n acc = function
            | [] -> (List.rev acc, [])
            | _ when n = 0 -> (List.rev acc, remaining)
            | x :: xs -> take (n - 1) (x :: acc) xs
          in
          take batch_size [] remaining
        in
        match upsert_points config batch with
        | Qd_ok ->
            let new_count = acc_count + List.length batch in
            on_progress new_count total;
            process_batches new_count acc_errors rest
        | Qd_error msg ->
            process_batches acc_count (msg :: acc_errors) rest
  in
  process_batches 0 [] chunks

(** Check if Qdrant is healthy *)
let health_check (config : qdrant_config) : bool =
  let cmd = Printf.sprintf "curl -s '%s/'" config.qd_base_url in
  let ic = Unix.open_process_in cmd in
  let output = In_channel.input_all ic in
  let status = Unix.close_process_in ic in
  match status with
  | Unix.WEXITED 0 ->
      (try
        let json = Yojson.Safe.from_string output in
        let open Yojson.Safe.Util in
        let version = json |> member "version" |> to_string_option in
        Option.is_some version
      with _ -> false)
  | _ -> false

(** Get collection info *)
let collection_info (config : qdrant_config) : (int * int, string) result =
  let url = Printf.sprintf "%s/collections/%s" config.qd_base_url config.qd_collection in
  let cmd = Printf.sprintf "curl -s '%s'" url in
  let ic = Unix.open_process_in cmd in
  let output = In_channel.input_all ic in
  let status = Unix.close_process_in ic in
  match status with
  | Unix.WEXITED 0 ->
      (try
        let json = Yojson.Safe.from_string output in
        let open Yojson.Safe.Util in
        let result = json |> member "result" in
        let points_count = result |> member "points_count" |> to_int_option |> Option.value ~default:0 in
        let vectors_count = result |> member "vectors_count" |> to_int_option |> Option.value ~default:0 in
        Ok (points_count, vectors_count)
      with e -> Error (Printexc.to_string e))
  | Unix.WEXITED code -> Error (Printf.sprintf "curl exited with code %d" code)
  | _ -> Error "curl failed"

(** Default search options *)
let default_search_options : search_options = {
  so_limit = 10;
  so_project_filter = None;
  so_score_threshold = None;
}

(** Parse a single search result from Qdrant response *)
let parse_search_result (json : Yojson.Safe.t) : search_result option =
  try
    let open Yojson.Safe.Util in
    let payload = json |> member "payload" in
    let score = json |> member "score" |> to_float in
    Some {
      sr_chunk_id = payload |> member "chunk_id" |> to_string |> make_chunk_id;
      sr_session_id = payload |> member "session_id" |> to_string |> make_session_id;
      sr_project_path = payload |> member "project_path" |> to_string;
      sr_timestamp = payload |> member "timestamp" |> to_string;
      sr_content = payload |> member "content" |> to_string;
      sr_context = payload |> member "context" |> to_string_option;
      sr_score = score;
    }
  with _ -> None

(** Search for similar vectors in Qdrant.
    Takes a query vector and returns ranked results. *)
let search_by_vector (config : qdrant_config) (query_vector : float array)
    (options : search_options) : (search_result list, string) result =
  (* Build the query payload *)
  let vector_list = Array.to_list query_vector |> List.map (fun f -> `Float f) in

  (* Build filter if project_filter is specified *)
  let filter = match options.so_project_filter with
    | Some path ->
        Some (`Assoc [
          ("must", `List [
            `Assoc [
              ("key", `String "project_path");
              ("match", `Assoc [("value", `String path)])
            ]
          ])
        ])
    | None -> None
  in

  let payload_fields = [
    ("vector", `Assoc [("name", `String "dense"); ("vector", `List vector_list)]);
    ("limit", `Int options.so_limit);
    ("with_payload", `Bool true);
  ] @ (match filter with Some f -> [("filter", f)] | None -> [])
    @ (match options.so_score_threshold with
       | Some t -> [("score_threshold", `Float t)]
       | None -> [])
  in
  let payload = `Assoc payload_fields in
  let payload_str = Yojson.Safe.to_string payload in

  (* Write to temp file to avoid shell escaping issues *)
  let temp_file = Filename.temp_file "qdrant_search_" ".json" in
  let oc = open_out temp_file in
  output_string oc payload_str;
  close_out oc;

  let url = Printf.sprintf "%s/collections/%s/points/search"
    config.qd_base_url config.qd_collection in
  let cmd = Printf.sprintf
    "curl -s -X POST '%s' -H 'Content-Type: application/json' -d @'%s'"
    url temp_file
  in

  let ic = Unix.open_process_in cmd in
  let output = In_channel.input_all ic in
  let status = Unix.close_process_in ic in

  (* Clean up temp file *)
  (try Sys.remove temp_file with _ -> ());

  match status with
  | Unix.WEXITED 0 ->
      (try
        let json = Yojson.Safe.from_string output in
        let open Yojson.Safe.Util in
        let results = json |> member "result" |> to_list in
        let parsed = List.filter_map parse_search_result results in
        Ok parsed
      with
      | Yojson.Json_error msg -> Error ("JSON parse error: " ^ msg)
      | Yojson.Safe.Util.Type_error (msg, _) -> Error ("JSON type error: " ^ msg))
  | Unix.WEXITED code -> Error (Printf.sprintf "curl exited with code %d: %s" code output)
  | Unix.WSIGNALED _ -> Error "curl killed by signal"
  | Unix.WSTOPPED _ -> Error "curl stopped"

(** High-level search: embed query text then search.
    Requires embed_config for generating query embedding. *)
let search (config : qdrant_config) (embed_config : embed_config)
    (query_text : string) (options : search_options)
    : (search_result list, string) result =
  (* First, embed the query text *)
  match Embed.embed_text embed_config query_text with
  | Embed_error msg -> Error ("Embedding failed: " ^ msg)
  | Embed_ok query_vector ->
      search_by_vector config query_vector options

(** Scroll all chunk_ids from the collection.
    Used for incremental indexing: diff against parsed chunks. *)
let scroll_all_chunk_ids (config : qdrant_config) : (string list, string) result =
  let rec scroll_loop acc offset =
    let payload_fields = [
      ("limit", `Int 1000);
      ("with_payload", `Assoc [("include", `List [`String "chunk_id"])]);
      ("with_vector", `Bool false);
    ] @ (match offset with
         | Some o -> [("offset", o)]
         | None -> [])
    in
    let payload = `Assoc payload_fields in
    let payload_str = Yojson.Safe.to_string payload in

    let temp_file = Filename.temp_file "qdrant_scroll_" ".json" in
    let oc = open_out temp_file in
    output_string oc payload_str;
    close_out oc;

    let url = Printf.sprintf "%s/collections/%s/points/scroll"
      config.qd_base_url config.qd_collection in
    let cmd = Printf.sprintf
      "curl -s -X POST '%s' -H 'Content-Type: application/json' -d @'%s'"
      url temp_file
    in

    let ic = Unix.open_process_in cmd in
    let output = In_channel.input_all ic in
    let status = Unix.close_process_in ic in
    (try Sys.remove temp_file with _ -> ());

    match status with
    | Unix.WEXITED 0 ->
        (try
          let json = Yojson.Safe.from_string output in
          let open Yojson.Safe.Util in
          let result = json |> member "result" in
          let points = result |> member "points" |> to_list in
          let chunk_ids = List.filter_map (fun p ->
            p |> member "payload" |> member "chunk_id" |> to_string_option
          ) points in
          let next_offset = result |> member "next_page_offset" in
          let new_acc = acc @ chunk_ids in
          if next_offset = `Null then
            Ok new_acc
          else
            scroll_loop new_acc (Some next_offset)
        with
        | Yojson.Json_error msg -> Error ("JSON parse error: " ^ msg)
        | Yojson.Safe.Util.Type_error (msg, _) -> Error ("JSON type error: " ^ msg))
    | Unix.WEXITED code -> Error (Printf.sprintf "curl exited with code %d" code)
    | _ -> Error "curl failed"
  in
  scroll_loop [] None
