# Hook Verification Findings

> **Date**: 2026-02-05
> **Status**: Automated tests complete, manual tests pending
> **Conclusion**: Core hook machinery works. Permission/question hooks need TUI verification.

---

## Executive Summary

We set out to verify whether Claude Code's hooks fire as documented, with the data needed to build a session monitor. **The core hooks work.** The remaining uncertainty is whether `PermissionRequest` and `Notification[elicitation_dialog]` fire correctly — these require manual TUI testing.

---

## Hypotheses Tested

| # | Hypothesis | Result |
|---|------------|--------|
| H1 | `SessionStart` fires when session begins | **CONFIRMED** |
| H2 | `Stop` fires when Claude finishes responding | **CONFIRMED** |
| H3 | `SessionEnd` fires when session terminates | **CONFIRMED** |
| H4 | `UserPromptSubmit` fires when user sends prompt | **CONFIRMED** |
| H5 | Tmux location can be captured inside hooks | **CONFIRMED** |
| H6 | `session_id` is stable across a session | **CONFIRMED** |
| H7 | `session_id` persists across resume | **INFIRMED** — new UUID per invocation |
| H8 | `source: "resume"` distinguishes resumed sessions | **CONFIRMED** |
| H9 | `PermissionRequest` fires on permission dialog | **UNTESTED** (requires TUI) |
| H10 | `Notification[elicitation_dialog]` fires on questions | **UNTESTED** (requires TUI) |

---

## Experiment Results

### A1: Basic Query

**Command**: `claude -p "What is 2+2?"`

**Hooks fired** (in order):
1. `SessionStart` — `source: "startup"`
2. `UserPromptSubmit` — `prompt: "What is 2+2?"`
3. `Stop` — `stop_hook_active: false`
4. `SessionEnd` — `reason: "other"`

**Tmux capture**:
```
location: claude-monitor:1.1
session:  claude-monitor
window:   1
pane:     1 (id: %318)
```

**Verdict**: All lifecycle hooks fire correctly with full context.

---

### A2: With Allowed Tools

**Command**: `claude -p "List the files" --allowedTools "Bash(ls:*)"`

**Hooks fired**: Same 4 as A1.

**Notable**: `PermissionRequest` did NOT fire — expected, since `--allowedTools` bypasses permission dialogs.

**Verdict**: Hooks work regardless of tool permissions. Permission hooks require actual dialogs.

---

### A3: Session Resume

**Command**: `claude -p "What was my previous question?" --continue`

**Hooks fired**: Same 4.

**Key fields**:
- `source: "resume"` ✓ (correctly identifies resumed session)
- `session_id`: NEW UUID (different from previous session)

**Verdict**: Resume is detectable via `source` field. However, `session_id` is NOT stable across resume — each CLI invocation gets a fresh UUID.

**Implication**: For our use case, track by **tmux location**, not `session_id`.

---

## Payload Structure (Confirmed)

All hooks receive:

```json
{
  "session_id": "766ca7e1-0e46-4f51-8358-320cab44df3a",
  "transcript_path": "/Users/marc/.claude/projects/.../766ca7e1-....jsonl",
  "cwd": "/Users/marc/DATA_PROG/AI-TOOLING/claudes-steward",
  "hook_event_name": "Stop",
  // ... event-specific fields
}
```

Event-specific additions:

| Hook | Additional Fields |
|------|-------------------|
| `SessionStart` | `source` ("startup", "resume", "clear", "compact") |
| `UserPromptSubmit` | `prompt`, `permission_mode` |
| `Stop` | `stop_hook_active`, `permission_mode` |
| `SessionEnd` | `reason` ("other", "clear", "logout", etc.) |

---

## What Remains Untested

### Critical (Must Verify Before Implementation)

| Test | Hook | Why Critical |
|------|------|--------------|
| M1 | `PermissionRequest` | Detects "waiting for permission" state |
| M3 | `Notification[elicitation_dialog]` | Detects "asked a question" state |

### Important (Should Verify)

| Test | What It Verifies |
|------|------------------|
| M2 | `Notification[permission_prompt]` — redundant with M1? |
| M5 | Tmux location correct across DIFFERENT tmux sessions |
| M7 | User interrupt (Escape) suppresses `Stop` |

### Nice to Have

| Test | What It Verifies |
|------|------------------|
| M8 | Empty prompt behavior |
| M9 | Hook timing relative to UI |
| M10 | Blocking/latency impact |

---

## Implications for Design

### Confirmed Safe to Rely On

- `Stop` hook for "Claude finished responding"
- `SessionStart` / `SessionEnd` for lifecycle tracking
- `UserPromptSubmit` for "user is actively engaged"
- Tmux location capture via `tmux display-message`

### Needs TUI Verification

- `PermissionRequest` for "waiting for permission"
- `Notification[elicitation_dialog]` for "asked a question"

### Design Adjustment

Originally assumed `session_id` would be stable across resume. It's not — each CLI invocation generates a new UUID.

**Solution**: Use `tmux_location` (session:window.pane) as the primary key for tracking, not `session_id`.

---

## Artifacts

### Test Infrastructure

```
shared/
├── hooks/
│   └── probe.sh              # Captures all hook events with tmux context
├── scripts/
│   └── new-experiment.sh     # Rotates logs, creates observation templates
└── experiments/
    ├── logs/
    │   ├── current.log       # Human-readable
    │   └── current.jsonl     # Machine-readable
    └── observations/
        └── *.md              # Per-experiment notes
```

### Configuration

```
.claude/settings.json         # Project-local hooks configuration
```

### Archived Logs

```
logs/2026-02-05_163007_A1-basic-query.log
logs/2026-02-05_163007_A1-basic-query.jsonl
logs/2026-02-05_163434_A2-allowed-tools.log
logs/2026-02-05_163434_A2-allowed-tools.jsonl
logs/2026-02-05_163518_A3-session-resume.log
logs/2026-02-05_163518_A3-session-resume.jsonl
```

---

## Next Steps

1. [ ] Run M1: Verify `PermissionRequest` fires (TUI required)
2. [ ] Run M3: Verify `Notification[elicitation_dialog]` fires (TUI required)
3. [ ] If confirmed: Proceed to implementation
4. [ ] If not: Investigate fallback strategies

---

## References

- [Claude Code Hooks Reference](https://code.claude.com/docs/en/hooks)
- [DESIGN.md](../../DESIGN.md) — Full design document
- [VERIFICATION.md](../../VERIFICATION.md) — Test plan
