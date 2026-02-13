# Language Choice: OCaml

> **Date**: 2026-02-06
> **Decision**: Use OCaml for hook scripts and core logic
> **Status**: Decided

---

## Context

claudes-steward needs hook scripts that:
- Are called by Claude Code on lifecycle events (SessionStart, Stop, PermissionRequest, etc.)
- Read JSON from stdin
- Capture tmux context
- Write state to SQLite
- Must be **FAST** (hooks block Claude)
- Must be **RELIABLE** (silent failures lose data)

---

## The Question

> "Do we still want to stick with bash? Or move to a 'proper language'?"

Initial bash prototype had issues:
- SQL injection risk (unescaped strings)
- Fragile JSON parsing (jq can fail silently)
- Weak error handling
- State machine logic gets messy

---

## Languages Evaluated

### Mainstream Options

| Language | Startup | Safety | JSON | SQLite | Verdict |
|----------|---------|--------|------|--------|---------|
| **Bash** | ~1ms | Poor | jq (fragile) | CLI | Fast but brittle |
| **Python/uv** | ~20ms | Medium | Native | Native | Quick iteration, acceptable speed |
| **Rust** | ~1ms | Excellent | serde | rusqlite | Best runtime, slower dev |
| **Go** | ~3ms | Good | Native | Native | Pragmatic middle ground |

### FP Options

| Language | Startup | Native? | State Machines | Ecosystem |
|----------|---------|---------|----------------|-----------|
| **OCaml** | ~1-5ms | Yes | Excellent (ADTs, pattern match) | Solid |
| **Haskell** | ~50-100ms | Possible | Excellent | Rich but heavy runtime |
| **Scala Native** | ~10-20ms | Yes | Good (case classes) | Limited, gaps |
| **F#** | ~30-50ms | .NET | Good | .NET ecosystem |

---

## Why OCaml?

### 1. Startup Time (Critical)

Hooks are called on **every** Claude Code event. Latency matters.

```
OCaml native:  ~1-5ms   ✓
Rust:          ~1ms     ✓
Go:            ~3ms     ✓
Python/uv:     ~20ms    Acceptable
Haskell:       ~50-100ms  Too slow
Scala Native:  ~10-20ms  Marginal
```

OCaml compiles to native code with minimal runtime overhead.

### 2. State Machines (The Core Problem)

The hook logic is fundamentally a state machine:

```
SessionStart      → Working
UserPromptSubmit  → Working
Stop              → NeedsAttention(Done)
PermissionRequest → NeedsAttention(Permission)
Notification(Elicitation) → NeedsAttention(Question)
SessionEnd        → Remove
```

OCaml's ADTs and pattern matching express this perfectly:

```ocaml
type hook_event =
  | SessionStart
  | Stop
  | PermissionRequest
  | UserPromptSubmit
  | SessionEnd
  | Notification of notification_type

type state = Working | NeedsAttention of reason
type reason = Done | Permission | Question

let transition event = match event with
  | SessionStart -> Working
  | UserPromptSubmit -> Working
  | Stop -> NeedsAttention Done
  | PermissionRequest -> NeedsAttention Permission
  | Notification Elicitation -> NeedsAttention Question
  | SessionEnd -> (* delete from DB *)
```

The compiler ensures all cases are handled. No silent bugs.

### 3. Safety

- **No SQL injection**: Parameterized queries via Caqti/sqlite3-ocaml
- **No null pointer exceptions**: Option types
- **Exhaustive pattern matching**: Compiler catches missing cases
- **Strong typing**: JSON parsing errors are explicit

### 4. Unix Philosophy (/fp-unix)

OCaml encourages separation of:
- **Data** (types for events, states)
- **Logic** (pure transition functions)
- **Effects** (IO at the edges — read stdin, write DB)

This makes the code testable and composable.

### 5. Ecosystem

- **yojson** / **ppx_yojson_conv**: JSON parsing with type derivation
- **sqlite3-ocaml** / **caqti**: SQLite bindings
- **dune**: Modern build system
- **opam**: Package manager

---

## Why Not Others?

### Bash
- SQL injection risk
- Fragile error handling
- State machine logic is ugly

### Python
- 20ms startup is acceptable but not ideal
- Dynamic typing means runtime errors
- Would work, but OCaml is better fit

### Rust
- Excellent choice, but:
- Slower development iteration
- More verbose for this problem size
- Ownership model overkill for simple scripts

### Haskell
- **Too slow** — GHC runtime adds 50-100ms startup
- Laziness can cause surprising behavior
- Would be great if startup weren't critical

### Scala Native
- User knows Scala, but:
- Ecosystem gaps (SQLite bindings?)
- Fighting limitations
- Compile times

### Go
- Pragmatic, would work
- But: less expressive for state machines
- Verbose compared to OCaml

---

## Architecture with OCaml

```
┌─────────────────────────────────────────────────────────────┐
│                   Claude Code Hook                          │
│                 (calls our binary)                          │
└─────────────────────────────────────────────────────────────┘
                              │
                              │ stdin: JSON payload
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                   steward-hook (OCaml)                      │
│                                                             │
│  1. Parse JSON → hook_event                                 │
│  2. Capture tmux context                                    │
│  3. Compute state transition (pure)                         │
│  4. Write to SQLite                                         │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                   steward.db (SQLite)                       │
└─────────────────────────────────────────────────────────────┘
```

Single binary, called by all hooks:
```json
{
  "hooks": {
    "SessionStart": [{"type": "command", "command": "steward-hook"}],
    "Stop": [{"type": "command", "command": "steward-hook"}],
    "PermissionRequest": [{"type": "command", "command": "steward-hook"}],
    ...
  }
}
```

---

## Project Structure (Proposed)

```
shared/
├── ocaml/
│   ├── dune-project
│   ├── bin/
│   │   └── steward_hook.ml    # Entry point
│   ├── lib/
│   │   ├── types.ml           # ADTs for events, states
│   │   ├── transition.ml      # Pure state machine
│   │   ├── tmux.ml            # Tmux context capture
│   │   ├── db.ml              # SQLite persistence
│   │   └── json.ml            # JSON parsing
│   └── test/
│       └── transition_test.ml # Unit tests for state logic
```

---

## Trade-offs Accepted

| Trade-off | Mitigation |
|-----------|------------|
| Less familiar than Python | OCaml is expressive, quick to learn |
| Smaller ecosystem | Core needs (JSON, SQLite) are covered |
| Compilation step | `dune build` is fast, can use `dune watch` |
| Binary distribution | Single native binary, no runtime deps |

---

## Next Steps

1. [ ] Set up OCaml project structure with dune
2. [ ] Define types (hook_event, state, etc.)
3. [ ] Implement pure state transition function
4. [ ] Add JSON parsing with yojson
5. [ ] Add tmux context capture
6. [ ] Add SQLite persistence
7. [ ] Build and test
8. [ ] Update .claude/settings.json to use binary

---

## References

- [OCaml official](https://ocaml.org/)
- [Real World OCaml](https://dev.realworldocaml.org/)
- [yojson](https://github.com/ocaml-community/yojson)
- [sqlite3-ocaml](https://github.com/mmottl/sqlite3-ocaml)
- [dune](https://dune.build/)
