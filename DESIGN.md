# Claude Session Monitor — Design Brief

> **Status**: Draft / Pre-verification
> **Date**: 2026-02-04
> **Problem Owner**: Marc
> **Revision**: 1.4 — added hook restart note, async/blocking verification question, clarified Stop description

---

## TL;DR

**Problem**: Managing dozens of parallel Claude Code sessions across tmux is cognitively exhausting.

**Solution**: Use Claude Code's built-in hooks (`Stop`, `PermissionRequest`, `Notification[elicitation_dialog]`) to detect when sessions need attention, persist state to SQLite, expose via dashboard + "jump to next" keybinding.

**Status**: Design complete. Must verify hooks actually fire as documented before implementing.

**Next action**: Run verification tests (Section 6).

---

## 1. Problem Statement

### The Pain

Managing dozens of Claude Code instances running in parallel across tmux sessions/windows/panes. The cognitive overhead of manually cycling through them to find which ones need attention is:

- **Exhausting**: Constant context-switching ("where was I?", "what needs me?")
- **Wasteful**: Sessions sit idle waiting for trivial approvals (sometimes 20+ minutes)
- **Unscalable**: Works at 3 sessions, breaks at 30

### What We Want

1. **Dashboard**: A single view showing all Claude sessions and their states
2. **Smart Navigation**: A keybinding that jumps directly to the next session needing attention

### Success Criteria

> "I press one key. I'm in the Claude session that most needs me. I handle it. I press again. Next one. When nothing needs me, it tells me 'all clear.'"

---

## 2. Requirements

| Requirement | Decision |
|-------------|----------|
| State model | **Binary**: "needs attention" vs "working" |
| Latency tolerance | **Relaxed** (~10-15 seconds acceptable) |
| Discovery | **Auto-discover** all Claude sessions (no manual registration) |
| Dashboard | **On-demand** preferred, persistent optional |
| Tagging | Tool provides its own tagging (independent of Claude CLI) |
| Architecture | Leverage existing tools where possible; on-the-fly computation acceptable |
| Interface | **Two keybindings**: dashboard view + direct cycle-to-urgent |

### Non-Goals (for v1)

- Priority/urgency ranking beyond binary (simplify first)
- Cross-machine coordination
- Integration with non-tmux environments

### Known Gaps (Accepted for v1)

- **Informal questions**: If Claude writes "What do you think?" in plain text (without using `AskUserQuestion` tool), no `elicitation_dialog` hook fires — it looks like a normal `Stop`. We accept this gap for now.
- **Long-running operations**: When Claude is actively working (processing, running tools) for several minutes, no hook fires until it finishes or hits a permission prompt. The session appears "working" but we don't know *how long* it's been working. Acceptable for v1 — you don't need to attend to it anyway.
- **User interrupt (Escape)**: Per the docs, `Stop` "does not run if the stoppage occurred due to a user interrupt." If you press Escape to cancel Claude mid-response, no hook fires. This is acceptable — if you interrupted, you're already at the keyboard and know the session state.
- **Non-tmux sessions**: If Claude Code is started outside of tmux (e.g., in a plain terminal), hooks will still fire but tmux location capture will fail gracefully (returns "N/A"). These sessions will appear in state but cannot be navigated to via tmux keybindings. For v1, we'll display them separately in the dashboard or filter them out. This is acceptable since the tool is explicitly designed for tmux workflows.

---

## 3. Technical Landscape

### 3.1 Claude Code Hooks — The Useful Subset

Claude Code provides hooks that fire at specific lifecycle points. These are **system-triggered** (no Claude discipline required).

| Hook Event | When It Fires | Use For |
|------------|---------------|---------|
| `SessionStart` | Session begins/resumes | Init state: "working" |
| `Stop` | Claude finishes responding | State: "needs attention" — covers task complete, error occurred, hit a dead end, or informal question asked (anything where Claude stopped generating) |
| `PermissionRequest` | Permission dialog shown | State: "needs attention (permission)" |
| `Notification[elicitation_dialog]` | Claude asks a question | State: "needs attention (question)" |
| `UserPromptSubmit` | User submits input | State: "working" (user responded) |
| `SessionEnd` | Session terminates | Remove from state |

#### Hook Input (common fields)

All hooks receive JSON via stdin:

```json
{
  "session_id": "abc123",
  "cwd": "/path/to/project",
  "transcript_path": "~/.claude/projects/.../transcript.jsonl",
  "hook_event_name": "Stop"
}
```

#### Event-Specific Fields

| Hook Event | Additional Fields |
|------------|-------------------|
| `PermissionRequest` | `tool_name`, `tool_input` (what command needs approval) |
| `Notification` | `notification_type`, `message`, optional `title` |
| `SessionStart` | `source` ("startup", "resume", "clear", "compact") |
| `SessionEnd` | `reason` ("clear", "logout", "prompt_input_exit", "other") |
| `UserPromptSubmit` | `prompt` (the text user submitted) |
| `Stop` | `stop_hook_active` (boolean — true if already continuing from a stop hook) |

#### Tmux Location Capture

Your existing `stop-announce.sh` **already proves this works** — it's been capturing tmux location reliably:

```bash
session=$(tmux display-message -p '#S')
window_num=$(tmux display-message -p '#I')
window_name=$(tmux display-message -p '#W')
# Also available: pane index via '#P', full location via '#S:#I.#P'
```

**Tmux format strings reference:**

| Format | Meaning | Example |
|--------|---------|---------|
| `#S` | Session name | `dev` |
| `#I` | Window index | `2` |
| `#W` | Window name | `backend` |
| `#P` | Pane index | `1` |
| `#S:#I.#P` | Full location | `dev:2.1` |
| `#D` | Unique pane ID | `%42` |

This is a known-good pattern — the only verification needed is whether it works in *all* hook events (not just `Stop`).

### 3.2 Existing Tools Evaluated

| Tool | What It Does | Why Not Sufficient |
|------|--------------|-------------------|
| **HCOM** | Inter-agent messaging via hooks + SQLite | Could be overkill; requires active signaling discipline |
| **MCP Agent Mail** | Project-scoped mailboxes | Too heavyweight; project-scoped not global |
| **claude-code-notify-mcp** | Desktop notifications | Automatic/noisy; no aggregation |
| **tmux monitor-bell** | Highlight windows with bell | No aggregation; must cycle manually |

### 3.3 Known Issues / Prior Art

- **GitHub #10168** (open): Requests `UserInputRequired` hook — may be addressed by `PermissionRequest` + `Notification[elicitation_dialog]`
- **GitHub #12048** (closed as dup): `idle_prompt` fires after every response — unusable
- **GitHub #11964**: `notification_type` field was missing from payload — may be fixed

### 3.4 Why Hasn't This Been Solved Already?

We asked ourselves this question. Possible explanations:

1. **Hooks may be newer than the complaints** — Issues were filed Oct 2025; `PermissionRequest` and `elicitation_dialog` may have been added since
2. **The hooks might not work as documented** — `notification_type` was reportedly missing; needs verification
3. **Tmux integration is the missing piece** — Hooks exist, but nobody connected: hook → tmux location → persist → dashboard → navigation
4. **Aggregation problem unsolved** — People built point notifications (audio, desktop) but not the aggregation + smart-cycle layer

Our hypothesis: the pieces exist, nobody assembled them. Verification will confirm or refute this.

---

## 4. Proposed Architecture

### 4.1 State Machine

```
┌─────────────────────────────────────────────────────────────┐
│                         WORKING                              │
│  (Claude is actively processing or user just responded)      │
└─────────────────────────────────────────────────────────────┘
        │                    ▲
        │ Stop               │ UserPromptSubmit
        │ PermissionRequest  │
        │ Notification[...]  │
        ▼                    │
┌─────────────────────────────────────────────────────────────┐
│                     NEEDS ATTENTION                          │
│  (Claude finished, waiting for permission, or asked question)│
└─────────────────────────────────────────────────────────────┘
        │
        │ SessionEnd
        ▼
┌─────────────────────────────────────────────────────────────┐
│                   [REMOVED FROM TRACKING]                    │
│  (Session terminated — entry deleted from state)             │
└─────────────────────────────────────────────────────────────┘
```

### 4.2 Data Flow

```
Hook fires ──→ Hook script ──→ Write to shared state ──→ Dashboard/Keybinding reads
                   │
                   └─ Captures: session_id, tmux location, reason, timestamp
```

### 4.3 Shared State (Options)

| Option | Pros | Cons |
|--------|------|------|
| **SQLite file** | Queryable, atomic writes, single file | Slight complexity |
| **JSON file** | Dead simple, human-readable | Race conditions, no queries |
| **HCOM's SQLite** | Already exists if using HCOM | Dependency |

**Tentative choice**: Simple SQLite at `~/.claude/session-monitor.db`

### 4.4 Components

```
~/.claude/hooks/
├── session-monitor-hook.sh    # Called by all relevant hooks
│                              # Writes state to SQLite
│
~/.local/bin/
├── claude-sessions            # Dashboard TUI or simple list
├── claude-next                # Jump to next needing attention
│
~/.tmux.conf
├── bind-key ...               # Keybindings for above
```

---

## 5. Open Questions / Verification Needed

### 5.1 Must Verify Before Building

| Question | How to Verify |
|----------|---------------|
| Does `PermissionRequest` hook fire reliably? | Add test hook, trigger permission prompt |
| Does `Notification[elicitation_dialog]` fire? | Add test hook, make Claude use AskUserQuestion |
| Does `Notification[permission_prompt]` fire? | Compare with `PermissionRequest` — are both redundant or different? |
| Is `notification_type` present in payload? | Log full JSON stdin |
| Are tmux env vars available inside hooks? | Log `$TMUX_PANE`, `tmux display-message` output (proven for `Stop`, verify others) |
| What's in `session_id`? Is it stable/unique? | Log across session resume/compact |
| Does Claude always use AskUserQuestion tool for questions? | Observe behavior — informal "what do you think?" vs formal tool |
| Does `UserPromptSubmit` fire BEFORE Claude processes? | Docs say "before" — verify timing is immediate on Enter, not after response |
| Does `UserPromptSubmit` fire on empty prompt? | Press Enter with no text — does hook fire? (edge case for state transitions) |
| What happens on session resume (`--resume`)? | Does `SessionStart` fire with `source: "resume"`? Is `session_id` the same? |
| When does `PermissionRequest` fire — before or after dialog shown? | Observe timing: does hook fire while dialog is visible, or before it renders? (Affects whether state update races with user seeing the prompt) |
| When does `Notification[elicitation_dialog]` fire relative to question display? | Same timing question — does hook fire before or after the question appears on screen? |
| Do hooks block Claude until script completes? | Docs say hooks block by default (unless `async: true`). Verify our logging script doesn't introduce noticeable lag. A fast SQLite write (~ms) should be fine. |

### 5.2 Design Decisions Deferred

- Exact SQLite schema
- Dashboard UI (TUI vs simple text vs fzf)
- How to handle "seen" state (mark as seen when visited?)
- Stale entry cleanup strategy

### 5.3 Implementation Notes

**`stop_hook_active` field**: The `Stop` event includes a boolean `stop_hook_active` field. When `true`, it means Claude is already continuing as a result of a previous stop hook. This exists to prevent infinite loops (a stop hook that always blocks would run forever). For our use case, we can ignore this field since we're not blocking stops — we're just recording state.

**Hook failure resilience**: Per Claude Code docs, if a hook script fails (any non-zero exit code other than 2), Claude Code logs the error and **continues normally** — it does not block the user's workflow. Exit code 2 specifically means "blocking error" and has event-specific effects (e.g., blocks a tool call for `PreToolUse`). For our hooks, we only read and log — we never exit 2. This means a buggy hook script won't break Claude sessions; at worst, we miss a state update.

**Hooks block by default**: Hook scripts run synchronously — Claude waits for them to complete before proceeding. This is fine for our use case (a fast SQLite write takes ~1ms), but worth keeping in mind. If hooks were slow, you could add `"async": true` to run them in the background, but then you lose the guarantee that state is written before Claude continues. For our lightweight logging/state-writing, synchronous is correct.

---

## 6. Verification Plan

> **Note**: This test setup is non-destructive and easily reversible. The test hook only logs to a file — it doesn't modify Claude's behavior. To remove after testing, delete the hook entries from `settings.json` and optionally remove `~/.claude/hooks/monitor-test.sh`.

> **Important — Hooks require restart**: Claude Code captures a snapshot of hooks at startup and uses it throughout the session. After modifying `settings.json`, you must **start a new Claude session** for hook changes to take effect. Editing hooks mid-session will trigger a warning and require review in the `/hooks` menu.

### Test Hook Script

Create `~/.claude/hooks/monitor-test.sh` and make it executable:

```bash
mkdir -p ~/.claude/hooks
touch ~/.claude/hooks/monitor-test.sh
chmod +x ~/.claude/hooks/monitor-test.sh
```

Script contents:

```bash
#!/usr/bin/env bash
set -euo pipefail

LOG="$HOME/.claude/hook-test.log"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

# Read JSON payload from stdin (must read once, before any other stdin operations)
PAYLOAD=$(cat)

# Extract hook event name from JSON payload
HOOK_EVENT=$(echo "$PAYLOAD" | jq -r '.hook_event_name // "unknown"')

# Log header
echo "=== $TIMESTAMP ===" >> "$LOG"
echo "Hook Event: $HOOK_EVENT" >> "$LOG"

# Log tmux environment variable
echo "TMUX_PANE env: ${TMUX_PANE:-unset}" >> "$LOG"

# Log tmux location via tmux command
if command -v tmux &>/dev/null && [ -n "${TMUX:-}" ]; then
  tmux display-message -p 'tmux location: #S:#I.#P (session:window.pane)' >> "$LOG"
else
  echo "tmux location: N/A (not in tmux or tmux unavailable)" >> "$LOG"
fi

# Log full JSON payload
echo "Payload:" >> "$LOG"
echo "$PAYLOAD" | jq '.' >> "$LOG" 2>/dev/null || echo "$PAYLOAD" >> "$LOG"
echo "" >> "$LOG"
```

### Test Configuration

**Important**: Merge these hooks with your existing `~/.claude/settings.json` hooks — don't replace the whole file.

**Note on coexisting hooks**: For events where you already have hooks (e.g., `Stop` has `stop-announce.sh`, `SessionStart` has `bd prime`), add the test hook to the same `hooks` array — both will run. Example below shows this pattern for `Stop` and `SessionStart`.

```json
{
  "hooks": {
    "PermissionRequest": [
      {
        "matcher": "",
        "hooks": [{ "type": "command", "command": "~/.claude/hooks/monitor-test.sh" }]
      }
    ],
    "Notification": [
      {
        "matcher": "elicitation_dialog",
        "hooks": [{ "type": "command", "command": "~/.claude/hooks/monitor-test.sh" }]
      },
      {
        "matcher": "permission_prompt",
        "hooks": [{ "type": "command", "command": "~/.claude/hooks/monitor-test.sh" }]
      }
    ],
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          { "type": "command", "command": "~/.claude/hooks/stop-announce.sh" },
          { "type": "command", "command": "~/.claude/hooks/monitor-test.sh" }
        ]
      }
    ],
    "SessionStart": [
      {
        "matcher": "",
        "hooks": [
          { "type": "command", "command": "bd prime" },
          { "type": "command", "command": "~/.claude/hooks/monitor-test.sh" }
        ]
      }
    ],
    "UserPromptSubmit": [
      {
        "matcher": "",
        "hooks": [{ "type": "command", "command": "~/.claude/hooks/monitor-test.sh" }]
      }
    ],
    "SessionEnd": [
      {
        "matcher": "",
        "hooks": [{ "type": "command", "command": "~/.claude/hooks/monitor-test.sh" }]
      }
    ]
  }
}
```

### Test Scenarios

Run these in a fresh Claude session inside tmux. Check `~/.claude/hook-test.log` after each step.

1. **SessionStart**: Start a new Claude session → check log for SessionStart event
2. **Stop**: Ask Claude a simple question, let it respond → check log for Stop event
3. **PermissionRequest + Notification[permission_prompt]**: Ask Claude to run a bash command that needs approval → check log for both events (do both fire? which has better payload?)
4. **Notification[elicitation_dialog]**: Ask Claude something ambiguous that makes it use AskUserQuestion tool → check log
   - Tip: Try "Should I use approach A or B?" or "What database should we use?" — Claude often uses AskUserQuestion for multi-choice decisions
5. **UserPromptSubmit**: After any of the above, type your response → check log for UserPromptSubmit
6. **SessionEnd**: Exit the session cleanly (`Ctrl+C` or `/exit`) → check log for SessionEnd event
7. **Tmux location**: Verify ALL events include correct tmux session/window/pane info
8. **Multi-session isolation**: Run tests from a DIFFERENT tmux **session** (not just a different window or pane within the same session) to confirm `tmux display-message` returns the correct location for THAT session, not a cached/global value. This verifies the hook truly captures where it's running, not some stale environment state.
9. **Session resume**: Exit a session, then `claude --resume` → does `SessionStart` fire with `source: "resume"`? Is `session_id` preserved?
10. **Empty prompt**: Press Enter with no text → does `UserPromptSubmit` fire? (edge case)
11. **User interrupt**: Press Escape mid-response → confirm `Stop` does NOT fire (per docs)
12. **Timing observation**: When triggering `PermissionRequest`, note whether the hook fires BEFORE the permission dialog renders or AFTER. Watch for the log entry timestamp relative to when you see the dialog. (If hooks fire after render, state is updated after user already sees the prompt — fine for our use case. If before, even better.)
13. **Blocking behavior check**: During any hook-triggering action, observe if there's perceptible delay. Our test script is lightweight, but this confirms hooks don't introduce lag. If you notice a pause, we may need to optimize or consider `async: true` for production.

### Expected Log Output (Example)

If everything works, `~/.claude/hook-test.log` should look something like:

```
=== 2026-02-04 15:30:01 ===
Hook Event: SessionStart
TMUX_PANE env: %42
tmux location: dev:2.1 (session:window.pane)
Payload:
{
  "session_id": "abc123-def456",
  "cwd": "/Users/marc/myproject",
  "hook_event_name": "SessionStart",
  "source": "startup"
}

=== 2026-02-04 15:30:15 ===
Hook Event: PermissionRequest
TMUX_PANE env: %42
tmux location: dev:2.1 (session:window.pane)
Payload:
{
  "session_id": "abc123-def456",
  "hook_event_name": "PermissionRequest",
  "tool_name": "Bash",
  "tool_input": {
    "command": "rm -rf node_modules"
  }
}
```

### Analyzing Results

After running test scenarios, check:

```bash
# View full log
cat ~/.claude/hook-test.log | less

# Watch log in real-time (in a separate tmux pane)
tail -f ~/.claude/hook-test.log

# Count events by type
grep "Hook Event:" ~/.claude/hook-test.log | sort | uniq -c

# Clear log before new test session
: > ~/.claude/hook-test.log
```

Key questions to answer:
- Which hooks actually fired?
- Is `notification_type` present in Notification payloads?
- Does tmux location capture work reliably across ALL hook events?
- Are `PermissionRequest` and `Notification[permission_prompt]` redundant or different?
- What's the timing of hooks relative to UI rendering? (before/after dialog appears)
- Is `session_id` stable across resume, or does it change?

---

## 7. Next Steps

1. [ ] Run verification tests (Section 6)
2. [ ] Analyze logs — confirm hooks fire, payloads contain expected data
   - [ ] Decide: Do we need both `PermissionRequest` AND `Notification[permission_prompt]`, or just one?
3. [ ] If verified: finalize schema and implement hook script
4. [ ] Build dashboard CLI
5. [ ] Build cycle-to-next CLI
6. [ ] Wire up tmux keybindings

---

## 8. Future Considerations (Post-v1)

Ideas discussed but explicitly deferred:

- **Priority/urgency tiers**: Beyond binary (e.g., permission > question > done)
- **Project-based weighting**: "production hotfix" sessions rank higher
- **Time-in-state tracking**: "Waiting for 20 minutes" ranks higher than "waiting for 30 seconds"
- **HCOM integration**: If richer inter-agent communication is needed later
- **Persistent dashboard mode**: Always-on view in a dedicated tmux pane
- **Cross-machine sync**: For distributed development setups
- **IDE integration**: VS Code / Cursor status bar integration

---

## Appendix A: Glossary

| Term | Meaning in this document |
|------|--------------------------|
| **Session** | A Claude Code instance (one `claude` process) |
| **Needs attention** | Claude has stopped and is waiting for human input |
| **Working** | Claude is actively processing OR user just provided input |
| **Hook** | A Claude Code lifecycle event that triggers a script |
| **Blocking hook** | A hook that runs synchronously — Claude waits for it to complete (default behavior) |
| **Tmux location** | The `session:window.pane` identifier (e.g., `dev:2.1`) |

---

## Appendix B: References

- [Claude Code Hooks Reference](https://code.claude.com/docs/en/hooks)
- [GitHub #10168 — UserInputRequired hook request](https://github.com/anthropics/claude-code/issues/10168)
- [GitHub #12048 — idle_prompt fires too often](https://github.com/anthropics/claude-code/issues/12048)
- [HCOM — Inter-agent messaging](https://github.com/aannoo/hcom)
- [Notification System for Tmux and Claude Code](https://quemy.info/2025-08-04-notification-system-tmux-claude.html)
