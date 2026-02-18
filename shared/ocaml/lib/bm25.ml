(** BM25 sparse vector generation for keyword search.

    Tokenizes text and computes term frequency vectors for use with
    Qdrant's sparse vector support. When combined with Qdrant's IDF
    modifier, this gives BM25-like keyword matching alongside dense
    semantic search. *)

open Types

(** Tokenize text into normalized terms.
    Lowercases, splits on non-alphanumeric boundaries,
    filters tokens shorter than 2 characters. *)
let tokenize (text : string) : string list =
  let lower = String.lowercase_ascii text in
  let buf = Buffer.create 64 in
  let tokens = ref [] in
  let flush () =
    let token = Buffer.contents buf in
    if String.length token >= 2 then
      tokens := token :: !tokens;
    Buffer.clear buf
  in
  String.iter (fun c ->
    if (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') then
      Buffer.add_char buf c
    else
      flush ()
  ) lower;
  flush ();
  List.rev !tokens

(** Hash a token string to a positive integer index.
    Uses FNV-1a for good distribution across the sparse vector space. *)
let hash_token (token : string) : int =
  let hash = ref 2166136261 in
  String.iter (fun c ->
    hash := !hash lxor (Char.code c);
    hash := !hash * 16777619;
  ) token;
  abs (!hash)

(** Compute term frequency counts from a token list.
    Returns (token_hash, count) pairs sorted by index for determinism. *)
let term_frequencies (tokens : string list) : (int * float) list =
  let tbl = Hashtbl.create 256 in
  List.iter (fun token ->
    let h = hash_token token in
    let count = try Hashtbl.find tbl h with Not_found -> 0.0 in
    Hashtbl.replace tbl h (count +. 1.0)
  ) tokens;
  Hashtbl.fold (fun k v acc -> (k, v) :: acc) tbl []
  |> List.sort (fun (a, _) (b, _) -> compare a b)

(** Generate a sparse vector from text.
    Tokenizes, counts term frequencies, returns indices and values.
    Designed for Qdrant's sparse vector format with IDF modifier. *)
let sparse_vector_of_text (text : string) : sparse_vector =
  let tokens = tokenize text in
  let freqs = term_frequencies tokens in
  { sv_indices = List.map fst freqs;
    sv_values = List.map snd freqs }
