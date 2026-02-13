# claudes-steward

Reduce cognitive load when managing many parallel Claude Code sessions.

## Problem

Managing dozens of Claude Code instances across tmux sessions/windows/panes is exhausting. You waste time cycling through them to find which ones need attention.

## Solution

Two tools sharing a common state layer:

| Tool | Purpose |
|------|---------|
| **roster** | Dashboard — see all sessions and their status |
| **triage** | Navigator — jump to the next session needing attention |

## Status

**Pre-verification.** See [DESIGN.md](./DESIGN.md) for full details.

Before building, we must verify that Claude Code's hooks (`Stop`, `PermissionRequest`, `Notification[elicitation_dialog]`) actually fire as documented.

## Structure

```
claudes-steward/
├── roster/     # Dashboard tool
├── triage/     # Navigation tool
├── shared/     # State management, hook scripts
└── DESIGN.md   # Full design document
```

## Next Steps

1. Run verification tests (see DESIGN.md Section 6)
2. Analyze hook behavior
3. Implement shared state layer
4. Build roster (dashboard)
5. Build triage (navigator)
