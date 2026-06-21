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

## Pre-flight

- `AGENTS_CONFIG_DIR` must be set.
- `gh` must be authenticated against the current repository.
- `gh` must have the `project` scope for Projects v2 attach. Add with
  `gh auth refresh -s project`.
- The `type:task` label must exist (run `bin/github-issues/sync-labels.sh` if missing).

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
   - **Interactive:** "The new issue will NOT be added to the current session's
     `closes_issues` (#N, ...). It will require a separate session. Alternatively,
     write to `<worktree>/WORKTREE_NOTES.md` as a fallback — see `CLAUDE.md`
     `## Mid-workflow finding capture`." Then proceed to Phase 1 unconditionally.
   - **Non-interactive:** print the same notice to stderr. Proceed to Phase 1.

## Procedure

Callable from main worktree or linked worktree — `issue-create.sh` sanctions the `gh issue create` call via `ISSUE_CREATE_SKILL=1` inline prefix.

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

Dedupe layer for the underlying `bin/github-issues/issue-create.sh`. Skip on non-GitHub remotes:

```bash
"$AGENTS_CONFIG_DIR/bin/is-github-dotcom-remote"; rc=$?
# rc != 0 → skip survey, jump to Phase 4 with --verdict none
```

**3-pass dedupe survey.** Extract 3–5 significant tokens (nouns/verbs/identifiers, no stopwords) AND 3–5 symptom-level tokens (behaviors, affected outputs/artifacts, feature area — including artifact names when they represent the affected feature) from the Background / Changes body.

**Pass 1 — keyword + symptom search (parallel):** `gh issue list --state all --limit 50 --search "<kw1> <kw2> <kw3>"` using 3–5 significant tokens. Always also run `gh issue list --state all --limit 50 --search "<st1> <st2> <st3>"` using 3–5 symptom-level tokens. Zero results → drop most specific identifier keyword, retry up to 3 times.

**Pass 2 — recent-open full scan:** `gh issue list --state open --paginate --search "created:>=<YYYY-MM-DD>"` where the date is 30 days before the current date. Also run `gh issue list --state open --limit 50 --search "<st1> <st2> <st3>"` (symptom tokens, no date filter) to surface older open issues. Deduplicate results against Pass 1 before inspection.

**Pass 3 — closed duplicate scan:** `gh issue list --state closed --limit 50 --search "<kw1> <kw2> <kw3>"`. Also run `gh issue list --state closed --limit 50 --search "<st1> <st2> <st3>"` (symptom tokens). Surfaces closed duplicates regardless of closure reason.

Still zero across all three passes → verdict `none`, jump to Phase 4.

**Candidate inspection:** Dedup candidates across Passes 1–3; inspect up to 25 unique candidates (closed candidates first, then exact-token open, then symptom-only open). `gh issue view <N> --json number,title,body,state,labels`.

**Verdict classification** (Claude's semantic judgement):

| Class | Verdict | Notes |
|---|---|---|
| **duplicate** (closed or open, same scope) | `reopen` | Confirm before reopening; warn on open-duplicate |
| **superset-open** (existing open issue covers the new one) | `sub-of` | Attach the new issue under the existing parent |
| **siblings-open** (≥2 open issues form a group the new one would head) | `make-parent` | Confirm with user; new issue becomes parent, listed issues become its children |
| **related-open** (overlapping but not subset/superset) | `sibling` | Append `Related to #N` to the new issue body |
| **recurrence** (same symptom on a closed issue, regardless of how closed) | `reopen` | Confirm before reopening; treat as regression |
| **unrelated** | (ignore) | — |

No match → verdict `none`.

IC-4. Apply the Verdict Rubric — apply in order before choosing a verdict:
IC-4a. **Symptom match** (weight: high): does the candidate describe the same observable failure/behavior? Same symptom + same scope → `reopen` or `duplicate` class.
IC-4b. **Scope overlap** (weight: high): does the candidate's scope substantially overlap the new report's scope? No overlap → class is at most `sibling`.
IC-4c. **Age is a tie-break only**: a closed issue from 2 years ago with identical symptoms outranks a recent open issue with partial overlap. Do not discard candidates based on age alone.
IC-4d. **Tie-break order** (when rules IC-4a–IC-4b yield equal weight): closed candidates > open candidates; more recent > older; lower issue number > higher (stable sort).
IC-4e. **No verdict**: if no candidate matches on both rules IC-4a and IC-4b, verdict is `none`.

### Phase 3 — Confirm

Confirmation is **required** for `reopen` and `make-parent` (mutating actions on
existing issues). Use `AskUserQuestion`. `sub-of` and `sibling` proceed without
confirmation; `none` proceeds without confirmation.

After a `reopen`: continue the workflow using the existing issue number. Follow
the same routing as `/workflow-init`:
- If the existing issue has `intent:clarified` → Path A (skip interview).
- Otherwise → Path B (pre-fill interview from issue body).

### Phase 4 — Dispatch

```bash
bash "$AGENTS_CONFIG_DIR/bin/github-issues/issue-create-dispatch.sh" \
    --verdict <none|reopen|sub-of|make-parent|sibling> \
    [--target N | --parent N | --children N,M | --related N,M] \
    -- \
    --title "<title>" --body "<body>" \
    [--label "<extra-label>" ...] [--assignee "<user>"] [--milestone "<name>"]
```

**Stdout contract**: Phase 4 emits exactly one line to stdout on success: the issue URL (`https://github.com/<owner>/<repo>/issues/<N>`). All other output goes to stderr. Callers extract the issue number with: `echo "$OUTPUT" | tail -n 1 | tr -d '\r' | grep -oE '[0-9]+$'`. Enforced by `bin/github-issues/issue-create-dispatch.sh`.

Issues created here may be added to an existing session's `closes_issues` list (see `rules/github-issues.md` "Session model").

### Phase 5 — Record to WORKTREE_NOTES.md (primary-path capture)

Runs for all Phase 4 verdicts (none|reopen|sub-of|make-parent|sibling).
After Phase 4 emits the issue URL, extract the issue number and invoke the helper:

    N=$(echo "$URL" | tail -n 1 | tr -d '\r' | grep -oE '[0-9]+$')
    node "$AGENTS_CONFIG_DIR/bin/worktree-notes-append.js" \
        --notes-path "$(git rev-parse --show-toplevel)/WORKTREE_NOTES.md" \
        --issue-number "$N" --title "<Phase 1 title>" \
        --label type:task --skip-if-main

Failure is non-fatal — log a stderr warning and continue. The helper handles
main-worktree skip, label-driven section routing, idempotent re-runs, and
atomic write internally.

## Label policy

- `type:task` is attached unconditionally by the underlying script.
- Additional non-`type:*` labels (e.g. `area:hooks`, `priority:high`) may be
  passed via `--label`. `type:*` is rejected to avoid confusing
  `/issue-close-finalize` routing.

## Behavioral notes

- **Projects v2**: the linked Projects v2 (owner, number, node id) is auto-resolved from the git remote via `bin/github-issues/lib/resolve-project.sh` (#641). No hardcoded defaults — repos without a linked Projects v2 skip the attach step with a warning. Result is cached per `owner/repo` at `${WORKFLOW_PLANS_DIR}/cache/project-resolve.tsv`. Attach failure is non-fatal — warnings on stderr; re-run `gh project item-add` manually to recover.
- **Content Date field**: when the resolved project has a field named "Content Date" of type `DATE`, the script sets it to the issue's creation date (`YYYY-MM-DD`). The field id is discovered alongside the project node — no env var override needed. Projects without a Content Date field skip the step silently.
- **Sub-issue API**: dispatcher uses `POST /repos/{owner}/{repo}/issues/{N}/sub_issues` with `sub_issue_id` = child's integer databaseId (fetched via `gh api graphql -f query='{ repository(owner: "OWNER", name: "REPO") { issue(number: N) { databaseId } } }' --jq '.data.repository.issue.databaseId'`), passed via `-F` (integer type).
- **make-parent partial failure**: if a child attach fails mid-loop, the parent is created but `make-parent` exits non-zero with retry instructions on stderr. No atomic semantics (GitHub has no transactions).
- **Untrusted content**: title/body are passed as separate `gh` arguments — no shell expansion. Do not interpolate unvalidated input into `--title`.
- **Schema enforcement (#443)**: `bin/github-issues/issue-create.sh` exits 3 when `Background` or `Changes` is missing. `ISSUE_CREATE_SKIP_SCHEMA=1` is an emergency escape hatch only — the sanctioned path is to add the missing fields. Incident issues (`type:incident`) bypass this skill entirely per Scope.
