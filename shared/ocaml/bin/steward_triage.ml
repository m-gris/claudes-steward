(** steward-triage: Navigate sessions needing attention, prioritized

    Usage: steward-triage [COMMAND] [OPTIONS]

    Commands:
      list [--json]   Show ranked needs-attention sessions (default)
      next            Switch tmux to highest-priority pane

    Priority order: Permission > Question > Done, oldest first within tier.
*)

type command = List_cmd | Next_cmd

let json_output = ref false
let command = ref List_cmd

let usage () =
  Printf.eprintf "Usage: steward-triage [list [--json] | next]\n";
  exit 0

let parse_args () =
  let args = Array.to_list Sys.argv |> List.tl in
  let rec parse = function
    | [] -> ()
    | "list" :: rest -> command := List_cmd; parse rest
    | "next" :: rest -> command := Next_cmd; parse rest
    | "--json" :: rest -> json_output := true; parse rest
    | "--help" :: _ | "-h" :: _ -> usage ()
    | arg :: _ ->
        Printf.eprintf "Error: Unknown argument: %s\n" arg;
        exit 1
  in
  parse args

let () =
  parse_args ();
  let db = Steward.Db.open_db () in
  let records = Steward.Db.list_needs_attention db in
  let _ = Sqlite3.db_close db in
  match !command with
  | List_cmd ->
      if !json_output then
        let sorted = Steward.Triage.sort_by_priority records in
        print_endline (Yojson.Safe.pretty_to_string (Steward.Triage.triage_to_json sorted))
      else
        let home = Sys.getenv_opt "HOME" |> Option.value ~default:"" in
        let now = Steward.Db.now_iso8601 () in
        print_endline (Steward.Triage.format_triage home now records)
  | Next_cmd ->
      match Steward.Triage.next records with
      | None ->
          print_endline "No sessions need attention.";
          exit 0
      | Some record ->
          let pane_id = record.tmux.pane_id in
          if Steward.Tmux.switch_to_pane pane_id then
            Printf.printf "Switched to %s (%s %s)\n"
              record.tmux.location
              (Steward.Roster.state_indicator record.state)
              (Steward.Roster.state_label record.state)
          else begin
            Printf.eprintf "Failed to switch to pane %s\n" pane_id;
            exit 1
          end
