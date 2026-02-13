# Contextual Transcript Search

> "Hey Claude, remember when we discussed X?" → finds it, responds naturally

## Problem

Dozens of Claude Code sessions across tmux. Can't remember where a discussion happened. Current tools (cc-conversation-search, claude-history) are keyword-based, return noisy results, require manual sifting.

## Goal

Natural language search over Claude Code transcripts with:
- Semantic understanding (not just keywords)
- High precision (LLM re-ranking)
- Natural response ("Yes, we discussed that in 3 places...")
- Optional navigation to running sessions

## Non-Goals (v1)

- Real-time indexing (batch is fine)
- Multi-user / collaboration
- Non-Claude-Code transcripts

---

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                      INDEX PIPELINE                          │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  ~/.claude/projects/**/*.jsonl                               │
│           │                                                  │
│           ▼                                                  │
│  ┌─────────────────┐                                        │
│  │  Chunk + Parse  │  Split transcripts into chunks          │
│  └────────┬────────┘                                        │
│           │                                                  │
│           ▼                                                  │
│  ┌─────────────────┐                                        │
│  │ Context Enrich  │  LLM adds: "This chunk discusses..."   │
│  │   (any LLM)     │  (Anthropic, OpenAI, local Llama, etc) │
│  └────────┬────────┘                                        │
│           │                                                  │
│           ▼                                                  │
│  ┌─────────────────┐                                        │
│  │    Embed        │  Dense vectors (OpenAI, Cohere, local) │
│  └────────┬────────┘                                        │
│           │                                                  │
│           ▼                                                  │
│  ┌─────────────────┐                                        │
│  │    Qdrant       │  Hybrid: dense vectors + sparse BM25   │
│  └─────────────────┘                                        │
│                                                              │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│                      QUERY PIPELINE (MCP)                    │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  User: "remember that state machine discussion?"             │
│           │                                                  │
│           ▼                                                  │
│  ┌─────────────────┐                                        │
│  │   Claude Code   │  Receives query, calls MCP tool         │
│  └────────┬────────┘                                        │
│           │                                                  │
│           ▼                                                  │
│  ┌─────────────────┐                                        │
│  │  MCP Tool       │                                        │
│  │  ┌───────────┐  │                                        │
│  │  │  Qdrant   │  │  Hybrid search → top 20                │
│  │  │  Hybrid   │  │                                        │
│  │  └─────┬─────┘  │                                        │
│  │        │        │                                        │
│  │        ▼        │                                        │
│  │  ┌───────────┐  │                                        │
│  │  │  steward  │  │  Enrich with tmux location if running  │
│  │  │  lookup   │  │                                        │
│  │  └───────────┘  │                                        │
│  └────────┬────────┘                                        │
│           │  Returns: [{chunk, score, session_id, tmux?}]   │
│           ▼                                                  │
│  ┌─────────────────┐                                        │
│  │   Claude Code   │  Reranks + responds NATURALLY          │
│  │   (no extra     │  "Yes! We discussed that in 3 places..." │
│  │    LLM call)    │                                        │
│  └─────────────────┘                                        │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

---

## LLM Touchpoints

**Key insight:** When used via MCP in Claude Code, Claude IS the reranker and responder. No separate LLM calls needed at query time.

| Stage | When | LLM? | Notes |
|-------|------|------|-------|
| Context enrichment | Index time | Yes (cheap) | Haiku/GPT-4-mini, one-time |
| Embedding | Index + query | No | Embedding model, not LLM |
| Qdrant search | Query time | No | Pure retrieval |
| Reranking | Query time | **Claude (free)** | Already in the loop via MCP |
| Response | Query time | **Claude (free)** | Already in the loop via MCP |

**CLI path:** If using `steward search` without Claude, may need optional LLM rerank/response.

**MCP path:** Just return structured results. Claude handles the rest.

---

## Technology Choices

### Search Backend: Qdrant

**Why Qdrant:**
- Rust, 29k stars, production-grade
- Native hybrid search (sparse + dense in one query)
- Filterable HNSW (filter by project, date without post-filtering)
- Built-in reranking support
- Quantization (75% memory reduction)
- Single binary, easy deployment

**Alternatives considered:**
- Meilisearch: Hybrid is newer, less RAG-focused
- Elasticsearch: Heavy, Java, overkill
- SQLite + FTS5: No vector support (what cc-conversation-search uses)

### Embeddings: Configurable

Options ranked by quality/speed tradeoff:
1. OpenAI text-embedding-3-large (best quality, API cost)
2. Cohere embed-v3 (good quality, cheaper)
3. BGE-large via ONNX (local, no API cost, slower)
4. rust-bert MiniLM (fastest local, lower quality)

### Orchestration: OCaml or Rust

**OCaml (current steward language):**
- Call Qdrant via REST/gRPC
- Shell out to LLM CLI or use HTTP API
- Keeps unified codebase

**Rust (alternative):**
- Native Qdrant client
- rust-bert for local embeddings
- More complex build

Recommendation: **OCaml for orchestration**, Qdrant handles the heavy lifting.

---

## Contextual Retrieval (Anthropic's Innovation)

Standard RAG loses context when chunking. A chunk saying "Revenue grew 3%" doesn't know which company or when.

**Fix:** Before embedding, prepend context:

```
[Context: This is from a Claude Code session on 2026-02-06 in the
claudes-steward project. The user and Claude were discussing hook
state machine design for tracking session attention states.]

Original chunk content here...
```

**Results (Anthropic's benchmarks):**
| Approach | Retrieval Failure Rate |
|----------|------------------------|
| Standard RAG | 5.7% |
| + Contextual Embeddings | 3.7% (-35%) |
| + BM25 hybrid | 2.9% (-49%) |
| + Reranking | 1.9% (-67%) |

Source: https://www.anthropic.com/news/contextual-retrieval

---

## Data Model

### Transcript Chunk

```
{
  "id": "chunk_abc123",
  "session_id": "6f46bd78-87d9-...",
  "project_path": "/Users/marc/steward",
  "timestamp": "2026-02-06T14:30:00Z",
  "role": "assistant",  // or "user"
  "content": "The state machine has two states: Working and NeedsAttention...",
  "context": "Discussion of hook-based session state tracking in claudes-steward project",
  "chunk_index": 12,
  "message_id": "msg_xyz"
}
```

### Qdrant Collection Schema

```
vectors:
  dense: 1536 dims (or model-specific)
  sparse: BM25 token weights

payload:
  session_id, project_path, timestamp, role, content, context

indexes:
  - project_path (keyword)
  - timestamp (range)
  - session_id (keyword)
```

---

## Interface Options

### 1. MCP Tool (Claude Code native)

Claude can call `search_transcripts` directly:

```
User: "remember when we discussed that book?"

Claude: [calls search_transcripts("book discussion recommendation")]

        "Yes! We discussed 'Designing Data-Intensive Applications'
        in the steward project on Feb 4th. You were comparing its
        approach to state machines with what we were building.

        That session is still running at dev:2.1 - want me to
        switch there?"
```

### 2. CLI Tool

```bash
steward search "state machine discussion"
# Returns formatted results with session IDs

steward search "that book" --navigate
# Opens fzf picker, jumps to selected tmux pane
```

### 3. TUI (future)

Interactive search with preview, like claude-history but smarter.

---

## Implementation Phases

### Phase 1: Core Search
- [ ] Qdrant setup (Docker or binary)
- [ ] Transcript parser (JSONL → chunks)
- [ ] Basic indexing (embeddings only, no context enrichment)
- [ ] Query endpoint (vector search)
- [ ] CLI: `steward search <query>`

### Phase 2: Hybrid + Context
- [ ] Add BM25 sparse vectors
- [ ] Context enrichment pipeline (LLM adds context per chunk)
- [ ] Hybrid search (dense + sparse)
- [ ] Basic reranking

### Phase 3: Integration
- [ ] MCP tool for Claude Code
- [ ] steward state lookup (session_id → tmux location)
- [ ] Navigation integration

### Phase 4: Polish
- [ ] Incremental indexing (watch for new transcripts)
- [ ] LLM provider config
- [ ] Caching / performance tuning
- [ ] TUI browser

---

## Open Questions

1. **Chunk size?** 512 tokens? Message-level? Turn-level (user+assistant)?
2. **Index frequency?** On-demand? Cron? Filesystem watch?
3. **Local vs cloud embeddings?** Cost vs quality vs privacy tradeoff
4. **Which LLM for context enrichment?** Fast+cheap (Haiku) or quality (Sonnet)?
5. **Reranking model?** LLM-based or cross-encoder (Cohere, BGE)?

---

## References

- [Anthropic: Contextual Retrieval](https://www.anthropic.com/news/contextual-retrieval)
- [Qdrant Documentation](https://qdrant.tech/documentation/)
- [Haystack Hybrid Retrieval Tutorial](https://haystack.deepset.ai/tutorials/33_hybrid_retrieval)
- [LlamaIndex Contextual Retrieval Cookbook](https://docs.llamaindex.ai/en/stable/examples/cookbooks/contextual_retrieval/)

---

## Related Work

| Tool | Approach | Limitation |
|------|----------|------------|
| cc-conversation-search | SQLite FTS5 | Keyword only, no semantic |
| claude-history | Fuzzy word matching | No embeddings, no rerank |
| Claude Desktop search | Full contextual retrieval | Not available for Claude Code |
