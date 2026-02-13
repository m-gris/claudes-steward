(** Async embedding with Lwt for parallel processing *)

open Types
open Lwt.Syntax

(** Default pool config *)
let default_pool_config : embed_pool_config = {
  epc_workers = 4;
  epc_embed_config = Embed.default_config;
}

(** Embed a single chunk asynchronously using Lwt.
    Uses Cohttp for async HTTP. *)
let embed_chunk_async (config : embed_config) (job : embed_job)
    : embed_job_result Lwt.t =
  let chunk = job.ej_chunk in
  (* Build the JSON payload *)
  let payload = `Assoc [
    ("model", `String (model_name_of config.embed_model));
    ("input", `String chunk.chunk_content);
  ] in
  let payload_str = Yojson.Safe.to_string payload in
  let uri = Uri.of_string (config.embed_base_url ^ "/api/embed") in
  let body = Cohttp_lwt.Body.of_string payload_str in
  let headers = Cohttp.Header.of_list [("Content-Type", "application/json")] in

  Lwt.catch
    (fun () ->
      let* (resp, body) = Cohttp_lwt_unix.Client.post ~headers ~body uri in
      let* body_str = Cohttp_lwt.Body.to_string body in
      let status = Cohttp.Response.status resp in
      if Cohttp.Code.(is_success (code_of_status status)) then
        try
          let json = Yojson.Safe.from_string body_str in
          let open Yojson.Safe.Util in
          let embeddings = json |> member "embeddings" |> to_list in
          match embeddings with
          | [] -> Lwt.return (Ej_failure { chunk; error = "No embeddings returned" })
          | first :: _ ->
              let vector = first |> to_list |> List.map to_float |> Array.of_list in
              let ec = { ec_chunk = chunk; ec_vector = vector } in
              Lwt.return (Ej_success ec)
        with e ->
          Lwt.return (Ej_failure { chunk; error = Printexc.to_string e })
      else
        (* Include response body for debugging HTTP errors *)
        let body_preview =
          if String.length body_str > 200
          then String.sub body_str 0 200 ^ "..."
          else body_str
        in
        Lwt.return (Ej_failure {
          chunk;
          error = Printf.sprintf "HTTP %d: %s" (Cohttp.Code.code_of_status status) body_preview
        }))
    (fun e ->
      Lwt.return (Ej_failure { chunk; error = Printexc.to_string e }))

(** Embed multiple chunks in parallel with bounded concurrency.
    Returns results in order of completion. *)
let embed_parallel (config : embed_pool_config) (chunks : index_chunk list)
    : embed_job_result list Lwt.t =
  let jobs = List.mapi (fun i c -> { ej_chunk = c; ej_id = i }) chunks in
  (* Use Lwt_list.map_p with a semaphore for bounded concurrency *)
  let sem = Lwt_mutex.create () in
  let active = ref 0 in
  let max_active = config.epc_workers in

  let process_job job =
    (* Simple concurrency control *)
    let rec wait_for_slot () =
      let* () = Lwt_mutex.lock sem in
      if !active >= max_active then begin
        Lwt_mutex.unlock sem;
        let* () = Lwt_unix.sleep 0.01 in
        wait_for_slot ()
      end else begin
        incr active;
        Lwt_mutex.unlock sem;
        Lwt.return_unit
      end
    in
    let* () = wait_for_slot () in
    let* result = embed_chunk_async config.epc_embed_config job in
    let* () = Lwt_mutex.lock sem in
    decr active;
    Lwt_mutex.unlock sem;
    Lwt.return result
  in

  Lwt_list.map_p process_job jobs

(** Convenience function: embed chunks and separate successes from failures *)
let embed_chunks_parallel (config : embed_pool_config) (chunks : index_chunk list)
    : (embedded_chunk list * (index_chunk * string) list) Lwt.t =
  let* results = embed_parallel config chunks in
  let successes, failures = List.partition_map (function
    | Ej_success ec -> Either.Left ec
    | Ej_failure { chunk; error } -> Either.Right (chunk, error)
  ) results in
  Lwt.return (successes, failures)

(** Run embedding synchronously (for testing/CLI) *)
let embed_sync (config : embed_pool_config) (chunks : index_chunk list)
    : embedded_chunk list * (index_chunk * string) list =
  Lwt_main.run (embed_chunks_parallel config chunks)
