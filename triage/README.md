# triage

Navigate to the next Claude session needing attention.

## Purpose

Answer: "Where should I go next?"

One keybinding → land in the right tmux pane.

## Open Design Questions

**The core question: What defines "next"?**

Possible strategies (not yet decided):
- Oldest (longest waiting)
- Newest (most recent state change)
- By type (permission > question > done)
- Round-robin (cycle through all)
- Weighted (combine multiple factors)
- User-defined priority tags

This is a key design decision. May require experimentation to find what actually reduces cognitive load best.

## Features (planned)

- Query state for sessions needing attention
- Apply (TBD) algorithm to select "next"
- Jump to selected session's tmux pane
- Track visited sessions to enable cycling
- Report "all clear" when nothing needs attention

## Usage (planned)

```bash
# Jump to next session needing attention
triage next

# Or via tmux keybinding
bind-key n run-shell "~/.local/bin/claudes-triage next"
```
