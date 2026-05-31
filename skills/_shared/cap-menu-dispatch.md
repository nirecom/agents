# Cap-menu Dispatch — Shared Protocol

Used by `make-outline-plan` Step 6 and `make-detail-plan` Step 6 when
`review-plan-codex` returns `FAILED — round cap reached`. Routes the caller
to land, adjust, or auto-extend via `bin/review-loop-cap-menu`.

`EXTENSIONS_USED` is owned by the caller; the caller increments it on each
extension and re-enters the review loop.

## Parameters (caller supplies)

| Parameter | outline value | detail value |
|---|---|---|
| LABEL | `"Outline Plan Review"` | `"Detail Plan Review"` |
| RAW_FILE | `<PLANS_DIR>/drafts/<session-id>-outline-codex-round-<N>-raw.md` | `<PLANS_DIR>/drafts/<session-id>-codex-round-<N>-raw.md` |
| MAX_EXTENSIONS | 1 | 1 |

## Protocol

a. `BUDGET_REMAINING = MAX_EXTENSIONS - EXTENSIONS_USED`

b. Inspect `RAW_FILE` → derive `ALL_HIGH` (1 if every concern is HIGH severity, 0 otherwise).

c. CC re-reads the draft + concerns → `CC_AGREES_HIGH` (1 if CC independently
   judges every concern as HIGH severity, 0 otherwise).

d. Invoke the helper:

```
menu_json=$(review-loop-cap-menu \
  --budget-remaining $BUDGET_REMAINING \
  --all-high $ALL_HIGH --cc-agrees-high $CC_AGREES_HIGH \
  --label <LABEL>)
rc=$?
```

e. Dispatch by exit code:

- `rc==42` (AUTO_EXTEND)         → `EXTENSIONS_USED += 1`; caller loops back to the review round (step c of `codex-review-loop.md`).
- `rc==0`, user picks `land`     → caller proceeds to the write/confirm phase.
- `rc==0`, user picks `adjust`   → caller escalates to the user (loop status + current plan + blocking concerns) and halts the loop.
- `rc==0`, user picks `extend`   → `EXTENSIONS_USED += 1`; caller loops back to the review round.
- `rc==2` (arg error)            → halt; surface helper stderr.

`AskUserQuestion` consumes the menu JSON:

- `question=$(jq -r '.question' <<<"$menu_json")`
- `options=$(jq -c '.options' <<<"$menu_json")`

## Absolute ceiling

When `BUDGET_REMAINING` reaches 0 (`EXTENSIONS_USED == MAX_EXTENSIONS`), the
helper renders only Land/Adjust (`.absolute_ceiling==true`); the next codex
invocation fires `FAILED — absolute ceiling reached`.

## Notes

- `bin/review-loop-cap-menu` is the canonical helper — see the script for
  the full menu JSON schema and exit-code contract.
- The caller's `revision_rounds` cap and `research_rounds` cap (where
  applicable) are unrelated to the bounded extension budget; they trigger
  separate escalation paths.
