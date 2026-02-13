(** File discovery for transcript indexing.
    Pure functions for filtering; effects at edges for filesystem access. *)

open Types

(** Default projects directory *)
let default_projects_dir () =
  Filename.concat (Sys.getenv "HOME") ".claude/projects"

(** Get file info for a path. Effect: reads filesystem. *)
let file_info (path : string) : file_info option =
  try
    let stats = Unix.stat path in
    Some {
      fi_path = path;
      fi_mtime = stats.Unix.st_mtime;
      fi_size = stats.Unix.st_size;
    }
  with Unix.Unix_error _ -> None

(** Recursively find all .jsonl files in a directory.
    Effect: reads filesystem. Returns file_info list. *)
let discover_files ?(pattern = "*.jsonl") (root : string) : file_info list =
  let rec walk acc dir =
    try
      let entries = Sys.readdir dir in
      Array.fold_left (fun acc entry ->
        let path = Filename.concat dir entry in
        if Sys.is_directory path then
          walk acc path
        else if Filename.check_suffix entry ".jsonl" then
          match file_info path with
          | Some fi -> fi :: acc
          | None -> acc
        else
          acc
      ) acc entries
    with Sys_error _ -> acc
  in
  let _ = pattern in (* TODO: support glob patterns *)
  walk [] root |> List.rev

(** Check if haystack contains needle. Pure helper. *)
let string_contains ~needle haystack =
  let needle_len = String.length needle in
  let haystack_len = String.length haystack in
  if needle_len > haystack_len then false
  else
    let rec check i =
      if i > haystack_len - needle_len then false
      else if String.sub haystack i needle_len = needle then true
      else check (i + 1)
    in
    check 0

(** Filter files by project path prefix. Pure. *)
let filter_by_project (project_path : string) (files : file_info list) : file_info list =
  (* Claude Code stores transcripts with path like:
     ~/.claude/projects/-Users-marc-myproject/session.jsonl
     So we normalize / to - for matching *)
  let normalized = String.map (fun c -> if c = '/' then '-' else c) project_path in
  List.filter (fun fi ->
    string_contains ~needle:normalized fi.fi_path ||
    string_contains ~needle:project_path fi.fi_path
  ) files

(** Filter files modified after a given timestamp. Pure. *)
let filter_by_mtime (min_mtime : float) (files : file_info list) : file_info list =
  List.filter (fun fi -> fi.fi_mtime >= min_mtime) files

(** Sort files by modification time, newest first. Pure. *)
let sort_by_mtime_desc (files : file_info list) : file_info list =
  List.sort (fun a b -> compare b.fi_mtime a.fi_mtime) files

(** Get total size of files. Pure. *)
let total_size (files : file_info list) : int =
  List.fold_left (fun acc fi -> acc + fi.fi_size) 0 files
