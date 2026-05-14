# Confirm Plan Artifact — Shared Protocol

Used by `clarify-intent` (CONFIRM_INTENT), `make-outline-plan` (CONFIRM_OUTLINE),
and `make-detail-plan` (CONFIRM_DETAIL) after writing a final plan artifact.

## Protocol (3 mandatory steps, in order)

All 3 steps run for **every** plan artifact write. Even when
`CONFIRM_<STEP>=off`, Steps 1 and 2 are mandatory — do not skip, reorder, or
collapse them. The flag only governs Step 3's behavior (auto-proceed vs. ask).

**Step 1 — Write the artifact**
Use the Write tool to write the artifact file. The `show-diff.js` PreToolUse
hook fires automatically and emits the diff as a `systemMessage`, so the user
sees the full content inline in chat. No extra agent action is needed for the
preview itself.

**Step 2 — Breadcrumb (MANDATORY)**
The `show-plan-link.js` PostToolUse hook emits `Plan file written: <absolute-path>`
into the chat after the write. Do not duplicate or paraphrase it. If the line is
absent (hook not yet deployed), print the absolute path as plain text — not a
markdown link, not a tilde path. Mandatory in **every** mode.

**Step 3 — `CONFIRM_<STEP>` check**
```bash
bash -c 'cd "$AGENTS_CONFIG_DIR" && get-config-var --is-off CONFIRM_<STEP> on && echo OFF || echo ON'
```
- `OFF`: Print a one-paragraph prose summary describing what was written.
  The `Plan file written:` breadcrumb from the hook is already in the chat —
  do not duplicate the path inside the summary. Then proceed without `AskUserQuestion`.
- `ON`: Call `AskUserQuestion`:
  > "Review the [artifact] above. Proceed with this, or revise?"
  - **Proceed**: continue to the next step.
  - **Revise**: ask what to change, apply edits with the Write tool,
    then loop back to Step 1 of this protocol (preview re-fires, re-confirm).

## Notes

- The revise → re-write → preview → re-confirm loop has no explicit cap;
  trust the user to say "Proceed" when satisfied.
- Do not paste the full artifact content in chat — the show-diff preview plus
  the `Plan file written:` hook line are sufficient. Pasting duplicates context unnecessarily.
- Each skill defines what "Revise" means concretely (e.g., re-run the planner,
  update inline, re-run the interview). This reference covers only the outer
  protocol.
