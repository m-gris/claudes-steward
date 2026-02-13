#!/usr/bin/env bash
# probe.sh — Scientific hook probe for claudes-steward
# Records all hook events with full context for analysis
#
# IMPORTANT: This script must be FAST and NEVER fail with exit code 2
# (exit 2 would block Claude operations)

set -uo pipefail
# Note: no -e, we handle errors gracefully

# === Configuration ===
STEWARD_DIR="${STEWARD_DIR:-$HOME/DATA_PROG/AI-TOOLING/claudes-steward}"
LOG_DIR="$STEWARD_DIR/shared/experiments/logs"
CURRENT_LOG="$LOG_DIR/current.log"

# === Ensure log directory exists ===
mkdir -p "$LOG_DIR" 2>/dev/null || true

# === Capture timestamp early ===
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S.%3N')
TIMESTAMP_COMPACT=$(date '+%Y%m%d_%H%M%S')

# === Read JSON payload from stdin (must happen before any other stdin ops) ===
PAYLOAD=$(cat 2>/dev/null || echo '{"error": "failed to read stdin"}')

# === Extract key fields from payload ===
HOOK_EVENT=$(echo "$PAYLOAD" | jq -r '.hook_event_name // "UNKNOWN"' 2>/dev/null || echo "PARSE_ERROR")
SESSION_ID=$(echo "$PAYLOAD" | jq -r '.session_id // "unknown"' 2>/dev/null || echo "unknown")
CWD=$(echo "$PAYLOAD" | jq -r '.cwd // "unknown"' 2>/dev/null || echo "unknown")

# === Capture tmux context ===
if [[ -n "${TMUX:-}" ]] && command -v tmux &>/dev/null; then
    TMUX_SESSION=$(tmux display-message -p '#S' 2>/dev/null || echo "N/A")
    TMUX_WINDOW=$(tmux display-message -p '#I' 2>/dev/null || echo "N/A")
    TMUX_WINDOW_NAME=$(tmux display-message -p '#W' 2>/dev/null || echo "N/A")
    TMUX_PANE=$(tmux display-message -p '#P' 2>/dev/null || echo "N/A")
    TMUX_PANE_ID=$(tmux display-message -p '#D' 2>/dev/null || echo "N/A")
    TMUX_LOCATION="$TMUX_SESSION:$TMUX_WINDOW.$TMUX_PANE"
    IN_TMUX="yes"
else
    TMUX_SESSION="N/A"
    TMUX_WINDOW="N/A"
    TMUX_WINDOW_NAME="N/A"
    TMUX_PANE="N/A"
    TMUX_PANE_ID="N/A"
    TMUX_LOCATION="N/A"
    IN_TMUX="no"
fi

# === Capture environment hints ===
TMUX_PANE_ENV="${TMUX_PANE:-unset}"
TTY=$(tty 2>/dev/null || echo "no tty")

# === Write structured log entry ===
{
    echo "================================================================================"
    echo "HOOK EVENT: $HOOK_EVENT"
    echo "TIMESTAMP:  $TIMESTAMP"
    echo "--------------------------------------------------------------------------------"
    echo "TMUX:"
    echo "  in_tmux:     $IN_TMUX"
    echo "  location:    $TMUX_LOCATION"
    echo "  session:     $TMUX_SESSION"
    echo "  window:      $TMUX_WINDOW ($TMUX_WINDOW_NAME)"
    echo "  pane:        $TMUX_PANE (id: $TMUX_PANE_ID)"
    echo "  TMUX_PANE:   $TMUX_PANE_ENV"
    echo "--------------------------------------------------------------------------------"
    echo "CONTEXT:"
    echo "  session_id:  $SESSION_ID"
    echo "  cwd:         $CWD"
    echo "  tty:         $TTY"
    echo "--------------------------------------------------------------------------------"
    echo "PAYLOAD (raw JSON):"
    echo "$PAYLOAD" | jq '.' 2>/dev/null || echo "$PAYLOAD"
    echo "================================================================================"
    echo ""
} >> "$CURRENT_LOG" 2>/dev/null

# === Also write a machine-readable JSONL entry ===
JSONL_LOG="$LOG_DIR/current.jsonl"
{
    jq -n \
        --arg ts "$TIMESTAMP" \
        --arg event "$HOOK_EVENT" \
        --arg session_id "$SESSION_ID" \
        --arg cwd "$CWD" \
        --arg tmux_location "$TMUX_LOCATION" \
        --arg tmux_session "$TMUX_SESSION" \
        --arg tmux_window "$TMUX_WINDOW" \
        --arg tmux_pane "$TMUX_PANE" \
        --arg in_tmux "$IN_TMUX" \
        --argjson payload "$PAYLOAD" \
        '{
            timestamp: $ts,
            event: $event,
            session_id: $session_id,
            cwd: $cwd,
            tmux: {
                in_tmux: ($in_tmux == "yes"),
                location: $tmux_location,
                session: $tmux_session,
                window: $tmux_window,
                pane: $tmux_pane
            },
            payload: $payload
        }'
} >> "$JSONL_LOG" 2>/dev/null || true

# === Exit success (never exit 2, that would block Claude) ===
exit 0
