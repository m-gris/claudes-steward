(** Core domain types for claudes-steward hook handler *)

(* ============================================================
   ID Newtypes - prevent confusion between different ID types
   ============================================================ *)

(** Session ID newtype *)
type session_id = SessionId of string

let make_session_id s = SessionId s
let string_of_session_id (SessionId s) = s

(** Chunk ID newtype *)
type chunk_id = ChunkId of string

let make_chunk_id s = ChunkId s
let string_of_chunk_id (ChunkId s) = s

(** Message UUID newtype *)
type msg_uuid = MsgUuid of string

let make_msg_uuid s = MsgUuid s
let string_of_msg_uuid (MsgUuid s) = s

(* ============================================================
   Hook Event Types
   ============================================================ *)

(** Session start sources *)
type session_start_source =
  | Startup   (** Fresh session start *)
  | Resume    (** Resumed from previous session *)
  | Clear     (** Session cleared *)
  | Compact   (** Session compacted *)

(** Session end reasons *)
type session_end_reason =
  | User_exit     (** User exited the session *)
  | Timeout       (** Session timed out *)
  | Error         (** Session ended due to error *)
  | Other_reason of string  (** Unknown reason *)

(** Convert session_start_source to string *)
let string_of_session_start_source = function
  | Startup -> "startup"
  | Resume -> "resume"
  | Clear -> "clear"
  | Compact -> "compact"

(** Parse session_start_source from string *)
let session_start_source_of_string = function
  | "startup" -> Some Startup
  | "resume" -> Some Resume
  | "clear" -> Some Clear
  | "compact" -> Some Compact
  | _ -> None

(** Convert session_end_reason to string *)
let string_of_session_end_reason = function
  | User_exit -> "user_exit"
  | Timeout -> "timeout"
  | Error -> "error"
  | Other_reason s -> s

(** Parse session_end_reason from string *)
let session_end_reason_of_string = function
  | "user_exit" -> User_exit
  | "timeout" -> Timeout
  | "error" -> Error
  | s -> Other_reason s

(** Notification types from Claude Code.
    Unknown captures unrecognized types for forward compatibility. *)
type notification_type =
  | Elicitation_dialog
  | Permission_prompt
  | Idle_prompt
  | Auth_success
  | Unknown of string  (** Unrecognized notification type *)

(** Hook events that Claude Code sends to us *)
type hook_event =
  | Session_start of { source : session_start_source }
  | Stop of { stop_hook_active : bool }
  | Permission_request of { tool_name : string; tool_input : Yojson.Safe.t }
  | User_prompt_submit of { prompt : string }
  | Session_end of { reason : session_end_reason }
  | Notification of { notification_type : notification_type; message : string }

(** Why a session needs attention *)
type attention_reason =
  | Done        (** Claude finished responding *)
  | Permission  (** Waiting for permission approval *)
  | Question    (** Claude asked a question via AskUserQuestion *)

(** Session state machine *)
type session_state =
  | Working
  | Needs_attention of attention_reason

(** Tmux context captured at hook time *)
type tmux_context = {
  pane_id : string;      (** e.g., "%318" — primary key, stable for pane lifetime *)
  session : string;      (** e.g., "dev" *)
  window : int;          (** e.g., 2 *)
  pane : int;            (** e.g., 1 *)
  location : string;     (** e.g., "dev:2.1" — for display *)
}

(** Full context from Claude Code hook payload *)
type hook_payload = {
  session_id : session_id;
  cwd : string;
  transcript_path : string;
  event : hook_event;
}

(** Session record stored in SQLite *)
type session_record = {
  tmux : tmux_context;
  session_id : session_id;
  cwd : string;
  transcript_path : string;
  state : session_state;
  first_seen : string;    (** ISO8601 timestamp *)
  last_updated : string;  (** ISO8601 timestamp *)
  last_session_id : session_id option;  (** For tracking session_id changes *)
}

(* ============================================================
   Session Finder Types (steward find)
   ============================================================ *)

(** Raw search result from cc-conversation-search --json *)
type search_hit = {
  session_id : session_id;
  title : string;
  project_path : string;
  last_activity : string;  (** ISO8601 timestamp *)
  score : float;           (** Relevance score from search *)
}

(** Running status from state store lookup *)
type running_status =
  | Running of {
      tmux_location : string;   (** e.g., "dev:2.1" *)
      state : session_state;    (** Current state *)
    }
  | Not_running                 (** session_id not in state store *)

(** Merged result: search hit + running status *)
type finder_result = {
  hit : search_hit;
  status : running_status;
}

(** Output of steward find command *)
type finder_output =
  | Found of finder_result list  (** Ordered by relevance *)
  | No_matches
  | Search_error of string

(* ============================================================
   Transcript Parser Types (contextual search indexing)
   ============================================================ *)

(** Message role in conversation *)
type message_role = User | Assistant

(** Convert message_role to string *)
let string_of_message_role = function
  | User -> "user"
  | Assistant -> "assistant"

(** Raw message from transcript JSONL (only user/assistant, others filtered) *)
type transcript_message = {
  msg_type : message_role;     (** User or Assistant *)
  msg_uuid : msg_uuid;         (** Unique message ID *)
  msg_parent_uuid : msg_uuid option;  (** Parent message for threading *)
  msg_session_id : session_id;
  msg_timestamp : string;      (** ISO8601 *)
  msg_cwd : string;
  msg_content : string;        (** Extracted text content *)
}

(** Turn = user message + assistant response (unit for contextual retrieval) *)
type transcript_turn = {
  turn_id : msg_uuid;          (** UUID of user message *)
  turn_session_id : session_id;
  turn_project_path : string;  (** Derived from transcript file path *)
  turn_timestamp : string;     (** Timestamp of user message *)
  turn_user_content : string;
  turn_assistant_content : string;
}

(** Chunk ready for embedding and indexing *)
type index_chunk = {
  chunk_id : chunk_id;         (** Generated unique ID *)
  chunk_session_id : session_id;
  chunk_project_path : string;
  chunk_timestamp : string;
  chunk_content : string;      (** Combined user+assistant content *)
  chunk_context : string option;  (** LLM-generated context (Phase 2) *)
}

(* ============================================================
   Chunk Splitting Configuration
   ============================================================ *)

(** Maximum characters per chunk.
    Based on analysis of 205 failing chunks (see shared/research/CHUNK-SPLITTING-ANALYSIS.md):
    - English prose: ~0.87 tokens/char
    - Log output: ~1.47 tokens/char
    - Stack traces: ~1.70 tokens/char
    - Terminal output with ANSI escapes: ~2.5 tokens/char
    - Emoji-heavy shell prompts: ~2.75+ tokens/char (worst case observed)
    2500 chars * 3.0 = 7500 tokens, leaving ~700 token headroom in 8192 context.
    This headroom accommodates future context prefix (~500 tokens). *)
let max_chunk_chars = 2500

(** Overlap ratio between adjacent chunks (10%).
    Preserves context at chunk boundaries for better retrieval.
    Anthropic recommends 10-20% overlap. *)
let chunk_overlap_ratio = 0.10

(** Calculated overlap in characters (250 for 2500 char chunks) *)
let chunk_overlap_chars = int_of_float (float_of_int max_chunk_chars *. chunk_overlap_ratio)

(** Stride between chunk starts = max_size - overlap (2250 chars) *)
let chunk_stride_chars = max_chunk_chars - chunk_overlap_chars

(* ============================================================
   Embedding Pipeline Types
   ============================================================ *)

(** Supported embedding models - dimensions and context derive from variant *)
type embed_model =
  | Mxbai_embed_large  (** 1024 dims, 512 context *)
  | Nomic_embed_text   (** 768 dims, 8192 context *)

(** Get vector dimensions for a model *)
let dimensions_of = function
  | Mxbai_embed_large -> 1024
  | Nomic_embed_text -> 768

(** Get context length (max tokens) for a model *)
let context_length_of = function
  | Mxbai_embed_large -> 512
  | Nomic_embed_text -> 8192

(** Get Ollama model name for API calls *)
let model_name_of = function
  | Mxbai_embed_large -> "mxbai-embed-large"
  | Nomic_embed_text -> "nomic-embed-text"

(** Embedding provider *)
type embed_provider = Ollama | OpenAI

(** Convert embed_provider to string *)
let string_of_embed_provider = function
  | Ollama -> "ollama"
  | OpenAI -> "openai"

(** Embedding provider configuration *)
type embed_config = {
  embed_provider : embed_provider;
  embed_model : embed_model;  (** Model determines dimensions and context *)
  embed_base_url : string;    (** e.g., "http://localhost:11434" for Ollama *)
}

(** A text with its embedding vector *)
type embedded_chunk = {
  ec_chunk : index_chunk;
  ec_vector : float array;    (** Dense embedding vector *)
}

(** Result of embedding operation *)
type embed_result =
  | Embed_ok of float array
  | Embed_error of string

(* ============================================================
   Sparse Vector Types (BM25)
   ============================================================ *)

(** Sparse vector for BM25 keyword search.
    Indices are token hashes, values are term frequencies.
    When stored in Qdrant with IDF modifier, gives BM25-like ranking. *)
type sparse_vector = {
  sv_indices : int list;    (** Token hash indices *)
  sv_values : float list;   (** Term frequency values *)
}

(* ============================================================
   Search Types
   ============================================================ *)

(** A search result from Qdrant vector query *)
type search_result = {
  sr_chunk_id : chunk_id;
  sr_session_id : session_id;
  sr_project_path : string;
  sr_timestamp : string;
  sr_content : string;
  sr_context : string option;
  sr_score : float;           (** Similarity score (higher = more similar) *)
}

(** Query options *)
type search_options = {
  so_limit : int;                        (** Max results to return *)
  so_project_filter : string option;     (** Filter by project path *)
  so_score_threshold : float option;     (** Minimum score threshold *)
}

(* ============================================================
   Indexer Types (steward-index)
   ============================================================ *)

(** File info from discovery phase *)
type file_info = {
  fi_path : string;           (** Absolute path to JSONL file *)
  fi_mtime : float;           (** Modification time (Unix timestamp) *)
  fi_size : int;              (** File size in bytes *)
}

(** Indexing plan: what needs to be indexed *)
type index_plan = {
  ip_total_files : int;       (** Total transcript files found *)
  ip_total_chunks : int;      (** Total chunks parsed from files *)
  ip_existing_ids : int;      (** Chunk IDs already in Qdrant *)
  ip_new_chunks : int;        (** Chunks to be indexed (total - existing) *)
}

(** Progress state during indexing *)
type index_progress = {
  ipg_embedded : int;         (** Chunks embedded so far *)
  ipg_written : int;          (** Chunks written to Qdrant *)
  ipg_errors : int;           (** Errors encountered *)
  ipg_total : int;            (** Total chunks to process *)
}

(** CLI options for steward-index *)
type index_options = {
  io_parallel : int;          (** Number of parallel embedding workers *)
  io_project_filter : string option;  (** Only index this project path *)
  io_dry_run : bool;          (** Show plan but don't execute *)
  io_batch_size : int;        (** Qdrant write batch size *)
  io_errors_file : string option;  (** Write errors to this JSONL file *)
}

(** Result of indexing operation *)
type index_result =
  | Index_success of { embedded : int; written : int; elapsed : float }
  | Index_partial of { embedded : int; written : int; errors : string list }
  | Index_error of string

(* ============================================================
   Async Embedding Types (Lwt-based parallel embedding)
   ============================================================ *)

(** Pool configuration for parallel embedding *)
type embed_pool_config = {
  epc_workers : int;          (** Number of concurrent workers *)
  epc_embed_config : embed_config;  (** Underlying embed config *)
}

(** Embedding job for the pool *)
type embed_job = {
  ej_chunk : index_chunk;     (** Chunk to embed *)
  ej_id : int;                (** Job ID for ordering *)
}

(** Result of an async embedding job *)
type embed_job_result =
  | Ej_success of embedded_chunk
  | Ej_failure of { chunk : index_chunk; error : string }
