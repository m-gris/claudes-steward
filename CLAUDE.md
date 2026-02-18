# Agent Instructions

This project uses **bd** (beads) for issue tracking.

**New session?** Run `bd mol wisp onboard` and follow the steps.

## Navigating Beads (Don't Just Grep!)

When asked "is X in beads?" or "where is the design for Y?":

1. **Use `bd show` on relevant epics** — read the description and design fields
2. **Follow the hierarchy** — epics contain context, children contain implementation
3. **Check `shared/research/*.md`** — design docs are referenced from beads

**Wrong:** `bd list | grep "keyword"` then give up

**Right:**
```bash
bd show STEW-6lv          # Read the epic's description/design
bd show STEW-6lv.2        # Check children for more detail
cat shared/research/TRANSCRIPT-SEARCH-DESIGN.md  # Follow references
```

Beads descriptions often say "See shared/research/FOO.md" — follow those breadcrumbs.

## Landing the Plane (Session Completion)

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **PUSH TO REMOTE** - This is MANDATORY:
   ```bash
   git pull --rebase
   bd sync
   git push
   git status  # MUST show "up to date with origin"
   ```
5. **Clean up** - Clear stashes, prune remote branches
6. **Verify** - All changes committed AND pushed
7. **Hand off** - Provide context for next session

**CRITICAL RULES:**
- Work is NOT complete until `git push` succeeds
- NEVER stop before pushing - that leaves work stranded locally
- NEVER say "ready to push when you are" - YOU must push
- If push fails, resolve and retry until it succeeds

