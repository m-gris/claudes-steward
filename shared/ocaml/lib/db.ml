(** SQLite persistence for session state *)

open Types

(** XDG data directory for all claude-steward runtime state *)
let data_dir () : string =
  Sys.getenv "HOME" ^ "/.local/share/claude-steward"

(** Database path — uses STEWARD_DB env var or XDG default *)
let db_path () : string =
  Sys.getenv_opt "STEWARD_DB"
  |> Option.value ~default:(data_dir () ^ "/steward.db")

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

(** Parse a row from a prepared statement into a session_record *)
let parse_session_row (stmt : Sqlite3.stmt) : session_record option =
  let get_text i = match Sqlite3.column stmt i with
    | Sqlite3.Data.TEXT s -> s
    | _ -> ""
  in
  let get_int i = match Sqlite3.column stmt i with
    | Sqlite3.Data.INT n -> Int64.to_int n
    | _ -> 0
  in
  let get_text_opt i = match Sqlite3.column stmt i with
    | Sqlite3.Data.TEXT s -> Some s
    | _ -> None
  in
  let tmux = {
    pane_id = get_text 0;
    session = get_text 1;
    window = get_int 2;
    pane = get_int 3;
    location = get_text 4;
  } in
  match state_of_db (get_text 8) with
  | None -> None
  | Some state ->
      Some {
        tmux;
        session_id = make_session_id (get_text 5);
        cwd = get_text 6;
        transcript_path = get_text 7;
        state;
        first_seen = get_text 9;
        last_updated = get_text 10;
        last_session_id = get_text_opt 11 |> Option.map make_session_id;
      }

(** Collect rows from a prepared statement into a session_record list *)
let collect_rows (stmt : Sqlite3.stmt) : session_record list =
  let records = ref [] in
  while Sqlite3.step stmt = Sqlite3.Rc.ROW do
    match parse_session_row stmt with
    | Some r -> records := r :: !records
    | None -> ()
  done;
  let _ = Sqlite3.finalize stmt in
  List.rev !records

(** The column list used by all session queries *)
let session_columns = "tmux_pane_id, tmux_session, tmux_window, tmux_pane, tmux_location, session_id, cwd, transcript_path, state, first_seen, last_updated, last_session_id"

(** List all sessions, ordered by tmux location (for roster) *)
let list_sessions (db : Sqlite3.db) : session_record list =
  let sql = Printf.sprintf
    "SELECT %s FROM sessions ORDER BY tmux_session, tmux_window, tmux_pane"
    session_columns
  in
  collect_rows (Sqlite3.prepare db sql)

(** List sessions needing attention, oldest first (for triage) *)
let list_needs_attention (db : Sqlite3.db) : session_record list =
  let sql = Printf.sprintf
    "SELECT %s FROM sessions WHERE state LIKE 'needs_attention:%%' ORDER BY last_updated ASC"
    session_columns
  in
  collect_rows (Sqlite3.prepare db sql)

(** Open database, initialize if needed *)
let open_db () : Sqlite3.db =
  let path = db_path () in
  let dir = Filename.dirname path in
  let rec mkdir_p d =
    if not (Sys.file_exists d) then begin
      mkdir_p (Filename.dirname d);
      Unix.mkdir d 0o755
    end
  in
  mkdir_p dir;
  let db = Sqlite3.db_open path in
  init_db db;
  db
