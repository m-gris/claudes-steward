(** steward-roster: Dashboard showing all active Claude Code sessions

    Usage: steward-roster [OPTIONS]

    Options:
      --json    Output as JSON

    Displays sessions grouped by tmux session, with state indicators:
      ⚙  Working        ✓  Done
      ⚠  Permission     ?  Question
*)

let json_output = ref false

let parse_args () =
  let args = Array.to_list Sys.argv |> List.tl in
  let rec parse = function
    | [] -> ()
    | "--json" :: rest -> json_output := true; parse rest
    | "--help" :: _ | "-h" :: _ ->
        Printf.eprintf "Usage: steward-roster [--json]\n";
        exit 0
    | arg :: _ ->
        Printf.eprintf "Error: Unknown option: %s\n" arg;
        exit 1
  in
  parse args

let () =
  parse_args ();
  let db = Steward.Db.open_db () in
  let records = Steward.Db.list_sessions db in
  let _ = Sqlite3.db_close db in
  if !json_output then
    print_endline (Yojson.Safe.pretty_to_string (Steward.Roster.roster_to_json records))
  else
    let home = Sys.getenv_opt "HOME" |> Option.value ~default:"" in
    print_endline (Steward.Roster.format_roster home records)
