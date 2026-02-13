(** Session finder module - bridges transcript search with running sessions *)

open Types

(** Parse a single search hit from cc-conversation-search JSON *)
let parse_search_hit (json : Yojson.Safe.t) : search_hit option =
  let open Yojson.Safe.Util in
  try
    let session_id = json |> member "session_id" |> to_string |> make_session_id in
    let title = json |> member "title" |> to_string in
    let project_path = json |> member "project_path" |> to_string in
    let last_activity = json |> member "last_activity" |> to_string in
    let score = json |> member "score" |> to_float in
    Some { session_id; title; project_path; last_activity; score }
  with
  | Type_error _ -> None

(** Parse array of search results *)
let parse_search_output (json : Yojson.Safe.t) : search_hit list =
  match json with
  | `List items ->
      List.filter_map parse_search_hit items
  | _ -> []

(** Merge a search hit with its running status *)
let merge_hit (hit : search_hit) (status : running_status) : finder_result =
  { hit; status }

(** Format a single finder result for display *)
let format_result (result : finder_result) : string =
  match result.status with
  | Running { tmux_location; state } ->
      let state_indicator = match state with
        | Working -> "⚙"
        | Needs_attention Done -> "✓"
        | Needs_attention Permission -> "⚠"
        | Needs_attention Question -> "?"
      in
      Printf.sprintf "%s %s  %s (%s)"
        tmux_location state_indicator result.hit.title result.hit.project_path
  | Not_running ->
      Printf.sprintf "⊘ %s (%s) [not running]"
        result.hit.title result.hit.project_path
