(** Roster module — pure functions for session dashboard display *)

open Types

(* ============================================================
   Display Helpers
   ============================================================ *)

(** State indicator symbol for display.
    Reuses the same symbols as Finder.format_result. *)
let state_indicator (state : session_state) : string =
  match state with
  | Working -> "⚙"
  | Needs_attention Done -> "✓"
  | Needs_attention Permission -> "⚠"
  | Needs_attention Question -> "?"

(** Human-readable state label *)
let state_label (state : session_state) : string =
  match state with
  | Working -> "working"
  | Needs_attention Done -> "done"
  | Needs_attention Permission -> "permission"
  | Needs_attention Question -> "question"

(** Shorten cwd by replacing $HOME prefix with ~ *)
let shorten_cwd (home : string) (path : string) : string =
  let home_len = String.length home in
  let path_len = String.length path in
  if path = home then "~"
  else if path_len > home_len
       && String.sub path 0 home_len = home
       && path.[home_len] = '/' then
    "~" ^ String.sub path home_len (path_len - home_len)
  else
    path

(* ============================================================
   Grouping
   ============================================================ *)

(** A group of sessions sharing the same tmux session *)
type roster_group = {
  tmux_session_name : string;
  sessions : session_record list;
}

(** Group session records by tmux session name, preserving order.
    Groups appear in the order their first member appears. *)
let group_by_tmux_session (records : session_record list) : roster_group list =
  let groups : (string * session_record list) list ref = ref [] in
  List.iter (fun (r : session_record) ->
    let name = r.tmux.session in
    match List.assoc_opt name !groups with
    | Some _ ->
        groups := List.map (fun (n, rs) ->
          if n = name then (n, rs @ [r]) else (n, rs)
        ) !groups
    | None ->
        groups := !groups @ [(name, [r])]
  ) records;
  List.map (fun (name, sessions) ->
    { tmux_session_name = name; sessions }
  ) !groups

(* ============================================================
   Human Display
   ============================================================ *)

(** Format a single roster row:
    "  W.P  INDICATOR  ~/shortened/cwd" *)
let format_row (home : string) (record : session_record) : string =
  Printf.sprintf "  %d.%d  %s  %s"
    record.tmux.window record.tmux.pane
    (state_indicator record.state)
    (shorten_cwd home record.cwd)

(** Format an entire roster group (header + rows) *)
let format_group (home : string) (group : roster_group) : string =
  let header = group.tmux_session_name in
  let rows = List.map (format_row home) group.sessions in
  String.concat "\n" (header :: rows)

(** Format the full roster for terminal display *)
let format_roster (home : string) (records : session_record list) : string =
  match records with
  | [] -> "No active sessions."
  | _ ->
      let groups = group_by_tmux_session records in
      String.concat "\n\n" (List.map (format_group home) groups)

(* ============================================================
   JSON Output
   ============================================================ *)

(** Convert a single session record to JSON *)
let session_to_json (record : session_record) : Yojson.Safe.t =
  `Assoc [
    ("pane_id", `String record.tmux.pane_id);
    ("tmux_session", `String record.tmux.session);
    ("window", `Int record.tmux.window);
    ("pane", `Int record.tmux.pane);
    ("location", `String record.tmux.location);
    ("session_id", `String (string_of_session_id record.session_id));
    ("cwd", `String record.cwd);
    ("state", `String (Db.state_to_db record.state));
    ("first_seen", `String record.first_seen);
    ("last_updated", `String record.last_updated);
  ]

(** Convert full roster to JSON *)
let roster_to_json (records : session_record list) : Yojson.Safe.t =
  `List (List.map session_to_json records)
