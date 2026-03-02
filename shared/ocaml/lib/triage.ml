(** Triage module — pure functions for needs-attention prioritization *)

open Types

(* ============================================================
   Priority Tiers
   ============================================================ *)

(** Priority tier for triage ordering *)
type priority_tier =
  | Tier_permission  (** Highest: blocking on permission *)
  | Tier_question    (** Medium: waiting for user answer *)
  | Tier_done        (** Lowest: finished, just needs review *)

(** Map an attention reason to its priority tier *)
let tier_of_reason (reason : attention_reason) : priority_tier =
  match reason with
  | Permission -> Tier_permission
  | Question -> Tier_question
  | Done -> Tier_done

(** Numeric rank for sorting (lower = higher priority) *)
let rank_of_tier (tier : priority_tier) : int =
  match tier with
  | Tier_permission -> 0
  | Tier_question -> 1
  | Tier_done -> 2

(** Rank a session_state for sorting.
    Working sessions get rank 3 (lowest) so they sort last. *)
let rank_of_state (state : session_state) : int =
  match state with
  | Needs_attention reason -> rank_of_tier (tier_of_reason reason)
  | Working -> 3

(** Sort needs-attention sessions by priority tier, then by last_updated (oldest first).
    Stable sort: within the same tier, preserves chronological order. *)
let sort_by_priority (records : session_record list) : session_record list =
  List.sort (fun (a : session_record) (b : session_record) ->
    let rank_cmp = compare (rank_of_state a.state) (rank_of_state b.state) in
    if rank_cmp <> 0 then rank_cmp
    else compare a.last_updated b.last_updated
  ) records

(** Get the next session to attend to, or None if list is empty *)
let next (records : session_record list) : session_record option =
  match sort_by_priority records with
  | [] -> None
  | first :: _ -> Some first

(* ============================================================
   Time Helpers (pure — no system clock)
   ============================================================ *)

(** Parse a subset of ISO8601 timestamps: "YYYY-MM-DDThh:mm:ssZ"
    Returns Unix timestamp as float, or None on parse failure. *)
let parse_iso8601 (s : string) : float option =
  try
    Scanf.sscanf s "%4d-%2d-%2dT%2d:%2d:%2dZ"
      (fun year month day hour min sec ->
        let tm = {
          Unix.tm_sec = sec; tm_min = min; tm_hour = hour;
          tm_mday = day; tm_mon = month - 1; tm_year = year - 1900;
          tm_wday = 0; tm_yday = 0; tm_isdst = false;
        } in
        let (time, _) = Unix.mktime tm in
        Some time)
  with _ -> None

(* ============================================================
   Human Display
   ============================================================ *)

(** Format how long a session has been waiting.
    Pure function: takes both timestamps as strings (ISO8601). *)
let format_waiting (last_updated : string) (now : string) : string =
  match (parse_iso8601 last_updated, parse_iso8601 now) with
  | (Some t_updated, Some t_now) ->
      let diff = t_now -. t_updated in
      let minutes = int_of_float (diff /. 60.0) in
      if minutes < 60 then Printf.sprintf "%d min" minutes
      else
        let hours = minutes / 60 in
        let remaining_min = minutes mod 60 in
        if remaining_min = 0 then Printf.sprintf "%dh" hours
        else Printf.sprintf "%dh %dmin" hours remaining_min
  | _ -> "?"

(** Reason string from a needs-attention state *)
let reason_label (state : session_state) : string =
  match state with
  | Needs_attention reason ->
      (match reason with
       | Permission -> "permission"
       | Question -> "question"
       | Done -> "done")
  | Working -> "working"

(** Format a single triage entry for terminal display *)
let format_entry (home : string) (now : string) (record : session_record) : string =
  Printf.sprintf "  %s  %s  %s  %s  (%s)"
    record.tmux.location
    (Roster.state_indicator record.state)
    (reason_label record.state)
    (Roster.shorten_cwd home record.cwd)
    (format_waiting record.last_updated now)

(** Format the full triage list for terminal display *)
let format_triage (home : string) (now : string) (records : session_record list) : string =
  match records with
  | [] -> "No sessions need attention."
  | _ ->
      let sorted = sort_by_priority records in
      let entries = List.map (format_entry home now) sorted in
      String.concat "\n" entries

(* ============================================================
   JSON Output
   ============================================================ *)

(** Convert a single triage entry to JSON *)
let entry_to_json (record : session_record) : Yojson.Safe.t =
  `Assoc [
    ("pane_id", `String record.tmux.pane_id);
    ("location", `String record.tmux.location);
    ("session_id", `String (string_of_session_id record.session_id));
    ("cwd", `String record.cwd);
    ("reason", `String (reason_label record.state));
    ("last_updated", `String record.last_updated);
  ]

(** Convert full triage list to JSON *)
let triage_to_json (records : session_record list) : Yojson.Safe.t =
  `List (List.map entry_to_json records)
