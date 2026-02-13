# shared

Common components used by both `roster` and `triage`.

## Components (planned)

- **Hook scripts** — Write session state on Claude Code lifecycle events
- **State schema** — SQLite database at `~/.claude/steward.db`
- **Tmux utilities** — Location capture, navigation helpers

## State Machine

```
SessionStart         → state = "working"
PermissionRequest    → state = "needs_attention:permission"
Notification[elicit] → state = "needs_attention:question"
Stop                 → state = "needs_attention:done"
UserPromptSubmit     → state = "working"
SessionEnd           → remove entry
```
