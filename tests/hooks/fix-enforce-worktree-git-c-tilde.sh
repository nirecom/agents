#!/usr/bin/env bash
# tests/hooks/fix-enforce-worktree-git-c-tilde.sh
# Tests: hooks/enforce-worktree.js, hooks/enforce-worktree/git-repo-detection.js
# Tags: TL1, hook, enforce, worktree, git-c, tilde, scope:common
# #1563 (via #2393): resolveScopeValue treats a `~`-prefixed -C value as
# AMBIGUOUS, falls back to the CWD repo (main) and BLOCKs a write aimed at an
# external repo under $HOME. E1 is RED until `~` is statically expanded; `$VAR`
# and relative paths must stay AMBIGUOUS (E3/E4), and a `~` that expands INTO
# the session repo must still BLOCK (E5). #2649 G/C-rows pin the narrowed-roots write verdict
# for `git -C` (E2/G1/G5/C1c/C2 RED until the fix); H-rows repeat them per command tool.

set -euo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
# shellcheck source=tests/lib/ew-runner.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/ew-runner.sh"

T="$(make_tmp)"
trap 'rm -rf "$T"' EXIT
harness_isolate "$T/iso"

# os.homedir() reads USERPROFILE on Windows and HOME on POSIX — pin both.
FAKE_HOME="$(np "$T/home")"
MAIN="$FAKE_HOME/main"
EXT_STATE="$FAKE_HOME/.claude/projects"
EXT_ABS="$(np "$T/ext-abs")"
ew_make_repo "$MAIN"
ew_make_repo "$EXT_STATE"
ew_make_repo "$EXT_ABS"
mkdir -p "$EXT_STATE/plans"
EW_CFG_ROOT="$MAIN"

run() { ew_run "$MAIN" "$(ew_bash_payload test "$1")" "HOME=$FAKE_HOME" "USERPROFILE=$FAKE_HOME"; }

case_begin "git-c-tilde-expansion" "hooks/enforce-worktree/git-repo-detection.js"
ew_expect allow "E1. main CWD: git -C ~/.claude/projects rm plans/*.json → ALLOW (external repo)" \
    "$(run 'git -C ~/.claude/projects rm plans/*.json')"
ew_expect allow "E1b. main CWD: git -C ~/.claude/projects commit -m x → ALLOW (external repo)" \
    "$(run 'git -C ~/.claude/projects commit -m x')"
ew_expect block "E5. main CWD: git -C ~/main commit -m x → BLOCK (tilde expands into session repo)" \
    "$(run 'git -C ~/main commit -m x')"
case_end

case_begin "git-c-scope-boundaries" "hooks/enforce-worktree.js"
# #2649 policy (A): the write verdict of a `git -C <path>` git write is judged
# against narrowed roots (cwd + ADDITIONAL_REPOS), never against the payload-
# derived -C path itself. E2 is RED until then: the absolute -C joins
# getSessionRepoRoots() and is judged as a session main checkout (same failure
# as main-enforce-worktree-guard.sh "Bug 2: Bash git -C non-session commit").
ew_expect allow "E2. main CWD: git -C <abs-external> commit -m x → ALLOW (external repo; RED until narrowed roots)" \
    "$(run "git -C \"$EXT_ABS\" commit -m x")"
ew_expect block "E3. main CWD: git -C \$HOME/.claude/projects commit → BLOCK (env var stays AMBIGUOUS)" \
    "$(run 'git -C $HOME/.claude/projects commit -m x')"
ew_expect block "E4. main CWD: git -C ./relative commit → BLOCK (relative stays AMBIGUOUS)" \
    "$(run 'git -C ./relative commit -m x')"
case_end

# --- #2649 E2 regression rows: only an explicit `git -C` write to a repo that
# shares no common dir with any narrowed root may turn allow. Every other row
# pins the verdict measured before the fix (it must not move).
WT="$FAKE_HOME/wt"
WT3="$(np "$T/wt-sib")"
WT_BROKEN="$(np "$T/wt-broken")"
ADD="$(np "$T/add-repo")"
PLAIN="$(np "$T/plain")"
git -C "$MAIN" worktree add -q -b feature/x "$WT"
git -C "$MAIN" worktree add -q -b feature/z "$WT3"
git -C "$MAIN" worktree add -q -b feature/y "$WT_BROKEN"
# Delete the metadata so `git rev-parse --git-common-dir` fails in WT_BROKEN.
rm -rf "$MAIN/.git/worktrees/wt-broken"
ew_make_repo "$ADD"
mkdir -p "$PLAIN"
run_in() { local cwd="$1" cmd="$2"; shift 2; ew_run "$cwd" "$(ew_bash_payload test "$cmd")" "HOME=$FAKE_HOME" "USERPROFILE=$FAKE_HOME" "$@"; }

case_begin "git-c-narrowed-roots-external" "hooks/enforce-worktree/handle-bash-write.js"
ew_expect allow "G1. worktree CWD: git -C <abs-external> commit → ALLOW (external repo; RED until narrowed roots)" \
    "$(run_in "$WT" "git -C \"$EXT_ABS\" commit -m x")"
ew_expect allow "G2. worktree CWD: git -C ~/.claude/projects commit → ALLOW (tilde form of an external repo)" \
    "$(run_in "$WT" 'git -C ~/.claude/projects commit -m x')"
ew_expect allow "G3. main CWD: git -C <abs-external> status → ALLOW (read, unchanged)" \
    "$(run_in "$MAIN" "git -C \"$EXT_ABS\" status")"
case_end

case_begin "git-c-narrowed-roots-session-repo" "hooks/enforce-worktree/handle-bash-write.js"
ew_expect block "G4. worktree CWD: git -C <session main checkout> commit → BLOCK (shared common dir)" \
    "$(run_in "$WT" "git -C \"$MAIN\" commit -m x")"
ew_expect block "G5. worktree CWD: git -C ~/main commit → BLOCK (tilde form of the session main checkout)" \
    "$(run_in "$WT" 'git -C ~/main commit -m x')"
ew_expect block "G6. main CWD: git -C <session main checkout> commit → BLOCK" \
    "$(run_in "$MAIN" "git -C \"$MAIN\" commit -m x")"
# A linked worktree on a feature branch is a sanctioned write target; the
# measured pre-fix verdict is allow and the fix must not change it.
ew_expect allow "G7. main CWD: git -C <linked feature worktree> commit → ALLOW (pre-fix verdict pinned)" \
    "$(run_in "$MAIN" "git -C \"$WT\" commit -m x")"
ew_expect allow "G8. worktree CWD: git -C <sibling feature worktree> commit → ALLOW (pre-fix verdict pinned)" \
    "$(run_in "$WT" "git -C \"$WT3\" commit -m x")"
ew_expect allow "G9. worktree CWD: git -C <cwd>/. commit → ALLOW (inside cwd, unchanged)" \
    "$(run_in "$WT" "git -C \"$WT/.\" commit -m x")"
ew_expect block "G10. main CWD: git -C <ADDITIONAL_REPOS main checkout> commit → BLOCK (unchanged)" \
    "$(run_in "$MAIN" "git -C \"$ADD\" commit -m x" "ENFORCE_WORKTREE_ADDITIONAL_REPOS=$ADD")"
ew_expect block "G11. worktree CWD: git -C <ADDITIONAL_REPOS main checkout> commit → BLOCK (unchanged)" \
    "$(run_in "$WT" "git -C \"$ADD\" commit -m x" "ENFORCE_WORKTREE_ADDITIONAL_REPOS=$ADD")"
case_end

case_begin "git-c-narrowed-roots-cd-path" "hooks/enforce-worktree.js"
# cd-derived paths stay on the getSessionRepoRoots() path; verdicts must not move.
ew_expect block "G12. main CWD: cd <abs-external> && git commit → BLOCK (cd path unchanged)" \
    "$(run_in "$MAIN" "cd \"$EXT_ABS\" && git commit -m x")"
ew_expect block "G13. main CWD: cd <abs-external> && echo > f → BLOCK (cd path unchanged)" \
    "$(run_in "$MAIN" "cd \"$EXT_ABS\" && echo x > f.txt")"
ew_expect allow "G14. main CWD: cd <linked worktree> && git commit → ALLOW (cd path unchanged)" \
    "$(run_in "$MAIN" "cd \"$WT\" && git commit -m x")"
ew_expect allow "G15. main CWD: cd <linked worktree> && echo > f → ALLOW (cd path unchanged)" \
    "$(run_in "$MAIN" "cd \"$WT\" && echo x > f.txt")"
ew_expect block "G16. worktree CWD: cd <session main checkout> && git commit → BLOCK (cd path unchanged)" \
    "$(run_in "$WT" "cd \"$MAIN\" && git commit -m x")"
ew_expect block "G17. worktree CWD: cd <session main checkout> && echo > f → BLOCK (cd path unchanged)" \
    "$(run_in "$WT" "cd \"$MAIN\" && echo x > f.txt")"
ew_expect block "G18. worktree CWD: cd <abs-external> && git commit → BLOCK (cd path unchanged)" \
    "$(run_in "$WT" "cd \"$EXT_ABS\" && git commit -m x")"
case_end

case_begin "git-c-narrowed-roots-fail-closed" "hooks/enforce-worktree/handle-bash-write.js"
# An unresolvable common dir is never "a different repo": no new allow.
for _cwd_tag in main wt; do
    if [ "$_cwd_tag" = main ]; then _cwd="$MAIN"; else _cwd="$WT"; fi
    ew_expect block "G19-$_cwd_tag. git -C <nonexistent> commit → BLOCK (fail-closed)" \
        "$(run_in "$_cwd" "git -C \"$T/nope\" commit -m x")"
    ew_expect block "G20-$_cwd_tag. git -C <non-git dir> commit → BLOCK (fail-closed)" \
        "$(run_in "$_cwd" "git -C \"$PLAIN\" commit -m x")"
    ew_expect block "G21-$_cwd_tag. git -C <worktree with unresolvable common dir> commit → BLOCK (fail-closed)" \
        "$(run_in "$_cwd" "git -C \"$WT_BROKEN\" commit -m x")"
done
ew_expect block "G22. main CWD: plain git commit → BLOCK (unchanged)" "$(run_in "$MAIN" "git commit -m x")"
ew_expect allow "G23. worktree CWD: plain git commit → ALLOW (unchanged)" "$(run_in "$WT" "git commit -m x")"
case_end

# --- #2649 review C1/C2 (all from worktree CWD): one command chaining two `git -C` writes
# blocks when EITHER segment targets the session main checkout, in both orders; two external
# repos stay allowed like G1. AMBIGUOUS -C ($VAR / relative) blocks here as it does from main.
# Columns: id | command (@EXT@ @EXT2@ @MAIN@ @WT@ expanded per row; `$HOME` stays literal) | want | note
EXT2="$(np "$T/ext-abs-2")"
ew_make_repo "$EXT2"
# C3f: an external repo whose own config moves its work tree onto the session main checkout.
EXTCW="$(np "$T/ext-core-worktree")"
ew_make_repo "$EXTCW"
git -C "$EXTCW" config core.worktree "$MAIN"
# C1f/C1g: a linked worktree on a protected branch (init.defaultBranch is a protected source).
WTP="$(np "$T/wt-protected")"
git -C "$MAIN" worktree add -q -b prot "$WTP"
git -C "$MAIN" config init.defaultBranch prot
# C4a/C4b: a repo nested inside the session main checkout (submodule shape: own common dir,
# files inside the checkout) vs. one nested inside an external repo.
NESTM="$(np "$MAIN/nested-repo")"
ew_make_repo "$NESTM"
NESTE="$(np "$EXT2/nested-repo")"
ew_make_repo "$NESTE"
CHAIN_ROWS='C1a|git -C "@EXT@" commit -m x && git -C "@MAIN@" commit -m x|block|<abs-external> then <session main checkout> → BLOCK
C1b|git -C "@MAIN@" commit -m x && git -C "@EXT@" commit -m x|block|<session main checkout> then <abs-external> → BLOCK
C1c|git -C "@EXT@" commit -m x && git -C "@EXT2@" commit -m x|allow|two external repos → ALLOW (RED until narrowed roots)
C1d|git -C "@WT@" commit -m x && git -C "@MAIN@" commit -m x|block|<linked worktree> then <session main checkout> → BLOCK (sanctioned first write does not clear the second)
C1e|git -C "@MAIN@" commit -m x && git -C "@WT@" commit -m x|block|<session main checkout> then <linked worktree> → BLOCK
C2-E3|git -C $HOME/.claude/projects commit -m x|block|git -C $HOME/.claude/projects commit → BLOCK (AMBIGUOUS; RED until fail-closed)
C2-E4|git -C ./relative commit -m x|block|git -C ./relative commit → BLOCK (AMBIGUOUS; RED until fail-closed)
C3a|GIT_WORK_TREE="@MAIN@" git -C "@EXT@" reset --hard|block|inline GIT_WORK_TREE=<session main checkout> on an external -C → BLOCK (override wins over -C)
C3b|GIT_DIR="@MAIN@/.git" git -C "@EXT@" commit -m x|block|inline GIT_DIR=<session main .git> on an external -C → BLOCK
C3c|env GIT_INDEX_FILE="@MAIN@/.git/index" git -C "@EXT@" commit -m x|block|env GIT_INDEX_FILE=<session main index> on an external -C → BLOCK
C3d|export GIT_WORK_TREE="@MAIN@" && git -C "@EXT@" reset --hard|block|export GIT_WORK_TREE in an earlier segment → BLOCK
C3e|git -C "@EXT@" -c core.worktree="@MAIN@" reset --hard|block|-c core.worktree=<session main checkout> on an external -C → BLOCK
C3f|git -C "@EXTCW@" reset --hard|block|external repo whose config core.worktree is the session main checkout → BLOCK
C1f|git -C "@WT@" commit -m x && git -C "@WTP@" commit -m x|block|<feature worktree> then <protected-branch linked worktree> → BLOCK (first verdict does not clear the second)
C1g|git -C "@WTP@" commit -m x && git -C "@WT@" commit -m x|block|<protected-branch linked worktree> then <feature worktree> → BLOCK
C4a|git -C "@NESTM@" reset --hard|block|repo nested inside the session main checkout → BLOCK (own common dir is not "external")
C4b|git -C "@NESTE@" commit -m x|allow|repo nested inside an external repo → ALLOW
C5a|git -C "@EXT@" config --file "@MAIN@/.git/config" core.bare true|block|external -C with config --file <session main .git/config> → BLOCK (explicit destination)
C5b|git -C "@EXT@" clone "@EXT2@" "@MAIN@/cloned"|block|external -C with clone into the session main checkout → BLOCK
C5c|git -C "@EXT@" push "@MAIN@" HEAD:refs/heads/main|block|external -C with push to the session main checkout path → BLOCK'
c_expand() { local s="$1"; s="${s//@NESTM@/$NESTM}"; s="${s//@NESTE@/$NESTE}"; s="${s//@EXT2@/$EXT2}"; s="${s//@EXTCW@/$EXTCW}"; s="${s//@EXT@/$EXT_ABS}"; s="${s//@WTP@/$WTP}"; s="${s//@WT@/$WT}"; printf '%s' "${s//@MAIN@/$MAIN}"; }

case_begin "git-c-narrowed-roots-chain-and-ambiguous" "hooks/enforce-worktree/handle-bash-write.js"
while IFS='|' read -r -u 3 _id _cmd _want _note; do
    [[ -z "$_id" ]] && continue
    ew_expect "$_want" "$_id. worktree CWD: $_note" "$(run_in "$WT" "$(c_expand "$_cmd")")"
done 3<<<"$CHAIN_ROWS"
case_end

# --- #2649 review round 5: redirection the command text does not show.
# C6a: GIT_INDEX_FILE inherited by the hook process (not a command token).
# C6b: an external repo whose work tree encloses a session worktree (submodule recursion reach).
EXT3="$(np "$T/ext-enclosing")"
ew_make_repo "$EXT3"
git -C "$MAIN" worktree add -q -b enclosed "$EXT3/inner-wt"
case_begin "git-c-hidden-redirection" "hooks/enforce-worktree/git-c-write-scope.js"
ew_expect block "C6a. worktree CWD: inherited GIT_INDEX_FILE=<session main index> on an external -C → BLOCK" \
    "$(run_in "$WT" "git -C \"$EXT_ABS\" commit -m x" "GIT_INDEX_FILE=$MAIN/.git/index")"
ew_expect allow "C6a-ctl. worktree CWD: inherited benign GIT_TERMINAL_PROMPT on an external -C → ALLOW" \
    "$(run_in "$WT" "git -C \"$EXT_ABS\" commit -m x" "GIT_TERMINAL_PROMPT=0")"
ew_expect block "C6b. worktree CWD: external repo enclosing a session worktree → BLOCK" \
    "$(run_in "$WT" "git -C \"$EXT3\" reset --hard --recurse-submodules")"
# C6c: the shell expands `~` with $HOME, the hook with os.homedir() (USERPROFILE on Windows).
HOME_MSYS="$(cygpath -u "$FAKE_HOME" 2>/dev/null || printf '%s' "$FAKE_HOME")"
ew_expect block "C6c. worktree CWD: git -C ~/... while HOME differs from the hook's home dir → BLOCK" \
    "$(run_in "$WT" 'git -C ~/.claude/projects commit -m x' "HOME=$MAIN")"
ew_expect block "C6c-empty. worktree CWD: git -C ~/... with an empty HOME (bash expands ~ to \"\") → BLOCK" \
    "$(run_in "$WT" 'git -C ~/.claude/projects commit -m x' "HOME=")"
ew_expect allow "C6c-ctl.worktree CWD: git -C ~/... with HOME in MSYS spelling of the same dir → ALLOW" \
    "$(run_in "$WT" 'git -C ~/.claude/projects commit -m x' "HOME=$HOME_MSYS")"
case_end

# --- Command-class parity (#2649 review C4): enforce-worktree.js routes every isCommandTool name
# (Bash, runInTerminal, runCommands) to the shared handleBashWrite, so each verdict must equal
# Bash's. Payload shape follows enforce-worktree-off-clearance-state-matrix.sh; runCommands
# carries a one-element `commands` ARRAY (no `.command`), so a reader of only `.command` fails.
# No read-only decoy elements: the array is joined with "\n", and a multi-line command moves the
# verdict for Bash too (pre-existing, outside #2649) — decoys would test that defect, not parity.
cmd_tool_payload() { # <tool> <command>
    node -e '
      const [tool, cmd] = process.argv.slice(1);
      const ti = tool === "runCommands" ? { commands: [cmd] } : { command: cmd };
      process.stdout.write(JSON.stringify({ session_id: "test", tool_name: tool, tool_input: ti }));
    ' "$1" "$2"
}
run_tool() { # <tool> <cwd> <command>
    ew_run "$2" "$(cmd_tool_payload "$1" "$3")" "HOME=$FAKE_HOME" "USERPROFILE=$FAKE_HOME"
}

for _tool in runInTerminal runCommands; do
    case_begin "git-c-narrowed-roots-$_tool" "hooks/enforce-worktree/handle-bash-write.js"
    ew_expect allow "H1-$_tool. main CWD: git -C <abs-external> commit → ALLOW (external repo; RED until narrowed roots)" \
        "$(run_tool "$_tool" "$MAIN" "git -C \"$EXT_ABS\" commit -m x")"
    ew_expect block "H2-$_tool. worktree CWD: git -C <session main checkout> commit → BLOCK" \
        "$(run_tool "$_tool" "$WT" "git -C \"$MAIN\" commit -m x")"
    ew_expect block "H3-$_tool. main CWD: git -C <nonexistent> commit → BLOCK (fail-closed)" \
        "$(run_tool "$_tool" "$MAIN" "git -C \"$T/nope\" commit -m x")"
    ew_expect block "H3b-$_tool. worktree CWD: git -C <worktree with unresolvable common dir> commit → BLOCK (fail-closed)" \
        "$(run_tool "$_tool" "$WT" "git -C \"$WT_BROKEN\" commit -m x")"
    ew_expect block "H4-$_tool. main CWD: cd <abs-external> && git commit → BLOCK (cd path unchanged)" \
        "$(run_tool "$_tool" "$MAIN" "cd \"$EXT_ABS\" && git commit -m x")"
    ew_expect allow "H4b-$_tool. main CWD: cd <linked worktree> && git commit → ALLOW (cd path unchanged)" \
        "$(run_tool "$_tool" "$MAIN" "cd \"$WT\" && git commit -m x")"
    while IFS='|' read -r -u 3 _id _cmd _want _note; do
        [[ "$_id" == C1* ]] || continue
        ew_expect "$_want" "$_id-$_tool. worktree CWD: $_note" "$(run_tool "$_tool" "$WT" "$(c_expand "$_cmd")")"
    done 3<<<"$CHAIN_ROWS"
    case_end
done

echo ""
echo "Results: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[[ "$FAIL" -eq 0 ]]
