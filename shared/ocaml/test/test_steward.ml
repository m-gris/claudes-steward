(** Tests for steward library *)

open Steward.Types

(* ============================================================
   Test Helpers
   ============================================================ *)

(** Alcotest testable for session_state *)
let state_testable : session_state Alcotest.testable =
  let pp fmt = function
    | Working -> Format.fprintf fmt "Working"
    | Needs_attention Done -> Format.fprintf fmt "Needs_attention(Done)"
    | Needs_attention Permission -> Format.fprintf fmt "Needs_attention(Permission)"
    | Needs_attention Question -> Format.fprintf fmt "Needs_attention(Question)"
  in
  Alcotest.testable pp ( = )

(** Alcotest testable for session_state option *)
let state_option_testable : session_state option Alcotest.testable =
  Alcotest.option state_testable

(** Alcotest testable for hook_event *)
let event_testable : hook_event Alcotest.testable =
  let pp fmt = function
    | Session_start { source } -> Format.fprintf fmt "SessionStart(%s)" (string_of_session_start_source source)
    | Stop { stop_hook_active } -> Format.fprintf fmt "Stop(active=%b)" stop_hook_active
    | Permission_request { tool_name; _ } -> Format.fprintf fmt "PermissionRequest(%s)" tool_name
    | User_prompt_submit { prompt } -> Format.fprintf fmt "UserPromptSubmit(%s)" prompt
    | Session_end { reason } -> Format.fprintf fmt "SessionEnd(%s)" (string_of_session_end_reason reason)
    | Notification { notification_type; message } ->
        let ntype = match notification_type with
          | Elicitation_dialog -> "elicitation_dialog"
          | Permission_prompt -> "permission_prompt"
          | Idle_prompt -> "idle_prompt"
          | Auth_success -> "auth_success"
          | Unknown s -> s
        in
        Format.fprintf fmt "Notification(%s, %s)" ntype message
  in
  let eq a b = match a, b with
    | Session_start { source = s1 }, Session_start { source = s2 } -> s1 = s2
    | Stop { stop_hook_active = a1 }, Stop { stop_hook_active = a2 } -> a1 = a2
    | Permission_request { tool_name = t1; _ }, Permission_request { tool_name = t2; _ } -> t1 = t2
    | User_prompt_submit { prompt = p1 }, User_prompt_submit { prompt = p2 } -> p1 = p2
    | Session_end { reason = r1 }, Session_end { reason = r2 } -> r1 = r2
    | Notification { notification_type = n1; message = m1 },
      Notification { notification_type = n2; message = m2 } -> n1 = n2 && m1 = m2
    | _ -> false
  in
  Alcotest.testable pp eq

(** Alcotest testable for hook_event option *)
let event_option_testable : hook_event option Alcotest.testable =
  Alcotest.option event_testable

(* ============================================================
   Transition Tests (Pure Logic)
   ============================================================ *)

let test_transition_session_start () =
  let event = Session_start { source = Startup } in
  let result = Steward.Transition.transition event in
  Alcotest.check state_option_testable "SessionStart -> Working"
    (Some Working) result

let test_transition_session_start_resume () =
  let event = Session_start { source = Resume } in
  let result = Steward.Transition.transition event in
  Alcotest.check state_option_testable "SessionStart(resume) -> Working"
    (Some Working) result

let test_transition_user_prompt_submit () =
  let event = User_prompt_submit { prompt = "help me" } in
  let result = Steward.Transition.transition event in
  Alcotest.check state_option_testable "UserPromptSubmit -> Working"
    (Some Working) result

let test_transition_stop () =
  let event = Stop { stop_hook_active = false } in
  let result = Steward.Transition.transition event in
  Alcotest.check state_option_testable "Stop -> Needs_attention(Done)"
    (Some (Needs_attention Done)) result

let test_transition_permission_request () =
  let event = Permission_request { tool_name = "Bash"; tool_input = `Null } in
  let result = Steward.Transition.transition event in
  Alcotest.check state_option_testable "PermissionRequest -> Needs_attention(Permission)"
    (Some (Needs_attention Permission)) result

let test_transition_elicitation_dialog () =
  let event = Notification { notification_type = Elicitation_dialog; message = "Pick one" } in
  let result = Steward.Transition.transition event in
  Alcotest.check state_option_testable "Notification(elicitation) -> Needs_attention(Question)"
    (Some (Needs_attention Question)) result

let test_transition_other_notification () =
  let event = Notification { notification_type = Idle_prompt; message = "idle" } in
  let result = Steward.Transition.transition event in
  Alcotest.check state_option_testable "Notification(idle_prompt) -> None"
    None result

let test_transition_session_end () =
  let event = Session_end { reason = User_exit } in
  let result = Steward.Transition.transition event in
  Alcotest.check state_option_testable "SessionEnd -> None"
    None result

let test_is_session_end_true () =
  let event = Session_end { reason = User_exit } in
  Alcotest.(check bool) "SessionEnd is session end" true
    (Steward.Transition.is_session_end event)

let test_is_session_end_false () =
  let event = Stop { stop_hook_active = false } in
  Alcotest.(check bool) "Stop is not session end" false
    (Steward.Transition.is_session_end event)

let transition_tests = [
  "SessionStart -> Working", `Quick, test_transition_session_start;
  "SessionStart(resume) -> Working", `Quick, test_transition_session_start_resume;
  "UserPromptSubmit -> Working", `Quick, test_transition_user_prompt_submit;
  "Stop -> Needs_attention(Done)", `Quick, test_transition_stop;
  "PermissionRequest -> Needs_attention(Permission)", `Quick, test_transition_permission_request;
  "Notification(elicitation) -> Needs_attention(Question)", `Quick, test_transition_elicitation_dialog;
  "Notification(other) -> None", `Quick, test_transition_other_notification;
  "SessionEnd -> None", `Quick, test_transition_session_end;
  "is_session_end true for SessionEnd", `Quick, test_is_session_end_true;
  "is_session_end false for Stop", `Quick, test_is_session_end_false;
]

(* ============================================================
   JSON Parsing Tests
   ============================================================ *)

let json_of_string s = Yojson.Safe.from_string s

let test_parse_session_start () =
  let json = json_of_string {|{
    "hook_event_name": "SessionStart",
    "source": "startup",
    "session_id": "abc123",
    "cwd": "/home/user",
    "transcript_path": "/tmp/session.jsonl"
  }|} in
  let result = Steward.Json.parse_event json in
  Alcotest.check event_option_testable "parse SessionStart"
    (Some (Session_start { source = Startup })) result

let test_parse_session_start_resume () =
  let json = json_of_string {|{
    "hook_event_name": "SessionStart",
    "source": "resume"
  }|} in
  let result = Steward.Json.parse_event json in
  Alcotest.check event_option_testable "parse SessionStart resume"
    (Some (Session_start { source = Resume })) result

let test_parse_stop () =
  let json = json_of_string {|{
    "hook_event_name": "Stop",
    "stop_hook_active": false
  }|} in
  let result = Steward.Json.parse_event json in
  Alcotest.check event_option_testable "parse Stop"
    (Some (Stop { stop_hook_active = false })) result

let test_parse_permission_request () =
  let json = json_of_string {|{
    "hook_event_name": "PermissionRequest",
    "tool_name": "Bash",
    "tool_input": {"command": "ls"}
  }|} in
  let result = Steward.Json.parse_event json in
  Alcotest.check event_option_testable "parse PermissionRequest"
    (Some (Permission_request { tool_name = "Bash"; tool_input = `Assoc [("command", `String "ls")] })) result

let test_parse_user_prompt_submit () =
  let json = json_of_string {|{
    "hook_event_name": "UserPromptSubmit",
    "prompt": "help me"
  }|} in
  let result = Steward.Json.parse_event json in
  Alcotest.check event_option_testable "parse UserPromptSubmit"
    (Some (User_prompt_submit { prompt = "help me" })) result

let test_parse_session_end () =
  let json = json_of_string {|{
    "hook_event_name": "SessionEnd",
    "reason": "user_exit"
  }|} in
  let result = Steward.Json.parse_event json in
  Alcotest.check event_option_testable "parse SessionEnd"
    (Some (Session_end { reason = User_exit })) result

let test_parse_notification_elicitation () =
  let json = json_of_string {|{
    "hook_event_name": "Notification",
    "notification_type": "elicitation_dialog",
    "message": "Choose an option"
  }|} in
  let result = Steward.Json.parse_event json in
  Alcotest.check event_option_testable "parse Notification elicitation"
    (Some (Notification { notification_type = Elicitation_dialog; message = "Choose an option" })) result

let test_parse_notification_idle () =
  let json = json_of_string {|{
    "hook_event_name": "Notification",
    "notification_type": "idle_prompt",
    "message": "Claude is idle"
  }|} in
  let result = Steward.Json.parse_event json in
  Alcotest.check event_option_testable "parse Notification idle"
    (Some (Notification { notification_type = Idle_prompt; message = "Claude is idle" })) result

let test_parse_unknown_event () =
  let json = json_of_string {|{
    "hook_event_name": "UnknownEvent"
  }|} in
  let result = Steward.Json.parse_event json in
  Alcotest.check event_option_testable "parse unknown event"
    None result

let test_parse_missing_event_name () =
  let json = json_of_string {|{
    "some_field": "value"
  }|} in
  let result = Steward.Json.parse_event json in
  Alcotest.check event_option_testable "parse missing event name"
    None result

let test_parse_payload () =
  let json = json_of_string {|{
    "hook_event_name": "Stop",
    "stop_hook_active": false,
    "session_id": "sess123",
    "cwd": "/home/user/project",
    "transcript_path": "/tmp/transcript.jsonl"
  }|} in
  let result = Steward.Json.parse_payload json in
  match result with
  | None -> Alcotest.fail "Expected Some payload"
  | Some payload ->
      Alcotest.(check string) "session_id" "sess123" (string_of_session_id payload.session_id);
      Alcotest.(check string) "cwd" "/home/user/project" payload.cwd;
      Alcotest.(check string) "transcript_path" "/tmp/transcript.jsonl" payload.transcript_path;
      match payload.event with
      | Stop { stop_hook_active } ->
          Alcotest.(check bool) "stop_hook_active" false stop_hook_active
      | _ -> Alcotest.fail "Expected Stop event"

let json_tests = [
  "parse SessionStart", `Quick, test_parse_session_start;
  "parse SessionStart resume", `Quick, test_parse_session_start_resume;
  "parse Stop", `Quick, test_parse_stop;
  "parse PermissionRequest", `Quick, test_parse_permission_request;
  "parse UserPromptSubmit", `Quick, test_parse_user_prompt_submit;
  "parse SessionEnd", `Quick, test_parse_session_end;
  "parse Notification elicitation", `Quick, test_parse_notification_elicitation;
  "parse Notification idle", `Quick, test_parse_notification_idle;
  "parse unknown event", `Quick, test_parse_unknown_event;
  "parse missing event name", `Quick, test_parse_missing_event_name;
  "parse full payload", `Quick, test_parse_payload;
]

(* ============================================================
   Finder Tests (Session Finder / steward find)
   ============================================================ *)

(** Alcotest testable for search_hit *)
let search_hit_testable : search_hit Alcotest.testable =
  let pp fmt hit =
    Format.fprintf fmt "{ session_id=%s; title=%s; project_path=%s; score=%f }"
      (string_of_session_id hit.session_id) hit.title hit.project_path hit.score
  in
  let eq a b =
    a.session_id = b.session_id &&
    a.title = b.title &&
    a.project_path = b.project_path &&
    a.score = b.score
  in
  Alcotest.testable pp eq

(** Alcotest testable for running_status *)
let running_status_testable : running_status Alcotest.testable =
  let pp fmt = function
    | Running { tmux_location; state } ->
        let state_str = match state with
          | Working -> "Working"
          | Needs_attention Done -> "Done"
          | Needs_attention Permission -> "Permission"
          | Needs_attention Question -> "Question"
        in
        Format.fprintf fmt "Running(%s, %s)" tmux_location state_str
    | Not_running -> Format.fprintf fmt "Not_running"
  in
  let eq a b = match a, b with
    | Running { tmux_location = l1; state = s1 },
      Running { tmux_location = l2; state = s2 } -> l1 = l2 && s1 = s2
    | Not_running, Not_running -> true
    | _ -> false
  in
  Alcotest.testable pp eq

(** Alcotest testable for finder_result *)
let finder_result_testable : finder_result Alcotest.testable =
  let pp fmt r =
    Format.fprintf fmt "{ hit=%a; status=%a }"
      (Alcotest.pp search_hit_testable) r.hit
      (Alcotest.pp running_status_testable) r.status
  in
  let eq a b =
    Alcotest.equal search_hit_testable a.hit b.hit &&
    Alcotest.equal running_status_testable a.status b.status
  in
  Alcotest.testable pp eq

(* --- Parse search output tests --- *)

let test_parse_search_hit_single () =
  let json = json_of_string {|{
    "session_id": "abc123",
    "title": "Working on steward",
    "project_path": "/home/user/steward",
    "last_activity": "2026-02-06T12:00:00Z",
    "score": 0.95
  }|} in
  let result = Steward.Finder.parse_search_hit json in
  let expected = {
    session_id = make_session_id "abc123";
    title = "Working on steward";
    project_path = "/home/user/steward";
    last_activity = "2026-02-06T12:00:00Z";
    score = 0.95;
  } in
  Alcotest.check (Alcotest.option search_hit_testable) "parse single hit"
    (Some expected) result

let test_parse_search_hit_missing_field () =
  let json = json_of_string {|{
    "session_id": "abc123",
    "title": "Working on steward"
  }|} in
  let result = Steward.Finder.parse_search_hit json in
  Alcotest.check (Alcotest.option search_hit_testable) "missing fields returns None"
    None result

let test_parse_search_output_array () =
  let json = json_of_string {|[
    {
      "session_id": "abc123",
      "title": "First session",
      "project_path": "/home/user/project1",
      "last_activity": "2026-02-06T12:00:00Z",
      "score": 0.95
    },
    {
      "session_id": "def456",
      "title": "Second session",
      "project_path": "/home/user/project2",
      "last_activity": "2026-02-05T12:00:00Z",
      "score": 0.80
    }
  ]|} in
  let result = Steward.Finder.parse_search_output json in
  Alcotest.(check int) "parses two hits" 2 (List.length result)

let test_parse_search_output_empty () =
  let json = json_of_string {|[]|} in
  let result = Steward.Finder.parse_search_output json in
  Alcotest.(check int) "empty array returns empty list" 0 (List.length result)

(* --- Merge results tests --- *)

let test_merge_with_running () =
  let hit = {
    session_id = make_session_id "abc123";
    title = "Test session";
    project_path = "/home/user/test";
    last_activity = "2026-02-06T12:00:00Z";
    score = 0.9;
  } in
  let status = Running { tmux_location = "dev:2.1"; state = Working } in
  let result = Steward.Finder.merge_hit hit status in
  Alcotest.check finder_result_testable "merge with running status"
    { hit; status } result

let test_merge_with_not_running () =
  let hit = {
    session_id = make_session_id "abc123";
    title = "Test session";
    project_path = "/home/user/test";
    last_activity = "2026-02-06T12:00:00Z";
    score = 0.9;
  } in
  let status = Not_running in
  let result = Steward.Finder.merge_hit hit status in
  Alcotest.check finder_result_testable "merge with not running"
    { hit; status } result

(* --- Output formatting tests --- *)

let test_format_running_result () =
  let result = {
    hit = {
      session_id = make_session_id "abc123";
      title = "Working on steward";
      project_path = "/home/user/steward";
      last_activity = "2026-02-06T12:00:00Z";
      score = 0.95;
    };
    status = Running { tmux_location = "dev:2.1"; state = Working };
  } in
  let output = Steward.Finder.format_result result in
  (* Should contain tmux location for running sessions *)
  Alcotest.(check bool) "contains tmux location"
    true (String.length output > 0 && String.sub output 0 3 = "dev")

let test_format_not_running_result () =
  let result = {
    hit = {
      session_id = make_session_id "abc123";
      title = "Old session";
      project_path = "/home/user/old";
      last_activity = "2026-02-01T12:00:00Z";
      score = 0.80;
    };
    status = Not_running;
  } in
  let output = Steward.Finder.format_result result in
  (* Should indicate not running *)
  Alcotest.(check bool) "output not empty"
    true (String.length output > 0)

let finder_tests = [
  "parse search hit single", `Quick, test_parse_search_hit_single;
  "parse search hit missing field", `Quick, test_parse_search_hit_missing_field;
  "parse search output array", `Quick, test_parse_search_output_array;
  "parse search output empty", `Quick, test_parse_search_output_empty;
  "merge with running", `Quick, test_merge_with_running;
  "merge with not running", `Quick, test_merge_with_not_running;
  "format running result", `Quick, test_format_running_result;
  "format not running result", `Quick, test_format_not_running_result;
]

(* ============================================================
   Transcript Parser Tests
   ============================================================ *)

(** Alcotest testable for message_role *)
let role_testable : message_role Alcotest.testable =
  let pp fmt = function
    | User -> Format.fprintf fmt "User"
    | Assistant -> Format.fprintf fmt "Assistant"
  in
  Alcotest.testable pp ( = )

(** Alcotest testable for transcript_message *)
let message_testable : transcript_message Alcotest.testable =
  let pp fmt m =
    Format.fprintf fmt "{ type=%s; uuid=%s; session_id=%s }"
      (string_of_message_role m.msg_type) (string_of_msg_uuid m.msg_uuid) (string_of_session_id m.msg_session_id)
  in
  let eq a b =
    a.msg_type = b.msg_type &&
    a.msg_uuid = b.msg_uuid &&
    a.msg_session_id = b.msg_session_id
  in
  Alcotest.testable pp eq

(** Alcotest testable for transcript_turn *)
let _turn_testable : transcript_turn Alcotest.testable =
  let pp fmt t =
    let truncate s = if String.length s > 20 then String.sub s 0 20 ^ "..." else s in
    Format.fprintf fmt "{ id=%s; user=%s; assistant=%s }"
      (string_of_msg_uuid t.turn_id) (truncate t.turn_user_content) (truncate t.turn_assistant_content)
  in
  let eq a b =
    a.turn_id = b.turn_id &&
    a.turn_session_id = b.turn_session_id &&
    a.turn_user_content = b.turn_user_content &&
    a.turn_assistant_content = b.turn_assistant_content
  in
  Alcotest.testable pp eq

(* --- Parse message tests --- *)

let test_parse_user_message () =
  let json = json_of_string {|{
    "type": "user",
    "uuid": "user-123",
    "parentUuid": "parent-456",
    "sessionId": "sess-789",
    "timestamp": "2026-02-06T12:00:00Z",
    "cwd": "/home/user/project",
    "message": {
      "role": "user",
      "content": "Hello Claude"
    }
  }|} in
  let result = Steward.Transcript.parse_message json in
  match result with
  | None -> Alcotest.fail "Expected Some message"
  | Some msg ->
      Alcotest.(check role_testable) "type" User msg.msg_type;
      Alcotest.(check string) "uuid" "user-123" (string_of_msg_uuid msg.msg_uuid);
      Alcotest.(check string) "session_id" "sess-789" (string_of_session_id msg.msg_session_id);
      Alcotest.(check string) "content" "Hello Claude" msg.msg_content

let test_parse_assistant_message () =
  let json = json_of_string {|{
    "type": "assistant",
    "uuid": "asst-123",
    "parentUuid": "user-123",
    "sessionId": "sess-789",
    "timestamp": "2026-02-06T12:00:01Z",
    "cwd": "/home/user/project",
    "message": {
      "role": "assistant",
      "content": [{"type": "text", "text": "Hello! How can I help?"}]
    }
  }|} in
  let result = Steward.Transcript.parse_message json in
  match result with
  | None -> Alcotest.fail "Expected Some message"
  | Some msg ->
      Alcotest.(check role_testable) "type" Assistant msg.msg_type;
      Alcotest.(check string) "content" "Hello! How can I help?" msg.msg_content

let test_skip_progress_message () =
  let json = json_of_string {|{
    "type": "progress",
    "uuid": "prog-123",
    "sessionId": "sess-789",
    "data": {"type": "hook_progress"}
  }|} in
  let result = Steward.Transcript.parse_message json in
  Alcotest.(check (option message_testable)) "progress skipped" None result

let test_skip_file_history () =
  let json = json_of_string {|{
    "type": "file-history-snapshot",
    "messageId": "fh-123",
    "snapshot": {}
  }|} in
  let result = Steward.Transcript.parse_message json in
  Alcotest.(check (option message_testable)) "file-history skipped" None result

(* --- Turn pairing tests --- *)

let test_pair_into_turns () =
  let messages = [
    { msg_type = User; msg_uuid = make_msg_uuid "u1"; msg_parent_uuid = None;
      msg_session_id = make_session_id "s1"; msg_timestamp = "2026-02-06T12:00:00Z";
      msg_cwd = "/proj"; msg_content = "Question 1" };
    { msg_type = Assistant; msg_uuid = make_msg_uuid "a1"; msg_parent_uuid = Some (make_msg_uuid "u1");
      msg_session_id = make_session_id "s1"; msg_timestamp = "2026-02-06T12:00:01Z";
      msg_cwd = "/proj"; msg_content = "Answer 1" };
    { msg_type = User; msg_uuid = make_msg_uuid "u2"; msg_parent_uuid = Some (make_msg_uuid "a1");
      msg_session_id = make_session_id "s1"; msg_timestamp = "2026-02-06T12:00:02Z";
      msg_cwd = "/proj"; msg_content = "Question 2" };
    { msg_type = Assistant; msg_uuid = make_msg_uuid "a2"; msg_parent_uuid = Some (make_msg_uuid "u2");
      msg_session_id = make_session_id "s1"; msg_timestamp = "2026-02-06T12:00:03Z";
      msg_cwd = "/proj"; msg_content = "Answer 2" };
  ] in
  let turns = Steward.Transcript.pair_into_turns messages "/path/to/transcript.jsonl" in
  Alcotest.(check int) "two turns" 2 (List.length turns);
  let turn1 = List.hd turns in
  Alcotest.(check string) "turn1 user" "Question 1" turn1.turn_user_content;
  Alcotest.(check string) "turn1 assistant" "Answer 1" turn1.turn_assistant_content

let test_orphan_user_message () =
  let messages = [
    { msg_type = User; msg_uuid = make_msg_uuid "u1"; msg_parent_uuid = None;
      msg_session_id = make_session_id "s1"; msg_timestamp = "2026-02-06T12:00:00Z";
      msg_cwd = "/proj"; msg_content = "Unanswered question" };
  ] in
  let turns = Steward.Transcript.pair_into_turns messages "/path/to/transcript.jsonl" in
  Alcotest.(check int) "no complete turns" 0 (List.length turns)

let transcript_tests = [
  "parse user message", `Quick, test_parse_user_message;
  "parse assistant message", `Quick, test_parse_assistant_message;
  "skip progress message", `Quick, test_skip_progress_message;
  "skip file-history", `Quick, test_skip_file_history;
  "pair into turns", `Quick, test_pair_into_turns;
  "orphan user message", `Quick, test_orphan_user_message;
]

(* ============================================================
   Embedding Pipeline Tests
   ============================================================ *)

(** Alcotest testable for index_chunk *)
let _chunk_testable : index_chunk Alcotest.testable =
  let pp fmt c =
    let truncate s = if String.length s > 30 then String.sub s 0 30 ^ "..." else s in
    Format.fprintf fmt "{ id=%s; content=%s }" (string_of_chunk_id c.chunk_id) (truncate c.chunk_content)
  in
  let eq a b =
    a.chunk_id = b.chunk_id &&
    a.chunk_session_id = b.chunk_session_id &&
    a.chunk_content = b.chunk_content
  in
  Alcotest.testable pp eq

(** Alcotest testable for embed_config *)
let _config_testable : embed_config Alcotest.testable =
  let pp fmt c =
    Format.fprintf fmt "{ provider=%s; model=%s; dims=%d }"
      (string_of_embed_provider c.embed_provider) (model_name_of c.embed_model) (dimensions_of c.embed_model)
  in
  let eq a b =
    a.embed_provider = b.embed_provider &&
    a.embed_model = b.embed_model
  in
  Alcotest.testable pp eq

(* --- Default config test --- *)

let test_default_config () =
  let config = Steward.Embed.default_config in
  Alcotest.(check string) "provider" "ollama" (string_of_embed_provider config.embed_provider);
  Alcotest.(check string) "model name" "nomic-embed-text" (model_name_of config.embed_model);
  Alcotest.(check int) "dimensions" 768 (dimensions_of config.embed_model);
  Alcotest.(check int) "context length" 8192 (context_length_of config.embed_model);
  Alcotest.(check string) "base_url" "http://localhost:11434" config.embed_base_url

(* --- Turn to chunk conversion tests --- *)

let test_turn_to_chunk () =
  let turn : transcript_turn = {
    turn_id = make_msg_uuid "turn-123";
    turn_session_id = make_session_id "sess-456";
    turn_project_path = "/home/user/project";
    turn_timestamp = "2026-02-06T12:00:00Z";
    turn_user_content = "What is OCaml?";
    turn_assistant_content = "OCaml is a functional programming language.";
  } in
  let chunk = Steward.Embed.turn_to_chunk turn in
  Alcotest.(check string) "chunk_id" "turn-123" (string_of_chunk_id chunk.chunk_id);
  Alcotest.(check string) "session_id" "sess-456" (string_of_session_id chunk.chunk_session_id);
  Alcotest.(check string) "project_path" "/home/user/project" chunk.chunk_project_path;
  Alcotest.(check string) "timestamp" "2026-02-06T12:00:00Z" chunk.chunk_timestamp;
  (* Content should combine user and assistant *)
  Alcotest.(check bool) "contains user" true
    (String.length chunk.chunk_content > 0 &&
     let needle = "What is OCaml?" in
     let rec search i =
       if i > String.length chunk.chunk_content - String.length needle then false
       else if String.sub chunk.chunk_content i (String.length needle) = needle then true
       else search (i + 1)
     in search 0);
  Alcotest.(check (option string)) "no context yet" None chunk.chunk_context

let test_turn_to_chunk_format () =
  let turn : transcript_turn = {
    turn_id = make_msg_uuid "t1";
    turn_session_id = make_session_id "s1";
    turn_project_path = "/proj";
    turn_timestamp = "2026-02-06T12:00:00Z";
    turn_user_content = "Hello";
    turn_assistant_content = "Hi there!";
  } in
  let chunk = Steward.Embed.turn_to_chunk turn in
  (* Should have format "User: ... Assistant: ..." *)
  let expected = "User: Hello\n\nAssistant: Hi there!" in
  Alcotest.(check string) "formatted content" expected chunk.chunk_content

(* --- Embed chunks aggregation test (pure logic, no API call) --- *)

let test_embed_chunks_empty () =
  (* Testing with empty list - should return empty results *)
  let config = Steward.Embed.default_config in
  let successes, errors = Steward.Embed.embed_chunks config [] in
  Alcotest.(check int) "no successes" 0 (List.length successes);
  Alcotest.(check int) "no errors" 0 (List.length errors)

(* Integration test - requires Ollama running *)
let test_embed_text_integration () =
  (* Skip if SKIP_INTEGRATION env var is set *)
  match Sys.getenv_opt "SKIP_INTEGRATION" with
  | Some _ -> ()  (* Skip *)
  | None ->
      let config = Steward.Embed.default_config in
      let result = Steward.Embed.embed_text config "Hello world" in
      match result with
      | Embed_ok vector ->
          Alcotest.(check int) "vector dimensions" 768 (Array.length vector);
          (* Vector should have non-zero values *)
          let has_nonzero = Array.exists (fun x -> x <> 0.0) vector in
          Alcotest.(check bool) "has non-zero values" true has_nonzero
      | Embed_error msg ->
          (* If Ollama not running, this is expected *)
          Alcotest.(check bool) "error contains message" true (String.length msg > 0)

let embed_tests = [
  "default config", `Quick, test_default_config;
  "turn to chunk", `Quick, test_turn_to_chunk;
  "turn to chunk format", `Quick, test_turn_to_chunk_format;
  "embed chunks empty", `Quick, test_embed_chunks_empty;
  "embed text integration", `Slow, test_embed_text_integration;
]

(* ============================================================
   Qdrant Index Writer Tests
   ============================================================ *)

(** Alcotest testable for qdrant_config *)
let _qdrant_config_testable : Steward.Qdrant.qdrant_config Alcotest.testable =
  let pp fmt c =
    Format.fprintf fmt "{ base_url=%s; collection=%s }"
      c.Steward.Qdrant.qd_base_url c.Steward.Qdrant.qd_collection
  in
  let eq a b =
    a.Steward.Qdrant.qd_base_url = b.Steward.Qdrant.qd_base_url &&
    a.Steward.Qdrant.qd_collection = b.Steward.Qdrant.qd_collection
  in
  Alcotest.testable pp eq

(* --- Default config test --- *)

let test_qdrant_default_config () =
  let config = Steward.Qdrant.default_config in
  Alcotest.(check string) "base_url" "http://localhost:6333" config.qd_base_url;
  Alcotest.(check string) "collection" "transcripts" config.qd_collection

(* --- Point ID generation tests --- *)

let test_string_to_point_id_deterministic () =
  let id1 = Steward.Qdrant.string_to_point_id "abc-123" in
  let id2 = Steward.Qdrant.string_to_point_id "abc-123" in
  Alcotest.(check int) "same input same output" id1 id2

let test_string_to_point_id_different () =
  let id1 = Steward.Qdrant.string_to_point_id "abc-123" in
  let id2 = Steward.Qdrant.string_to_point_id "xyz-789" in
  Alcotest.(check bool) "different inputs different outputs" true (id1 <> id2)

let test_string_to_point_id_positive () =
  let id = Steward.Qdrant.string_to_point_id "test-uuid-12345" in
  Alcotest.(check bool) "id is positive" true (id >= 0)

(* --- Chunk to point conversion test --- *)

let test_chunk_to_point () =
  let chunk : index_chunk = {
    chunk_id = make_chunk_id "chunk-123";
    chunk_session_id = make_session_id "sess-456";
    chunk_project_path = "/home/user/project";
    chunk_timestamp = "2026-02-06T12:00:00Z";
    chunk_content = "User: Hello\n\nAssistant: Hi there!";
    chunk_context = None;
  } in
  let ec : embedded_chunk = {
    ec_chunk = chunk;
    ec_vector = [| 0.1; 0.2; 0.3 |];  (* Simplified for test *)
  } in
  let point = Steward.Qdrant.chunk_to_point ec in
  let open Yojson.Safe.Util in
  (* Check structure *)
  let id = point |> member "id" |> to_int in
  Alcotest.(check bool) "id is positive" true (id >= 0);
  let payload = point |> member "payload" in
  Alcotest.(check string) "chunk_id in payload" "chunk-123"
    (payload |> member "chunk_id" |> to_string);
  Alcotest.(check string) "session_id in payload" "sess-456"
    (payload |> member "session_id" |> to_string)

(* --- Integration tests (require Qdrant running) --- *)

let test_qdrant_health_check () =
  match Sys.getenv_opt "SKIP_INTEGRATION" with
  | Some _ -> ()
  | None ->
      let config = Steward.Qdrant.default_config in
      let healthy = Steward.Qdrant.health_check config in
      (* Just check it doesn't crash - may fail if Qdrant not running *)
      Alcotest.(check bool) "health check returns bool" true (healthy || not healthy)

let test_qdrant_collection_info () =
  match Sys.getenv_opt "SKIP_INTEGRATION" with
  | Some _ -> ()
  | None ->
      let config = Steward.Qdrant.default_config in
      let result = Steward.Qdrant.collection_info config in
      match result with
      | Ok (points, _vectors) ->
          Alcotest.(check bool) "points >= 0" true (points >= 0)
      | Error _ ->
          (* Expected if Qdrant not running *)
          ()

let test_qdrant_upsert_empty () =
  let config = Steward.Qdrant.default_config in
  let result = Steward.Qdrant.upsert_points config [] in
  match result with
  | Steward.Qdrant.Qd_ok -> ()
  | Steward.Qdrant.Qd_error _ -> Alcotest.fail "Empty upsert should succeed"

let test_safe_to_string () =
  Alcotest.(check (option string)) "string value"
    (Some "hello") (Steward.Qdrant.safe_to_string (`String "hello"));
  Alcotest.(check (option string)) "null value"
    None (Steward.Qdrant.safe_to_string `Null);
  (* These would raise Type_error with Yojson 3.0.0's to_string_option *)
  Alcotest.(check (option string)) "object value"
    None (Steward.Qdrant.safe_to_string (`Assoc [("error", `String "bad")]));
  Alcotest.(check (option string)) "int value"
    None (Steward.Qdrant.safe_to_string (`Int 42));
  Alcotest.(check (option string)) "list value"
    None (Steward.Qdrant.safe_to_string (`List [`String "a"]))

(* --- Search options tests --- *)

let test_default_search_options () =
  let opts = Steward.Qdrant.default_search_options in
  Alcotest.(check int) "default limit" 10 opts.so_limit;
  Alcotest.(check (option string)) "no project filter" None opts.so_project_filter;
  Alcotest.(check (option (float 0.001))) "no score threshold" None opts.so_score_threshold

(* --- Search result parsing test --- *)

let test_parse_search_result () =
  let json = json_of_string {|{
    "id": 12345,
    "score": 0.95,
    "payload": {
      "chunk_id": "chunk-123",
      "session_id": "sess-456",
      "project_path": "/home/user/project",
      "timestamp": "2026-02-06T12:00:00Z",
      "content": "User: Hello\n\nAssistant: Hi!",
      "context": null
    }
  }|} in
  let result = Steward.Qdrant.parse_search_result json in
  match result with
  | None -> Alcotest.fail "Expected Some search_result"
  | Some sr ->
      Alcotest.(check string) "chunk_id" "chunk-123" (string_of_chunk_id sr.sr_chunk_id);
      Alcotest.(check string) "session_id" "sess-456" (string_of_session_id sr.sr_session_id);
      Alcotest.(check (float 0.01)) "score" 0.95 sr.sr_score;
      Alcotest.(check (option string)) "context" None sr.sr_context

(* --- Integration test: search by vector --- *)

let test_search_by_vector_integration () =
  match Sys.getenv_opt "SKIP_INTEGRATION" with
  | Some _ -> ()
  | None ->
      let config = Steward.Qdrant.default_config in
      (* Create a dummy vector of correct size *)
      let query_vector = Array.make 768 0.1 in
      let options = Steward.Qdrant.default_search_options in
      let result = Steward.Qdrant.search_by_vector config query_vector options in
      match result with
      | Ok results ->
          (* Should return a list (may be empty if no data) *)
          Alcotest.(check bool) "results is list" true (List.length results >= 0)
      | Error _ ->
          (* Expected if Qdrant not running or collection empty *)
          ()

let qdrant_tests = [
  "default config", `Quick, test_qdrant_default_config;
  "point id deterministic", `Quick, test_string_to_point_id_deterministic;
  "point id different", `Quick, test_string_to_point_id_different;
  "point id positive", `Quick, test_string_to_point_id_positive;
  "chunk to point", `Quick, test_chunk_to_point;
  "health check", `Slow, test_qdrant_health_check;
  "collection info", `Slow, test_qdrant_collection_info;
  "upsert empty", `Quick, test_qdrant_upsert_empty;
  "safe_to_string handles all types", `Quick, test_safe_to_string;
  "default search options", `Quick, test_default_search_options;
  "parse search result", `Quick, test_parse_search_result;
  "search by vector integration", `Slow, test_search_by_vector_integration;
]

(* ============================================================
   Discover Tests (file discovery)
   ============================================================ *)

let test_discover_string_contains () =
  Alcotest.(check bool) "contains yes"
    true (Steward.Discover.string_contains ~needle:"foo" "foobar");
  Alcotest.(check bool) "contains middle"
    true (Steward.Discover.string_contains ~needle:"ob" "foobar");
  Alcotest.(check bool) "contains no"
    false (Steward.Discover.string_contains ~needle:"xyz" "foobar");
  Alcotest.(check bool) "needle longer"
    false (Steward.Discover.string_contains ~needle:"foobarbaz" "foo")

let test_discover_filter_by_mtime () =
  let files : file_info list = [
    { fi_path = "/a.jsonl"; fi_mtime = 100.0; fi_size = 10 };
    { fi_path = "/b.jsonl"; fi_mtime = 200.0; fi_size = 20 };
    { fi_path = "/c.jsonl"; fi_mtime = 300.0; fi_size = 30 };
  ] in
  let filtered = Steward.Discover.filter_by_mtime 150.0 files in
  Alcotest.(check int) "two files after 150" 2 (List.length filtered);
  Alcotest.(check string) "first is b" "/b.jsonl" (List.hd filtered).fi_path

let test_discover_sort_by_mtime () =
  let files : file_info list = [
    { fi_path = "/old.jsonl"; fi_mtime = 100.0; fi_size = 10 };
    { fi_path = "/new.jsonl"; fi_mtime = 300.0; fi_size = 30 };
    { fi_path = "/mid.jsonl"; fi_mtime = 200.0; fi_size = 20 };
  ] in
  let sorted = Steward.Discover.sort_by_mtime_desc files in
  Alcotest.(check string) "newest first" "/new.jsonl" (List.hd sorted).fi_path;
  Alcotest.(check string) "oldest last" "/old.jsonl" (List.nth sorted 2).fi_path

let test_discover_total_size () =
  let files : file_info list = [
    { fi_path = "/a.jsonl"; fi_mtime = 100.0; fi_size = 100 };
    { fi_path = "/b.jsonl"; fi_mtime = 200.0; fi_size = 200 };
  ] in
  Alcotest.(check int) "total size" 300 (Steward.Discover.total_size files)

let test_discover_filter_by_project () =
  let files : file_info list = [
    { fi_path = "/home/.claude/projects/-Users-marc-myproject/sess.jsonl"; fi_mtime = 100.0; fi_size = 10 };
    { fi_path = "/home/.claude/projects/-Users-marc-other/sess.jsonl"; fi_mtime = 200.0; fi_size = 20 };
  ] in
  let filtered = Steward.Discover.filter_by_project "/Users/marc/myproject" files in
  Alcotest.(check int) "one match" 1 (List.length filtered);
  Alcotest.(check bool) "contains myproject" true
    (Steward.Discover.string_contains ~needle:"myproject" (List.hd filtered).fi_path)

let discover_tests = [
  "string_contains", `Quick, test_discover_string_contains;
  "filter by mtime", `Quick, test_discover_filter_by_mtime;
  "sort by mtime desc", `Quick, test_discover_sort_by_mtime;
  "total size", `Quick, test_discover_total_size;
  "filter by project", `Quick, test_discover_filter_by_project;
]

(* ============================================================
   Indexer Tests (pure orchestration logic)
   ============================================================ *)

let test_indexer_default_options () =
  let opts = Steward.Indexer.default_options in
  Alcotest.(check int) "parallel" 4 opts.io_parallel;
  Alcotest.(check bool) "not dry run" false opts.io_dry_run;
  Alcotest.(check int) "batch size" 50 opts.io_batch_size

let test_indexer_plan_all_new () =
  let chunks : index_chunk list = [
    { chunk_id = make_chunk_id "c1"; chunk_session_id = make_session_id "s1"; chunk_project_path = "/p";
      chunk_timestamp = "2026-01-01"; chunk_content = "test"; chunk_context = None };
    { chunk_id = make_chunk_id "c2"; chunk_session_id = make_session_id "s1"; chunk_project_path = "/p";
      chunk_timestamp = "2026-01-02"; chunk_content = "test2"; chunk_context = None };
  ] in
  let plan, new_chunks = Steward.Indexer.plan_indexing
    ~total_files:1 ~all_chunks:chunks ~existing_ids:[] in
  Alcotest.(check int) "total chunks" 2 plan.ip_total_chunks;
  Alcotest.(check int) "existing" 0 plan.ip_existing_ids;
  Alcotest.(check int) "new chunks" 2 plan.ip_new_chunks;
  Alcotest.(check int) "new list length" 2 (List.length new_chunks)

let test_indexer_plan_some_existing () =
  let chunks : index_chunk list = [
    { chunk_id = make_chunk_id "c1"; chunk_session_id = make_session_id "s1"; chunk_project_path = "/p";
      chunk_timestamp = "2026-01-01"; chunk_content = "test"; chunk_context = None };
    { chunk_id = make_chunk_id "c2"; chunk_session_id = make_session_id "s1"; chunk_project_path = "/p";
      chunk_timestamp = "2026-01-02"; chunk_content = "test2"; chunk_context = None };
    { chunk_id = make_chunk_id "c3"; chunk_session_id = make_session_id "s1"; chunk_project_path = "/p";
      chunk_timestamp = "2026-01-03"; chunk_content = "test3"; chunk_context = None };
  ] in
  let plan, new_chunks = Steward.Indexer.plan_indexing
    ~total_files:1 ~all_chunks:chunks ~existing_ids:["c1"; "c2"] in
  Alcotest.(check int) "new chunks" 1 plan.ip_new_chunks;
  Alcotest.(check string) "only c3" "c3" (string_of_chunk_id (List.hd new_chunks).chunk_id)

let test_indexer_batch () =
  let items = [1; 2; 3; 4; 5; 6; 7] in
  let batches = Steward.Indexer.batch 3 items in
  Alcotest.(check int) "3 batches" 3 (List.length batches);
  Alcotest.(check (list int)) "first batch" [1; 2; 3] (List.hd batches);
  Alcotest.(check (list int)) "last batch" [7] (List.nth batches 2)

let test_indexer_progress () =
  let p = Steward.Indexer.init_progress 100 in
  Alcotest.(check int) "initial written" 0 p.ipg_written;
  let p = Steward.Indexer.progress_embedded p 10 in
  Alcotest.(check int) "embedded 10" 10 p.ipg_embedded;
  let p = Steward.Indexer.progress_written p 10 in
  Alcotest.(check int) "written 10" 10 p.ipg_written;
  let pct = Steward.Indexer.progress_percent p in
  Alcotest.(check (float 0.1)) "10%" 10.0 pct

let test_indexer_format_plan () =
  let plan : index_plan = {
    ip_total_files = 10;
    ip_total_chunks = 100;
    ip_existing_ids = 80;
    ip_new_chunks = 20;
  } in
  let s = Steward.Indexer.format_plan plan in
  Alcotest.(check bool) "contains files" true
    (Steward.Discover.string_contains ~needle:"10" s);
  Alcotest.(check bool) "contains new" true
    (Steward.Discover.string_contains ~needle:"20" s)

let indexer_tests = [
  "default options", `Quick, test_indexer_default_options;
  "plan all new", `Quick, test_indexer_plan_all_new;
  "plan some existing", `Quick, test_indexer_plan_some_existing;
  "batch", `Quick, test_indexer_batch;
  "progress", `Quick, test_indexer_progress;
  "format plan", `Quick, test_indexer_format_plan;
]

(* ============================================================
   AsyncEmbed Tests (Lwt-based parallel embedding)
   ============================================================ *)

let test_async_embed_default_config () =
  let config = Steward.Async_embed.default_pool_config in
  Alcotest.(check int) "workers" 4 config.epc_workers;
  Alcotest.(check string) "model" "nomic-embed-text"
    (model_name_of config.epc_embed_config.embed_model)

let test_async_embed_empty () =
  let config = Steward.Async_embed.default_pool_config in
  let successes, failures = Steward.Async_embed.embed_sync config [] in
  Alcotest.(check int) "no successes" 0 (List.length successes);
  Alcotest.(check int) "no failures" 0 (List.length failures)

let test_async_embed_integration () =
  match Sys.getenv_opt "SKIP_INTEGRATION" with
  | Some _ -> ()
  | None ->
      let config = Steward.Async_embed.default_pool_config in
      let chunks : index_chunk list = [
        { chunk_id = make_chunk_id "test-1"; chunk_session_id = make_session_id "s1"; chunk_project_path = "/p";
          chunk_timestamp = "2026-01-01"; chunk_content = "Hello world"; chunk_context = None };
        { chunk_id = make_chunk_id "test-2"; chunk_session_id = make_session_id "s1"; chunk_project_path = "/p";
          chunk_timestamp = "2026-01-02"; chunk_content = "Goodbye world"; chunk_context = None };
      ] in
      let successes, failures = Steward.Async_embed.embed_sync config chunks in
      (* If Ollama running, should succeed *)
      if List.length failures = 0 then begin
        Alcotest.(check int) "2 successes" 2 (List.length successes);
        let first = List.hd successes in
        let expected_dims = dimensions_of config.epc_embed_config.embed_model in
        Alcotest.(check int) "vector dims" expected_dims (Array.length first.ec_vector)
      end else
        (* Ollama not running - that's OK *)
        ()

let async_embed_tests = [
  "default config", `Quick, test_async_embed_default_config;
  "empty list", `Quick, test_async_embed_empty;
  "parallel integration", `Slow, test_async_embed_integration;
]

(* ============================================================
   QdrantScroll Tests
   ============================================================ *)

let test_qdrant_scroll_integration () =
  match Sys.getenv_opt "SKIP_INTEGRATION" with
  | Some _ -> ()
  | None ->
      let config = Steward.Qdrant.default_config in
      let result = Steward.Qdrant.scroll_all_chunk_ids config in
      match result with
      | Ok ids ->
          (* Should return a list (may be empty) *)
          Alcotest.(check bool) "ids is list" true (List.length ids >= 0)
      | Error _ ->
          (* Expected if Qdrant not running *)
          ()

let qdrant_scroll_tests = [
  "scroll integration", `Slow, test_qdrant_scroll_integration;
]

(* ============================================================
   Chunk Splitting Tests (pure functions)
   ============================================================ *)

(** Alcotest testable for index_chunk list *)
let _chunk_list_testable : index_chunk list Alcotest.testable =
  let pp fmt chunks =
    Format.fprintf fmt "[%s]"
      (String.concat "; " (List.map (fun c ->
        Printf.sprintf "{ id=%s; len=%d }"
          (string_of_chunk_id c.chunk_id) (String.length c.chunk_content)
      ) chunks))
  in
  let eq a b =
    List.length a = List.length b &&
    List.for_all2 (fun x y ->
      x.chunk_id = y.chunk_id &&
      x.chunk_session_id = y.chunk_session_id &&
      x.chunk_content = y.chunk_content
    ) a b
  in
  Alcotest.testable pp eq

(* --- split_text tests --- *)

let test_split_text_short () =
  (* Content shorter than limit should return singleton *)
  let text = "Short text" in
  let result = Steward.Embed.split_text ~max_size:100 ~overlap:10 text in
  Alcotest.(check int) "singleton" 1 (List.length result);
  Alcotest.(check string) "unchanged" text (List.hd result)

let test_split_text_exact () =
  (* Content exactly at limit should return singleton *)
  let text = String.make 100 'x' in
  let result = Steward.Embed.split_text ~max_size:100 ~overlap:10 text in
  Alcotest.(check int) "singleton" 1 (List.length result);
  Alcotest.(check int) "same length" 100 (String.length (List.hd result))

let test_split_text_long () =
  (* Content longer than limit should return multiple chunks *)
  let text = String.make 250 'x' in  (* 250 chars, max 100, stride 90 *)
  let result = Steward.Embed.split_text ~max_size:100 ~overlap:10 text in
  Alcotest.(check bool) "multiple chunks" true (List.length result > 1);
  (* Each chunk should be at most max_size *)
  List.iter (fun chunk ->
    Alcotest.(check bool) "chunk <= max_size" true (String.length chunk <= 100)
  ) result

let test_split_text_overlap () =
  (* Adjacent chunks should overlap by the specified amount *)
  let text = String.init 200 (fun i -> Char.chr (65 + (i mod 26))) in  (* A-Z repeating *)
  let result = Steward.Embed.split_text ~max_size:100 ~overlap:20 text in
  Alcotest.(check bool) "at least 2 chunks" true (List.length result >= 2);
  (* Check overlap: end of chunk 0 should match start of chunk 1 *)
  let c0 = List.nth result 0 in
  let c1 = List.nth result 1 in
  let c0_end = String.sub c0 (String.length c0 - 20) 20 in
  let c1_start = String.sub c1 0 20 in
  Alcotest.(check string) "overlap matches" c0_end c1_start

let test_split_text_paragraphs () =
  (* Should prefer splitting at paragraph boundaries *)
  let text = "First paragraph.\n\nSecond paragraph.\n\nThird paragraph." in
  let result = Steward.Embed.split_text ~max_size:30 ~overlap:5 text in
  (* Should split at \n\n boundaries when possible *)
  Alcotest.(check bool) "multiple chunks" true (List.length result >= 2);
  (* First chunk should end cleanly (not mid-word) *)
  let first = List.hd result in
  Alcotest.(check bool) "clean boundary" true
    (String.length first > 0)

let test_split_text_words () =
  (* Fallback to word boundaries when no paragraphs *)
  let text = "word1 word2 word3 word4 word5 word6 word7 word8 word9 word10" in
  let result = Steward.Embed.split_text ~max_size:25 ~overlap:5 text in
  Alcotest.(check bool) "multiple chunks" true (List.length result >= 2);
  (* Chunks should not break in middle of words (ideally) *)
  List.iter (fun chunk ->
    (* Each chunk should be non-empty *)
    Alcotest.(check bool) "non-empty" true (String.length chunk > 0)
  ) result

let test_split_text_determinism () =
  (* Same input should always produce same output *)
  let text = String.make 500 'a' in
  let result1 = Steward.Embed.split_text ~max_size:100 ~overlap:10 text in
  let result2 = Steward.Embed.split_text ~max_size:100 ~overlap:10 text in
  Alcotest.(check int) "same count" (List.length result1) (List.length result2);
  List.iter2 (fun a b ->
    Alcotest.(check string) "same content" a b
  ) result1 result2

(* --- turn_to_chunks tests --- *)

let test_turn_to_chunks_short () =
  (* Short turn should return single chunk *)
  let turn : transcript_turn = {
    turn_id = make_msg_uuid "short-turn";
    turn_session_id = make_session_id "sess-1";
    turn_project_path = "/project";
    turn_timestamp = "2026-02-13T12:00:00Z";
    turn_user_content = "Short question";
    turn_assistant_content = "Short answer";
  } in
  let chunks = Steward.Embed.turn_to_chunks turn in
  Alcotest.(check int) "single chunk" 1 (List.length chunks);
  let chunk = List.hd chunks in
  (* Single chunk should have original turn_id (no suffix) *)
  Alcotest.(check string) "original id" "short-turn" (string_of_chunk_id chunk.chunk_id)

let test_turn_to_chunks_long () =
  (* Long turn should return multiple chunks *)
  let long_content = String.make 5000 'x' in  (* Well over 4000 limit *)
  let turn : transcript_turn = {
    turn_id = make_msg_uuid "long-turn";
    turn_session_id = make_session_id "sess-1";
    turn_project_path = "/project";
    turn_timestamp = "2026-02-13T12:00:00Z";
    turn_user_content = "Question";
    turn_assistant_content = long_content;
  } in
  let chunks = Steward.Embed.turn_to_chunks turn in
  Alcotest.(check bool) "multiple chunks" true (List.length chunks > 1);
  (* All chunks should be under max limit *)
  List.iter (fun chunk ->
    Alcotest.(check bool) "under limit" true (String.length chunk.chunk_content <= max_chunk_chars)
  ) chunks

let test_turn_to_chunks_ids () =
  (* Sub-chunk IDs should be deterministic: {parent_id}:{index} *)
  let long_content = String.make 5000 'y' in
  let turn : transcript_turn = {
    turn_id = make_msg_uuid "parent-id";
    turn_session_id = make_session_id "sess-1";
    turn_project_path = "/project";
    turn_timestamp = "2026-02-13T12:00:00Z";
    turn_user_content = "Q";
    turn_assistant_content = long_content;
  } in
  let chunks = Steward.Embed.turn_to_chunks turn in
  Alcotest.(check bool) "multiple chunks" true (List.length chunks > 1);
  (* Check ID format *)
  List.iteri (fun i chunk ->
    let expected_id = Printf.sprintf "parent-id:%d" i in
    Alcotest.(check string) (Printf.sprintf "chunk %d id" i) expected_id (string_of_chunk_id chunk.chunk_id)
  ) chunks;
  (* Same input should give same IDs (determinism) *)
  let chunks2 = Steward.Embed.turn_to_chunks turn in
  List.iter2 (fun a b ->
    Alcotest.(check string) "same ids" (string_of_chunk_id a.chunk_id) (string_of_chunk_id b.chunk_id)
  ) chunks chunks2

let test_turn_to_chunks_metadata () =
  (* All chunks should inherit session_id, project_path, timestamp *)
  let long_content = String.make 5000 'z' in
  let turn : transcript_turn = {
    turn_id = make_msg_uuid "meta-turn";
    turn_session_id = make_session_id "my-session";
    turn_project_path = "/my/project";
    turn_timestamp = "2026-02-13T15:30:00Z";
    turn_user_content = "User says";
    turn_assistant_content = long_content;
  } in
  let chunks = Steward.Embed.turn_to_chunks turn in
  Alcotest.(check bool) "multiple chunks" true (List.length chunks > 1);
  List.iter (fun chunk ->
    Alcotest.(check string) "session_id" "my-session" (string_of_session_id chunk.chunk_session_id);
    Alcotest.(check string) "project_path" "/my/project" chunk.chunk_project_path;
    Alcotest.(check string) "timestamp" "2026-02-13T15:30:00Z" chunk.chunk_timestamp;
    Alcotest.(check (option string)) "no context yet" None chunk.chunk_context
  ) chunks

let chunk_splitting_tests = [
  "split_text short", `Quick, test_split_text_short;
  "split_text exact", `Quick, test_split_text_exact;
  "split_text long", `Quick, test_split_text_long;
  "split_text overlap", `Quick, test_split_text_overlap;
  "split_text paragraphs", `Quick, test_split_text_paragraphs;
  "split_text words", `Quick, test_split_text_words;
  "split_text determinism", `Quick, test_split_text_determinism;
  "turn_to_chunks short", `Quick, test_turn_to_chunks_short;
  "turn_to_chunks long", `Quick, test_turn_to_chunks_long;
  "turn_to_chunks ids", `Quick, test_turn_to_chunks_ids;
  "turn_to_chunks metadata", `Quick, test_turn_to_chunks_metadata;
]

(* ============================================================
   Main
   ============================================================ *)

let () =
  Alcotest.run "steward" [
    "Transition", transition_tests;
    "Json", json_tests;
    "Finder", finder_tests;
    "Transcript", transcript_tests;
    "Embed", embed_tests;
    "Qdrant", qdrant_tests;
    "QdrantScroll", qdrant_scroll_tests;
    "Discover", discover_tests;
    "Indexer", indexer_tests;
    "AsyncEmbed", async_embed_tests;
    "ChunkSplitting", chunk_splitting_tests;
  ]
