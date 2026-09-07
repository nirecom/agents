# Complexity Evaluation + Outline-Skip Dispatch — Shared Procedure

Canonical procedure for the step that records the complexity evaluation and
settles whether `outline` is skipped. Referenced by `skills/workflow-init/SKILL.md`
(Path A, A3a/A3b) and `skills/clarify-intent/SKILL.md` (CI-C1b/CI-C1c) — one
owner so the two cannot drift apart (CPR-SSOT).

Substitute `<SESSION_ID>` and `<PLANS_DIR>` with literal values before issuing
any command below. Each step is one standalone Bash call.

## Step 1 — Judge

Read `skills/_shared/judge-task-complexity.md` and evaluate every signal against
the confirmed intent.md (S6 is approximated from the intent.md line count alone —
outline.md does not exist yet).

Also evaluate so_c1 / so_c2 (criteria: `skills/_shared/judge-plan-skip.md`) from
intent.md. Both are needed regardless of the internal `SKIP_MODE`, which is not
known until Step 3 returns.

## Step 2 — Write the signals file

Use the **Write tool** — never Bash — to write the judged CSV, alone and
unquoted, to `<PLANS_DIR>/<SESSION_ID>-complexity-signals.txt`.

Write only IDs from the generated Valid Signal IDs list. Substitute
`S0-undecidable` when the judged CSV does not match `^[A-Za-z0-9,_-]*$` — the
judge's line is untrusted text, never shell syntax.

Never splice the CSV into a Bash command; the file is the only transport.

## Step 3 — Record and dispatch

Issue exactly this one standalone Bash call:

`bash "$AGENTS_CONFIG_DIR/bin/workflow/record-complexity-and-skip" --session "<SESSION_ID>" --signals-file "<PLANS_DIR>/<SESSION_ID>-complexity-signals.txt" --target outline --dispatch-only --so-c1 <true|false> --so-c2 <true|false>`

`--dispatch-only` puts everything else on stderr, so stdout is the single line
`SKIP_DISPATCH=<value>`. Read `<value>` from it — no pipe, no capture.

The wrapper records the complexity evaluation and, when its internal
`SKIP_MODE=auto`, also settles `outline` as skipped in the same call.

## Step 4 — Branch on `<value>`

- `no-skip` → outline is not skipped; continue with the caller's next step.
- `advanced` → outline was already settled skipped by Step 3. Dispatch the Agent
  tool (`run_in_background: true`) with `subagent_type=skip-verifier`,
  `session_id=<SESSION_ID>`, `target=outline`,
  `intent_path=<PLANS_DIR>/<SESSION_ID>-intent.md`, then continue.
- `need-judgment` (internal `SKIP_MODE=judgment` with so_c1/so_c2 both true) →
  issue `bash "$AGENTS_CONFIG_DIR/skills/clarify-intent/scripts/check-complexity-skip.sh" --skip-mode judgment --session "<SESSION_ID>" --so-c1 true --so-c2 true`
  (settles `outline` as skipped via `--advance` internally and emits
  `<<WORKFLOW_OUTLINE_NOT_NEEDED: {reason}>>` for the debug log), then dispatch
  the same skip-verifier Agent call and continue.
