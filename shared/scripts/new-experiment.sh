#!/usr/bin/env bash
# new-experiment.sh — Start a fresh experiment with clean logs
#
# Usage: ./new-experiment.sh <experiment-name>
# Example: ./new-experiment.sh "probe-sessionstart"

set -euo pipefail

STEWARD_DIR="${STEWARD_DIR:-$HOME/DATA_PROG/AI-TOOLING/claudes-steward}"
LOG_DIR="$STEWARD_DIR/shared/experiments/logs"
OBS_DIR="$STEWARD_DIR/shared/experiments/observations"

EXPERIMENT_NAME="${1:-unnamed}"
TIMESTAMP=$(date '+%Y-%m-%d_%H%M%S')
ARCHIVE_NAME="${TIMESTAMP}_${EXPERIMENT_NAME}"

# === Archive current logs if they exist ===
if [[ -f "$LOG_DIR/current.log" ]] && [[ -s "$LOG_DIR/current.log" ]]; then
    mv "$LOG_DIR/current.log" "$LOG_DIR/${ARCHIVE_NAME}.log"
    echo "Archived: ${ARCHIVE_NAME}.log"
fi

if [[ -f "$LOG_DIR/current.jsonl" ]] && [[ -s "$LOG_DIR/current.jsonl" ]]; then
    mv "$LOG_DIR/current.jsonl" "$LOG_DIR/${ARCHIVE_NAME}.jsonl"
    echo "Archived: ${ARCHIVE_NAME}.jsonl"
fi

# === Create fresh logs ===
mkdir -p "$LOG_DIR"
: > "$LOG_DIR/current.log"
: > "$LOG_DIR/current.jsonl"

# === Create observation template ===
OBS_FILE="$OBS_DIR/${TIMESTAMP}_${EXPERIMENT_NAME}.md"
cat > "$OBS_FILE" << EOF
# Experiment: $EXPERIMENT_NAME

> **Date**: $(date '+%Y-%m-%d %H:%M')
> **Log files**: logs/${ARCHIVE_NAME}.*

## Hypothesis

What do we expect to happen?

-

## Setup

What hooks are configured? Any special conditions?

-

## Execution

What did we do?

1.

## Observations

What actually happened?

-

## Findings

What did we learn? Confirmed/refuted?

-

## Next Steps

What should we test next based on this?

-
EOF

echo ""
echo "=== New experiment started: $EXPERIMENT_NAME ==="
echo "Log:         $LOG_DIR/current.log"
echo "Log (jsonl): $LOG_DIR/current.jsonl"
echo "Observation: $OBS_FILE"
echo ""
echo "To watch live: tail -f $LOG_DIR/current.log"
