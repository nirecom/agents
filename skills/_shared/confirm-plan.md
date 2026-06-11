# Confirm Plan Artifact — Shared Protocol

Used by `clarify-intent` (CONFIRM_INTENT), `make-outline-plan` (CONFIRM_OUTLINE),
and `make-detail-plan` (CONFIRM_DETAIL) after writing a final plan artifact.

## Steps

Steps 1–3 always run. `CONFIRM_<STEP>` (default `on`) gates Step 1's diff preview
and Step 3's prompt; Step 2's breadcrumb is unconditional.

**Step 1 — Write the artifact.** Use the Write tool. The `show-diff.js` PreToolUse
hook emits the diff as a `systemMessage`. When `CONFIRM_<STEP>=off`, the hook
suppresses the preview — Step 3's prose summary substitutes.

**Step 2 — Breadcrumb.** `show-plan-link.js` PostToolUse emits exactly one line
after the Write returns:

    Plan file written: <absolute-path>

This is the **only** path surface. The orchestrator MUST NOT emit any path
representation — no duplication, translation, paraphrase, markdown link,
relative/tilde path, `file:///` URI, dual-path, or path appended to a Japanese
sentence.

Rationale: artifacts under `~/.workflow-plans/` (configurable via
`WORKFLOW_PLANS_DIR` — see `skills/_shared/resolve-plans-dir.md`) do not render
as clickable links in VS Code. When `CONFIRM_<STEP>=on`, `show-plan-link.js`
also routes the artifact to the matching VS Code window (#291); skipped when
`CONFIRM_<STEP>=off` (preserves #445). Hook internals (detection, URI ladder,
opt-out env): see `docs/architecture/claude-code/settings.md`.

If the hook line is absent, the orchestrator MAY print the absolute path as
plain text — same prohibitions still apply.
Enforcement: `stop-confirm-plan-guard.js` Stop hook structurally blocks turns where a `WORKFLOW_PLANS_DIR` path appears in the last assistant message (always active, regardless of `CONFIRM_<STEP>`).

**Step 3 — `CONFIRM_<STEP>` check.**
```bash
bash -c 'cd "$AGENTS_CONFIG_DIR" && get-config-var --is-off CONFIRM_<STEP> on && echo OFF || echo ON'
```
- `OFF`: print a one-paragraph prose summary (do not duplicate the breadcrumb path); proceed.
- `ON`: emit the matching sentinel via Bash (no `AskUserQuestion` call). Replace `<STAGE>` with `INTENT` / `OUTLINE` / `DETAIL` per the caller:

  `echo "<<WORKFLOW_CONFIRM_<STAGE>: <one-line summary>>>"`

  The `confirm-checkpoint.js` PreToolUse hook resolves the artifact path, opens it in VS Code, and surfaces a "Click Allow / Deny" message above the permission dialog (the sentinel is registered under `permissions.ask`, so the dialog is the user's approval surface).
  - **Co-emission (preferred path):** co-emit the sentinel echo with the next step's tool calls (next sentinel / TodoWrite / next skill invocation) in the same assistant response — Allow then continues straight through, no extra inference round. Structural fallback: `workflow-mark.js` PostToolUse recognizes the CONFIRM sentinel and injects an equivalent next-step hint via `additionalContext`, so the workflow recovers within one round even if only the sentinel was emitted.
  - **Allow** (user clicks Allow on the sentinel's permission dialog): continue.
  - **Deny**: ask what to change, write edits, loop back to Step 1.

## Notes

- Revise loop has no explicit cap — trust the user to say "Proceed".
- Do not paste the full artifact in chat — diff + breadcrumb are sufficient.
- Each skill defines what "Revise" means concretely.
