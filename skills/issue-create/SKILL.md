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
- **Out of scope**: incident issues (use the web UI incident template or a
  `--label "type:incident"` invocation of your own); issues for other repos or
  projects, which take the cross-repo path below.
- Cross-repo work: confirm the ownership of the target repository before filing the issue — an issue lands publicly in whichever repo `gh` resolves, and that resolution follows the working directory when no target is named.

Required reading: Read `rules/github-issues.md` before Pre-flight — it is on-demand-only and never auto-injected.
Read `rules/coding.md` before writing any issue title or body — on-demand-only, never auto-injected; its Public GitHub Rules govern this outbound write.
Apply the TERMS line of hooks/lib/lang-directives.txt and the Writer directives in skills/_shared/combined-glossary.md to issue titles and bodies; both govern terminology only, not the body language.

## Phase 0b — Project preflight

Runs before Pre-flight. Detects a missing Projects v2 board and offers to run `/issue-setup`. Independent of Phase 0a (label auto-repair in `issue-create.sh`) — one's result never affects the other.

- Skip Phase 0b and proceed to Pre-flight when `bin/is-github-dotcom-remote` returns non-zero (non-GitHub remote).
- Run `bash "$AGENTS_MAIN_ROOT/bin/github-issues/issue-create-preflight.sh" --check-project` (add `--repo OWNER/REPO` when targeting another repo).
- On rc=1 (no board), AskUserQuestion:
  - `run-issue-setup`: run `/issue-setup` against the target repo, then re-check Phase 0b.
  - `skip-this-time`: proceed to Pre-flight; the attach step remains warn-only.
- `skip-this-time` is NOT persisted — Phase 0b re-checks on every `issue-create` run (no suppression state file).

## Pre-flight

- `AGENTS_MAIN_ROOT` must be set.
- `gh` must be authenticated against the current repository.
- `gh` must have the `project` scope for Projects v2 attach. Add with
  `gh auth refresh -s project`.
- The `type:task` label must exist. `issue-create.sh` Phase 0a auto-syncs it when missing (run `/issue-setup` to initialize a fresh repo).

## Mid-workflow gate

Runs after Pre-flight, before Phase 1. Detects mid-workflow context to surface
adjacent-issue awareness to the user. Informational-only — never aborts the skill.
Phase 1 runs regardless of gate outcome.

IC-1. Resolve session intent:
   Resolve `<PLANS_DIR>` with one standalone Bash call —
   `bash "$AGENTS_MAIN_ROOT/bin/workflow-plans-dir"` — and read `<SESSION_ID>`
   from `$CLAUDE_CODE_SESSION_ID`. `<INTENT_MD>` is the output of `node "$AGENTS_MAIN_ROOT/bin/plan-artifact-path" --step clarify_intent --session <SESSION_ID>` (a failed call counts as no intent).
   Skip the gate silently when `<SESSION_ID>` is empty or `<INTENT_MD>` does not exist.

IC-1a. Read `rules/mid-workflow-findings.md` — on-demand-only, never auto-injected; it owns the capture paths the IC-3 notice points the user at.

IC-2. Parse `closes_issues` with one standalone call (pass the path as a script
   argument — never use `node -e`):
   `node "$AGENTS_MAIN_ROOT/bin/parse-closes-issues" "<INTENT_MD>"`.
   If its stdout is `[]`, empty, or the call fails: skip the gate silently and
   proceed to Phase 1.

IC-3. When `CLOSES` is non-empty, emit a notice:
   - **Interactive:** "This issue is created now and is NOT added to the current session's
     `closes_issues` (#N, ...); only its implementation belongs to a separate session.
     Fallback: write to `<worktree>/WORKTREE_NOTES.md` — see
     `rules/mid-workflow-findings.md`." Then proceed to Phase 1.
   - **Non-interactive:** print the same notice to stderr. Proceed to Phase 1.

## Procedure

Must be invoked from a linked worktree when `ENFORCE_WORKTREE=on`.
Exception — the notes-promotion pass reaches this skill from the main worktree via `/session-close` SC-8 and via `/issue-close-finalize`; both are sanctioned callers with no linked worktree of their own.

Four phases: **Gather → Survey → Confirm → Dispatch**.

### Phase 1 — Gather

Collect title and canonical-schema body from the user.
Treat a direct `/issue-create` invocation as user-acknowledged (`true`); never ask whether to file it.

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

Every route below produces the same schema-v2 artifact. The worker-bypassing routes write it with `bash "$AGENTS_MAIN_ROOT/skills/issue-create/scripts/make-empty-verdict.sh" <out-path> <verdict> --title T --background B --changes C [--parent N]`.

Of that artifact the main conversation reads only `verdict` / `target` / `children` / `related` / `reason` / `review_result` / `review.worth_filing` / `review.verdict` / `review.target` / `review.children` / `review.related`. Never read `proposal` or `candidates[].body` into the main context.

If invoked with `--skip-survey` (caller already ran a bulk dedupe pass and supplies an explicit `--verdict bulk-sub-of --parent N --manifest FILE`): skip Phase 2 entirely, write the artifact with `make-empty-verdict.sh <out> bulk-sub-of --parent N`, and proceed to Phase 3 with the caller-supplied verdict.

Skip this phase when `bin/is-github-dotcom-remote` returns non-zero (non-GitHub remote) — write the artifact with `make-empty-verdict.sh <out> none` and proceed to Phase 3 with `verdict: none`.

2a. Pre-resolve in main: `session_id` (from `$CLAUDE_CODE_SESSION_ID`), `agents_main_root` (absolute), `artifact_dir` (`PLANS_DIR` resolved by calling `bash "$AGENTS_MAIN_ROOT/bin/workflow-plans-dir"` directly at this callsite — do NOT reuse any variable from IC-1).
2b. Invoke the `issue-create-survey-worker` subagent via the Agent tool (`subagent_type`) with `title`, `background`, `changes` from Phase 1 input.
    Set the JSON prompt's `dispatch_directive` key to the canonical line of the `rules/shell-commands.md` Subagent Dispatch Prompts section.
2c. `status: failed` → stop and report error.
2d. `status: no_candidates` → write the artifact with `make-empty-verdict.sh <out> none` and proceed to Phase 3 with `verdict: none`.
2e. `status: complete` → read verdict JSON from `artifact_path`.

### Phase 3 — Review and confirm

3a. Review the survey verdict: `bash "$AGENTS_MAIN_ROOT/bin/github-issues/review-survey-verdict-codex.sh" --artifact <survey-artifact> --out <final-artifact>`.
3b. Of `<final-artifact>` read only `verdict` / `target` / `children` / `related` / `reason` / `review.status` / `review.worth_filing` / `review.verdict` / `review.target` / `review.children` / `review.related`. Phase 4 dispatches on these, not on the Phase 2 values.
3c. Delete the Phase 2 survey artifact (`rm -f <survey-artifact>`) — it is the only file holding full candidate bodies, and the final artifact has superseded it. Skip silently if absent.
3d. Classify the gate: `bash "$AGENTS_MAIN_ROOT/skills/issue-create/scripts/eval-confirm-gate.sh" <final-artifact>` — stdout is `confirm: yes|no`, `reasons: <G-list>`, then the info line `worth_filing: true|false|unknown`.
3e. `confirm: no` → proceed to Phase 4 without asking.
3f. Applies only when `confirm: yes`, `review.status` is not `disputed`, and G3 did not fire → check the fired conditions against the verdict and placement yourself.
When you agree, first record with `bash "$AGENTS_MAIN_ROOT/skills/issue-create/scripts/record-confirm-decision.sh" '<PLANS_DIR>' '<session-id>' auto '<reasons>' '<rationale>'`; proceed to Phase 4 without asking only when that exits 0, and tell the main conversation why in 1–2 sentences.
Single-quote every argument of record-confirm-decision.sh and drop any `'` from the text you substitute (rationale is free text; double quotes would expand `$(...)`).
3g. Otherwise (`disputed`, G3 fired, you disagree or are unsure, or the 3f record exited non-zero) → AskUserQuestion before Phase 4, naming the fired conditions (for `disputed`, both verdicts), and record it the same way with `asked`.

The gate is the logical OR of four conditions; the script owns the decision, this list only supplies the question text:
- G1 — final verdict is `reopen`, `make-parent`, `sub-of` or `bulk-sub-of` (mutates existing state; `sub-of` / `bulk-sub-of` may reopen closed ancestors of the parent chain)
- G2 — `review.status` is `disputed`, or the survey and final verdicts differ
- G3 — the final JSON is missing or unreadable (no readable verdict to agree with, so G3 always goes to 3g)
- G4 — review status is anything other than `upheld` or `disputed` (verdict unverified)

Note: the artifact's `same_fix` is a different axis and is never a gate input — G1 asks how destructive the action is, `same_fix` asks whether one fix covers both.

After a `reopen`: continue the workflow using the existing issue number. Follow the same routing as `/workflow-init`:
- If the existing issue has `intent:clarified` → Path A (skip interview).
- Otherwise → Path B (pre-fill interview from issue body).

### Phase 4 — Dispatch

```bash
bash "$AGENTS_MAIN_ROOT/bin/github-issues/issue-create-dispatch.sh" \
    --verdict <none|reopen|sub-of|make-parent|sibling> \
    [--target N | --parent N | --children N,M | --related N,M] [--note "<review note>"] \
    -- \
    --title "<title>" --body "<body>" \
    [--label "<extra-label>" ...] [--assignee "<user>"] [--milestone "<name>"]
```

When `review.status` is `disputed` and the user chose the reviewer's verdict, dispatch on `review.verdict` / `review.target` / `review.children` / `review.related` instead.
`--note` applies to `reopen` only, and only when `review.status` is `disputed` and the user chose the reviewer's verdict: build it with `node "$AGENTS_MAIN_ROOT/bin/github-issues/lib/validate-review-verdict.js" --format-note --from <final-artifact>` — never retype the fields, the note is a public record of what the artifact says.

`make-parent` creates TWO issues:
- a `meta`-labeled, `Group: `-titled parent with a generated body
- the proposal verbatim as its child
- the named `--children` and the new child all attach under that parent

`sub-of` / `bulk-sub-of` vet the parent before creating anything:
- parent is not `meta` + `Group: ` → exit 2
- parent is unreadable → exit 1
- recover per `rules/github-issues.md` "Converting an issue into a meta parent"

For `bulk-sub-of`: pipe TSV rows (one `title<TAB>body` per child) to `bash "$AGENTS_MAIN_ROOT/skills/issue-create/scripts/run-bulk-dispatch.sh" "$PLANS_DIR" N [-- passthrough flags]`; the script writes the manifest under `PLANS_DIR` and calls the dispatcher. Stdout is N URL lines (one per child, manifest order).

**Stdout contract**: `none|reopen|sub-of|sibling` emit exactly one URL line on success (last line of stdout); `make-parent` emits two (parent first, proposal last); `bulk-sub-of` emits N URL lines (one per child, manifest order, end of stdout). All other output goes to stderr. Single-verdict callers read the last stdout line and take the trailing digits of that URL as the issue number — no pipeline; `bulk-sub-of` callers loop over all trailing URL lines. Enforced by `bin/github-issues/issue-create-dispatch.sh`.

Issues created here may be added to an existing session's `closes_issues` list (see `rules/github-issues.md` "Session model").

### Phase 5 — Record to WORKTREE_NOTES.md (primary-path capture)

Runs for all Phase 4 verdicts (none|reopen|sub-of|make-parent|sibling|bulk-sub-of).
Write Phase 4's stdout to `<PLANS_DIR>/<session-id>-issue-create-dispatch.txt` with the Write tool, then issue one standalone call: `bash "$AGENTS_MAIN_ROOT/skills/issue-create/scripts/run-phase5-record.sh" "<VERDICT>" auto "<Phase 1 title>" "<MANIFEST>" --input-file "<PLANS_DIR>/<session-id>-issue-create-dispatch.txt"` (`auto` resolves WORKTREE_NOTES.md itself; the manifest arg is used only for `bulk-sub-of`, pass `""` otherwise).
Failure is non-fatal — the script logs a stderr warning and continues.

## Label policy

- `type:task` is attached by `bin/github-issues/issue-create.sh` on every call. (meaning: implementation task ticket — closes as a FEATURE history entry)
- Additional non-`type:*` labels (e.g. `area:hooks`, `priority:high`) may be
  passed via `--label`. `type:*` is rejected to avoid confusing
  `/issue-close-finalize` routing.
- **severity label (auto-classify, Phase 1)**: after gathering the issue title and body, classify severity; add at most one `severity:*` label — no script under `bin/` infers severity from keywords or any other signal.
  - Read `skills/_shared/severity.md` before judging severity; it is the only definition (SSOT).
  - Apply the label that file maps the severity to (`--label severity:high`, `--label severity:low`, or no label).
- **reporter-model label (auto-detect, Phase 4)**: the system prompt contains a self-report sentence — either the named form `"You are powered by the model named <name>. The exact model ID is <id>."` or the named-less short form `"You are powered by the model <name>."` (#1988) — pass it verbatim as `--reporter-model-text "<sentence>"` in the `--` passthrough args. The dispatch script extracts the identifier and resolves the label through the shared matcher.
  - No self-report sentence present → omit the flag; never add a `reporter-model:*` label by hand.

## Behavioral notes

- **Projects v2**: the linked Projects v2 (owner, number, node id) is auto-resolved from the git remote via `bin/github-issues/lib/resolve-project.sh` (#641). No hardcoded defaults — repos without a linked Projects v2 skip the attach step with a warning. Result is cached per `owner/repo` at `${WORKFLOW_STATE_DIR}/cache/project-resolve.tsv`. Attach failure is non-fatal — warnings on stderr; re-run `gh project item-add` manually to recover.
- **Content Date field**: when the resolved project has a field named "Content Date" of type `DATE`, the script sets it to the issue's creation date (`YYYY-MM-DD`). The field id is discovered alongside the project node — no env var override needed. Projects without a Content Date field skip the step silently.
- **Sub-issue API**: dispatcher uses `POST /repos/{owner}/{repo}/issues/{N}/sub_issues` with `sub_issue_id` = child's integer databaseId (fetched via `gh api graphql -f query='{ repository(owner: "OWNER", name: "REPO") { issue(number: N) { databaseId } } }' --jq '.data.repository.issue.databaseId'`), passed via `-F` (integer type).
- **make-parent partial failure**: if a child attach fails mid-loop, both the parent and the proposal are already created — their URLs are still emitted, and `make-parent` exits non-zero with retry instructions on stderr. No atomic semantics (GitHub has no transactions).
- **bulk-sub-of partial failure**: if any child create or attach fails, successfully created URLs are still output and recorded; the dispatcher writes retry info to stderr and exits non-zero. No atomic semantics (GitHub has no transactions).
- **Untrusted content**: title/body are passed as separate `gh` arguments — no shell expansion. Do not interpolate unvalidated input into `--title`.
- **Schema enforcement (#443)**: `bin/github-issues/issue-create.sh` exits 3 when `Background` or `Changes` is missing. `ISSUE_CREATE_SKIP_SCHEMA=1` is an emergency escape hatch only — the sanctioned path is to add the missing fields. Incident issues (`type:incident`) bypass this skill entirely per Scope.
