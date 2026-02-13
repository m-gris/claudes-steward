> **ATOMIZED** → Epic: STEW-6lv.2.6 | 2026-02-13

# Plan: Chunk Splitting (Anthropic-Aligned, Path A)

> Task: STEW-6lv.2.6
> Approach: Conservative fixed limit + 10% overlap
> Methodology: dual-TDD-autonomous, FP/Unix principles

## Goal

Transform `turn_to_chunk : transcript_turn -> index_chunk` into
`turn_to_chunks : transcript_turn -> index_chunk list` that:
- Splits turns > 4,000 chars into multiple chunks
- Uses 10% overlap between adjacent sub-chunks
- Achieves 0 embedding errors on full corpus

## Architecture (FP/Unix)

```
Functional Core (pure, no I/O):
├── split_text : max_size:int -> overlap:int -> string -> string list
├── split_at_paragraphs : string -> string list
├── split_at_words : int -> string -> string list
└── turn_to_chunks : transcript_turn -> index_chunk list

Imperative Shell (unchanged):
└── steward_index.ml calls turn_to_chunks instead of turn_to_chunk
```

## Beads Structure (dual-TDD-autonomous)

```
STEW-6lv.2.6: Chunk splitting strategy (existing, claim this)
├── STEW-6lv.2.6.T: Define types for chunk splitting
├── STEW-6lv.2.6.C: Compile check
├── STEW-6lv.2.6.W: Write tests for splitting
├── STEW-6lv.2.6.R: Red phase - tests fail
├── STEW-6lv.2.6.I: Implement splitting logic
├── STEW-6lv.2.6.G: Green phase - tests pass
├── STEW-6lv.2.6.F: Refactor if needed
└── STEW-6lv.2.6.V: Verify 0 errors on full corpus
```

## Phase Details

### T: Types (lib/types.ml)

Add constant and consider if index_chunk needs changes:
- `max_chunk_chars : int` constant (4000)
- `chunk_overlap_ratio : float` constant (0.10)
- index_chunk already has all needed fields (no changes needed)

### W: Tests (test/test_steward.ml)

Pure function tests (no mocks):
```
test_split_text_short        - content < limit returns singleton
test_split_text_exact        - content = limit returns singleton
test_split_text_long         - content > limit returns multiple
test_split_text_overlap      - adjacent chunks overlap by 10%
test_split_text_paragraphs   - splits at paragraph boundaries
test_split_text_words        - fallback to word boundaries
test_split_text_determinism  - same input = same output
test_turn_to_chunks_short    - short turn returns single chunk
test_turn_to_chunks_long     - long turn returns multiple chunks
test_turn_to_chunks_ids      - sub-chunk IDs are deterministic
test_turn_to_chunks_metadata - all chunks have same session/project
```

### I: Implementation (lib/embed.ml)

```ocaml
(* Constants *)
let max_chunk_chars = 4000
let overlap_ratio = 0.10

(* Pure: split at paragraph boundaries *)
let split_at_paragraphs (text : string) : string list

(* Pure: split at word boundaries with size limit *)
let split_at_words (max_size : int) (text : string) : string list

(* Pure: main splitting logic with overlap *)
let split_text ~max_size ~overlap (text : string) : string list

(* Pure: convert turn to one or more chunks *)
let turn_to_chunks (turn : transcript_turn) : index_chunk list
```

### V: Verification

```bash
just build && just test
steward-index --dry-run  # Should show 0 errors expected
steward-index            # Run actual indexing, verify 0 errors
```

## Files to Modify

| File | Change |
|------|--------|
| `lib/types.ml` | Add max_chunk_chars, overlap_ratio constants |
| `lib/embed.ml` | Add split_text, split_at_paragraphs, split_at_words, turn_to_chunks |
| `bin/steward_index.ml` | Change `turn_to_chunk` → `turn_to_chunks`, flatten results |
| `test/test_steward.ml` | Add 11 new tests for splitting logic |

## ID Generation Strategy

Sub-chunk IDs must be deterministic for incremental indexing:
```
{parent_turn_id}:{chunk_index}

Example:
  turn_id = "abc123"
  chunks = ["abc123:0", "abc123:1", "abc123:2"]
```

## Overlap Strategy

For 4000 char chunks with 10% overlap:
- Overlap = 400 chars
- Stride = 3600 chars
- Chunk N starts at: N * 3600
- Chunk N ends at: N * 3600 + 4000

```
|<------ 4000 ------>|
                |<-- 400 -->|<------ 4000 ------>|
[     Chunk 0       ]
              [     Chunk 1       ]
                            [     Chunk 2       ]
```

## Verification Checklist

- [ ] `just build` succeeds
- [ ] `just test` - all 66+ tests pass (11 new)
- [ ] `steward-index --dry-run` shows plan with 0 expected errors
- [ ] `steward-index` completes with 0 actual errors
- [ ] Spot check: search still finds content from long turns
