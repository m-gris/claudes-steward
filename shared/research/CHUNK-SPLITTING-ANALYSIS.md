# Chunk Splitting Strategy Analysis

> Parent task: STEW-6lv.2.6
> Status: **Solution enumeration complete — awaiting user decision**
> Last updated: 2026-02-12

## Problem Statement

Given transcript turns that can exceed the embedding model's context window (8192 tokens for nomic-embed-text), transform them into embeddable chunks such that:
1. No content is silently dropped
2. Semantic searchability is preserved or improved
3. Chunk IDs remain deterministic (for incremental indexing)
4. Headroom exists for ~500 token contextual prefix

## Decomposition

| Layer / Aspect | Question to Answer | Status |
|----------------|-------------------|--------|
| **Measurement** | What are the 205 failing turns? Size distribution? | ✅ DONE |
| **Content analysis** | Are long turns mostly tool outputs, code, or dialogue? | ✅ DONE |
| **Semantic unit** | What's the smallest unit that remains searchable? | ✅ Turns, with sub-chunks when needed |
| **Boundary detection** | Where can we split without breaking meaning? | ✅ Tool calls, code fences, paragraphs |
| **ID stability** | How do we generate deterministic IDs for sub-chunks? | ✅ `{parent_id}:{hash}` |
| **Overlap strategy** | Do split chunks need overlapping context? | ⏳ User decision: 10-20% recommended |
| **Metadata propagation** | How do sub-chunks inherit session_id, timestamp? | ✅ Copy all, add chunk_type |
| **Retrieval behavior** | When sub-chunk matches, what do we return? | ⏳ User decision needed |

## Unknowns to Investigate

### Missing Information
1. [x] What's in the 202 failing turns? Token distribution? Content type? → **DONE: See findings below**
2. [x] How does Anthropic's contextual retrieval handle long chunks? → **DONE: 250-512 tokens, 10-20% overlap**
3. [x] Does nomic-embed-text degrade gracefully near limit, or hard-fail? → **DONE: Hard fail (HTTP 400)**

### Technical Unknowns
4. [~] If turn splits into A and B, and search spans both, will either match? → **Mitigated by overlap strategy**
5. [x] What overlap size preserves cross-boundary retrieval? → **10-20% recommended**

### User Decisions Needed (see Solution Enumeration)
6. [ ] Is summarizing/dropping tool outputs acceptable?
7. [ ] Is returning "chunk 2 of 3" with pointer to full turn acceptable?
8. [ ] Should sub-chunks include overlap with adjacent sub-chunks?

## Assumptions Challenged

| Assumption | Challenge | Finding |
|------------|-----------|---------|
| "Turns" are the right unit | Maybe messages? Sliding windows? | TBD |
| All content worth embedding | Tool outputs may be noise | **Log pastes = noise** |
| 8192 tokens is the limit | Need ~7700 for context prefix | **Effective limit varies by content!** |
| Must embed everything | Could skip/summarize tool-heavy turns | **Consider skipping** |
| Long = problematic | Long turns may be *more* valuable | Mixed - depends on content |

## Investigation Findings

### Unknown #1: The 205 Failing Turns (2026-02-12)

**Statistics:**
- Count: 205 failing chunks
- Min: 4,509 chars
- Max: 713,869 chars
- Median: 11,879 chars

**Character length distribution:**
| Range | Count | % |
|-------|-------|---|
| <10k chars | 70 | 34% |
| 10k-20k chars | 87 | 42% |
| 20k-30k chars | 19 | 9% |
| 30k-50k chars | 20 | 9% |
| 50k-100k chars | 4 | 1% |
| 100k+ chars | 5 | 2% |

**Content categories:**
| Category | Count | % | Avg Chars | Notes |
|----------|-------|---|-----------|-------|
| long_dialogue | 111 | 54% | 17,534 | Normal conversation overflow |
| compaction_summary | 31 | 15% | 11,520 | Context recovery after /compact |
| long_plan | 20 | 10% | 13,140 | Implementation plans |
| log_paste | 16 | 8% | 26,386 | User pasted log output |
| intentional_dump | 10 | 5% | 31,732 | User explicitly dumped content |
| test_output_paste | 9 | 4% | 14,537 | pytest/test results |
| stack_trace_paste | 6 | 3% | 55,855 | Error traces |
| git_diff_paste | 2 | 1% | 713,869 | Full git diffs |

### Unknown #3: Model Behavior - CRITICAL FINDING

**Tokenization varies dramatically by content type:**

| Content Type | Char Limit | Tokens/Char | Chars/Token |
|--------------|------------|-------------|-------------|
| English prose | ~9,400 | 0.87 | 1.15 |
| Log output | ~5,500 | 1.47 | 0.68 |
| Stack traces | ~4,800 | 1.70 | 0.59 |

**Key insight:** The 8192 token limit translates to:
- English prose: ~9-10k char limit
- Log/stack traces: ~5-6k char limit
- This explains why 4,509 char minimum fails - it's token-dense content

**Model behavior:** Hard fail (HTTP 400), no graceful degradation.

### Unknown #2: Anthropic's Contextual Retrieval Approach (2026-02-12)

**Source:** https://www.anthropic.com/news/contextual-retrieval

**Chunk Size:**
- Anthropic uses ~800 token chunks in their examples
- Industry consensus: start with 250-512 tokens, adjust based on testing
- Maximum embedding model capacity (8k) not recommended - creates coarse representations

**Context Prepending:**
- Add 50-100 tokens of context BEFORE embedding
- Prompt: *"Please give a short succinct context to situate this chunk within the overall document for the purposes of improving search retrieval."*
- Use cheap model (Claude Haiku) for context generation

**Overlap Strategy:**
- 10-20% overlap recommended (50-100 tokens for 500-token chunks)
- Helps preserve continuity at boundaries
- Too much overlap = redundancy, reduced effective capacity

**Conversation/Transcript-Specific Guidance:**
(From industry best practices)
- Sliding window useful for chat logs, transcripts
- Keep one speaker's speech contained within a chunk
- Attach speaker labels and timestamps as metadata
- Query-dependent: optimal chunk size varies by content type

**Hierarchical Chunking:**
- For very long documents: chunk recursively (chapter → page → paragraph)
- Allows retrieval at multiple granularity levels

**Retrieval:**
- Retrieve top-20 chunks (outperforms top-10 or top-5)
- Combine with BM25 hybrid search for best results
- Reranking adds another 5-10% improvement

**Key Insight for Our Use Case:**
Turns are already semantic units. For oversized turns:
1. Split at natural boundaries (tool calls, code blocks, paragraphs)
2. Use sliding window with overlap for truly long content
3. Preserve metadata (session_id, timestamp, project) on all sub-chunks
4. Consider summarizing noise (log pastes, stack traces) rather than embedding verbatim

**Sources:**
- https://www.anthropic.com/news/contextual-retrieval
- https://stackoverflow.blog/2024/12/27/breaking-up-is-hard-to-do-chunking-in-rag-applications/
- https://unstructured.io/blog/chunking-for-rag-best-practices
- https://docs.cohere.com/v2/page/chunking-strategies

---

## Solution Enumeration (2026-02-12)

### Candidate Approaches

#### Path A: Conservative Char Limit
Split all turns at fixed threshold (4,000 chars) to handle worst-case tokenization.

**Key insight:** Use worst-case ratio as universal limit.

**Steps:**
1. Define threshold: `min_safe = 8192 / 1.7 - 500 ≈ 4,300 chars`
2. Measure turn length
3. Split at paragraph boundaries (double newline)
4. Fallback: split at word boundary if no paragraphs
5. Generate sub-chunk IDs: `{parent_id}:{index}`
6. Propagate metadata to sub-chunks

#### Path B: Content-Aware Splitting ⭐ RECOMMENDED
Detect content type, apply type-specific limits, split at natural boundaries.

**Key insight:** Match strategy to content's tokenization density.

**Steps:**
1. Classify content: prose vs logs vs code (heuristics)
2. Apply type-specific limits: Prose 8k, Code 6k, Logs 4k
3. Identify natural boundaries: tool calls, code fences, paragraphs
4. Split at boundaries, prefer natural over arbitrary
5. Generate IDs: `{parent_id}:{content_hash[:8]}`
6. Propagate metadata + add `chunk_type` field

#### Path C: Hierarchical Chunking
Keep turns as parents, create sub-chunks only when needed, link back.

**Key insight:** Preserve semantic wholeness via parent-child relationships.

**Steps:**
1. Store full turn content (not embedded)
2. If turn < 4k chars, embed directly
3. Create sub-chunks for oversized, link to parent
4. Embed sub-chunks only
5. Search returns sub-chunk + parent context

#### Path D: Filter + Summarize Noise
Detect noise (logs, traces), summarize via LLM, embed summary.

**Key insight:** Compress noise, preserve signal.

**Steps:**
1. Detect noise patterns (regex)
2. LLM summarize: "Summarize this log in 2-3 sentences"
3. Replace noise with summary
4. Embed cleaned turn
5. Store original for retrieval display

#### Path E: Sliding Window
Fixed window (3k chars) with 20% overlap, ignore turn boundaries.

**Key insight:** Uniform treatment eliminates edge cases.

**Steps:**
1. Concatenate all turns in session
2. Slide window: size=3000, stride=2400
3. Generate IDs: `{session_id}:{offset}`
4. Embed all windows uniformly

### Tradeoff Matrix

| Dimension | A: Conservative ⭐ | B: Content-Aware | C: Hierarchical | D: Summarize | E: Sliding |
|-----------|-------------------|------------------|-----------------|--------------|------------|
| Complexity | **Low** | Medium | Medium | High (LLM) | Low |
| Reversibility | **High** | High | High | Medium | High |
| ID Stability | **Good** | Good | Good | Fragile | Different |
| Semantic coherence | Medium* | High | High | High | Low |
| Search quality | Medium* | High | High | High | Medium |
| LLM dependency | **None** | None | None | Required | None |
| Incremental indexing | **Easy** | Easy | Complex | Complex | Tricky |
| Anthropic-aligned | **Yes** | No | Partial | No | No |

*Compensated by context enrichment in Phase 2

### Recommendation: Path A (Conservative) — Anthropic-Aligned

**Revised rationale:**
Anthropic's actual approach is simpler than content-aware splitting. They use:
1. Fixed chunk size (~800 tokens)
2. Context enrichment via LLM (the key innovation)
3. Let the context prefix compensate for semantic breaks

**Why this is better:**
- Simpler implementation, fewer edge cases
- Context enrichment (Phase 2) will add semantic grounding anyway
- No content classification heuristics to maintain
- Proven at scale by Anthropic

**Implementation:**
1. Use conservative fixed limit: **4,000 chars** (safe for worst-case tokenization)
2. Split at paragraph boundaries when possible
3. Fallback to word boundaries
4. Deterministic sub-chunk IDs: `{parent_id}:{index}`
5. Later: add context prefix in Phase 2 (STEW-6lv.2.2)

**Tradeoffs accepted:**
- Some over-splitting of prose content (could fit more)
- Compensated by context enrichment in Phase 2

**Reconsider Path B if:**
- Context enrichment proves insufficient for search quality
- We need to optimize chunk count (storage/cost concerns)

### Remaining Decisions (User Input Needed)

1. **Overlap:** Include 10-20% overlap between sub-chunks? (Anthropic recommends yes)
2. **Result format:** Accept "chunk 2 of 3" or always return full turn context?

### Implementation Steps (Path A)

1. Define char limit constant: `MAX_CHUNK_CHARS = 4000`
2. Add paragraph-boundary split function
3. Add word-boundary fallback split
4. Generate deterministic sub-chunk IDs
5. Update indexer to split before embedding
6. Test: verify 0 embedding errors

### Risks to Monitor

- Very long single paragraphs with no breaks → word-boundary fallback handles this
- Compaction summaries (15%) may get over-split → acceptable, context enrichment will help
