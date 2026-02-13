# Transcript Search Tools Research

> **Date**: 2026-02-05
> **Status**: Initial survey
> **Goal**: Find tool to integrate with claudes-steward for "where in tmux is session about X?"

---

## The Landscape

Two categories:
1. **MCP Servers** — Run as Claude Code plugins, Claude can search its own history
2. **CLI Tools** — Human-operated, search from terminal

---

## MCP Servers (Semantic Search)

| Tool | Description | Search Type | Key Feature |
|------|-------------|-------------|-------------|
| [**episodic-memory**](https://github.com/obra/episodic-memory) | Semantic search for conversations | Embeddings + SQLite | Local, offline, by obra (well-known) |
| [**clancey**](https://github.com/divmgl/clancey) | Index & search by meaning | Local embeddings | "Search by meaning, not keywords" |
| [**cccmemory**](https://github.com/xiaolai/cccmemory) | Long-term memory with decision tracking | Semantic + Full-text (RRF) | Cross-project search, git integration |
| [**claude-historian-mcp**](https://github.com/Vvkmnn/claude-historian-mcp) | Surface useful history | Semantic + clustering | Query similarity clustering |
| [**conversation-search-mcp**](https://glama.ai/mcp/servers/@cordlesssteve/conversation-search-mcp) | Comprehensive search | Hybrid (keyword + semantic) | Role-based filtering |

---

## CLI Tools

| Tool | Language | Search Type | Key Feature |
|------|----------|-------------|-------------|
| [**claude-history**](https://github.com/raine/claude-history) | Rust | Fuzzy search | Fast, can pipe to other tools |
| [**claude-code-tools**](https://github.com/pchalasani/claude-code-tools) | Rust/Tantivy | Full-text | TUI for humans, CLI for agents |
| [**claude-history-explorer**](https://github.com/adewale/claude-history-explorer) | Python | Regex | Rich TUI, export formats |
| [**cc-conversation-search**](https://github.com/akatz-ai/cc-conversation-search) | ? | Semantic | Returns session IDs for `--resume` |
| [**claude-code-history-viewer**](https://github.com/yanicklandry/claude-code-history-viewer) | ? | ? | Web UI, visual chat interface |
| [**ccstat**](https://github.com/ktny/ccstat) | ? | N/A | Activity timeline visualization |

---

## Evaluation Criteria (for our use case)

What we need:
1. **Returns session_id** — so we can correlate with tmux location
2. **Searchable by topic/content** — keywords, fuzzy, or semantic
3. **Fast** — usable interactively
4. **Scriptable** — can be called from other tools (not just TUI)
5. **Local/offline** — no cloud dependencies

Nice to have:
- Semantic search (find "webhook" even if I said "HTTP callback")
- Cross-project search
- Snippet preview in results

---

## Candidates to Try First

### Tier 1: Most promising for integration

| Tool | Why |
|------|-----|
| **claude-history** (raine) | Rust, fast, fuzzy, scriptable, returns session info |
| **cc-conversation-search** | Explicitly returns session IDs for `--resume` |
| **claude-code-tools** | Rust/Tantivy, CLI mode for agents |

### Tier 2: If Tier 1 doesn't fit

| Tool | Why |
|------|-----|
| **episodic-memory** | Well-maintained, semantic search |
| **clancey** | Local embeddings, meaning-based |

### Tier 3: Reference only

| Tool | Why |
|------|-----|
| **claude-code-history-viewer** | Web UI, not scriptable |
| **ccstat** | Visualization, not search |

---

## Questions to Answer by Trying

1. What does each tool return? (session_id? path? preview?)
2. How fast is search on large history?
3. Can results be piped/parsed programmatically?
4. Does it handle multi-project correctly?
5. How hard to install/configure?

---

## Integration Architecture (Draft)

```
┌─────────────────────────────────────────────────────────────┐
│                    User Query                               │
│              "where was I working on webhooks?"             │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                 Transcript Search Tool                       │
│          (claude-history / cc-conversation-search)           │
│                                                              │
│  Input: "webhooks"                                           │
│  Output: [ {session_id: "abc123", preview: "..."}, ... ]    │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                 claudes-steward State                        │
│                                                              │
│  session_id → tmux_location mapping                          │
│  (from hooks: SessionStart captures location + session_id)   │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                      Result                                  │
│                                                              │
│  "Session about 'webhooks' is running at dev:3.1"           │
│  [Press Enter to jump]                                       │
└─────────────────────────────────────────────────────────────┘
```

---

## Next Steps

1. [ ] Install & try `claude-history` (raine) — fast, Rust, fuzzy
2. [ ] Install & try `cc-conversation-search` — semantic, returns session IDs
3. [ ] Evaluate: which returns data we can use?
4. [ ] Build bridge to claudes-steward state
