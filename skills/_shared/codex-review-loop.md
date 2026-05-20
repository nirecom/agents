# Codex Review Loop — Shared Protocol

Used by `make-outline-plan` Step 5 and `make-detail-plan` Step 5. Wraps draft
persistence, context build, codex invocation, verdict parsing, raw-output
persistence, and the symmetric round-log + planner-response trailer.

`EXTENSIONS_USED` is owned by the caller; the caller passes the current value
on each invocation and increments it on AUTO_EXTEND.

## Parameters (caller supplies)

| Parameter | outline value | detail value |
|---|---|---|
| FORMAT | `outline-plan` | `detail-plan` |
| DRAFT_FILE | `<PLANS_DIR>/drafts/<session-id>-outline-draft.md` | `<PLANS_DIR>/drafts/<session-id>-detail-draft.md` |
| RAW_FILE | `<PLANS_DIR>/drafts/<session-id>-outline-codex-round-<N>-raw.md` | `<PLANS_DIR>/drafts/<session-id>-codex-round-<N>-raw.md` |
| CONCERNS_LOG | `<PLANS_DIR>/drafts/<session-id>-outline-concerns-log.md` | `<PLANS_DIR>/drafts/<session-id>-concerns-log.md` |
| DEBUG_LOG | `<PLANS_DIR>/drafts/<session-id>-outline-debug.log` | `<PLANS_DIR>/drafts/<session-id>-detail-debug.log` |
| CAP | 1 | 2 |
| MAX_EXTENSIONS | 1 | 2 |
| PLANNER_AGENT | `outline-planner` | `detail-planner` |
| REVIEWER_AGENT | `outline-reviewer` | `detail-reviewer` |
| ACCEPTED_TRADEOFFS_FILE | `<PLANS_DIR>/<session-id>-intent.md` | `<PLANS_DIR>/<session-id>-outline.md` |
| NON_APPROVED_VERDICT | `MISSING_ALTERNATIVE` | `NEEDS_REVISION` |

## Protocol (per review round)

### a. Write draft

Write the planner's output to `DRAFT_FILE` via the Write tool. The Write tool
auto-creates the `drafts/` directory.

### b. Build review context file (once per skill invocation)

Determine which prior-stage files exist; concatenate verbatim into
`<PLANS_DIR>/drafts/<session-id>-context.md` with the headers below. Skip if
no prior-stage file exists; reuse across revision rounds (do not regenerate).

- intent only: Section 1 only (no separator, no Section 2).
- outline only: Section 2 only (no separator, no Section 1).
- both: both sections + `---` separator.

```
<!-- Source: <PLANS_DIR>/<session-id>-intent.md -->
## Section 1: Intent (User Requirements)
<verbatim>

---

<!-- Source: <PLANS_DIR>/<session-id>-outline.md -->
## Section 2: Outline (Design Proposal)
<verbatim>
```

### c. Invoke review-plan-codex

```
review-plan-codex --input <DRAFT_FILE> \
                  --format <FORMAT> \
                  --session-id <session-id> \
                  --log-dir <PLANS_DIR>/drafts \
                  --cap <CAP> --max-extensions <MAX_EXTENSIONS> \
                  --extensions-used $EXTENSIONS_USED \
                  --accepted-tradeoffs <ACCEPTED_TRADEOFFS_FILE> \
                  [--context <PLANS_DIR>/drafts/<session-id>-context.md] \
                  [--context <CONCERNS_LOG>] \
                  --context "$AGENTS_CONFIG_DIR/rules/core-principles.md"
```

Omit `--context` args that point to files not yet created.

### d. Parse verdict (first line of stdout)

- `## Codex Plan Review: PERFORMED` → extract content between
  `<!-- begin-codex-output -->` and `<!-- end-codex-output -->`. The first
  non-blank line is the verdict token:
  - `APPROVED` (bare or `APPROVED <justification>`) → caller proceeds to the write/confirm phase.
  - `NON_APPROVED_VERDICT` (`NEEDS_REVISION` for detail, `MISSING_ALTERNATIVE: …` for outline) →
    extract numbered concerns; proceed to d.1 then e.
  - `FAILED — round cap reached` → caller invokes cap-menu-dispatch
    (`skills/_shared/cap-menu-dispatch.md`).
  - Anything else → **format malformed**: append
    `<ISO-timestamp> round=<N> codex output malformed (could not parse verdict)`
    to `DEBUG_LOG` via Bash `printf '%s\n' "..." >> <path>`; silently launch
    `REVIEWER_AGENT` subagent. Do NOT emit to chat.
- `SKIPPED` / `FAILED — <other>` → **codex unavailable**: append
  `<ISO-timestamp> round=<N> codex unavailable (<reason>)` to `DEBUG_LOG`;
  silently launch `REVIEWER_AGENT` subagent. Do NOT emit to chat.

### d.1. Raw-codex persistence (on non-APPROVED verdict)

Extract the content between `<!-- begin-codex-output -->` and
`<!-- end-codex-output -->` and write it to `RAW_FILE` (substitute the current
round number `<N>` = count of prior round-log entries + 1). Pass this path as
a literal string in the next `PLANNER_AGENT` invocation so the planner reads
the raw codex output directly via Read tool.

### e. Symmetric round log + planner-response trailer

Append to `CONCERNS_LOG`:

```
## Round <N> (<ISO-timestamp>)
Verdict: <NON_APPROVED_VERDICT>
Concerns (verbatim from codex):
<numbered concern lines>

Planner's intended response (next round):
<extracted verbatim from PLANNER_AGENT's ROUND_RESPONSE trailer>
```

Extract the planner trailer per `agents/<PLANNER_AGENT>.md` contract
(`<!-- begin-planner-response -->` block). Codex receives this log via
`--context <CONCERNS_LOG>` on the next round (re-running step c).

## Outcomes

- APPROVED → return to caller for the write/confirm phase.
- non-APPROVED verdict → caller increments its revision-round counter and
  re-invokes `PLANNER_AGENT` with `RAW_FILE` + `CONCERNS_LOG`.
- `FAILED — round cap reached` → caller invokes cap-menu-dispatch.
- codex unavailable / format malformed → caller silently falls back to
  `REVIEWER_AGENT` subagent.
