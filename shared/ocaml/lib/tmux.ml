(** Tmux context capture — reads from tmux commands *)

open Types

(** Run a command and return trimmed stdout, or None on failure *)
let run_cmd (cmd : string) : string option =
  try
    let ic = Unix.open_process_in cmd in
    let result = input_line ic in
    let _ = Unix.close_process_in ic in
    Some (String.trim result)
  with _ -> None

(** Check if we're running inside tmux *)
let in_tmux () : bool =
  Sys.getenv_opt "TMUX" |> Option.is_some

(** Capture current tmux context.
    Returns None if not in tmux or if capture fails. *)
let capture () : tmux_context option =
  if not (in_tmux ()) then None
  else
    let pane_id = run_cmd "tmux display-message -p '#D'" in
    let session = run_cmd "tmux display-message -p '#S'" in
    let window = run_cmd "tmux display-message -p '#I'" |> Option.map int_of_string_opt |> Option.join in
    let pane = run_cmd "tmux display-message -p '#P'" |> Option.map int_of_string_opt |> Option.join in
    match (pane_id, session, window, pane) with
    | (Some pane_id, Some session, Some window, Some pane) ->
        let location = Printf.sprintf "%s:%d.%d" session window pane in
        Some { pane_id; session; window; pane; location }
    | _ -> None
