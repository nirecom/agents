# settings.json Design

**Allow rules** — read-only operations only:
- Git read commands (`git status`, `git log`, `git diff`, `git branch`, etc.)
- `git -C <path>` for cross-directory git reads — preferred method
- Filesystem reads (`ls`, `tree`, `head`, `tail`, `grep`, `wc`, etc.)
- `.env.example` reads (`.env` itself is denied)

**Deny rules** — four categories (wildcard prefix `*` to catch compound commands):

| Category | Target |
|:---|:---|
| Environment files | `.env`, `.env.*` |
| Destructive commands | Force push, hard reset, deletion |
| Credentials | SSH, GPG, AWS, Azure, gh, git, Docker, kube, npm, PyPI, gem, netrc, pgpass, MySQL, curl, Maven, Gradle, Terraform |
| Direct dotfile editing | Home directory dotfiles |

See `docs/security-policy.md` for the full pattern list.

**Hook format**: Nested format — `matcher` + `hooks` array. Timeout in seconds.

```json
{ "matcher": "Edit|Write", "hooks": [{ "type": "command", "command": "node .../hook.js", "timeout": 5 }] }
```

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
- `block-subagent-sentinels.js` (PreToolUse, matcher: `Bash|runInTerminal|runCommands`) — blocks
  `WORKFLOW_*` sentinel echoes issued from subagents. Sentinels are reserved for the orchestrator
  (main conversation); subagents cannot drive the workflow state machine. Detection uses the
  `isStrictSentinel`, `CHAIN_BOUNDARY_SENTINEL_DQ_RE`, and `CHAIN_BOUNDARY_SENTINEL_SQ_MARKER_RE`
  patterns from `hooks/lib/sentinel-patterns.js`. Subagent identification via `agent_id` presence
  (see `hooks/lib/subagent-detect.js`). Fail-open: approves on malformed stdin or absent `agent_id`.
  Defense-in-depth with the `workflow-mark.js` PostToolUse backstop (C2).
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
  `git commit`. Reads state from `~/.claude/projects/workflow/<session-id>.json`. Fail-safe:
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
- `workflow-mark.js` (PostToolUse) — intercepts `echo "<<WORKFLOW_MARK_STEP_step_status>>"` and
  `echo "<<WORKFLOW_RESET_FROM_{step}: {reason}>>"` via strict regex on `tool_input.command`. Supports `&&`-chained
  sentinel commands (all-or-nothing: any non-sentinel part rejects the whole command). Step sequencing
  is next-step-driven: the model queries `bin/workflow/next-step` after each completion rather than
  receiving a static prose hint
- `show-plan-link.js` — PostToolUse on Write. Always emits a `Plan file written: <path>` breadcrumb when a final plan artifact (intent/outline/detail.md matching `*-(intent|outline|detail).md` directly under `~/.workflow-plans/`) is written. When `CONFIRM_<STEP>=on` (default) AND a VS Code session is detected (`TERM_PROGRAM=vscode` or `CLAUDE_CODE_ENTRYPOINT=claude-vscode` (excluded when `VSCODE_CRASH_REPORTER_PROCESS_TYPE=extensionHost`)) AND `SHOW_PLAN_LINK_NO_AUTO_OPEN` is unset, additionally spawns a single `code --folder-uri <uri> <filePath>` invocation (raises window and opens file atomically, eliminating the two-spawn timing race — #546 Gap 3). `normalizeCwd()` is applied at the entry of `workspaceFolderUriFrom` to convert Unix-style Git Bash drive-letter paths (as emitted by MSYS2/Git Bash `pwd`) to native Windows drive-letter form before URI construction, fixing multi-window routing on Windows. URI source ladder: `input.cwd` → `process.cwd()` → bare `code -r` (no folder-uri). Folder URI path segments are percent-encoded via `encodeURIComponent` for spaces / `#` / `%` / non-ASCII / UNC support (#492). Windows uses `cmd.exe /d /s /c code ...` per spawn (CVE-2024-27980 mitigation). VS Code 1.121 regression: when `--folder-uri` and a file path are passed together, the file-open arg is silently dropped; fixed in 1.122+. Users on 1.121 must click the breadcrumb manually — no fallback provided (#546). Fail-open: spawn errors do not abort the hook.
- `show-diff.js` (PreToolUse, matcher: `Write`) — shows an inline diff in chat for any final
  plan artifact written under `~/.workflow-plans/` (non-draft direct children:
  `*-(intent|outline|detail).md`). When the corresponding `CONFIRM_<STEP>` flag is off, the
  diff is suppressed (#445). Draft artifacts (`drafts/` subdirectory) are always suppressed.
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
- `detect-worktree-conflict.js` (PostToolUse, matcher: `Bash|runInTerminal|runCommands`) — when a
  failed terminal command's stderr matches `fatal: '<branch>' is already used by worktree`, emits a
  single `additionalContext` guidance message (locate via `git worktree list`, finish with
  `/worktree-end` or reclaim with `/sweep-worktrees`). Non-blocking, fail-open on malformed input;
  success detection uses the shared 3-field contract (`exit_code ?? exitCode ?? success`).
  Deliberately limited to exactly one pattern + one message (#1443) — generalizing git-error
  guidance into a table is #1447's scope
- `session-start.js` (SessionStart) — appends `CLAUDE_SESSION_ID=<sid>` to `CLAUDE_ENV_FILE`;
  inherits prior session's workflow steps if cwd+branch match found in transcript (see
  [workflow.md — Session ID flow](workflow.md)); otherwise creates fresh state; outputs
  `additionalContext` containing session_id, all 16 step statuses, and a `NEXT ACTION:` line
  from next-step (`bin/workflow/next-step`); runs zombie cleanup
- `post-compact.js` (PostCompact) — re-injects session_id into conversation context after
  compaction so the transcript retains the marker for future inheritance lookups
- `instructions-loaded-audit.js` (InstructionsLoaded) — classifies ONE loaded instruction
  file per firing (the host dispatches per file, asynchronously, in separate processes)
  and publishes a receipt under `<workflowDir>/<sid>.instructions-loaded/`. Verdicts:
  `ok` / `S-MISSING` / `S-MALFORMED` / `S-LEAK` / `unreadable`; `S-MISSING`+ emit one
  supervisor finding per verdict change. Always exits 0 with empty stdout (fail-open) —
  blocking is the static checker's job (`bin/check-on-demand-rules.sh`). See
  [rules-injection.md](rules-injection.md)
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
  `ENFORCE_WORKTREE_EXCLUDE`: unified path-coverage list. When ALL staged files are covered,
  the main-checkout and protected-branch gates in `pre-commit` are skipped (the private-info
  scanner still runs). An entry containing `*` matches file paths via glob (`**` = any path
  segments, `*` = any non-separator chars, case-insensitive on Windows); a plain path entry
  matches via path-boundary prefix (the target equals the entry or is under its subtree).
  Honored by both `enforce-worktree.js` (repo-granularity) and `pre-commit` (file-granularity).
  Example: `ENFORCE_WORKTREE_EXCLUDE=C:\git\**\todo.md;C:\git\repo-a`
  Built-in (non-overridable): `.worktree-backup/**` is always excluded so `/worktree-end` Step 5 can copy gitignored files to `.worktree-backup/` even when Bash CWD has reset to the main worktree.
  **gh command classification** — Bash write-detection uses `hooks/lib/bash-write-patterns.js`:
  - **Classified "write" (session-scope check applies)**: `gh pr merge`, `gh issue create/delete`,
    `gh repo delete`, `gh release create/edit/delete/upload`, `gh api` with
    POST/PUT/PATCH/DELETE in any flag form (`-X`, `-XVERB`, `-X=VERB`, `--method`,
    `--method=`), GitHub Contents API PUT (`repos/.../contents/...`), Git Data API
    POST/PATCH (`repos/.../git/{blobs,trees,commits,refs}`). Write commands verify that
    the detected repo root is in-scope (CWD repo + `ENFORCE_WORKTREE_ADDITIONAL_REPOS`).
    `gh issue create` is sanctioned only via the `/issue-create` skill — bare invocation
    from the main worktree is blocked (#672).
  - **Classified "read" (guard never fires)**: `gh pr create/edit/close/comment/review`,
    `gh issue edit/close/comment`, `gh repo create/edit/rename/archive` — metadata-only,
    never changes tracked repo content.
  **Dispatch provenance (#2064)** — write predicates re-parse command fragments (one segment,
  one newline-split line, one `$(…)` body) *after* quoted spans and heredoc bodies have been
  stripped, so a dispatcher call whose `--body "$(cat <<'EOF'` opener survives the strip as a
  bare, unterminated opener looked like a heredoc write. That false positive blocked
  repository-write-free `/issue-create` dispatches from the main worktree.
  `hooks/lib/bash-write-patterns/dispatch-provenance.js` supplies the lost context in two layers:
  layer 1 inspects the INTACT top-level IR and returns `{dispatchCleared:true}` only when some
  segment is a known dispatcher / gh Group-A invocation AND no segment — nor any command
  substitution nested inside it, to depth 4 — trips a narrow write predicate; layer 2 threads
  that verdict as a `ctx` argument into every fragment re-parse, where the truncated opener is
  then read as a stripping artifact rather than a write. The clearance is deliberately narrow:
  it sets aside the truncated-opener artifact only, so `… && rm -rf repo` or an `eval 'touch f'`
  hidden in the same command still classifies as a write. Fail-closed throughout — parse
  failure, an empty IR, or a lazy require that does not resolve yields `null` (no provenance,
  prior behavior kept). Threading a `ctx` also closed a pre-existing gap: `innerCommandIsWrite`
  now includes both `isExoticExecWriteIR` and `isNewlineInjectedWriteIR` in its OR-chain, so an
  `eval` / `xargs` / `find -exec` write — and a write on a later line of a quoted multi-line
  body such as `eval 'echo hi<NL>rm -rf docs'` — is detected where it previously escaped every
  per-segment predicate. An inner body IS a command string, so an unquoted newline separates
  commands there exactly as at top level; the recursion terminates on `isNewlineInjectedWriteIR`'s
  own `/[\r\n]/` and `lines.length < 2` guards.

  That symmetry needed one artifact accounted for. `stripHeredocBody` runs before the split, so a
  here-doc opener still standing on a split line has already had its body and delimiter taken away;
  cutting the fragment then strands that opener from its own `)` (`echo $(cat <<'EOF'` + `)`), and
  the lone opener reads as a here-doc write — an ordinary dispatcher body fail-closed back into a
  write. `isSplitArtifactHeredocLine` skips such a line, under three conditions that together keep
  every case where the here-doc is the payload rather than the artifact: the command must carry
  dispatch clearance, the opener must be a `cat` opener with a `\w+` quoted delimiter sitting at
  the very END of the line, and the line minus that opener must pass the FULL write predicate chain
  (`innerCommandIsWrite`). `classify()` alone is NOT sufficient there: it is WRITE_PATTERNS-only and
  reads `rm -rf docs;` and `git commit -m x` as `read`, so appending `; cat <<'X'` to such a payload
  inside a sanctioned dispatch substitution would have evaded detection entirely.

  The standing rule these repairs converged on, after three successive narrowings each opened a
  new fail-open (restricted split → opener stripping → a `classify()`-judged remainder): a
  condition that DEMOTES a write in this guard must be judged by the full write predicate chain
  (`innerCommandIsWrite`), never by a single classifier, and every narrowing must be measured
  against the counter-shape where the demoted token IS the payload before it lands. `classify()`
  is WRITE_PATTERNS-only — it does not see file-ops, git writes, or package-manager writes — so it
  is a widening signal (it never demotes) and must never be the sole gate on a demotion.

  Nothing is rewritten before judging, and that is deliberate. Erasing opener tokens in place —
  the shape this repair first took — also erases the write signal of `cat <<'X' | bash`, whose
  payload IS the here-doc; the trailing-position test is what separates the two. The other two
  conditions carry their own counter-example: `cat <<'EOF' >/tmp/pwn` and `rm -rf docs; cat <<'EOF'`
  are both still judged, and a delimiter outside `\w+` (`<<'END-MARK'`) stays fail-closed.

  The split itself stays INCLUSIVE of expanding frames. Suppressing it inside them instead — via
  `{ includeCmdSubstBody: false }` — is NOT safe: for an UNQUOTED expanding frame the IR keeps no
  substitution fragment behind, because a newline-crossing `$(` opener is not preserved as one
  token, so `isCommandSubstWriteIR` has nothing to recurse into and this raw split is the only
  detector that ever reaches a write injected into an unquoted substitution, a bare subshell, or a
  process substitution.

  Which token counts as the invoked script is part of the clearance boundary. `segmentDispatchKind`
  resolves it left to right and accepts a leading `-` token only when it is a known value-less shell
  option (`SHELL_BOOLEAN_OPTS`) or the `--` terminator; a value-taking or unknown option makes the
  segment unresolvable and no provenance is raised. Reading the script as "the first non-dash token"
  would let `bash --rcfile <dispatch-path> /tmp/evil.sh` present an attacker-chosen script as a
  sanctioned dispatch and inherit the clearance.
  `ENFORCE_WORKTREE_ADDITIONAL_REPOS`: semicolon-separated list of additional repo roots
  or parent directories treated as in-scope for gh write scope checks. If an entry
  is not itself a git repo, its immediate subdirectories are scanned (depth 1)
  and any git repos found are added. The CWD repo is always included.
  **Quote-span analysis (SSOT)** — every predicate that needs to know whether a character sits
  inside `'…'`, `"…"`, `$'…'`, `` `…` ``, `$(…)`, `(…)` or `$((…))` asks one scanner,
  `hooks/lib/quote-spans.js` (`quote-spans/{scan,query,transform}.js`). Before #1569 each
  consumer carried its own ad-hoc quote walker, so a quoting form fixed in one predicate stayed
  broken in its siblings (CPR-UNV). Consumers: `hooks/lib/{strip-quoted-args,bash-write-targets,
  command-ir}.js`, `hooks/enforce-worktree/arg-tail-guard.js`, and
  `main-worktree-allows/worker-script.js`. Ambiguity is never guessed
  at: unparseable nesting or nesting past the depth cap (`MAX_SPAN_DEPTH`) yields `ok:false`
  plus a fail reason, and every consumer maps `ok:false` to the write/block side. The transform
  boundaries return their input unchanged instead of throwing, so a pathological command cannot
  crash the hook into emitting no verdict at all (a crash would be fail-open).
  **`AGENTS_CONFIG_DIR` trust anchor** — predicates that recognize a sanctioned script by
  `<agents-config-dir>/<relative-path>` resolve that directory through
  `hooks/lib/agents-config-dir.js` rather than reading `process.env.AGENTS_CONFIG_DIR`. The env
  var is absent in subagent- and Bash-tool-spawned hook processes (which false-BLOCKed the
  sanctioned finalize-worker overlay, #1630) and attacker-supplied in the hostile case. The
  resolver falls through env → module anchor (`__dirname`) → realpath and accepts a candidate
  only when it carries both markers (`hooks/enforce-worktree.js` and `bin/`); a candidate
  matching one marker is ambiguous and rejected. `hooks/lib/load-env.js` deliberately does not
  share the fall-through — an explicit `AGENTS_CONFIG_DIR` must remain the sole source of
  settings, or an alternate config dir would silently be injected with the real repo's `.env`
  (CPR-SC). The two share only the candidate enumeration.
  **Worker-dispatch sanction (#1643, #1673)** — `main-worktree-allows/worker-dispatch-overlay.js`
  sanctions exactly one command shape from the main worktree:
  `node "<acd>/bin/worker-dispatch.js" <worker> <main-root> <payload-json>`. It deliberately
  does **not** call the quote-spans scanner: rather than parse arbitrary quoting, it accepts
  only two token shapes (a bare word free of quote characters, or a fully double-quoted word)
  and rejects everything else, so no env prefix, redirect, pipe, `&&`, or `$VAR` can ride
  along. Three locks must all hold: the script path's derived root equals the marker-validated
  `AGENTS_CONFIG_DIR`; the `<main-root>` argument equals the repo under judgement; and that
  same argument is one of `getSessionRepoRoots()`'s trusted main worktrees. The payload must
  live under the plans dir. Argument values are screened against the reject set exported by
  `hooks/enforce-worktree/arg-value-guard.js` (`UNSAFE_ARG_VALUE_RE`, `hasControlChar`,
  `isUnderPlansDir`, plus `ID_VALUE_RE` / `REPO_SLUG_VALUE_RE` / `isSimpleArgValue` /
  `stripRelSuffix`). That module is the sole owner of those helpers, and it is the VALUE-level
  sibling of the SHAPE-level `arg-tail-guard.js`: shape decides whether a token is one plain
  word, value decides whether that word is safe to hand onward. The overlay never reads
  the payload: field-level trust is `bin/worker-dispatch/` 's own job, and a field it refuses
  surfaces as `status: failed` on stdout, never as a silent drop. Worker names come from
  `hooks/lib/worker-dispatch-registry.js`; when that module cannot be loaded the overlay
  degrades to BLOCK instead of crashing the hook.
  Because the enum is read from the registry rather than restated in the overlay, this one
  guard covers all nine declared workers (`WORKER_NAMES`) with no per-worker code. Together
  with the registry's per-worker capability contracts (`payloadSpec`, `binaries`,
  `envPassthrough`, `writeScopes`) it is the **sole** guard layer for worker-dispatch write
  operations — there is no second, worker-specific overlay, by design (CPR-ORTH).
  **Retired: `finalize-worker-overlay.js` (#1600 → #1673)** — the finalize scripts
  (`run-initial.sh`, `run-loop-step.js`, `run-finalize-terminal.sh`) used to be invoked as a
  Bash-tool `eval` from the main worktree, and that one shape needed an overlay of its own to
  HARD-validate its env VALUES and argument positions. #1673 moved those scripts behind
  `bin/worker-dispatch.js`, where they run as child processes: the `eval` shape no longer
  exists, so the overlay guarding it was deleted rather than left as dead surface. Its shared
  value helpers moved unchanged to `arg-value-guard.js` (above); its `G5_DECISION_VALUES` enum
  became the `g5_decision` payload enum in the registry. Three `SANCTIONED` entries in
  `worker-script.js` retired with it (`bin/issue-close-gate.sh`,
  `bin/github-issues/issue-close-stage-triage.sh`, `bin/github-issues/parent-body-update.sh`):
  all three are reachable only as children of `run-stage-chain.sh` / `run-initial.sh`, and a
  PreToolUse hook that inspects the command head only never sees a child process, so the
  listing granted nothing.
  **Heredoc gate widening + self-reinforcing-loop fix (#2120/#2121)** —
  `stripHeredocBody` (`hooks/lib/strip-quoted-args.js`) widened past #371's `cat`-only,
  `\w+`-delimiter baseline: the sink set is now `cat|tee|sponge` (data sinks, not
  interpreters — `mail` was dropped as an outbound/info-leakage channel), the sink must
  own its own command segment (a negative lookbehind rejects `cat x; bash <<'EOF'` and
  `git cat-file -p HEAD <<EOF` stealing another command's heredoc), the delimiter accepts
  hyphens (`END-MARK`, not just `\w+`), and stripping is refused when the opener's own
  line pipes or chains onward (`tee out <<'EOF' | bash` feeds the body to an interpreter —
  caught by testing `restOfLine` for `[|&;]`). Separately, `hasCommandSequencing`
  (`hooks/enforce-worktree/shared-cmd-utils.js`) became heredoc-aware itself (it now
  parses `stripHeredocBody(cmd)` before checking for `;`/`&&`/`||`), so a heredoc-body-only
  operator (e.g. `cat <<'EOF' > plans-dir/file.md` containing `a;` in its body) no longer
  registers as real sequencing at all — over-broadening Guard 5 in
  `universal-target-allow.js` and the "Bug 2" branch in `handle-bash-write.js`, both of
  which previously routed such commands through the narrower plans-dir/claude-scratchpad
  gate (#1109) only when sequencing was detected. Fix: both guards now key on `hasHeredoc(cmd)`
  directly — a predicate that detects a heredoc opener independently of whether
  `stripHeredocBody` actually strips it, so the dangerous shapes `stripHeredocBody` refuses
  to touch still route to the narrow gate — restoring the pre-#2121 split for every heredoc
  command regardless of its sequencing shape. The now-redundant `hasCommandSequencingOutsideHeredoc`
  alias was removed. On the friction side (#2120's "block → retry same tool → block again"
  loop), `hooks/lib/alt-target-remedy.js` (`buildAltTargetRemedy()`) is a new shared remedy
  line appended to every `enforce-worktree.js` / `handle-edit-write.js` /
  `workflow-gate/worktree-entry-gate.js` block reason, naming the plans dir and the
  scratchpad as targets reachable right now via Write/Edit/MultiEdit — turning a bare stop
  into a redirect. `early-gate-messages.js`'s `READ_TOOLS_NOTE` also dropped `Bash` from its
  "remains available" list: Bash writes are themselves gated during the early-gate block, so
  the prior wording overstated what was actually open.
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
  source consumed by `subagent-start.js` (which injects `PLAN_LANG` only for the
  planner/reviewer agent whitelist). Fail-open: any error yields `{}`.
- `codegraph-context-inject.js` (UserPromptSubmit) — forwards the upstream CodeGraph prompt-hook's
  OUTPUT as `additionalContext`, without ever running `codegraph install` (which would rewrite
  `~/.claude/CLAUDE.md` and register the hook itself). Gated three ways before it spawns anything:
  `CODEGRAPH=on`, a `.codegraph/codegraph.db` found within six levels above the payload cwd, and a
  scope gate that refuses the home directory and any filesystem root — upstream's own exclusion,
  ported. Fail-open at every step: a missing flag, a failed spawn, a non-zero exit, empty output, or
  any throw all yield `{}` and exit 0, so a prompt is never blocked or delayed past the 5s timeout.
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

**Permission glob matching**: Permissions are matched against the entire command string.
`&&` does not split into subcommands. `Bash(git commit *)` does not match
`cd /path && git commit -m msg` (starts with `cd`). Deny rules use a leading `*`
(e.g., `*git commit --amend*`) to catch compound commands. Only interactive approval
("Yes, don't ask again") splits subcommands and saves individual rules (separate mechanism).

**Generated allow rules for agents' own commands**: because a rule matches the whole command
string, one internal command issued two ways needs two rules, and hand maintenance cannot track
that. The fact "this command is an allow-target" therefore has exactly one owner and the rule
strings are generated from it.

- Dataflow: `install/settings-allow-commands.txt` (the SSOT — command paths only) → `install/gen-settings-allow.js` (the CLI) → `install/lib/settings-allow-rules.js` (expansion) → merged over the repository's `settings.json` by `install/lib/settings-assembly.js` → the deployed file. Never hand-edit a generated rule.
- The expanded rules are injected into the deployed `~/.claude/settings.json` at deploy time; that deployed document is the only place an operator reads them back.
- They are therefore never committed: the tracked `settings.json` in this repo carries hand-written rules only, so a generated rule found there is a leftover from before this design, not a source.
- `install/lib/settings-allow-rules.js` owns the spelling template table — the one place it exists; the CLI, the assembler and the drift check all read it from there rather than restating it.
- Twenty-four path spellings are emitted per command, plus six bare spellings when `install/path-exposed-commands.txt` gives that command's basename a PATH shim — thirty rules for a PATH-exposed command. The interpreter comes from the command's own shebang, and anything but bash or node stops the generator.
- Each template is emitted as a pair: an argument-bearing form and an argument-less twin as well.
- The pair exists because the permission engine matches the whole command string, not a prefix — a trailing ` *` demands the space before it, so it never covers the argument-less invocation.
- `install/assemble-settings.js` is the sole deploy entry point and `install/lib/settings-deploy.js` its single writer, so any other code writing that file is a bug. The deploy is fail-closed: when the rules cannot be expanded, nothing is written and the previous deployment stands.
- Admitted: auto-issued, repo-state-invariant, idempotent internal tools. Excluded on principle: `gh` writes, git state changes, `.env` readers, platform-launched hook bodies, wrapper launchers such as `bin/run-with-timeout.sh` whose trailing ` *` template would allow-list every command reachable through them, and dispatchers that reach a state-changing or credential-reading operation through an argument or subcommand the permission engine never sees (e.g. a worker-dispatch script whose outer invocation is the only thing matched).
- Orphan detection is the known limit of the design: `--check` reports a generated-shaped rule whose command has left the SSOT, but the deploy appends only and never removes one, because removal is a manual judgment made by hand. A bare-form rule is only claimed when the generator emits bare rules for this tree at all, its name carries a separator and no command of that name is left under `bin/`, so a dropped command whose file still exists goes unreported.
- An allow rule only removes the permission prompt; it does not disarm a PreToolUse hook. `bin/review-code-codex` is allow-listed and still sends a diff outbound under `hooks/scan-outbound.js`.
- Nothing in the commit path guards these rules any more, and nothing needs to: a hand-maintained mirror is what could drift, and there is no longer one. `hooks/session-start.js` reports a deployed document that has fallen behind, and `hooks/post-merge` / `hooks/post-checkout` re-deploy when the SSOT, either list, or any of the four modules changes.
- `install/settings-allow-commands.txt` entries must be plain repo-relative paths — no `..`, leading slash, drive letter, backslash, glob, or shell metacharacter — because each entry is interpolated into twenty-four path permission rules, plus six more bare rules when `install/path-exposed-commands.txt` gives it a PATH shim, where a metacharacter widens a rule instead of naming a file. `install/gen-settings-allow.js` itself is deliberately absent from its own SSOT: it is run by hand, never auto-issued mid-session, so listing it would buy no coverage.

**Known limitations**:
- TL3 verification gap: `tests/feature-2119-settings-allow-ssot/` proves the generated rule
  strings match the template contract exactly, never that Claude Code's own permission matcher
  honors a given spelling live — that engine is the product's closed runtime, outside this repo's
  test reach. Confidence rests on the #2201 root-cause measurement (94.7% ask rate for
  `resolve-worktree-path` across 482 real transcripts, resolved once the missing quoted-absolute
  template was the one variable changed), not on an executable assertion. A human confirming a
  real quoted-absolute-path invocation stops prompting against a live deployed settings.json is
  the final check for any future template addition, not something CI can close out.
- PreToolUse hook on Edit|Write bypasses the "Ask before edits" dialog (hook success =
  permission granted). Delegate Edit|Write scanning to the pre-commit hook.
- Hook format must be nested. Flat format (matcher/command/timeout at the same level) causes
  the entire settings.json to be skipped.
- VSCode's "Ask before edits" mode covers Edit/Write only — Bash commands do not trigger
  the ask dialog.
- Hot-reloading of settings.json hook changes is unreliable. Restart Claude Code after changes.

## AWS Permission Posture

Claude Code operates with read-only AWS access during scan skills. Recommended IAM grants:
- `ec2:Describe*`, `s3:ListAllMyBuckets`, `s3:ListBucket`, `s3:GetBucketAcl`, `s3:GetBucketPolicyStatus`
- `iam:List*`, `iam:Get*` (not Create/Put/Attach/Delete)
- `ce:GetCostAndUsage`, `ce:GetCostForecast`
- `ecs:List*`, `ecs:Describe*`, `lambda:List*`, `lambda:Get*`
- `elasticloadbalancing:Describe*`, `apigateway:GET`, `apigatewayv2:GET`, `cloudfront:List*`, `cloudfront:Get*`
- `cloudtrail:Describe*`, `cloudtrail:Get*`, `guardduty:List*`, `guardduty:Get*`, `config:Describe*`, `securityhub:Describe*`
- Explicit deny: `*:Delete*`, `*:Remove*`, `*:Terminate*`, `*:Put*`

`settings.json` deny/ask rules are defense-in-depth. Server-side IAM is the authoritative layer.
IAM policy setup is tracked in `docs/todo.md`.
