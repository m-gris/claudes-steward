(** Transcript parser - parses Claude Code JSONL transcripts into turns *)

open Types

(** Extract text content from assistant message content array *)
let extract_assistant_content (content : Yojson.Safe.t) : string =
  match content with
  | `List items ->
      items
      |> List.filter_map (fun item ->
          let open Yojson.Safe.Util in
          match item |> member "type" |> to_string_option with
          | Some "text" -> item |> member "text" |> to_string_option
          | _ -> None)
      |> String.concat "\n"
  | `String s -> s
  | _ -> ""

(** Parse a single JSONL line into a transcript_message.
    Returns None for non-conversation types (progress, file-history, etc.) *)
let parse_message (json : Yojson.Safe.t) : transcript_message option =
  let open Yojson.Safe.Util in
  let type_str = json |> member "type" |> to_string_option |> Option.value ~default:"" in
  (* Only process user and assistant messages *)
  match type_str with
  | "user" ->
      let msg_uuid = json |> member "uuid" |> to_string_option |> Option.value ~default:"" |> make_msg_uuid in
      let msg_parent_uuid = json |> member "parentUuid" |> to_string_option |> Option.map make_msg_uuid in
      let msg_session_id = json |> member "sessionId" |> to_string_option |> Option.value ~default:"" |> make_session_id in
      let msg_timestamp = json |> member "timestamp" |> to_string_option |> Option.value ~default:"" in
      let msg_cwd = json |> member "cwd" |> to_string_option |> Option.value ~default:"" in
      let message = json |> member "message" in
      let msg_content = message |> member "content" |> to_string_option |> Option.value ~default:"" in
      Some { msg_type = User; msg_uuid; msg_parent_uuid; msg_session_id; msg_timestamp; msg_cwd; msg_content }
  | "assistant" ->
      let msg_uuid = json |> member "uuid" |> to_string_option |> Option.value ~default:"" |> make_msg_uuid in
      let msg_parent_uuid = json |> member "parentUuid" |> to_string_option |> Option.map make_msg_uuid in
      let msg_session_id = json |> member "sessionId" |> to_string_option |> Option.value ~default:"" |> make_session_id in
      let msg_timestamp = json |> member "timestamp" |> to_string_option |> Option.value ~default:"" in
      let msg_cwd = json |> member "cwd" |> to_string_option |> Option.value ~default:"" in
      let message = json |> member "message" in
      let msg_content = extract_assistant_content (message |> member "content") in
      Some { msg_type = Assistant; msg_uuid; msg_parent_uuid; msg_session_id; msg_timestamp; msg_cwd; msg_content }
  | _ -> None

(** Pair user+assistant messages into turns.
    Orphan messages (user without response) are dropped. *)
let pair_into_turns (messages : transcript_message list) (transcript_path : string) : transcript_turn list =
  (* Build a map from uuid string -> message for quick lookup *)
  let msg_by_uuid =
    messages
    |> List.to_seq
    |> Seq.map (fun m -> (string_of_msg_uuid m.msg_uuid, m))
    |> Hashtbl.of_seq
  in
  (* Find assistant messages and look up their parent (user message) *)
  messages
  |> List.filter_map (fun msg ->
      match msg.msg_type with
      | Assistant ->
          (* Find the parent user message *)
          (match msg.msg_parent_uuid with
          | Some parent_uuid ->
              (match Hashtbl.find_opt msg_by_uuid (string_of_msg_uuid parent_uuid) with
              | Some parent when parent.msg_type = User ->
                  Some {
                    turn_id = parent.msg_uuid;
                    turn_session_id = parent.msg_session_id;
                    turn_project_path = transcript_path;
                    turn_timestamp = parent.msg_timestamp;
                    turn_user_content = parent.msg_content;
                    turn_assistant_content = msg.msg_content;
                  }
              | _ -> None)
          | None -> None)
      | User -> None)
