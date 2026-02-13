(** Pure state transition function — the core logic *)

open Types

(** Compute new state from hook event.
    Returns None for Session_end (delete from DB) or irrelevant events. *)
let transition (event : hook_event) : session_state option =
  match event with
  | Session_start _ -> Some Working
  | User_prompt_submit _ -> Some Working
  | Stop _ -> Some (Needs_attention Done)
  | Permission_request _ -> Some (Needs_attention Permission)
  | Notification { notification_type = Elicitation_dialog; _ } ->
      Some (Needs_attention Question)
  | Notification _ -> None  (* Other notifications don't change state *)
  | Session_end _ -> None   (* Signal to delete from DB *)

(** Check if event signals session should be removed from tracking *)
let is_session_end (event : hook_event) : bool =
  match event with
  | Session_end _ -> true
  | _ -> false
