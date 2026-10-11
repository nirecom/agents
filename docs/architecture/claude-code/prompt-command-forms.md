# Prompt Command Forms

Why command examples in prompt assets (skills, rules, agents, `CLAUDE.md`) are written in the standalone absolute form, with the incidents that taught it.

## Why

A command shown in a prompt is not read as an illustration — the model copies it verbatim into a Bash call.
So the example IS the command that runs, and its form decides whether the call is auto-approved, falls to a permission ask, or fails.

Two properties make an example safe to copy:

- **Standalone** — one command, no compound form; anything compound goes into a scratchpad script.
- **Absolute** — a repo tool is spelled `node "$AGENTS_MAIN_ROOT/bin/<tool>" …` or `bash "$AGENTS_MAIN_ROOT/bin/<tool>" …`, with the interpreter taken from the tool's shebang, so it runs from any cwd.

The issuance discipline itself (what counts as compound, the scratchpad procedure, the forbidden literals) is owned by `rules/shell-commands.md`; this page does not restate it.
Whether a subagent inherits that rule depends on its dispatch shape (`rules-injection.md`), so dispatch prompts carry its canonical line — see the Subagent Dispatch Prompts section there and `rules-injection.md`.

Argument-less name-only references (`bin/resolve-merge-base.sh` resolves the base) are prose, not invocations, and stay as they are.

## Few-shot pairs

Each pair is: the old form a prompt once showed → the current form → why the old one failed.

### 1. Variable capture and pipe → a dispatch-only flag

- Old: the complexity-and-outline-skip step (CI-C1b / A3a) captured the wrapper's output into a shell variable and piped it through a filter to extract `SKIP_DISPATCH`.
- Current: one standalone call with `--dispatch-only`, whose stdout is the single line `SKIP_DISPATCH=<value>` — `skills/_shared/complexity-and-outline-skip.md` COS-3 (PR #2272).
- Why: the capture-and-pipe form is compound, so it was blocked or prompted on every run; moving the extraction into the tool made the prompt's command standalone.

### 2. `cd … &&` confirm-off probe → standalone absolute form

- Old: `bash -c 'cd "$AGENTS_MAIN_ROOT" && bash "$AGENTS_MAIN_ROOT/bin/confirm-off" KEY on'`.
- Current: `bash "$AGENTS_MAIN_ROOT/bin/confirm-off" KEY on`.
- Why: the `cd` prefix was redundant (the path is already absolute) and the `bash -c` compound fell to a permission ask; it only ran from the main worktree through a dedicated exemption (`workflow-runtime.md` Exemptions), which now stays for compatibility only.

### 3. Relative `bin/` → `$AGENTS_MAIN_ROOT` form

- Old: `bin/review-plan-codex --format test-review`, `node bin/workflow/next-step --list`.
- Current: `bash "$AGENTS_MAIN_ROOT/bin/review-plan-codex" --format test-review`, `node "$AGENTS_MAIN_ROOT/bin/workflow/next-step" --list`.
- Why: a relative path resolves against the cwd, which is usually a project or worktree other than the agents checkout; the call exits 127, and once that silently voided a Codex review verdict (#2452).

## Regression guards

- `tests/bin/feature-2452-relative-bin-invocations.sh` — scans skills/, rules/, agents/ and `CLAUDE.md` for relative `bin/` invocations and for the `cd`-prefixed confirm-off probe.
- Forbidden literals in general are left to the classifier tracked as #2266; until it lands, `hooks/bash-guard.js` (#2134) blocks them at issue time, whatever prompt they were copied from.
