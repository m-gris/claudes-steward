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

# DB path: XDG default lives in ~/.local/share/claude-steward/steward.db
# The OCaml binary handles this internally; only override via STEWARD_DB if needed

# Run the OCaml binary, piping stdin through
exec "$BINARY"
