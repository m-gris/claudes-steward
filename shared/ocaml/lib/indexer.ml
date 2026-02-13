(** Indexer orchestration logic. Pure functions for planning and progress. *)

open Types

(** Default index options *)
let default_options : index_options = {
  io_parallel = 4;
  io_project_filter = None;
  io_dry_run = false;
  io_batch_size = 50;
  io_errors_file = None;
}

(** Create an indexing plan from parsed chunks and existing IDs.
    Pure: just computes the diff. *)
let plan_indexing
    ~(total_files : int)
    ~(all_chunks : index_chunk list)
    ~(existing_ids : string list)
    : index_plan * index_chunk list =
  let existing_set = List.fold_left (fun acc id ->
    (* Simple set using sorted list for small-medium sizes *)
    id :: acc
  ) [] existing_ids in
  let is_existing cid = List.mem (string_of_chunk_id cid) existing_set in
  let new_chunks = List.filter (fun c -> not (is_existing c.chunk_id)) all_chunks in
  let plan = {
    ip_total_files = total_files;
    ip_total_chunks = List.length all_chunks;
    ip_existing_ids = List.length existing_ids;
    ip_new_chunks = List.length new_chunks;
  } in
  (plan, new_chunks)

(** Initial progress state *)
let init_progress (total : int) : index_progress = {
  ipg_embedded = 0;
  ipg_written = 0;
  ipg_errors = 0;
  ipg_total = total;
}

(** Update progress after embedding. Pure. *)
let progress_embedded (p : index_progress) (count : int) : index_progress =
  { p with ipg_embedded = p.ipg_embedded + count }

(** Update progress after writing. Pure. *)
let progress_written (p : index_progress) (count : int) : index_progress =
  { p with ipg_written = p.ipg_written + count }

(** Update progress with error. Pure. *)
let progress_error (p : index_progress) : index_progress =
  { p with ipg_errors = p.ipg_errors + 1 }

(** Calculate completion percentage. Pure. *)
let progress_percent (p : index_progress) : float =
  if p.ipg_total = 0 then 100.0
  else float_of_int p.ipg_written /. float_of_int p.ipg_total *. 100.0

(** Split list into batches of given size. Pure. *)
let batch (size : int) (items : 'a list) : 'a list list =
  let rec go acc current current_size = function
    | [] ->
        if current_size > 0 then List.rev (List.rev current :: acc)
        else List.rev acc
    | x :: xs ->
        if current_size >= size then
          go (List.rev current :: acc) [x] 1 xs
        else
          go acc (x :: current) (current_size + 1) xs
  in
  go [] [] 0 items

(** Format progress for display. Pure. *)
let format_progress (p : index_progress) : string =
  Printf.sprintf "[%d/%d] %.1f%% (embedded: %d, errors: %d)"
    p.ipg_written p.ipg_total (progress_percent p)
    p.ipg_embedded p.ipg_errors

(** Format plan for display. Pure. *)
let format_plan (plan : index_plan) : string =
  Printf.sprintf
    "Files: %d, Total chunks: %d, Already indexed: %d, To index: %d"
    plan.ip_total_files plan.ip_total_chunks
    plan.ip_existing_ids plan.ip_new_chunks
