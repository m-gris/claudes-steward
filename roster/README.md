# roster

Dashboard view of all Claude Code sessions.

## Purpose

Answer: "What's the situation across all my Claude sessions?"

## Features (planned)

- List all tracked sessions with their state
- Show tmux location (session:window.pane)
- Display time in current state
- Filter by state (needs_attention / working)
- Hierarchical view (sessions → windows → panes)

## Interface (TBD)

Options under consideration:
- Simple CLI list
- TUI with navigation (e.g., using `charmbracelet/bubbletea`)
- fzf-based interactive picker
