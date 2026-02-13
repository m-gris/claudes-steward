(** steward-hook: Claude Code hook handler for claudes-steward

    Reads JSON from stdin, captures tmux context, updates session state in SQLite.
    Called by Claude Code on lifecycle events (SessionStart, Stop, PermissionRequest, etc.)

    IMPORTANT: Must be fast and never fail with exit code 2 (which would block Claude).
*)

let () =
  (* Read JSON from stdin *)
  let json_str = In_channel.(input_all stdin) in
  let json =
    try Yojson.Safe.from_string json_str
    with _ -> exit 0  (* Invalid JSON — fail silently *)
  in

  (* Parse payload *)
  let payload = Steward.Json.parse_payload json in
  match payload with
  | None -> exit 0  (* Unknown event — skip *)
  | Some payload ->
      (* Check if we're in tmux *)
      let tmux = Steward.Tmux.capture () in
      match tmux with
      | None -> exit 0  (* Not in tmux — skip state tracking *)
      | Some tmux ->
          (* Open database *)
          let db = Steward.Db.open_db () in

          (* Handle session end (delete) *)
          if Steward.Transition.is_session_end payload.event then begin
            Steward.Db.delete_session db tmux.pane_id;
            ignore (Sqlite3.db_close db);
            exit 0
          end;

          (* Compute state transition *)
          let new_state = Steward.Transition.transition payload.event in
          match new_state with
          | None ->
              ignore (Sqlite3.db_close db);
              exit 0  (* No state change *)
          | Some state ->
              Steward.Db.upsert_session db tmux payload state;
              ignore (Sqlite3.db_close db);
              exit 0
