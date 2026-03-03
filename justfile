# claudes-steward — top-level recipes
# Sub-projects: shared/ocaml/justfile, shared/qdrant/justfile

# ============================================================================
# Build & Test (delegates to OCaml sub-project)
# ============================================================================

# Build the OCaml project
build:
    just shared/ocaml/build

# Run all tests
test:
    just shared/ocaml/test

# Check types without building
check:
    just shared/ocaml/check

# Format code
fmt:
    just shared/ocaml/fmt

# ============================================================================
# Install (delegates to OCaml sub-project)
# ============================================================================

# Install all binaries to ~/.local/bin/
install: build
    just shared/ocaml/install

# Uninstall binaries from ~/.local/bin/
uninstall:
    just shared/ocaml/uninstall

# ============================================================================
# Qdrant (delegates to Qdrant sub-project)
# ============================================================================

# Start Qdrant server (background)
qdrant-start:
    just shared/qdrant/start-bg

# Stop Qdrant server
qdrant-stop:
    just shared/qdrant/stop

# Check Qdrant health
qdrant-health:
    just shared/qdrant/health

# ============================================================================
# Development
# ============================================================================

# Start all services needed for development
up: qdrant-start
    @echo "Services ready."

# Stop all services
down: qdrant-stop
    @echo "Services stopped."
