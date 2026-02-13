(** JSON parsing for Claude Code hook payloads *)

open Types

(** Parse notification_type from string.
    Unknown types are captured explicitly for forward compatibility. *)
let parse_notification_type (s : string) : notification_type =
  match s with
  | "elicitation_dialog" -> Elicitation_dialog
  | "permission_prompt" -> Permission_prompt
  | "idle_prompt" -> Idle_prompt
  | "auth_success" -> Auth_success
  | unknown -> Unknown unknown

(** Parse hook event from JSON *)
let parse_event (json : Yojson.Safe.t) : hook_event option =
  let open Yojson.Safe.Util in
  let event_name = json |> member "hook_event_name" |> to_string_option in
  match event_name with
  | Some "SessionStart" ->
      let source_str = json |> member "source" |> to_string_option |> Option.value ~default:"startup" in
      let source = session_start_source_of_string source_str |> Option.value ~default:Startup in
      Some (Session_start { source })
  | Some "Stop" ->
      let active = json |> member "stop_hook_active" |> to_bool_option |> Option.value ~default:false in
      Some (Stop { stop_hook_active = active })
  | Some "PermissionRequest" ->
      let tool_name = json |> member "tool_name" |> to_string_option |> Option.value ~default:"unknown" in
      let tool_input = json |> member "tool_input" in
      Some (Permission_request { tool_name; tool_input })
  | Some "UserPromptSubmit" ->
      let prompt = json |> member "prompt" |> to_string_option |> Option.value ~default:"" in
      Some (User_prompt_submit { prompt })
  | Some "SessionEnd" ->
      let reason_str = json |> member "reason" |> to_string_option |> Option.value ~default:"other" in
      let reason = session_end_reason_of_string reason_str in
      Some (Session_end { reason })
  | Some "Notification" ->
      let ntype = json |> member "notification_type" |> to_string_option |> Option.value ~default:"" in
      let message = json |> member "message" |> to_string_option |> Option.value ~default:"" in
      Some (Notification { notification_type = parse_notification_type ntype; message })
  | _ -> None

(** Parse full hook payload from JSON *)
let parse_payload (json : Yojson.Safe.t) : hook_payload option =
  let open Yojson.Safe.Util in
  match parse_event json with
  | None -> None
  | Some event ->
      let session_id = json |> member "session_id" |> to_string_option |> Option.value ~default:"" |> make_session_id in
      let cwd = json |> member "cwd" |> to_string_option |> Option.value ~default:"" in
      let transcript_path = json |> member "transcript_path" |> to_string_option |> Option.value ~default:"" in
      Some { session_id; cwd; transcript_path; event }
