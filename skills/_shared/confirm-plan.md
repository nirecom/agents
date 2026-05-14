# Confirm Plan Artifact — Shared Protocol

Used by `clarify-intent` (CONFIRM_INTENT), `make-outline-plan` (CONFIRM_OUTLINE),
and `make-detail-plan` (CONFIRM_DETAIL) after writing a final plan artifact.

## Protocol

After writing the artifact with the Write tool:

**Step 1 — Write preview (automatic)**
The `show-diff.js` PreToolUse hook fires on Write and displays a diff preview of
the written content in chat. No extra action needed — the user sees the full content.

**Step 2 — Absolute path link**
Present the artifact as a clickable absolute path link.
Resolve the full path — never use `~` (tilde is not expanded in markdown rendering).
- Windows: `[<session-id>-<artifact>.md](C:/Users/<user>/.workflow-plans/<session-id>-<artifact>.md)`
- POSIX: `[<session-id>-<artifact>.md](/home/<user>/.workflow-plans/<session-id>-<artifact>.md)`

**Step 3 — CONFIRM_<STEP> check**
```bash
bash -c 'cd "$AGENTS_CONFIG_DIR" && get-config-var --is-off CONFIRM_<STEP> on && echo OFF || echo ON'
```
- `OFF`: print a one-paragraph summary and proceed without `AskUserQuestion`.
- `ON`: call `AskUserQuestion`:
  > "Review the [artifact] above. Proceed with this, or revise?"
  - **Proceed**: continue to the next step.
  - **Revise**: ask what to change, apply edits with the Write tool,
    then loop back to Step 1 of this protocol (preview re-fires, re-confirm).

## Notes

- The loop (revise → re-write → preview → re-confirm) has no explicit cap;
  trust the user to say "Proceed" when satisfied.
- Do not paste the full artifact content in chat — the show-diff preview and the
  clickable link are sufficient. Pasting duplicates context unnecessarily.
- Each skill defines what "Revise" means concretely (e.g., re-run the planner,
  update inline, re-run the interview). This reference covers only the outer protocol.
