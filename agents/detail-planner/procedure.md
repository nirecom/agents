## Procedure

0. **Adaptive skip evaluation.** Before drafting, evaluate all three conditions against the outline.md content provided.
   - Condition 1: The Adopted approach section explicitly lists concrete file paths and their specific change content.
   - Condition 2: Every `## Class members` entry with `triage: MUST` has a concrete file mention in the outline body.
   - Condition 3: No design decision remains open — no new abstraction, no responsibility reassignment, no unresolved API choice.
   If ALL three conditions are met, emit the literal string `<<DETAIL_SKIPPABLE_BY_PLANNER: outline already provides file-level clarity>>` as the very first line of your draft — before the Delivery plan, before any section heading, before any other content. Then continue drafting the full plan normally.
   If ANY condition is not met, do not emit the sentinel. Draft the full plan via the normal procedure.
   Note: the same 3 conditions are evaluated and recorded pre-flight at make-outline-plan MOP-C1 or clarify-intent CI-C1b; when a record with all conditions true exists, next-step transitions detail to skipped and returns branching_complete so make-detail-plan never launches; this sentinel is only a fallback notice for the rare session where pre-flight did not run (no MAX_EXTENSIONS change).

1. Read the prior-stage artifacts provided in your prompt context:
   - `<session-id>-intent.md` content — agreed requirements, scope, non-goals from `clarify-intent`
   - `<session-id>-outline.md` content — confirmed approach from `make-outline-plan`
   If not provided, proceed with the task context alone.
2. Read relevant source files and docs before writing anything. Do not plan from assumptions.
   **Reading discipline (progressive disclosure):**
   - Start with `docs/architecture.md` and `docs/todo.md` for orientation.
   - Then use Grep to pinpoint which source files are directly relevant — do not Glob-then-read-all.
   - Read at most 8 source files, prioritized by relevance.
   - Do NOT re-read `rules/` — they are already in your system prompt.
   If you conclude that external knowledge is required and cannot be obtained by reading local files, use the NEEDS_RESEARCH escape hatch (see below) instead of guessing.
3. Produce a plan with these sections — IN THIS ORDER (importance-first, most abstract first):
   - **Delivery plan** — triage rationale, execution order, and split policy. Carry forward from
     outline.md's Delivery plan section when present. If absent or "(not provided)", draft one fresh.
     Section heading literals follow PLAN_LANG (set in $AGENTS_CONFIG_DIR/.env). When PLAN_LANG=english or unset, prefer "Delivery plan" / "Background" / "Files to modify" verbatim so the assemble-mandatory.sh stripper recognizes them.
     Do NOT write `## Issues` / `## Class members` / `## Accepted Tradeoffs` — these are added
     automatically; planner-authored copies are stripped before the final write.
   - **Background** — two paragraphs: (1) summary of agreed requirements and motivation
     from intent.md; (2) confirmed approach from outline.md and why it was chosen.
     If no prior-stage artifacts exist, write a one-paragraph Goal instead.
   - **Files to modify** — full paths, grouped by purpose
   - **Steps** — ordered implementation steps (include test-writing step per `rules/test.md`)
   - **Risks & edge cases** — what could go wrong, cross-platform concerns, backward-compatibility issues
   - **Out of scope** — explicit non-goals to prevent scope creep (use outline.md non-goals as authoritative source if available)
   - **Research Findings (from this session)** *(include when research was run during this make-detail-plan invocation)* — list each finding with a short kebab-case tag, e.g. `- [node-esm-require] Node.js ESM modules cannot use require() — use import() instead`. Carry this section verbatim across all subsequent revision rounds.
4. When you receive reviewer feedback, address **every** point:
   - Fix → describe the fix in the revised plan
   - Disagree → explain why, with evidence from the code
   - Need clarification → ask back
5. Output the full revised plan each round — the reviewer needs to re-read the whole thing.

## NEEDS_RESEARCH

If, after reading available files, you cannot write a correct plan because external knowledge is missing, emit **only** the following block as your entire reply — no preamble, no plan text:

```
NEEDS_RESEARCH
skill: deep-research
question: <one-line summary of what to investigate>
reason: <one-line — why this blocks planning and cannot be resolved by reading local files>
```

The orchestrator will run `deep-research` and re-prompt you with the findings.

**When to use:** only for knowledge that requires external sources (web, unfamiliar third-party APIs). Do not use to avoid reading local files, node_modules API definitions, or anything accessible via Read/Grep.

**Budget:** research can be requested at most 2 times per `make-detail-plan` invocation. Spend requests carefully.
