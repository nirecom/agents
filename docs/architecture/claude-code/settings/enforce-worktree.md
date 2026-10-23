# enforce-worktree.js Details

Detail companion of the `enforce-worktree.js` entry in [hooks.md](hooks.md), which keeps the hook's core contract.

## Path coverage (`ENFORCE_WORKTREE_EXCLUDE`)

`ENFORCE_WORKTREE_EXCLUDE`: unified path-coverage list. When ALL staged files are covered,
the main-checkout and protected-branch gates in `pre-commit` are skipped (the private-info
scanner still runs). An entry containing `*` matches file paths via glob (`**` = any path
segments, `*` = any non-separator chars, case-insensitive on Windows); a plain path entry
matches via path-boundary prefix (the target equals the entry or is under its subtree).
Honored by both `enforce-worktree.js` (repo-granularity) and `pre-commit` (file-granularity).
Example: `ENFORCE_WORKTREE_EXCLUDE=C:\work\**\todo.md;C:\work\repo-a`
Built-in (non-overridable): `.worktree-backup/**` is always excluded so `/worktree-end` Step 5 can copy gitignored files to `.worktree-backup/` even when Bash CWD has reset to the main worktree.

## gh command classification

Bash write-detection uses `hooks/lib/bash-write-patterns.js`:
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

## Dispatch provenance (#2064)

Write predicates re-parse command fragments (one segment,
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

## Additional repos (`ENFORCE_WORKTREE_ADDITIONAL_REPOS`)

`ENFORCE_WORKTREE_ADDITIONAL_REPOS`: semicolon-separated list of additional repo roots
or parent directories treated as in-scope for gh write scope checks. If an entry
is not itself a git repo, its immediate subdirectories are scanned (depth 1)
and any git repos found are added. The CWD repo is always included.

## Quote-span analysis (SSOT)

Every predicate that needs to know whether a character sits
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

## `SCRIPT_CHECKOUT_ROOT` trust anchor

Predicates that recognize a sanctioned script by
`<script-checkout-root>/<relative-path>` resolve that directory through
`hooks/lib/script-checkout-root.js` rather than reading `process.env.AGENTS_MAIN_ROOT`. The env
var is absent in subagent- and Bash-tool-spawned hook processes (which false-BLOCKed the
sanctioned finalize-worker overlay, #1630) and attacker-supplied in the hostile case. The
resolver falls through module anchor (`__dirname`) → realpath, with no env candidate, and
accepts a candidate only when it carries both markers (`hooks/enforce-worktree.js` and `bin/`);
a candidate matching one marker is ambiguous and rejected. `hooks/lib/load-env.js` deliberately
does not share the fall-through — an explicit `AGENTS_MAIN_ROOT` must remain the sole source of
settings, or an alternate settings directory would silently be injected with the real repo's
`.env` (CPR-SC). The two share only the candidate enumeration.

## Worker-dispatch sanction (#1643, #1673)

`main-worktree-allows/worker-dispatch-overlay.js`
sanctions exactly one command shape from the main worktree:
`node "<script-checkout-root>/bin/worker-dispatch.js" <worker> <target-main-root> <payload-json>`. It deliberately
does **not** call the quote-spans scanner: rather than parse arbitrary quoting, it accepts
only two token shapes (a bare word free of quote characters, or a fully double-quoted word)
and rejects everything else, so no env prefix, redirect, pipe, `&&`, or `$VAR` can ride
along. Three locks must all hold: the script path's derived root equals the marker-validated
`SCRIPT_CHECKOUT_ROOT`; the `<target-main-root>` argument equals the repo under judgement; and that
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
test-runner also holds a control-outcome scope: per file, not per root, it lets only the
dispatcher create that dispatch's own `<stem>.outcome.json` once (#2544).

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

## Heredoc gate widening + self-reinforcing-loop fix (#2120/#2121)

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
