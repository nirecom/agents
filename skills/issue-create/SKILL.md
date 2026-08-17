---
name: issue-create
description: Create a task GitHub Issue with the type:task label and add it to Projects v2, after surveying existing issues for duplicates, parents, and siblings.
user-invocable: true
---

The sanctioned path for creating **task issues** (`type:task`) from a Claude Code
session. Surveys existing issues first, classifies the relationship semantically,
then dispatches to a wrapper that handles reopen / sub-issue attach / new-parent
reclassification / sibling cross-reference / plain creation. The dispatcher
delegates new-issue creation to `bin/github-issues/issue-create.sh`.

## Scope

- **In scope**: task issues (`type:task`) for the current repository.
- **Out of scope**: incident issues (use the web UI incident template or
  `gh issue create --label "type:incident"` directly); issues for other repos or
  projects (use `gh issue create --repo OWNER/REPO` directly).

Required reading: Read `rules/github-issues.md` before Pre-flight — it is on-demand-only and never auto-injected.

## Phase 0b — Project preflight

Runs before Pre-flight. Detects a missing Projects v2 board and offers to run `/issue-setup`. Independent of Phase 0a (label auto-repair in `issue-create.sh`) — one's result never affects the other.

- Skip Phase 0b and proceed to Pre-flight when `bin/is-github-dotcom-remote` returns non-zero (non-GitHub remote).
- Run `bash "$AGENTS_CONFIG_DIR/bin/github-issues/issue-create-preflight.sh" --check-project` (add `--repo OWNER/REPO` when targeting another repo).
- On rc=1 (no board), AskUserQuestion:
  - `run-issue-setup`: run `/issue-setup` against the target repo, then re-check Phase 0b.
  - `skip-this-time`: proceed to Pre-flight; the attach step remains warn-only.
- `skip-this-time` is NOT persisted — Phase 0b re-checks on every `issue-create` run (no suppression state file).

## Pre-flight

- `AGENTS_CONFIG_DIR` must be set.
- `gh` must be authenticated against the current repository.
- `gh` must have the `project` scope for Projects v2 attach. Add with
  `gh auth refresh -s project`.
- The `type:task` label must exist. `issue-create.sh` Phase 0a auto-syncs it when missing (run `/issue-setup` to initialize a fresh repo).

## Mid-workflow gate

Runs after Pre-flight, before Phase 1. Detects mid-workflow context to surface
adjacent-issue awareness to the user. Informational-only — never aborts the skill.
Phase 1 runs unconditionally regardless of gate outcome.

IC-1. Resolve session intent:
   ```bash
   PLANS_DIR=$(bash "$AGENTS_CONFIG_DIR/bin/workflow-plans-dir" 2>/dev/null \
                 || printf '%s\n' "${WORKFLOW_PLANS_DIR:-$HOME/.workflow-plans}")
   SESSION_ID="${CLAUDE_SESSION_ID:-}"
   INTENT_MD="$PLANS_DIR/${SESSION_ID}-intent.md"
   ```
   Skip gate silently when `SESSION_ID` is empty or `INTENT_MD` does not exist.

IC-2. Parse `closes_issues` (pass path as script argument — never use `node -e`):
   ```bash
   CLOSES=$(node "$AGENTS_CONFIG_DIR/bin/parse-closes-issues" "$INTENT_MD" 2>/dev/null || echo "[]")
   ```
   If `CLOSES` is `[]` or empty: skip gate silently, proceed to Phase 1.

IC-3. When `CLOSES` is non-empty, emit a notice:
   - **Interactive:** "This issue is created now and is NOT added to the current session's
     `closes_issues` (#N, ...); only its implementation belongs to a separate session.
     Fallback: write to `<worktree>/WORKTREE_NOTES.md` — see
     `rules/mid-workflow-findings.md`." Then proceed to Phase 1 unconditionally.
   - **Non-interactive:** print the same notice to stderr. Proceed to Phase 1.

## Procedure

Must be invoked from a linked worktree when `ENFORCE_WORKTREE=on`.
Exception — the notes-promotion pass reaches this skill from the main worktree via `/session-close` Step SC-8 and via `/issue-close-finalize`; both are sanctioned callers with no linked worktree of their own.

Four phases: **Gather → Survey → Confirm → Dispatch**.

### Phase 1 — Gather

Collect title and canonical-schema body from the user.

Required body schema for `type:task` (enforced by `bin/github-issues/issue-create.sh` exit 3):

| Field | Shape variants accepted |
|---|---|
| `Background` | `Background: <text>` / `## Background` / `### Background` |
| `Changes`    | `Changes: <text>` / `## Changes` / `### Changes` |

When the user-provided body is missing one or both required fields, use `AskUserQuestion` with these branches:
- `fix-now`: re-author the body inline with the missing field(s) added.
- `template`: prefill the 2-section template `## Background\n<TBD>\n\n## Changes\n<TBD>` and ask the user to fill it.
- `bypass`: set `ISSUE_CREATE_SKIP_SCHEMA=1` for this invocation — emergency escape hatch; sanctioned path is always to add the missing fields.

### Phase 2 — Survey

The survey follows an ordered cascade that considers `reopen` first; the criteria are defined in `skills/_shared/issue-verdict-cascade.md` (SSOT — never restated here or in the worker).

Every route below produces the same schema-v2 artifact. The worker-bypassing routes write it with `bash "$AGENTS_CONFIG_DIR/skills/issue-create/scripts/make-empty-verdict.sh" <out-path> <verdict> --title T --background B --changes C [--parent N]`.

Of that artifact the main conversation reads only `verdict` / `target` / `children` / `related` / `reason` / `review_result` / `review.worth_filing`. Never read `proposal` or `candidates[].body` into the main context.

If invoked with `--skip-survey` (caller already ran a bulk dedupe pass and supplies an explicit `--verdict bulk-sub-of --parent N --manifest FILE`): skip Phase 2 entirely, write the artifact with `make-empty-verdict.sh <out> bulk-sub-of --parent N`, and proceed to Phase 3 with the caller-supplied verdict.

Skip this phase when `bin/is-github-dotcom-remote` returns non-zero (non-GitHub remote) — write the artifact with `make-empty-verdict.sh <out> none` and proceed to Phase 3 with `verdict: none`.

2a. Pre-resolve in main: `session_id` (from `$CLAUDE_SESSION_ID` or env), `agents_config_dir` (absolute), `artifact_dir` (`PLANS_DIR` resolved by calling `bash "$AGENTS_CONFIG_DIR/bin/workflow-plans-dir"` directly at this callsite — do NOT reuse any variable from IC-1).
2b. Invoke the `issue-create-survey-worker` subagent via the Agent tool (`subagent_type`) with `title`, `background`, `changes` from Phase 1 input.
2c. `status: failed` → stop and report error.
2d. `status: no_candidates` → write the artifact with `make-empty-verdict.sh <out> none` and proceed to Phase 3 with `verdict: none`.
2e. `status: complete` → read verdict JSON from `artifact_path`.

### Phase 3 — Review and confirm

3a. Review the survey verdict: `bash "$AGENTS_CONFIG_DIR/bin/github-issues/review-survey-verdict-codex.sh" --artifact <survey-artifact> --out <final-artifact>`.
3b. Of `<final-artifact>` read only `verdict` / `target` / `children` / `related` / `reason` / `review.status` / `review.worth_filing`. Phase 4 dispatches on these, not on the Phase 2 values.
3c. Delete the Phase 2 survey artifact (`rm -f <survey-artifact>`) — it is the only file holding full candidate bodies, and the final artifact has superseded it. Skip silently if absent.
3d. Classify the gate: `bash "$AGENTS_CONFIG_DIR/skills/issue-create/scripts/eval-confirm-gate.sh" <final-artifact> <severity-label>` — stdout is `confirm: yes|no` then `reasons: <G-list>`.
3e. `confirm: yes` → AskUserQuestion before Phase 4, naming the fired conditions. `confirm: no` → proceed to Phase 4 without asking.

The gate is the logical OR of five conditions; the script owns the decision, this list only supplies the question text:
- G1 — final verdict is `reopen`, `make-parent`, `sub-of` or `bulk-sub-of` (mutates existing state)
- G2 — the review stage replaced the survey verdict
- G3 — the review did not confirm filing is worthwhile (`review.worth_filing` is not `true`)
- G4 — review status is anything other than `upheld` or `replaced` (verdict unverified)
- G5 — severity is not `severity:high`

Unattended filing therefore requires G1–G5 all clear: a `severity:high` finding that the codex review independently affirmed. `severity:low` and no-label findings always ask the user first — the inflow brake for #1973.

Note: `sub-of` and `bulk-sub-of` are G1 because they may trigger ancestor reopen when the parent chain contains closed issues.
Note: the artifact's `same_fix` is a different axis and is never a gate input — G1 asks how destructive the action is, `same_fix` asks whether one fix covers both.

After a `reopen`: continue the workflow using the existing issue number. Follow
the same routing as `/workflow-init`:
- If the existing issue has `intent:clarified` → Path A (skip interview).
- Otherwise → Path B (pre-fill interview from issue body).

### Phase 4 — Dispatch

```bash
bash "$AGENTS_CONFIG_DIR/bin/github-issues/issue-create-dispatch.sh" \
    --verdict <none|reopen|sub-of|make-parent|sibling> \
    [--target N | --parent N | --children N,M | --related N,M] [--note "<review note>"] \
    -- \
    --title "<title>" --body "<body>" \
    [--label "<extra-label>" ...] [--assignee "<user>"] [--milestone "<name>"]
```

`--note` applies to `reopen` only, and only when `review.status` is `replaced`: build it with `node "$AGENTS_CONFIG_DIR/bin/github-issues/lib/validate-review-verdict.js" --format-note --from <final-artifact>` — never retype the fields, the note is a public record of what the artifact says.

`make-parent` creates TWO issues:
- a `meta`-labeled, `Group: `-titled parent with a generated body
- the proposal verbatim as its child
- the named `--children` and the new child all attach under that parent

`sub-of` / `bulk-sub-of` vet the parent before creating anything:
- parent is not `meta` + `Group: ` → exit 2
- parent is unreadable → exit 1
- recover per `rules/github-issues.md` "Converting an issue into a meta parent"

For `bulk-sub-of`: pipe TSV rows (one `title<TAB>body` per child) to `bash "$AGENTS_CONFIG_DIR/skills/issue-create/scripts/run-bulk-dispatch.sh" "$PLANS_DIR" N [-- passthrough flags]`; the script writes the manifest under `PLANS_DIR` and calls the dispatcher. Stdout is N URL lines (one per child, manifest order).

**Stdout contract**: `none|reopen|sub-of|sibling` emit exactly one URL line on success (last line of stdout); `make-parent` emits two (parent first, proposal last); `bulk-sub-of` emits N URL lines (one per child, manifest order, end of stdout). All other output goes to stderr. Single-verdict callers extract the issue number with `echo "$OUTPUT" | tail -n 1 | tr -d '\r' | grep -oE '[0-9]+$'`; `bulk-sub-of` callers loop over all trailing URL lines. Enforced by `bin/github-issues/issue-create-dispatch.sh`.

Issues created here may be added to an existing session's `closes_issues` list (see `rules/github-issues.md` "Session model").

### Phase 5 — Record to WORKTREE_NOTES.md (primary-path capture)

Runs for all Phase 4 verdicts (none|reopen|sub-of|make-parent|sibling|bulk-sub-of).
Pipe Phase 4 stdout to `bash "$AGENTS_CONFIG_DIR/skills/issue-create/scripts/run-phase5-record.sh" "$VERDICT" "$(git rev-parse --show-toplevel)/WORKTREE_NOTES.md" "<Phase 1 title>" "$MANIFEST"` (manifest arg only used for `bulk-sub-of`).
Failure is non-fatal — the script logs a stderr warning and continues.

## Label policy

- `type:task` is attached unconditionally by the underlying script. (meaning: implementation task ticket — closes as a FEATURE history entry)
- Additional non-`type:*` labels (e.g. `area:hooks`, `priority:high`) may be
  passed via `--label`. `type:*` is rejected to avoid confusing
  `/issue-close-finalize` routing.
- **severity label (auto-classify, Phase 1)**: These three conditions are the only definition of severity (SSOT) — no script under `bin/` infers severity from keywords or any other signal. After gathering the issue title and body in Phase 1, evaluate the content and classify severity. Add at most one `severity:*` label:
  - Fatal or high-impact behavior → `--label severity:high`:
    - Workflow interruption or abnormal behavior mid-execution (abort, hang, infinite loop, etc.)
    - Security breach (confidential information leak, external attack vector, prompt injection)
    - Primary feature rendered completely unusable
    - The condition must be a confirmed instance, not a theoretical or deferred one — a hardening opportunity, a residual/follow-up finding explicitly deferred as non-blocking, or an unconfirmed "could happen" risk does not qualify.
  - Cosmetic or safely deferrable (visual glitch, non-blocking inconvenience, low-impact improvement) → `--label severity:low`.
  - All other cases → no severity label (no label = normal severity).
- **reporter-model label (auto-detect, Phase 4)**: the system prompt contains a self-report sentence — either the named form `"You are powered by the model named <name>. The exact model ID is <id>."` or the named-less short form `"You are powered by the model <name>."` (#1988) — pass it verbatim as `--reporter-model-text "<sentence>"` in the `--` passthrough args. The dispatch script extracts the identifier and resolves the label through the shared matcher.
  - No self-report sentence present → omit the flag; never add a `reporter-model:*` label by hand.

## Behavioral notes

- **Projects v2**: the linked Projects v2 (owner, number, node id) is auto-resolved from the git remote via `bin/github-issues/lib/resolve-project.sh` (#641). No hardcoded defaults — repos without a linked Projects v2 skip the attach step with a warning. Result is cached per `owner/repo` at `${WORKFLOW_PLANS_DIR}/cache/project-resolve.tsv`. Attach failure is non-fatal — warnings on stderr; re-run `gh project item-add` manually to recover.
- **Content Date field**: when the resolved project has a field named "Content Date" of type `DATE`, the script sets it to the issue's creation date (`YYYY-MM-DD`). The field id is discovered alongside the project node — no env var override needed. Projects without a Content Date field skip the step silently.
- **Sub-issue API**: dispatcher uses `POST /repos/{owner}/{repo}/issues/{N}/sub_issues` with `sub_issue_id` = child's integer databaseId (fetched via `gh api graphql -f query='{ repository(owner: "OWNER", name: "REPO") { issue(number: N) { databaseId } } }' --jq '.data.repository.issue.databaseId'`), passed via `-F` (integer type).
- **make-parent partial failure**: if a child attach fails mid-loop, both the parent and the proposal are already created — their URLs are still emitted, and `make-parent` exits non-zero with retry instructions on stderr. No atomic semantics (GitHub has no transactions).
- **bulk-sub-of partial failure**: if any child create or attach fails, successfully created URLs are still output and recorded; the dispatcher writes retry info to stderr and exits non-zero. No atomic semantics (GitHub has no transactions).
- **Untrusted content**: title/body are passed as separate `gh` arguments — no shell expansion. Do not interpolate unvalidated input into `--title`.
- **Schema enforcement (#443)**: `bin/github-issues/issue-create.sh` exits 3 when `Background` or `Changes` is missing. `ISSUE_CREATE_SKIP_SCHEMA=1` is an emergency escape hatch only — the sanctioned path is to add the missing fields. Incident issues (`type:incident`) bypass this skill entirely per Scope.
