# settings.json Hooks

Per-hook behavior contracts for the hooks registered in `settings.json`. This is the detail companion of [settings.md](../settings.md), which keeps the allow/deny model, permission glob matching, generated allow rules, and known limitations.

**Hooks**:
- `scan-outbound.js` (PreToolUse, matcher: `Bash`) — scans commands for private info patterns
- `block-dotenv.js` (PreToolUse, matcher: `Bash|Read|Grep|Glob|Edit|Write|MultiEdit`) — blocks `.env` file access (read and write).
  Sanitizes git commit messages (`git commit` and `git -C <path> commit`) to avoid false positives
- `block-credentials.js` (PreToolUse, matcher: `Bash|Read|Grep|Glob|Edit|Write|MultiEdit|editFiles|runInTerminal|runCommands`) — blocks Read/Edit/Write/Grep/Glob/Bash access to 22 credential-path families (24 protected roots; Terraform spans 3 roots): SSH keys, GnuPG, AWS, Azure, gh CLI config, git credentials, Docker config, kube, npm, PyPI, gem, netrc, pgpass, MySQL, curl, Maven, Gradle, Terraform, gcloud SDK, HashiCorp Vault, Cargo, password-manager CLI. Supersedes `block-ssh-private-key.js` (issue #254). WORKFLOW_OFF does NOT bypass. Path table: `CREDENTIALS_TABLE` in `hooks/block-credentials.js`. Recognizes `~`, `$HOME`, `${HOME}`, `$USERPROFILE`, `${USERPROFILE}`, and dot-segment forms; additionally recognizes the corresponding `/root/<tail>` sibling of every `~/`-rooted family (same path with `~/` stripped; see `CREDENTIALS_TABLE` in `hooks/block-credentials.js`). `..` traversal resolved by `path.posix.normalize`.
- `confirm-forge-target-ownership.js` (PreToolUse, matcher: `Bash|runInTerminal|runCommands`) — asks
  before a `gh issue create` / `gh api` issue write whose target repository is not proven to belong to
  the authenticated account. Silence requires positive proof (login match or repo admin); an
  unreadable command shape is unresolved, not safe. Never blocks, never bypassed by WORKFLOW_OFF or
  WORKTREE_OFF. Reason codes: `hooks/confirm-forge-target-ownership/reasons.js` (issue #2053).
- `block-subagent-sentinels.js` (PreToolUse, matcher: `Bash|runInTerminal|runCommands`) — blocks a
  subagent from driving the workflow state machine through either door: a `WORKFLOW_*` sentinel
  echo, or an advance-class CLI invoked with a mutating flag (`--advance`/`--mark`/`--reset`) — the
  CLI-invocation door #2102 added once `research`/`write_tests` moved their completion door off the
  sentinel echo. Sentinels are reserved for the orchestrator (main conversation) either way.
  Sentinel detection uses `isStrictSentinel`, `CHAIN_BOUNDARY_SENTINEL_DQ_RE`, and
  `CHAIN_BOUNDARY_SENTINEL_SQ_MARKER_RE` (`hooks/lib/sentinel-patterns.js`); CLI-door detection is
  `isWorkflowStateDriverCommand` (`hooks/lib/workflow-driver-commands.js`), which tokenizes each
  `runCommands`-array element on its own (never a joined string) and recognizes any CLI named in
  `ADVANCE_ORIGINS`, including one reached via `bash`/`pwsh`/`cmd -c` recursion. Subagent
  identification via `agent_id` presence (see `hooks/lib/subagent-detect.js`). Fail-open: malformed JSON
  approves (stdin contract: [hook-stdin-input.md](../hook-stdin-input.md)), as do an absent `agent_id` or an empty `ADVANCE_ORIGINS` roster. Defense-in-depth with
  the `workflow-mark.js` PostToolUse backstop (C2).
- `block-history-direct.js` — blocks direct writes to the **append-only document family**:
  the canonical documents (`docs/history.md`, `CHANGELOG.md`) *and* their rotated archives
  (`docs/history/*.md`, `changelog/*.md`, `docs/changelog/*.md`). Rotation moves entries out of
  the canonical file, so protecting only the canonical name leaves every rotated entry
  unguarded — the sanctioned path is `doc-append` / `doc-rotate.py` for both. The rule-of-the-rule
  documents (`rules/docs/history.md`, `rules/docs/changelog.md`) are ordinary editable prose and
  are excluded by name. **Registered as two matcher groups**: `Edit|Write|MultiEdit|NotebookEdit`
  for tool writes, and `Bash|runInTerminal|runCommands` for shell redirects / `tee` / `cp` / `mv`
  into a protected path. Both groups are required — either alone leaves the other lane open.
  `WORKFLOW_ENFORCE_WORKFLOW_OFF` / `WORKFLOW_ENFORCE_WORKFLOW_OFF_EMERGENCY` bypass: a protected
  hit approves instead of blocking when the calling session has an active `isWorkflowOff(sid)`
  marker. See `marker-bypass-contract.md` for the full cross-hook
  honoring contract.
- `workflow-gate.js` (PreToolUse, matcher: `Bash`) — enforces all 10 workflow steps before
  `git commit`. Reads state from `~/.workflow-state/<session-id>.json`. Fail-safe:
  blocks on missing session_id, missing state file, or corrupted JSON. Evidence-based override
  for `write_tests` (staged `tests/` files) and `docs` (staged `*.md` files).
  **Docs-only short-circuit**: when every staged file matches the human-facing docs allowlist
  (regex `^(docs\/.+\.md|(README|CHANGELOG|CONTRIBUTING|LICENSE)\.md)$/i`),
  only `user_verification` is required — research/plan/write_tests/run_tests/review_security
  are automatically bypassed. Behavior/prompt `.md` files (`CLAUDE.md`, `SKILL.md`, any
  subdirectory `README.md`) are NOT eligible — they are treated as code.
  Use case: follow-up commits that tick a checkbox in `docs/todo.md`, append to
  `docs/history.md`, or refresh the user-visible description in root `README.md`.
  Replaces `check-docs-updated.js` and `check-tests-updated.js`
- `bash-guard.js` (PreToolUse, matcher: `Bash`) — Bash command classifier with four verdicts
  (deny → notify → allow → passThrough); full contract: [bash-guard.md](bash-guard.md).
- `rtk-rewrite.js` (PreToolUse, matcher: `Bash`) — when `RTK=on` in `.env`, rewrites
  eligible Bash commands to pipe their output through the RTK binary before it reaches
  the model, compressing repeated tokens to reduce LLM input size. Default OFF
  (`RTK=off`). Four passthrough guards (all returning `{}` — no modification): G-a
  (`isAgentsEmit`) passes framework scripts under `AGENTS_MAIN_ROOT` unchanged; G-b
  (`isMachineReadable`) passes commands producing porcelain/structured output (e.g.
  `git status --porcelain`, `git log --format=…`) unchanged; G-c (`isComposite`)
  passes compound commands (pipes, redirects, newlines, command substitution)
  unchanged; G-d (`isShellBuiltin`) passes shell builtins (`cd`, `echo`, `export`,
  etc.) unchanged. Only a single, non-machine-readable, non-framework, non-builtin
  command is wrapped. RTK config is managed by the RTK binary itself (installers
  run `rtk config` / `rtk config --create`, no hardcoded schema); guard logic
  lives in `hooks/rtk-rewrite.js`.
- `jev-shadow-pre.js` (PreToolUse, matcher: `Agent|Task`) and `jev-shadow-post.js`
  (PostToolUse, matcher: `Agent|Task`) — when `JEV=on` in `.env`, query the Jev typed
  classifier alongside a `complexity-judge` dispatch and record both answers for comparison.
  Shadow mode: the LLM judge's result is always adopted, and both hooks always exit 0.
  Default OFF (`JEV=off`). Contract and module map: [jev.md](../../jev.md).
- `subagent-dispatch-prompt.js` (PreToolUse, matcher: `Agent|Task`, own group) — backstop for the
  `rules/shell-commands.md` Subagent Dispatch Prompts canonical line: appends it (absolute rule path)
  unless one trimmed prompt line fully matches it; a JSON-object prompt gets it under `dispatch_directive`.
  Named agents whose `tools:` line has none of Bash/Write/Edit are skipped. Returns only `updatedInput`
  (all original fields carried forward), never a permission verdict; fail-open. Whether the host replaces
  or merges `updatedInput` is unverified (the TL3 spike is pending). Do not add another hook that returns `updatedInput`
  on the same matcher: the result of combining two such outputs is undefined.
- `workflow-mark.js` (PostToolUse) — intercepts `echo "<<WORKFLOW_MARK_STEP_step_status>>"` and
  `echo "<<WORKFLOW_RESET_FROM_{step}: {reason}>>"` via strict regex on `tool_input.command`. Supports `&&`-chained
  sentinel commands (all-or-nothing: any non-sentinel part rejects the whole command). Step sequencing
  is next-step-driven: the model queries `bin/workflow/next-step` after each completion rather than
  receiving a static prose hint
- `show-plan-link.js` — PostToolUse on the edit-write tool class and `assemble-mandatory.sh` commands. Runs when a final plan artifact (`*-(intent|outline|detail).md` directly under `~/.workflow-plans/`) is written, regardless of `CONFIRM_<STEP>`. It records the project host (from the hook input's `cwd`), publishes the file through plan-sync, then always emits `hookSpecificOutput.additionalContext` (`[plan-link]`): the blob URL plus the local path, or the local path plus a reason, for the model to write in its response text. The `systemMessage` breadcrumb (`Plan file: <local path>` plus a `[plan-sync]` status line) is added only when there is no URL for a reason other than the project-host verdict (`host-mismatch`, `no-project-host`). Fail-open: a sync failure never aborts the hook or the workflow. Design and setup: [../plan-sync.md](../plan-sync.md).
- `confirm-checkpoint.js` (PreToolUse, CONFIRM sentinel) — reaches the dialog only on a presentation receipt (#2729, [glossary](../../../glossary/internal.md)): the receipt the Stop hook wrote for this stage must still match today's plan path, link (published URL, or the local path where no URL can be made) and whole-file content sha, and the judgment spends it, so two concurrent echoes cannot both pass. Anything it cannot verify denies with a present-again reason (`no-receipt`, `unpublished`, `unreadable-receipt`, a path/link/content mismatch, …), with no deny cap: a third echo is denied like the first. The one fail-open is a hook input it cannot read, where not even the sentinel is known. Otherwise it emits the user-facing `systemMessage` plus `additionalContext` (`[plan-link]`); it never emits allow. The off waiver comes from `hooks/lib/confirm-gate/plan-gate.js` (`planGateState`), the same predicate `next-step --gate` uses; `ERROR` shows the dialog, and intent has no waiver. Where plan-sync can publish, an unpublished plan is denied before any receipt is looked at.
- `gate-plan-skill-advance.js` (PreToolUse, matcher: `Skill`) — denies `make-outline-plan` / `make-detail-plan` / `write-tests` while the preceding plan stage's approval is `unapproved` (#2277); every other state, including unreadable ones, passes silently. A deterrent only — the side-effect owners (`run-completion.sh`, the completion sentinels) fail closed.
- `block-send-user-file.js` (PreToolUse, matcher: `SendUserFile`) — denies the tool so a plan is shown by its plan-link line in the response text, never sent as a file. Any other tool or unreadable stdin passes with no output.
- `gate-plan-lang.js` (PreToolUse, matcher: `Write|Edit|MultiEdit|editFiles`) — rejects a write to a final plan artifact under the plans directory whose submitted text violates a strict `PLAN_LANG` (`english` / `japanese`) BEFORE the file changes (#2278). The unit of analysis is the per-edit fragment: each `edits[]` element carries its own path (inheriting the top-level one when absent) and is linted on its own, so an unclosed code fence in one fragment cannot hide prose in the next. The gate never reads the target file and never writes; the block reason is prefixed `[gate-plan-lang] PLAN_LANG=<policy>` and echoes only the violating lines, numbered relative to the fragment. Hint-tier policies and every error path approve silently. Why a PreToolUse gate when `check-plan-lang.js` already exists: a PostToolUse block lands after the bytes are on disk, so a non-compliant model could still confirm the stage. A `Write` to an intent artifact carries the whole document, so it also gets the intent `## Glossary` structure check (#2529), reported under `[gate-plan-lang] intent structure`; Edit fragments skip it because a headingless fragment is normal.
- `gate-worktree-notes-lang.js` (PreToolUse, matcher: `Write|Edit|MultiEdit|editFiles`) — the
  same pre-write treatment for `WORKTREE_NOTES.md` `## History Notes` / `## Changelog Notes`
  bullets against `DOCS_LANG_PUBLIC` / `DOCS_LANG_PRIVATE`, routed by the hook's own
  private-repo detection of the cwd (#2278). A fragment that carries one of the two headings is
  self-contained and linted alone; a headingless fragment (a bullet-only Edit) is judged on the
  reconstructed post-edit document, because only the file on disk says which section the bullet
  lands in. Unreadable file or an `old_string` absent from disk approve (fail-open); the
  PostToolUse checker below remains the backstop. Block prefix:
  `[gate-worktree-notes-lang] WORKTREE_NOTES.md language check failed`.
- `block-case-markers.js` (PreToolUse, matcher: `Write|Edit|MultiEdit|editFiles`) — rejects a
  write leaving a NEW `.sh` test entrypoint (absent from HEAD, repo carrying `tests/lib/harness.sh`)
  with missing or malformed `case_begin`/`case_end` markers (#2388). Each MultiEdit element is
  judged against its own path; the post-edit content is rebuilt in memory (`hooks/lib/post-edit-content.js`)
  and checked by `bin/check-case-markers.sh` on a temp copy. editFiles and every error path approve;
  `hooks/pre-commit` is the backstop. Block prefix: `[block-case-markers]`. See
  [case-marker-gate.md](../case-marker-gate.md).
- `check-plan-lang.js` (PostToolUse, matcher: `Write|Edit|MultiEdit|editFiles`) — post-write backstop for the plan-artifact language policy: strict tier blocks with the `[check-plan-lang] PLAN_LANG=<policy>` header, hint tier emits `additionalContext` only. Shares plan-artifact path resolution and violation formatting with the PreToolUse gate through `hooks/lib/plan-artifact-lang.js`, so the two surfaces cannot drift (#2278). It also runs the intent `## Glossary` structure check on the whole written document (#2529) and lists any such violation under `[check-plan-lang] intent structure` in the same block message.
- `check-worktree-notes-lang.js` (PostToolUse, matcher: `Write|Edit|MultiEdit|editFiles`) —
  post-write backstop for `WORKTREE_NOTES.md`; reads the file as written and lints the two
  target sections with the same routing (`safeIsPrivateRepo` from `hooks/lib/is-private-repo.js`)
  as the PreToolUse gate.
- `stop-confirm-plan-guard.js` (Stop) — Layer 2 and the plan-link check, with distinct reason
  prefixes. The former Layer 1, which blocked any plans-directory path in the last message, is
  removed: the local path is now part of the plan-link line. Layer 2 runs on EVERY Stop (#2278 removed the marker precondition): when a
  `CONFIRM_<STAGE>` sentinel appears in the last assistant turn, it first re-lints the confirmed
  artifact against a strict `PLAN_LANG` (`[confirm-plan] Layer 2/plan-lang:`) and then requires a
  stage-valid follow-up tool_use after the Allowed echo's result in the same turn (`[confirm-plan] Layer 2/follow-up:`);
  a denied echo needs none. The re-lint resolves `<sid>-<stage>.md` only for UUID or timestamp
  session ids; any other id, an absent or unreadable artifact, or a non-strict policy skips it.
  The plan-link check (`[confirm-plan] plan-link:`) applies only to a turn that wrote a plan
  artifact (per-turn marker), not to a CONFIRM-only turn: the turn's LAST text block must carry
  that stage's plan-link output — the blob URL when one exists, otherwise the local path in any
  of its spellings (native, forward-slash, `~`, `file:///`, inline code). Parsing lives in
  `hooks/lib/plan-link-turn-check.js`; the check blocks once (stands down on `stop_hook_active`).
  The plan-link duty follows the stage's gate: with the gate `ON` the link line must close the
  turn's last text block; with it `OFF` the line may sit anywhere in the turn (#2724). The
  presentation receipt (#2729): a turn the hook lets through that closed on unapproved stages'
  link lines (every stage whose link run ends the last text block, Gap 5) gets one receipt per
  stage, holding the plan path, the link shown and the whole-file content sha. A turn the hook
  blocks voids every receipt of the session. An `ON` stage whose plan is not published where
  plan-sync could publish it is blocked once as unpublished.
  The continuation (`[confirm-plan] continue:`, last, #2650): when the last text block shows
  exactly one plan stage's link line and that stage is unapproved, not yet echoed, and `ON`
  (at most one `planGateState` probe inside a 4000 ms budget), it blocks once so the CONFIRM
  echo follows in the same turn. Logic: `hooks/lib/confirm-continuation.js`. Fail-open
  throughout.
- `hooks/lib/transcript-reader.js` — the one transcript reader of the Stop and PreToolUse hooks (#2610). At Stop it waits until the transcript's last text block agrees with `last_assistant_message`, which only confirms the flush and is never judged as the body; a flush that never agrees reads as `undecidable` and the caller fails open. `readPreviousTurn` splits the previous and current turns for `confirm-checkpoint.js`.
- `workflow-run-tests.js` (PostToolUse, matcher: `Bash`) — marks `run_tests` from the machine-readable
  `RUN_CONTRACT` line emitted by `tests/run-all.sh`, never from a raw exit code (#1242, contract-trust).
  Detects test runner commands over the shared command IR (`hooks/lib/command-ir.js` `parse()` +
  `resolveEffectiveSegment()`), which resolves each segment's effective command through control-structure
  keywords and env-prefix assignments before matching path pattern (`tests/`) and known runner names — so a
  read-only command that merely names a test path inside a loop/condition header (e.g.
  `for f in tests/*.sh; do head "$f"; done`) is no longer mis-detected (#1330). Exec-position classification
  (which command-IR segments count as candidate emitters at all) and emitter-identity/provenance resolution
  are split into `hooks/workflow-run-tests/exec-model.js` and `hooks/workflow-run-tests/provenance-identity.js`
  respectively (#1273) — the former decides *where in the command* a test runner could legitimately execute,
  the latter decides *which segment's* output is attributable to a verified runner, flagging 2+ distinct
  verified emitters as `ambiguous` (same emitter appearing twice is not ambiguous by itself). Independently,
  `stdoutAttributed()` enforces byte-position invariants over the whole stdout string so a forged
  `RUN_CONTRACT`/`log_tail` line prepended or appended around the real payload cannot be parsed as
  authoritative: worker-dispatch payloads require `RUN_CONTRACT:` as the first line with exactly one
  unindented `log_tail: |` marker; run-all payloads require `RUN_CONTRACT:` as the last non-empty line.
  `complete` requires all of: run-all.sh provenance, unambiguous emitter attribution, stdout byte-attribution,
  exactly one well-formed `RUN_CONTRACT` line, `executed>0` and `fail==0` (and `write_tests` already
  satisfied). exit ≠ 0, any test command lacking a valid contract (ad-hoc runner, piped/compound run-all.sh,
  no-match), ambiguous emitter attribution, or an unattributed stdout region, demotes `run_tests` to
  `pending`. Sentinel echoes, read-only commands, and git non-exec subcommands (resolved past leading global
  options) excluded. Any unrelated Bash call observed between an explicit completion sentinel and the next
  workflow-state read can retrigger this demotion (continuous re-verification, not a bug) — re-emit the
  completion sentinel immediately before checking workflow state if this happens.
  **Two recording routes (#2544).** Besides the stdout route above, a test-runner dispatch leaves
  `<stem>.outcome.json` in the session control dir (written only by the dispatcher, exclusive create).
  Every Bash call, whatever its command, first settles the latest test-runner dispatch
  (`hooks/workflow-run-tests/dispatch-outcome.js`): a trusted outcome is recorded through the same
  judgement as stdout (`record-run.js`, the hook's only run_tests writer) and then marked
  `<stem>.ingested`; a replay of the same outcome bytes records nothing. Trust requires a regular file,
  a valid shape, matching worker/stem/session, the payload's SHA-256 and `cwd`, and a `.dispatched`
  marker; `failing_tests` is kept only when every name exists under that `cwd`. While the latest dispatch
  is unsettled, a non-test call demotes a stale complete or failing record to `pending`, and a test
  call's stdout may demote but never complete. `outcome_source` records which outcome bytes a state
  write came from; `bin/run-tests-baseline-evidence` refuses (exit 3) when a newer dispatch is unsettled
  or those bytes changed.
- `detect-worktree-conflict.js` (PostToolUse, matcher: `Bash|runInTerminal|runCommands`) — when a
  failed terminal command's stderr matches `fatal: '<branch>' is already used by worktree`, emits a
  single `additionalContext` guidance message (locate via `git worktree list`, finish with
  `/worktree-end` or reclaim with `/sweep-worktrees`). Non-blocking, fail-open on malformed input;
  success detection uses the shared 3-field contract (`exit_code ?? exitCode ?? success`).
  Deliberately limited to exactly one pattern + one message (#1443) — generalizing git-error
  guidance into a table is #1447's scope
- `postuse-shell-snapshot-repair.js` (PostToolUse + PostToolUseFailure, matcher: `Bash`) — rewrites a
  Windows-form `PATH` line in shell snapshots to POSIX form so Bash stops exiting 127; fail-open, never
  re-runs the failed command (#2221). See [../shell-snapshot-repair.md](../shell-snapshot-repair.md)
- `session-start.js` (SessionStart) — inherits prior session's workflow steps if cwd+branch match found in transcript (see
  [workflow.md — Session ID flow](../workflow.md)); otherwise creates fresh state; outputs
  `additionalContext` containing session_id, every step status, and a `NEXT ACTION:` line
  from next-step (`bin/workflow/next-step`); runs zombie cleanup; repairs Windows-form shell snapshots
- `post-compact.js` (PostCompact) — re-injects session_id into conversation context after
  compaction so the transcript retains the marker for future inheritance lookups
- `instructions-loaded-audit.js` (InstructionsLoaded) — classifies ONE loaded instruction
  file per firing (the host dispatches per file, asynchronously, in separate processes)
  and publishes a receipt under `<workflowDir>/<sid>.instructions-loaded/`. Verdicts:
  `ok` / `S-MISSING` / `S-MALFORMED` / `S-LEAK` / `unreadable`; `S-MISSING`+ emit one
  supervisor finding per verdict change. Always exits 0 with empty stdout (fail-open) —
  blocking is the static checker's job (`bin/check-on-demand-rules.sh`). See
  [rules-injection.md](../rules-injection.md)
- `stop-final-report-guard.js` (Stop) — two independent trigger lanes, so a skipped
  session-close is caught even when the session never reached the lane-A precondition:
  - **Lane A (format validation)** — fires when the Final Report env file exists; blocks
    the turn if any required heading is missing from the rendered report.
  - **Lane B (state-driven)** — fires when the env file is absent but the workflow state has
    reached `pre_final_report_gate` (asked via `bin/workflow/next-step`): the close procedure
    was never run, so the turn is blocked unconditionally. Three escape hatches: `WORKFLOW_OFF`
    for the session, a session-close gate artifact whose `gate_action` is `yield`, and any
    failure to consult next-step (fail-open).
  `stop-premature-stop-guard.js` delegates to this hook rather than competing with it: when
  next-step reports `pre_final_report_gate`, it exits 0 and lets lane B own the message.
- `check-cross-platform.js` (PreToolUse, matcher: `Bash`) — blocks `git commit` when
  platform-specific files (`install/win/` ↔ `install/linux/`) are staged without counterpart
  changes. Skip mechanisms: `.cross-platform-skiplist` (permanent, base tool names) and
  `.git/.cross-platform-reviewed` (one-time, HEAD hash)
- `enforce-worktree.js` (PreToolUse, matcher: `Bash|Edit|Write|MultiEdit`) — when
  `ENFORCE_WORKTREE=on` (default), blocks writes from the main worktree regardless
  of branch, and blocks default-branch edits. Main-worktree detection: `--git-common-dir
  == --git-dir` (linked worktrees have differing values). Default-branch detection:
  `refs/remotes/origin/HEAD` → local `main`/`master` → `init.defaultBranch` → fallback
  `main`. Override via `DEFAULT_BRANCHES=develop,trunk,...` (comma-separated).
  Allows: HEAD unborn, detached HEAD, files outside any git repo, `git worktree
  add/remove/prune` lifecycle commands, PowerShell `New-Item -ItemType Directory`
  (target resolves outside the repo, or under the session scratchpad / `WORKFLOW_PLANS_DIR`),
  and Bash writes whose targets ALL resolve under the session scratchpad
  (`<os-tmpdir>/claude/`, scoped to `$SCRATCHPAD` when set) or `WORKFLOW_PLANS_DIR`
  (heredoc/redirect forms included). The workflow-gate early gate allows the same two
  destinations through the same predicate (#2108, `hooks/workflow-gate/early-gate-allowlist.js`),
  so an agent blocked by one hook is not handed a different answer by the other. Non-directory `New-Item`, in-repo targets, quoted
  paths that expand into the repo, and mixed/unresolvable target sets stay fail-closed.
  Defense-in-depth at commit time via the bash block in `pre-commit`. Falsy values
  (`off|0|false|no|disabled`, case-insensitive) opt out.
  Path coverage (`ENFORCE_WORKTREE_EXCLUDE`), gh command classification, dispatch provenance
  (#2064), additional repos, quote-span analysis, the script checkout root trust anchor, the
  worker-dispatch sanction (#1643, #1673) and the heredoc gate widening (#2120/#2121) are
  detailed in [enforce-worktree.md](enforce-worktree.md).
- `post-push-workflow-reset.js` (UserPromptSubmit) — detects push milestone:
  if `last_pushed_sha` (recorded by `workflow-mark.js` on a successful `git push`)
  equals current HEAD, resets workflow step `branching_complete` to pending and
  clears `last_pushed_sha`. Forces fresh branch/worktree creation for the next task.
- `lang-inject.js` (UserPromptSubmit) — per-turn re-injection of the `CONV_LANG`
  directive to counter language drift in long sessions (lost-in-the-middle); additionally
  injects the `PLAN_LANG` directive when `isPlanning()` is true (any of
  `clarify_intent`/`outline`/`detail` not complete/skipped) so plan artifacts are steered
  before they are written. Directive text is the shared SSOT from `getConvLangInjection`
  / `getPlanLangInjection` (`hooks/lib/conv-lang.js`, `hooks/lib/lang-config.js`), the same
  source consumed by `subagent-start.js` (which injects `PLAN_LANG` for every subagent type
  whenever the policy is not noop, so a mis-dispatched `general-purpose` planner still receives
  it). Fail-open: any error yields `{}`.
- `codegraph-context-inject.js` (UserPromptSubmit) — forwards the upstream CodeGraph prompt-hook's
  OUTPUT as `additionalContext`, without ever running `codegraph install` (which would rewrite
  `~/.claude/CLAUDE.md` and register the hook itself). Gated three ways before it spawns anything:
  `CODEGRAPH=on`, a `.codegraph/codegraph.db` found within six levels above the payload cwd, and a
  scope gate that refuses the home directory and any filesystem root — upstream's own exclusion,
  ported. Fail-open at every step: a missing flag, a failed spawn, a non-zero exit, empty output, or
  any throw all yield `{}` and exit 0, so a prompt is never blocked or delayed past the 5s timeout.
- `progress-nudge.js` (UserPromptSubmit, PostToolUse matcher `""`, Stop) — in the active period and
  main conversation only, injects a `[progress check]` request to update `session-progress.md`; PostToolUse
  leaves after a stat-only pre-check unless something could fire. Kinds, cap, Stop handling, state:
  [progress-file.md — Progress request](../progress-file.md#progress-request).
  Fail-open: any error yields `{}`.
- `user-prompt-submit-wf-init-mark.js` (UserPromptSubmit) — when the user's prompt invokes `/workflow-init`
  (detected via `promptInvokesWfInit` in `hooks/lib/step-in-flight-policy.js`), records `workflow_init`
  as `in_progress` via `hooks/lib/wf-init-begun-mark.js` (#1633). A slash command expands to prompt text
  rather than a Skill tool call, so `postuse-step-in-flight-mark.js` cannot see it; this hook closes that
  gap. Fail-open throughout: a missed mark only delays the "begun" read in the workflow gate.
- `record-off-skill-invocation.js` (UserPromptSubmit) — records PROVENANCE for the EMERGENCY OFF
  escape hatch (#1780). `UserPromptSubmit` is an event the model cannot trigger, so a marker written
  from it is evidence the human acted: a prompt invoking `/enforce-workflow-off` writes
  `<workflowDir>/<sid>.off-emergency-invoked`, any other prompt clears a stale one.
  `workflow-mark/enforce-override-handlers/off-clearance.js` consumes and unlinks it when the
  emergency sentinel fires, stamping the `escape_hatch_event` audit record and the override marker
  with `provenance=user_skill_invocation` or `provenance=unattributed`. Evidence only, never a gate —
  absence never blocks the override, and `unattributed` means "not provably user-invoked" (a user who
  asks in prose rather than typing the slash command is under-attributed by design).
  What `user_skill_invocation` asserts is bounded, and the marker payload is what bounds it
  (`hooks/lib/off-emergency-provenance.js` is the shared writer/reader contract): the human typed a
  slash command resolving to the `enforce-workflow-off` skill, within the freshness window, and that
  skill covers the target being activated. It asserts nothing about the reason text, and nothing about
  a target outside the set the marker names — the typed plugin namespace is deliberately not recorded,
  since it is attacker-choosable prompt content, so the marker carries the resolved skill name instead.
  Attribution is contingent on the marker being successfully CONSUMED: if the unlink fails, provenance
  downgrades to `unattributed` and the audit record carries a `provenance_notes=` explanation, because
  a marker that survives could otherwise vouch for several activations from one invocation. Every other
  unverifiable case (stale, future-dated, corrupt, missing binding fields) downgrades the same way. The marker
  basename is in the `hooks/lib/protected-basenames.js` protected set, so `block-clearance-token-write.js`
  refuses `Edit`/`Write`/`MultiEdit`/`editFiles`/`NotebookEdit` calls naming it and refuses Bash write
  targets that spell it — literally, via backslash escapes or intra-word quoting, via a glob, or via a
  `$VAR` the same command line assigns. That is a best-effort deterrent, not proof of unforgeability:
  the hook's TRUST MODEL comment enumerates what remains out of reach (dynamic path construction,
  base64, alternate interpreters, edits to the hook itself). Nothing depends on it being airtight —
  provenance is an audit signal, never a gate, so a forged marker grants no clearance; it only
  mislabels the audit record. Fail-open: any error yields `{}`.
- **Protected-basename boundary: suffix, then stem (#2108)** — a basename used to be protected on its
  SUFFIX alone (`*.workflow-off`, `*.gh-env`, …), which caught every unrelated file that happened to
  end that way, since a scratchpad note named `issue-2108-survey.md` shares no clearance with the
  marker files. The decision now needs both halves: the suffix, AND a stem that could actually be
  opened by a clearance reader — every reader opens exactly `path.join(dir, sid + ".<kind>")`, so only
  a stem that IS an effective session id can confer clearance. `isClearanceBearingStem()` in
  `hooks/lib/protected-basenames.js` owns that predicate; `hooks/lib/active-session-ids.js` observes
  the candidate sids (the hook payload's session id, the resolved session id, and the stems present in
  the workflow dir) and reports whether that observation was COMPLETE.
  Two named exceptions keep the narrowing from cutting into real coverage. **Per-route spelling**: the
  `Edit`/`Write` route matches a stem exactly (`spelling:"clean"`), but the Bash route
  (`spelling:"bash"`) can only match a non-alphanumeric-bounded tail, because bash-word unquoting
  collapses `C:\wf\<uuid>` to `C:wf<uuid>` — so on that route a stem carrying any character outside
  `[A-Za-z0-9._-]` is unprovable normalization residue and stays protected. **Fail-closed on
  unobservable**: if the sid observation is incomplete (unreadable workflow dir, any throw), no
  narrowing is applied at all and behaviour is identical to the pre-#2108 suffix-only rule. A glob
  candidate keeps matching on suffix alone for the same reason — its post-expansion stem is unprovable.
  Residual risk (R2b): a file whose stem genuinely IS an active session id but which is not a clearance
  artifact remains protected, and, in the other direction, an attacker who can already learn the
  session id gains nothing here that the pre-change rule denied them — the narrowing only removes
  false positives, it never widens what a caller may write.
- **Outbound content and the verdict review** — the verdict review runs on **every**
  `/issue-create` candidate; there is no on/off toggle, and the only condition that skips it
  is `codex` being absent from `PATH`. It sends the proposed issue text AND the bodies of the
  surveyed candidate issues to codex. Server-side web search (`-c tools.web_search=true`) is
  opt-in via `ISSUE_VERDICT_WEB_SEARCH` (default off); when enabled, model-composed queries
  derived from that text also reach an external search engine. That second hop is bounded by
  prompt constraint only — the prompt forbids repository names, URLs, issue numbers,
  organization names and other identifying tokens in queries, and requires symptoms to be
  paraphrased generically — which is not mechanically enforceable. The reverse direction
  (codex output reaching GitHub) is scanned by `gh_outbound_guard` before any comment is
  posted, and a web-search hit alone may never justify suppressing a filing.
- **Model-conditional prompt injection** — `hooks/lib/verbose-prompt.js` is the language-injection
  provider's sibling: a pure provider holding the single definition of a one-line procedure-hardening
  directive, injected only for models whose identifier matches `VERBOSE_PROMPT_MODELS`. Keeping the
  text in `hooks/lib/` rather than `rules/*.md` is what makes it cost zero context while the flag is
  off. Which model is driving the session is resolved once at SessionStart from the hook payload's
  `model` field, and frozen in the session state file (`session_model` + `verbose_prompt`), so later
  reads never re-decide. Two consumers: `session-start.js` (resolves, freezes, then injects) and
  `post-compact.js` (read-only re-injection after compaction). Fail-open throughout: an unresolvable
  model, an unusable session id, or an unwritable state directory all yield no injection.
  The directive names the five observed failure modes of less compliant models — skipping skill
  steps, summarizing over a prescribed command's output, editing append-only documents directly,
  dispatching a subagent under a type other than the one the skill names, and drafting plan
  artifacts outside `PLAN_LANG` (#2278) — and its exact wording lives only in that module.

