(** Embedding pipeline - generates vector embeddings for transcript chunks *)

open Types

(** Default configuration for local Ollama *)
let default_config : embed_config = {
  embed_provider = Ollama;
  embed_model = Nomic_embed_text;  (* 768 dims, 8192 context, 3.4x faster *)
  embed_base_url = "http://localhost:11434";
}

(** Call Ollama embedding API via curl.
    Returns the embedding vector or an error. *)
let embed_text (config : embed_config) (text : string) : embed_result =
  (* Build the JSON payload *)
  let payload = `Assoc [
    ("model", `String (model_name_of config.embed_model));
    ("input", `String text);
  ] in
  let payload_str = Yojson.Safe.to_string payload in

  (* Write to temp file to avoid shell escaping issues *)
  let temp_file = Filename.temp_file "embed_" ".json" in
  let oc = open_out temp_file in
  output_string oc payload_str;
  close_out oc;

  (* Build curl command using file *)
  let url = config.embed_base_url ^ "/api/embed" in
  let cmd = Printf.sprintf
    "curl -s -X POST '%s' -H 'Content-Type: application/json' -d @'%s'"
    url temp_file
  in

  (* Execute curl *)
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
        (* Ollama returns: {"embeddings": [[0.1, 0.2, ...]]} *)
        let embeddings = json |> member "embeddings" |> to_list in
        match embeddings with
        | [] -> Embed_error "No embeddings returned"
        | first :: _ ->
            let vector = first |> to_list |> List.map to_float |> Array.of_list in
            Embed_ok vector
      with
      | Yojson.Json_error msg -> Embed_error ("JSON parse error: " ^ msg)
      | Yojson.Safe.Util.Type_error (msg, _) -> Embed_error ("JSON type error: " ^ msg))
  | Unix.WEXITED code -> Embed_error (Printf.sprintf "curl exited with code %d" code)
  | Unix.WSIGNALED _ -> Embed_error "curl killed by signal"
  | Unix.WSTOPPED _ -> Embed_error "curl stopped"

(* ============================================================
   Chunk Splitting - pure functions for splitting long text
   ============================================================ *)

(** Find the last occurrence of a substring before a given position.
    Returns the start index of the substring, or None if not found. *)
let rfind_before (needle : string) (text : string) (before : int) : int option =
  let needle_len = String.length needle in
  if needle_len = 0 || before < needle_len then None
  else
    let rec search i =
      if i < 0 then None
      else if String.sub text i needle_len = needle then Some i
      else search (i - 1)
    in
    search (min (before - needle_len) (String.length text - needle_len))

(** Find a good split point near the target position.
    Prefers paragraph boundaries (\n\n), then word boundaries (space).
    Falls back to hard split at target if no good boundary found. *)
let find_split_point (text : string) (target : int) : int =
  let len = String.length text in
  if target >= len then len
  else
    (* Try paragraph boundary first *)
    match rfind_before "\n\n" text target with
    | Some pos when pos > target / 2 -> pos + 2  (* Include the newlines in first chunk *)
    | _ ->
        (* Try word boundary *)
        match rfind_before " " text target with
        | Some pos when pos > target / 2 -> pos + 1  (* Include space in first chunk *)
        | _ -> target  (* Hard split *)

(** Split text into chunks with overlap.
    Pure function: text in, string list out. *)
let split_text ~(max_size : int) ~(overlap : int) (text : string) : string list =
  let len = String.length text in
  if len <= max_size then [text]
  else
    let stride = max_size - overlap in
    let rec loop acc pos =
      if pos >= len then List.rev acc
      else
        let remaining = len - pos in
        if remaining <= max_size then
          (* Last chunk - take everything *)
          List.rev (String.sub text pos remaining :: acc)
        else
          (* Find a good split point *)
          let split_target = pos + max_size in
          let split_at = find_split_point text split_target in
          let chunk_end = min split_at len in
          let chunk = String.sub text pos (chunk_end - pos) in
          (* Next position: stride forward from current, not from split point *)
          let next_pos = pos + stride in
          loop (chunk :: acc) next_pos
    in
    loop [] 0

(** Convert a transcript turn into an index chunk (single chunk, original behavior) *)
let turn_to_chunk (turn : transcript_turn) : index_chunk =
  let chunk_content = Printf.sprintf "User: %s\n\nAssistant: %s"
    turn.turn_user_content turn.turn_assistant_content
  in
  {
    chunk_id = make_chunk_id (string_of_msg_uuid turn.turn_id);
    chunk_session_id = turn.turn_session_id;
    chunk_project_path = turn.turn_project_path;
    chunk_timestamp = turn.turn_timestamp;
    chunk_content;
    chunk_context = None;  (* Phase 2 will add context *)
  }

(** Convert a transcript turn into one or more index chunks.
    Splits long turns using max_chunk_chars and chunk_overlap_chars constants.
    Short turns return a single chunk with the original turn_id.
    Long turns return multiple chunks with IDs: {turn_id}:0, {turn_id}:1, etc. *)
let turn_to_chunks (turn : transcript_turn) : index_chunk list =
  let content = Printf.sprintf "User: %s\n\nAssistant: %s"
    turn.turn_user_content turn.turn_assistant_content
  in
  let turn_id_str = string_of_msg_uuid turn.turn_id in
  let text_chunks = split_text ~max_size:max_chunk_chars ~overlap:chunk_overlap_chars content in
  match text_chunks with
  | [single] ->
      (* Single chunk - use original turn_id *)
      [{
        chunk_id = make_chunk_id turn_id_str;
        chunk_session_id = turn.turn_session_id;
        chunk_project_path = turn.turn_project_path;
        chunk_timestamp = turn.turn_timestamp;
        chunk_content = single;
        chunk_context = None;
      }]
  | chunks ->
      (* Multiple chunks - append index to ID *)
      List.mapi (fun i chunk_content ->
        {
          chunk_id = make_chunk_id (Printf.sprintf "%s:%d" turn_id_str i);
          chunk_session_id = turn.turn_session_id;
          chunk_project_path = turn.turn_project_path;
          chunk_timestamp = turn.turn_timestamp;
          chunk_content;
          chunk_context = None;
        }
      ) chunks

(** Embed a single chunk *)
let embed_chunk (config : embed_config) (chunk : index_chunk) : (embedded_chunk, string) result =
  match embed_text config chunk.chunk_content with
  | Embed_ok vector -> Ok { ec_chunk = chunk; ec_vector = vector }
  | Embed_error msg -> Error msg

(** Embed multiple chunks, collecting results.
    Returns (successes, errors) pair. *)
let embed_chunks (config : embed_config) (chunks : index_chunk list)
    : embedded_chunk list * (chunk_id * string) list =
  List.fold_left (fun (successes, errors) chunk ->
    match embed_chunk config chunk with
    | Ok ec -> (ec :: successes, errors)
    | Error msg -> (successes, (chunk.chunk_id, msg) :: errors)
  ) ([], []) chunks
  |> fun (s, e) -> (List.rev s, List.rev e)
