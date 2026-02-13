#!/usr/bin/env bash
# Wrapper for OCaml steward-hook binary
# Must be fast (< 100ms) and never exit with code 2 (which blocks Claude)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OCAML_DIR="$SCRIPT_DIR/../ocaml"
BINARY="$OCAML_DIR/_build/default/bin/steward_hook.exe"

# Check if binary exists
if [[ ! -x "$BINARY" ]]; then
    # Binary not built yet — fail silently (don't block Claude)
    exit 0
fi

# Export DB path (use project-local db by default)
export STEWARD_DB="${STEWARD_DB:-$SCRIPT_DIR/../steward.db}"

# Run the OCaml binary, piping stdin through
exec "$BINARY"
