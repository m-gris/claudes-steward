-- claudes-steward state schema
-- Tracks Claude Code sessions and their tmux locations

CREATE TABLE IF NOT EXISTS sessions (
    -- Primary key: tmux location (stable identifier for a pane)
    tmux_pane_id    TEXT PRIMARY KEY,  -- e.g., "%318" (unique pane ID from tmux)

    -- Tmux location components (for display/navigation)
    tmux_session    TEXT NOT NULL,      -- e.g., "dev"
    tmux_window     INTEGER NOT NULL,   -- e.g., 2
    tmux_pane       INTEGER NOT NULL,   -- e.g., 1
    tmux_location   TEXT NOT NULL,      -- e.g., "dev:2.1" (computed)

    -- Claude session info
    session_id      TEXT,               -- Claude's session UUID (may change on resume!)
    cwd             TEXT,               -- Working directory
    transcript_path TEXT,               -- Path to transcript JSONL

    -- State machine
    state           TEXT NOT NULL DEFAULT 'unknown',  -- 'working', 'needs_attention', 'unknown'
    state_reason    TEXT,               -- 'done', 'permission', 'question', etc.

    -- Timestamps
    first_seen      TEXT NOT NULL,      -- When we first saw this session
    last_updated    TEXT NOT NULL,      -- When state last changed

    -- For search integration
    last_session_id TEXT                -- Track session_id changes for search correlation
);

-- Index for session_id lookups (the bridge query)
CREATE INDEX IF NOT EXISTS idx_session_id ON sessions(session_id);

-- Index for state queries (roster/triage)
CREATE INDEX IF NOT EXISTS idx_state ON sessions(state);

-- View: sessions needing attention, ordered by longest waiting
CREATE VIEW IF NOT EXISTS needs_attention AS
SELECT
    tmux_location,
    state_reason,
    session_id,
    cwd,
    last_updated,
    (julianday('now') - julianday(last_updated)) * 24 * 60 AS minutes_waiting
FROM sessions
WHERE state = 'needs_attention'
ORDER BY last_updated ASC;

-- View: all running sessions for roster
CREATE VIEW IF NOT EXISTS roster AS
SELECT
    tmux_location,
    state,
    state_reason,
    session_id,
    cwd,
    last_updated
FROM sessions
ORDER BY tmux_session, tmux_window, tmux_pane;
