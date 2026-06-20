# Cap-menu Dispatch — Shared Protocol

Used by `make-outline-plan` MOP-6 and `make-detail-plan` MDP-6 when
`review-plan-codex` returns `FAILED — round cap reached`. Routes the caller
to land, adjust, or auto-extend via `bin/review-loop-cap-menu`.

`EXTENSIONS_USED` is owned by the caller; the caller increments it on each
extension and re-enters the review loop.

## Parameters (caller supplies)

| Parameter | outline value | detail value |
|---|---|---|
| LABEL | `"Outline Plan Review"` | `"Detail Plan Review"` |
| RAW_FILE | `<PLANS_DIR>/<session-id>-outline-codex-round-<ROUND_NUMBER-1>-raw.md` (most recently persisted; the cap-reach round's RAW_FILE is never written — see codex-review-loop.md §d.1) | `<PLANS_DIR>/<session-id>-codex-round-<ROUND_NUMBER-1>-raw.md` (most recently persisted) |
| LEDGER_FILE | `<PLANS_DIR>/<session-id>-outline-plan-concern-ledger-cap-snapshot.txt` | `<PLANS_DIR>/<session-id>-detail-plan-concern-ledger-cap-snapshot.txt` |
| MAX_EXTENSIONS | 1 | 1 |

## Protocol

a. `BUDGET_REMAINING = MAX_EXTENSIONS - EXTENSIONS_USED`

b. Inspect `RAW_FILE` → derive `ALL_HIGH` (1 if every concern is HIGH severity, 0 otherwise).

c. CC re-reads the draft + concerns → `CC_AGREES_HIGH` (1 if CC independently
   judges every concern as HIGH severity, 0 otherwise).

c.5. Render the concern summary block to the main conversation: invoke `review-loop-summarize-concerns --ledger <LEDGER_FILE> --raw <RAW_FILE> --budget-remaining $BUDGET_REMAINING --label <LABEL>` and print its stdout verbatim. `<RAW_FILE>` is the path with `<ROUND_NUMBER-1>` already substituted by the caller (MOP-6 / MDP-6). This output is exempted from the per-stage chat-output restrictions. When ROUND_NUMBER==1 the prior-round RAW_FILE does not exist; the helper's degraded RAW mode handles this and is the documented expected outcome — do not patch the persistence contract.

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
- `bin/review-loop-summarize-concerns` is the canonical concern-summary renderer — see the script for the full argument contract, output schema, the prior-round (`ROUND_NUMBER-1`) RAW_FILE convention, and the first-round cap-reach degraded path.
- When `ALL_HIGH==true` AND `CC_AGREES_HIGH==true` AND `BUDGET_REMAINING>0`, step c.5 still fires (summary is printed) but step d exits 42 (AUTO_EXTEND) without showing the dialog — the user gets visibility into deferred concerns.
