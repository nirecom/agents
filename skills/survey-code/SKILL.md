---
name: survey-code
description: Explore the codebase to understand existing patterns, constraints, and relevant files before planning.
model: sonnet
---

Investigate the codebase related to the given task.

## Procedure

### Step 0 — Resolve <PLANS_DIR>

Before any tool call below that references <PLANS_DIR>, run the following Bash command exactly once:

```bash
PLANS_DIR=$(bash "$AGENTS_CONFIG_DIR/bin/workflow-plans-dir" 2>/dev/null \
              || printf '%s\n' "${WORKFLOW_PLANS_DIR:-$HOME/.workflow-plans}")
printf 'PLANS_DIR=%s\n' "$PLANS_DIR"
```

Capture the printed absolute path and substitute it for every <PLANS_DIR>
placeholder in the remainder of this SKILL.md. Subagent prompts must receive
the resolved absolute path as a literal string (subagents cannot expand $VAR).
Reuse across all subsequent steps in this skill invocation — do not re-resolve.

When invoked as a parallel Agent subagent by workflow-init, the orchestrator
passes `artifact_path` and `context_path` as resolved absolute strings — use
those instead of running Step 0.

Canonical documentation: skills/_shared/resolve-plans-dir.md.

0. **Claim extraction** (run before reading any code):
   Input precedence (read whichever exists first):
     (a) `<PLANS_DIR>/<session-id>-intent.md` — preferred (post-clarify-intent calls)
     (b) `<PLANS_DIR>/<session-id>-context.md` — fallback (pre-clarify-intent calls
         from workflow-init; use "User initial prompt" and "Issue body" sections)
   If neither exists: proceed to Step 1 with an empty claim list.
   Extract up to 5 behavioral/factual claims from Background/Motivation and Scope.
   Target: "X is blocked", "X does Y", "X is broken", "X cannot Z". Exclude aesthetic
   claims and pure preferences. Works with Japanese and English content.

1. Identify candidate files and areas using Glob and Grep.
2. Read relevant source files, configs, tests, and docs.
3. For each claim extracted in Step 0, verify it against the current codebase:
   - `verdict: holds` — evidence in code confirms the claim
   - `verdict: contradicted` — evidence in code contradicts the claim
   - `verdict: indeterminate` — insufficient evidence to confirm or deny
4. Summarize: existing patterns, architectural constraints, relevant files (with line numbers), and anything that affects implementation.
5. Write findings to `<PLANS_DIR>/<session-id>-survey-code.md`. The file must
   include a `## Verified Claims` section:
   ```
   ## Verified Claims
   - claim: <text from intent.md>
     verdict: holds | contradicted | indeterminate
     evidence: <file:line or "no matching code found">
   ```
   If no claims were extracted in Step 0, write the section with the note
   "No verifiable behavioral/factual claims found in intent.md or context.md."

   The file must also include a `## Candidate class members` section:
   ```
   ## Candidate class members
   - <member name>: <one-line role> (<file>:<line>)
     proposed triage: <MUST | OPTIONAL | NA> — <one-line rationale>
   ```
   List sibling members of the class being changed (per `rules/core-principles.md`
   §1 Elevate Perspective). Each member is two lines: (a) name + role + primary
   file:line reference; (b) `proposed triage:` value and 1-line rationale grounded
   in the survey evidence. Triage values:
   - `proposed triage: MUST` — symmetric to the user-requested change; failing to fix it leaves the class inconsistent.
   - `proposed triage: OPTIONAL` — related but independently fixable; user choice whether to bundle.
   - `proposed triage: NA` — sibling exists but genuinely orthogonal; no fix needed for this task.
   When uncertain, propose `OPTIONAL`. If no candidates are detected, write a
   single line: `- (none detected)`. This section is required.
6. Present findings for user review before proceeding to plan.

## Rules

- Read **project source files** only — do not modify them. Writing the output
  artifact to `<PLANS_DIR>/<session-id>-survey-code.md` (Step 5 above) is
  REQUIRED and allowed — `<PLANS_DIR>` lives outside the git repo. See
  `skills/_shared/survey-artifact-valid.md` for the artifact validity contract.
- Use Explore subagents for broad searches when needed
- Follow `rules/core-principles.md`.
- Do NOT emit the research-complete sentinel — `make-outline-plan` Step 0 aggregates
  both survey-code and survey-history before emitting it.

## Completion

After completing this skill:
1. Invoke `make-outline-plan` via the Skill tool.
   Note: when invoked as a parallel Agent subagent by workflow-init, skip this step —
   Do NOT invoke make-outline-plan. workflow-init orchestrates the next stage.

Skip this skill when the change target is already known (single file/function).

If research is genuinely not needed for this task (typo fix, docs-only change):
1. Run: `echo "<<WORKFLOW_RESEARCH_NOT_NEEDED: <reason>>"` (reason must be ≥3 non-space chars, not a placeholder like "none"/"skip", and contain no '>')
2. Invoke `make-outline-plan` via the Skill tool.
