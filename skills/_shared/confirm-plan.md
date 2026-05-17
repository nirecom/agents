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

**Step 2 — Breadcrumb (orchestrator output: FORBIDDEN)**

The `show-plan-link.js` PostToolUse hook emits exactly one line into the chat
immediately after the Write tool returns:

    Plan file written: <absolute-path>

This line is the **only** path surfaced to the user. The orchestrator MUST NOT
output any path representation. Specifically, the orchestrator MUST NOT:

- duplicate the hook line (verbatim or otherwise)
- translate it (e.g., "計画ファイルを書きました…", "outline.md を書きました…")
- paraphrase it ("Plan written to…", "Wrote outline to…", etc.)
- wrap the path in a markdown link (`[text](path)` syntax)
- present a bare relative path or tilde-prefixed path
- present a `file:///`-scheme URI
- emit a second path representation after the hook line (no `(フルパス: ...)` annotations)
- prepend or append any path to a Japanese sentence

Rationale: workflow-plan files under `~/.workflow-plans/` (default; configurable
via WORKFLOW_PLANS_DIR — see skills/_shared/resolve-plans-dir.md) do not render
as clickable links in VS Code. The hook's breadcrumb plus the automatic `code -r`
auto-open are the *only* sanctioned UX.

If the hook line is absent (hook not yet deployed), the orchestrator MAY print
the absolute path as plain text on its own line — still subject to all
prohibitions above (no markdown link, no tilde, no forward-slash on Windows,
no dual-path). Mandatory in **every** mode (CONFIRM_<STEP>=on or off).

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
