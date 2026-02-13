# Session Finder: Research Findings

> **Date**: 2026-02-05
> **Status**: Research complete, ready for implementation
> **Epic**: STEW-mq6

---

## The Problem

"I was working on X somewhere... which tmux session/window/pane was it?"

You have dozens of Claude Code sessions across tmux. You remember the *topic* but not the *location*.

---

## Key Discovery: Two Distinct Problems

| Problem | Scope | Solution Exists? |
|---------|-------|------------------|
| **Transcript search** | Find sessions by content (historical) | YES — many tools |
| **Tmux location lookup** | Map session_id → tmux location | NO — this is our gap |

**Insight**: The tools exist for searching. What's missing is the *bridge* to tmux.

---

## Transcript Search Tools Evaluated

### Tested

| Tool | Verdict | Notes |
|------|---------|-------|
| **cc-conversation-search** | **WINNER** | Returns session_id, `--json` flag, Python API, fast |
| **claude-history (raine)** | TUI-only | Great for humans, not scriptable |

### Surveyed (not tested)

| Tool | Type | Key Feature |
|------|------|-------------|
| episodic-memory | MCP | Semantic search, local embeddings |
| clancey | MCP | Meaning-based search |
| cccmemory | MCP | Cross-project, decision tracking |
| claude-historian-mcp | MCP | Query clustering |
| claude-code-tools | CLI | Rust/Tantivy full-text |

### cc-conversation-search Output (actual)

```
🔍 Found 20 matches for 'hook':

🤖  None
   Session: 5ac411c7-6211-4598-807b-83cc833309ee
   Project: /Users/marc/Work/dodobird/ai/chatbot/...
   Time: 2026-02-06 11:55
   Message: 7f63792c-ac2e-4edf-be15-b62e8a123b72

   ...The **hooks** block commits because no **hooks** are configured...

   Resume:
     cd /Users/marc/Work/dodobird/ai/chatbot/...
     claude --resume 5ac411c7-6211-4598-807b-83cc833309ee
```

**What it returns:**
- ✓ session_id
- ✓ project path
- ✓ timestamp
- ✓ message snippets
- ✓ resume command
- ✗ tmux location — **THE GAP**

---

## The Bridge Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    User Query                               │
│              "where was I working on webhooks?"             │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│              cc-conversation-search                          │
│                                                              │
│  $ cc-conversation-search search "webhooks" --json          │
│  → [ {session_id: "5ac411c7-...", project: "...", ...} ]    │
└─────────────────────────────────────────────────────────────┘
                              │
                              │ session_id
                              ▼
┌─────────────────────────────────────────────────────────────┐
│              claudes-steward state (SQLite)                  │
│                                                              │
│  SELECT tmux_location FROM sessions                          │
│  WHERE session_id = '5ac411c7-...'                          │
│  → "dev:3.1"                                                 │
└─────────────────────────────────────────────────────────────┘
                              │
                              │ tmux_location
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                      Result                                  │
│                                                              │
│  "Session about 'webhooks' is at dev:3.1"                   │
│  → tmux select-window -t dev:3; tmux select-pane -t 1       │
└─────────────────────────────────────────────────────────────┘
```

---

## Critical Design Decision: Primary Key

**Problem**: `session_id` changes on every CLI invocation (including `--resume`).

**Discovery** (from hook verification):
```
A2 session_id: 766ca7e1-0e46-4f51-8358-320cab44df3a
A3 resumed:    da0251e0-50a6-4d89-b49f-545019c59640  ← DIFFERENT!
```

**Solution**: Use `tmux_pane_id` (e.g., `%318`) as primary key.
- Stable for lifetime of the pane
- `session_id` stored but can change
- Track `last_session_id` for search correlation

---

## State Schema (Draft)

```sql
CREATE TABLE sessions (
    tmux_pane_id    TEXT PRIMARY KEY,  -- "%318" (stable)
    tmux_location   TEXT NOT NULL,      -- "dev:2.1" (for display)
    session_id      TEXT,               -- Current Claude session UUID
    state           TEXT NOT NULL,      -- 'working' | 'needs_attention'
    state_reason    TEXT,               -- 'done' | 'permission' | 'question'
    last_updated    TEXT NOT NULL,
    last_session_id TEXT                -- For search correlation
);

-- The bridge query
SELECT tmux_location FROM sessions WHERE session_id = ?;
```

---

## How Hooks Feed the State

| Hook Event | State Transition |
|------------|------------------|
| `SessionStart` | Insert/update: `state = 'working'` |
| `Stop` | Update: `state = 'needs_attention', reason = 'done'` |
| `PermissionRequest` | Update: `state = 'needs_attention', reason = 'permission'` |
| `Notification[elicitation_dialog]` | Update: `state = 'needs_attention', reason = 'question'` |
| `UserPromptSubmit` | Update: `state = 'working'` |
| `SessionEnd` | Delete row |

---

## Convergence with claudes-steward

The Session Finder naturally merges with the original steward design:

| Feature | Data Source | Query |
|---------|-------------|-------|
| **Roster** (dashboard) | Same state table | `SELECT * FROM roster` |
| **Triage** (next urgent) | Same state table | `SELECT * FROM needs_attention LIMIT 1` |
| **Session Finder** | Same state table + cc-search | `WHERE session_id = ?` |

**One state store serves all three use cases.**

---

## Open Questions

1. **Stale entries**: How to clean up sessions that ended without `SessionEnd` firing (crash, kill -9)?
   - Option A: TTL-based cleanup
   - Option B: Periodic liveness check (`tmux list-panes`)
   - Option C: Accept staleness, manual cleanup

2. **Multi-session_id**: A pane might have multiple session_ids over time. Store history?
   - Current design: Only track current + last
   - Could expand to full history if needed

3. **Search result ranking**: If multiple panes match a session_id (unlikely but possible)?
   - Return most recent
   - Return all with timestamps

---

## Next Steps

1. [x] STEW-44h: Try cc-conversation-search — **DONE, works great**
2. [x] STEW-8gv: Try claude-history — **DONE, TUI-only**
3. [ ] STEW-ebi: Build session_id → tmux mapping — **IN PROGRESS**
4. [ ] STEW-aj9: Bridge script — **Blocked by ebi**

---

## References

- [cc-conversation-search](https://github.com/akatz-ai/cc-conversation-search) — Our chosen search tool
- [episodic-memory](https://github.com/obra/episodic-memory) — Alternative (semantic)
- [claude-history](https://github.com/raine/claude-history) — TUI browser
- Hook Verification Findings — `../experiments/FINDINGS.md`
