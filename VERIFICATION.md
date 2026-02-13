# Hook Verification Plan

> **Status**: Pre-verification
> **Purpose**: Confirm Claude Code hooks fire as documented before building claudes-steward

---

## TL;DR

We need to verify that Claude Code's hooks (`Stop`, `PermissionRequest`, `Notification[elicitation_dialog]`, etc.) actually fire with the data we expect. Some tests can be automated via `claude -p`, others require manual TUI interaction.

---

## 1. What Can Be Tested Programmatically

Using `claude -p` (headless mode):

| Hook | How to trigger | Command |
|------|----------------|---------|
| `SessionStart` | Any headless query | `claude -p "What is 2+2?"` |
| `Stop` | Query completes | `claude -p "What is 2+2?"` |
| `SessionEnd` | Process exits | (fires after any `claude -p` completes) |
| `UserPromptSubmit` | Prompt is processed | `claude -p "What is 2+2?"` |

---

## 2. What Requires Manual TUI Testing

These hooks require interactive Claude Code because headless mode doesn't show dialogs:

| Hook | Why manual | What happens in headless |
|------|------------|-------------------------|
| `PermissionRequest` | Dialog must be shown | Fails with error, no dialog |
| `Notification[elicitation_dialog]` | Claude must ask interactive question | Claude skips or fails |
| `Notification[permission_prompt]` | Same as PermissionRequest | No notification sent |

### Why Headless Can't Test These

When `claude -p` runs and Claude needs permission:
- **Without `--allowedTools`**: Fails with `"Error: Claude requested permissions to use [Tool], but you haven't granted it yet."`
- **With `--allowedTools`**: Permission auto-granted, no dialog shown, hook doesn't fire

There's no middle ground where a dialog is shown programmatically.

### Manual Test Procedure

1. Start Claude Code in a tmux pane (TUI mode)
2. Trigger each scenario
3. Check `~/.claude/hook-test.log` after each

---

## 3. Test Hook Configuration

Configure hooks in `~/.claude/settings.json` for all events we want to test:
- `PermissionRequest`
- `Notification` (with matchers: `elicitation_dialog`, `permission_prompt`)
- `Stop`
- `SessionStart`
- `UserPromptSubmit`
- `SessionEnd`

Each hook should call a test script that logs the event.

**Important**: Restart Claude Code after modifying hooks (hooks are captured at startup).

---

## 4. Test Hook Script

Create a test hook script (`~/.claude/hooks/monitor-test.sh`) that:
- Reads the JSON payload from stdin
- Extracts the hook event name
- Captures tmux location (session, window, pane)
- Logs everything to `~/.claude/hook-test.log`

---

## 5. Test Scenarios Checklist

### Automated (via `claude -p`)

| # | Scenario | Command | Expected Hook |
|---|----------|---------|---------------|
| A1 | Basic query | `claude -p "What is 2+2?"` | SessionStart, Stop, SessionEnd |
| A2 | With allowed tools | `claude -p "List files" --allowedTools "Bash"` | SessionStart, Stop, SessionEnd |
| A3 | Continue session | `claude -p "Continue" --continue` | SessionStart (source=resume?), Stop |

### Manual (TUI required)

| # | Scenario | How to trigger | Expected Hook |
|---|----------|----------------|---------------|
| M1 | Permission prompt | Ask Claude to run a bash command, wait for dialog | PermissionRequest |
| M2 | Permission notification | Same as M1 | Notification[permission_prompt] |
| M3 | Clarifying question | Ask ambiguous question, Claude uses AskUserQuestion | Notification[elicitation_dialog] |
| M4 | User responds | After any prompt, type a response | UserPromptSubmit |
| M5 | Multi-session tmux | Run tests from different tmux sessions | Verify tmux location is correct per-session |
| M6 | Session resume | Exit, then `claude --resume` | SessionStart with source="resume" |
| M7 | User interrupt | Press Escape mid-response | Verify Stop does NOT fire |
| M8 | Empty prompt | Press Enter with no text | Check if UserPromptSubmit fires |

---

## 6. Analyzing Results

After running tests:
- Review `~/.claude/hook-test.log`
- Count events by type
- Check for specific fields (`notification_type`, tmux location)
- Watch log in real-time during manual tests

---

## 7. Key Questions to Answer

After running tests, document answers to:

| Question | Finding |
|----------|---------|
| Does `PermissionRequest` fire reliably? | |
| Does `Notification[elicitation_dialog]` fire? | |
| Is `notification_type` present in payload? | |
| Are tmux locations correct across sessions? | |
| Is `session_id` stable across resume? | |
| Do both `PermissionRequest` AND `Notification[permission_prompt]` fire? Which is better? | |
| Any hooks that DON'T fire as expected? | |

---

## 8. Contingency

If hooks don't work as documented:

1. **Check GitHub issues** for known bugs with specific hooks
2. **Try different Claude Code version** (hooks may be version-dependent)
3. **Fall back to alternative detection**:
   - Process monitoring (is `claude` running?)
   - Tmux pane content inspection (brittle but possible)
   - Active signaling via HCOM (requires Claude discipline)

---

## References

- [Claude Code Hooks Reference](https://code.claude.com/docs/en/hooks)
- [Headless Mode Docs](https://code.claude.com/docs/en/headless)
- [GitHub #581 — Non-interactive mode permission issues](https://github.com/anthropics/claude-code/issues/581)
- [GitHub #9026 — CLI hangs without TTY](https://github.com/anthropics/claude-code/issues/9026)
