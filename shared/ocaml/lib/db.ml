(** SQLite persistence for session state *)

open Types

(** Database path — uses STEWARD_DB env var or default *)
let db_path () : string =
  Sys.getenv_opt "STEWARD_DB"
  |> Option.value ~default:(Sys.getenv "HOME" ^ "/DATA_PROG/AI-TOOLING/claudes-steward/shared/steward.db")

(** Initialize database with schema if needed *)
let init_db (db : Sqlite3.db) : unit =
  let schema = {|
    CREATE TABLE IF NOT EXISTS sessions (
      tmux_pane_id    TEXT PRIMARY KEY,
      tmux_session    TEXT NOT NULL,
      tmux_window     INTEGER NOT NULL,
      tmux_pane       INTEGER NOT NULL,
      tmux_location   TEXT NOT NULL,
      session_id      TEXT,
      cwd             TEXT,
      transcript_path TEXT,
      state           TEXT NOT NULL DEFAULT 'working',
      first_seen      TEXT NOT NULL,
      last_updated    TEXT NOT NULL,
      last_session_id TEXT
    );
    CREATE INDEX IF NOT EXISTS idx_session_id ON sessions(session_id);
    CREATE INDEX IF NOT EXISTS idx_state ON sessions(state);
  |} in
  let _ = Sqlite3.exec db schema in
  ()

(** Convert session_state to single DB string.
    Encoding makes illegal states unrepresentable in the DB. *)
let state_to_db (state : session_state) : string =
  match state with
  | Working -> "working"
  | Needs_attention Done -> "needs_attention:done"
  | Needs_attention Permission -> "needs_attention:permission"
  | Needs_attention Question -> "needs_attention:question"

(** Parse DB string back to session_state.
    Returns None for invalid/unknown encodings. *)
let state_of_db (s : string) : session_state option =
  match s with
  | "working" -> Some Working
  | "needs_attention:done" -> Some (Needs_attention Done)
  | "needs_attention:permission" -> Some (Needs_attention Permission)
  | "needs_attention:question" -> Some (Needs_attention Question)
  | _ -> None

(** Current timestamp in ISO8601 format *)
let now_iso8601 () : string =
  let t = Unix.gettimeofday () in
  let tm = Unix.gmtime t in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
    (tm.Unix.tm_year + 1900)
    (tm.Unix.tm_mon + 1)
    tm.Unix.tm_mday
    tm.Unix.tm_hour
    tm.Unix.tm_min
    tm.Unix.tm_sec

(** Upsert session record *)
let upsert_session (db : Sqlite3.db) (tmux : tmux_context) (payload : hook_payload) (state : session_state) : unit =
  let state_str = state_to_db state in
  let now = now_iso8601 () in
  let sid = string_of_session_id payload.session_id in
  let sql = Printf.sprintf {|
    INSERT INTO sessions (
      tmux_pane_id, tmux_session, tmux_window, tmux_pane, tmux_location,
      session_id, cwd, transcript_path, state,
      first_seen, last_updated, last_session_id
    ) VALUES ('%s', '%s', %d, %d, '%s', '%s', '%s', '%s', '%s', '%s', '%s', '%s')
    ON CONFLICT(tmux_pane_id) DO UPDATE SET
      tmux_session = '%s',
      tmux_window = %d,
      tmux_pane = %d,
      tmux_location = '%s',
      last_session_id = CASE WHEN session_id != '%s' THEN session_id ELSE last_session_id END,
      session_id = '%s',
      cwd = '%s',
      transcript_path = '%s',
      state = '%s',
      last_updated = '%s';
  |}
    (* INSERT values *)
    tmux.pane_id tmux.session tmux.window tmux.pane tmux.location
    sid payload.cwd payload.transcript_path state_str
    now now sid
    (* UPDATE values *)
    tmux.session tmux.window tmux.pane tmux.location
    sid sid
    payload.cwd payload.transcript_path state_str now
  in
  let _ = Sqlite3.exec db sql in
  ()

(** Delete session by tmux pane ID *)
let delete_session (db : Sqlite3.db) (pane_id : string) : unit =
  let sql = Printf.sprintf "DELETE FROM sessions WHERE tmux_pane_id = '%s';" pane_id in
  let _ = Sqlite3.exec db sql in
  ()

(** Open database, initialize if needed *)
let open_db () : Sqlite3.db =
  let path = db_path () in
  let db = Sqlite3.db_open path in
  init_db db;
  db
