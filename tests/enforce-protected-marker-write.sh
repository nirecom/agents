#!/usr/bin/env bash
# tests/enforce-protected-marker-write.sh
# Tests: hooks/block-clearance-token-write.js, hooks/block-clearance-token-write/dispatch.js, hooks/block-clearance-token-write/bash-scan.js, hooks/block-clearance-token-write/nested-bodies.js, hooks/block-clearance-token-write/interpreter-scan.js, hooks/block-clearance-token-write/bash-target-context.js, hooks/block-clearance-token-write/bash-target-context/classify.js, hooks/lib/command-parser.js, hooks/lib/path-containment.js, hooks/lib/protected-basenames.js, hooks/lib/basename-glob-normalize.js, hooks/lib/basename-glob-normalize/brace-ansi-expand.js, hooks/enforce-worktree/bash-write-scope/marker-gate.js, hooks/lib/session-markers.js
# Tags: off-clearance, session-marker, protected-basename, glob, ads, pretooluse, block-write, classifier, security, redirect-operator, parse-failure, eval, command-substitution, here-string, heredoc, stdin-program, pipe, process-substitution, interpreter, interpreter-identity, argv-operand, flag-cluster, brace-expansion, ansi-c-quoting, workflow-dir, symlink, case-fold, fail-direction, on-unknown, path-containment, cwd-tracking, pushd, popd, dir-stack, command-wrapper, gh, ownership, forge-state, scope:common, pwsh-not-required, TL2, hook-registration
# TL3 gap (what this test does NOT catch):
# - The hook firing as a REAL PreToolUse hook inside a live claude -p session
#   (here it is a node subprocess fed synthetic stdin), i.e. that settings.json's
#   Edit|Write|MultiEdit|editFiles|Bash|runInTerminal|runCommands matcher actually
#   routes those tool calls to it. X6 asserts the registration STATICALLY only.
set -u

# - Real NTFS alternate-data-stream semantics and real shell glob expansion at
#   redirect time: the OS/shell behaviour is the premise, and only the hook's
#   treatment of the spelling is asserted here.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration.
AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# WHAT THIS FILE DEFENDS (#1780 security-scanner round 8: H-1..H-4, M-1, M-3)
# hooks/lib/session-markers.js authorizes purely on a marker file's EXISTENCE, so
# ONE forged `<sid>.workflow-off` (or any sibling kind) grants the session full
# clearance. The guard against that must be location-independent (H-1, Section L),
# glob-aware (H-3, Section G), ADS-aware (H-4, Section A), shape-complete
# (M-1, Section S) and .tmp-symmetric (M-3, Section X).
if command -v cygpath >/dev/null 2>&1; then _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"; else _AGENTS_DIR_NODE="$AGENTS_DIR"; fi

# Every block case is paired with its CPR-ORTH sanctioned counterpart: a guard that
# over-blocks ordinary work is a different, equally real defect (Section N).

# ASSERTION CONTRACT (same strictness as tests/enforce-off-clearance-write.sh):
# the hook ALWAYS exits 0 and ALWAYS prints a JSON decision. An allow is only an
# allow when the process exited 0 AND affirmatively said so; a crash, a timeout,
# empty stdout or unparseable stdout each get their own verdict token and can
# never be confused with "approve". See classify() below.

HOOK="$AGENTS_DIR/hooks/block-clearance-token-write.js"
RWT="$AGENTS_DIR/bin/run-with-timeout.sh"
PB_NODE="$_AGENTS_DIR_NODE/hooks/lib/protected-basenames.js"
MARKER_GATE_NODE="$_AGENTS_DIR_NODE/hooks/enforce-worktree/bash-write-scope/marker-gate.js"
SESSION_MARKERS_SRC="$AGENTS_DIR/hooks/lib/session-markers.js"
ZOMBIE_SRC="$AGENTS_DIR/hooks/workflow-state/state-io/zombie-cleanup.js"
SETTINGS="$AGENTS_DIR/settings.json"

PASS=0; FAIL=0; SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }
make_tmp() { mktemp -d 2>/dev/null || mktemp -d -t 'protmark'; }
node_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
cleanup_tmp() { [ -n "${1:-}" ] && [ -d "$1" ] && chmod -R u+w "$1" 2>/dev/null; [ -n "${1:-}" ] && rm -r -f "$1" 2>/dev/null; return 0; }

# --- stdin JSON builders (pure bash: no extra node process per case) ---------
json_esc() { local s="$1"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; printf '%s' "$s"; }
# mk_bash_input <command> <cwd>
mk_bash_input() {
    printf '{"tool_name":"Bash","session_id":"wsid","cwd":"%s","tool_input":{"command":"%s"}}' \
        "$(json_esc "$2")" "$(json_esc "$1")"
}
# mk_tool_input <tool_name> <cwd> <key> <path>   (key: file_path | path)
mk_tool_input() {
    printf '{"tool_name":"%s","session_id":"wsid","cwd":"%s","tool_input":{"%s":"%s"}}' \
        "$1" "$(json_esc "$2")" "$3" "$(json_esc "$4")"
}
# mk_edits_input <tool_name> <cwd> <key> <path>  (per-edit shape, M-1)
mk_edits_input() {
    printf '{"tool_name":"%s","session_id":"wsid","cwd":"%s","tool_input":{"file_path":"%s/unrelated.txt","edits":[{"old_string":"a","new_string":"b"},{"%s":"%s"}]}}' \
        "$1" "$(json_esc "$2")" "$(json_esc "$2")" "$3" "$(json_esc "$4")"
}

# run_hook_cwd <cwd> <workflow_dir_node> <stdin-json> -> "<rc>|<stdout, newlines stripped>"
# The CWD is a real process CWD, not just a payload field: H-1 is precisely the
# claim that the verdict does not depend on where the tool call originates.
# stderr is discarded on purpose — a crashing hook must be caught by rc/stdout.
run_hook_cwd() {
    local cwd="$1" tn="$2" input="$3" out rc
    [ -f "$HOOK" ] || { printf 'absent|'; return; }
    out=$(cd "$cwd" 2>/dev/null && CLAUDE_WORKFLOW_DIR="$tn" WORKFLOW_PLANS_DIR="$tn" \
        AGENTS_CONFIG_DIR="$_AGENTS_DIR_NODE" "$RWT" 15 node "$HOOK" <<< "$input" 2>/dev/null)
    rc=$?
    printf '%s|%s' "$rc" "$(printf '%s' "$out" | tr -d '\r\n')"
}

# classify "<rc>|<out>" -> approve | block | timeout | crash:<rc> | empty | unrecognized | hook-absent
classify() {
    local raw="$1" rc out
    rc="${raw%%|*}"; out="${raw#*|}"
    case "$rc" in
        absent) printf 'hook-absent'; return ;;
        124)    printf 'timeout'; return ;;
        0)      ;;
        *)      printf 'crash:%s' "$rc"; return ;;
    esac
    [ -z "$out" ] && { printf 'empty'; return; }
    case "$out" in
        *'"decision":"block"'*)   printf 'block'; return ;;
        *'"decision":"approve"'*) printf 'approve'; return ;;
    esac
    case "$out" in
        *'"permissionDecision":"allow"'*) printf 'approve'; return ;;
        *'"continue":true'*)              printf 'approve'; return ;;
    esac
    printf 'unrecognized'
}

# assert_verdict <label> <want> <raw "rc|out">
assert_verdict() {
    local label="$1" want="$2" raw="$3" got
    got="$(classify "$raw")"
    if [ "$got" = "$want" ]; then pass "$label -> $got"
    else fail "$label want=$want got=$got  [raw=$(printf '%.200s' "$raw")]"; fi
}
assert_block()   { assert_verdict "$1" block "$2"; }
assert_approve() { assert_verdict "$1" approve "$2"; }
assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then pass "$name"
    else fail "$name - want=$(printf '%q' "$want") got=$(printf '%q' "$got")"; fi
}

# H0 - harness self-check: without the hook every verdict below is "hook-absent"
# and the whole file proves nothing, so make the vacuous run loud.
if [ -f "$HOOK" ]; then pass "H0 hook file present"
else
    fail "H0 hook file MISSING at $HOOK - every case below would be vacuous"
    echo ""; echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"; exit 1
fi

# --- sandbox: a throwaway workflow dir + a throwaway session id -------------
# NOTHING here touches the real ~/.claude/projects/workflow. The hook is a pure
# classifier over the tool payload (it creates no files), but CLAUDE_WORKFLOW_DIR
# and WORKFLOW_PLANS_DIR are sandboxed anyway so that no future side effect can
# escape into real session state.
SANDBOX=$(make_tmp); WFDIR=$(node_path "$SANDBOX")
SID="protmarksid"
# stem realigned to effective sid — a stem must equal the active session-id to carry clearance (#2108)
# The block-expecting cases below name markers after $SID and `s1` while the stdin
# payload's session_id is `wsid`; registering those two as ordinary state files makes
# them OBSERVED session ids, so the cases keep testing cross-session protection
# rather than silently degrading into "unknown stem, therefore unprotected".
printf '{"session_id":"%s"}\n' "$SID" > "$SANDBOX/$SID.json"
printf '{"session_id":"s1"}\n' > "$SANDBOX/s1.json"
# Exported as a pair so the direct `node` probes below INHERIT them
# (rules/test/fixture-isolation.md). Without this the registrations above are
# invisible to those probes: they resolve the real workflow dir, `s1` is not an
# observed sid there, and every stem-dependent case degrades to "unprotected".
# classify() on line 77 still overrides both per-invocation for its own sandbox.
export CLAUDE_WORKFLOW_DIR="$WFDIR"
export WORKFLOW_PLANS_DIR="$WFDIR"

# --- SSOT introspection: the protected sets are DERIVED, never hardcoded ----
# A hardcoded copy here would silently stop covering a marker kind added later to
# hooks/lib/protected-basenames.js; Section X asserts the SSOT itself still agrees
# with hooks/lib/session-markers.js and zombie-cleanup.js.
# PROTECTED_STATE_KINDS, not SESSION_MARKER_KINDS: the latter omits the forge
# ownership kinds PR #2089 added, so the marker cases below were covering only part
# of what this hook actually protects (#2108).
MARKER_KINDS=$("$RWT" 10 node -e \
    "process.stdout.write(require(process.argv[1]).PROTECTED_STATE_KINDS.join(' '))" "$PB_NODE" 2>/dev/null)
TOKEN_SUFFIXES=$("$RWT" 10 node -e \
    "process.stdout.write(require(process.argv[1]).OFF_CLEARANCE_TOKEN_SUFFIXES.join(' '))" "$PB_NODE" 2>/dev/null)
if [ -z "$MARKER_KINDS" ] || [ -z "$TOKEN_SUFFIXES" ]; then
    fail "H1 protected-basename SSOT is introspectable (hooks/lib/protected-basenames.js exports)"
    echo ""; echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"; exit 1
fi
pass "H1 protected-basename SSOT introspected: kinds=[$MARKER_KINDS]"

# --- location fixture: a REAL linked worktree on a REAL feature branch ------
# Built hermetically in a temp dir (never the developer's repo) so the H-1
# condition holds wherever this suite runs. --no-verify + inline user.* keep the
# fixture independent of the ambient git config and of any repo hooks.
FIXTURE=""; MAIN_WT=""; LINKED_WT=""; NONREPO=""
if command -v git >/dev/null 2>&1; then
    FIXTURE=$(make_tmp)
    MAIN_WT="$FIXTURE/repo"; LINKED_WT="$FIXTURE/wt"; NONREPO="$FIXTURE/plain"
    mkdir -p "$MAIN_WT" "$NONREPO"
    git init -q "$MAIN_WT" >/dev/null 2>&1
    git -C "$MAIN_WT" symbolic-ref HEAD refs/heads/main >/dev/null 2>&1
    git -C "$MAIN_WT" -c user.email=test@example.com -c user.name=test -c commit.gpgsign=false \
        commit -q --allow-empty --no-verify -m init >/dev/null 2>&1
    git -C "$MAIN_WT" worktree add -q -b fix/protected-marker-probe "$LINKED_WT" >/dev/null 2>&1
fi

LOCATION_FIXTURE_OK=no
if [ -n "$LINKED_WT" ] && [ -d "$LINKED_WT" ]; then
    _gd=$(cd "$LINKED_WT" && git rev-parse --git-dir 2>/dev/null || true)
    _br=$(cd "$LINKED_WT" && git rev-parse --abbrev-ref HEAD 2>/dev/null || true)
    case "$_gd" in
        */worktrees/*) [ "$_br" = "fix/protected-marker-probe" ] && LOCATION_FIXTURE_OK=yes ;;
    esac
fi
if [ "$LOCATION_FIXTURE_OK" = "yes" ]; then
    pass "H2 location fixture: LINKED worktree on feature branch fix/protected-marker-probe"
else
    skip "H2 location fixture unavailable (git missing or worktree add failed) - Section L falls back to CWD=$AGENTS_DIR only"
    LINKED_WT="$AGENTS_DIR"; MAIN_WT="$AGENTS_DIR"; NONREPO="$SANDBOX"
fi

# ---- case parts (rules/coding/file-split.md: sibling <name>/ folder) -------
PARTS_DIR="$AGENTS_DIR/tests/enforce-protected-marker-write"
# shellcheck source=./enforce-protected-marker-write/cases-location.sh
. "$PARTS_DIR/cases-location.sh"
# shellcheck source=./enforce-protected-marker-write/cases-normalize.sh
. "$PARTS_DIR/cases-normalize.sh"
# shellcheck source=./enforce-protected-marker-write/cases-shapes.sh
. "$PARTS_DIR/cases-shapes.sh"
# shellcheck source=./enforce-protected-marker-write/cases-negative.sh
. "$PARTS_DIR/cases-negative.sh"
# shellcheck source=./enforce-protected-marker-write/cases-ssot.sh
. "$PARTS_DIR/cases-ssot.sh"
# shellcheck source=./enforce-protected-marker-write/cases-round5-scan.sh
. "$PARTS_DIR/cases-round5-scan.sh"
# shellcheck source=./enforce-protected-marker-write/cases-round5-containment.sh
. "$PARTS_DIR/cases-round5-containment.sh"
# shellcheck source=./enforce-protected-marker-write/cases-round6-stdin.sh
. "$PARTS_DIR/cases-round6-stdin.sh"
# shellcheck source=./enforce-protected-marker-write/cases-round6-identity.sh
. "$PARTS_DIR/cases-round6-identity.sh"
# shellcheck source=./enforce-protected-marker-write/cases-round7-proof.sh
. "$PARTS_DIR/cases-round7-proof.sh"
# shellcheck source=./enforce-protected-marker-write/cases-round8-operand.sh
. "$PARTS_DIR/cases-round8-operand.sh"
# shellcheck source=./enforce-protected-marker-write/cases-round9-flagcluster.sh
. "$PARTS_DIR/cases-round9-flagcluster.sh"
# shellcheck source=./enforce-protected-marker-write/cases-round9-brace-ansi.sh
. "$PARTS_DIR/cases-round9-brace-ansi.sh"
# shellcheck source=./enforce-protected-marker-write/cases-round9-globdir.sh
. "$PARTS_DIR/cases-round9-globdir.sh"
# cases-round10-brace-span.sh defines _r10_expand/_run_r10_table and must be sourced
# before the other round-10 parts, which use them.
# shellcheck source=./enforce-protected-marker-write/cases-round10-brace-span.sh
. "$PARTS_DIR/cases-round10-brace-span.sh"
# shellcheck source=./enforce-protected-marker-write/cases-round10-ansi-argv.sh
. "$PARTS_DIR/cases-round10-ansi-argv.sh"
# shellcheck source=./enforce-protected-marker-write/cases-round10-dynamic-target.sh
. "$PARTS_DIR/cases-round10-dynamic-target.sh"
# shellcheck source=./enforce-protected-marker-write/cases-round13-onunknown.sh
. "$PARTS_DIR/cases-round13-onunknown.sh"
# shellcheck source=./enforce-protected-marker-write/cases-round14-cwd-tracking.sh
. "$PARTS_DIR/cases-round14-cwd-tracking.sh"
# shellcheck source=./enforce-protected-marker-write/cases-forge-ownership-state.sh
. "$PARTS_DIR/cases-forge-ownership-state.sh"

run_L_marker_matrix        # H-1: every kind x {bare,.tmp} x {Edit,Write,MultiEdit,Bash}
run_L_location_invariance  # H-1: identical verdict from linked / main / non-repo CWD
run_L_token_suffixes       # CPR-ORTH: the token side of the same matrix
run_G_glob                 # H-3
run_A_ads                  # H-4
run_S_input_shapes         # M-1
run_R_redirect             # unresolvable-but-literal redirect targets
run_N_false_positive       # CPR-ORTH sanctioned counterparts
run_X_ssot                 # M-3 + cross-file drift detection
run_R5_shell_syntax        # round-5 R5-1..R5-4: redirect ops, parse failure, eval, substitution
run_R5_nested_bodies       # round-5 R5-5/R5-6: here-strings, body-first interpreters
run_R5_readonly_allowlist  # round-5 R5-7: `less -o` is a WRITE
run_R5_containment         # round-5 codex-HIGH: one containment SSOT, two call sites
run_R5_marker_gate         # round-5 MED-7: bashTargetsHitProtectedMarker token + malformed
run_R6_here_strings        # round-6: `<<<` into a LANGUAGE interpreter (the `-e` sibling's twin)
run_R6_heredocs            # round-6: `<<WORD` bodies, quoted delimiter, unterminated
run_R6_opaque_routes       # round-6: pipe / `<(..)` / `< FILE` - fail closed on mention
run_R6_identity            # round-6/7: interpreterKindOfWord() + proof-flag SSOT, route bucketing
run_R7_program_proof       # round-7: a flag VALUE / bare operand is not proof of an argv program
run_R7_flag_lookalikes     # round-7: -E / -p / -P / --print must not count as proof
run_R8_sibling_operand     # round-8 fix B: a protected path in a SIBLING OPERAND of an interpreter body
run_R8_operand_seams       # round-8 fix B: argv order / body count / bodyless interpreter seams
run_R8_deferral_survives   # round-8 fix B counterweight: RD3 + #1709 reads must stay allowed
run_R8_proof_kind_scope    # round-8 fix A: inline-program proof is scoped to the interpreter kind
run_R8_operand_unit        # round-8 unit: the deferring token IS an extracted body, the operand is not
run_R9_flag_cluster        # round-9 H-1: a `-c`-cluster flag on a NON-interpreter (tar -cf mints a marker)
run_R9_flag_cluster_controls  # round-9 H-1: which mechanism is responsible + over-block controls
run_R9_deferral_intact     # round-9 H-1 counterweight: the narrowed deferral must not be deleted
run_R9_flag_cluster_payloads  # round-9 H-1: same defect via runInTerminal / runCommands[1]
run_R9_brace_ansi          # round-9 H-2: brace expansion + ANSI-C quoting CREATE the protected basename
run_R9_brace_ansi_boundary # round-9 H-2: the pre-existing glob verdict and the named over-block
run_R9_brace_ansi_unit     # round-9 H-2 unit: the enumeration IS bash's, and the cap fails closed
run_R9_workflow_dir_glob   # round-9 M-1: `$HOME` / `${HOME}` / `~` / `$VAR` spellings of the workflow dir
run_R10_brace_span         # round-10 H-1: a brace group that spans the path separator
run_R10_brace_span_controls   # round-10 H-1: the over-block boundary of that enumeration
run_R10_ansi_argv_parity   # round-10 H-2: argv form and redirect form must reach ONE verdict
run_R10_ansi_argv_commands # round-10 H-2: escape-bearing argv on write commands with no redirect sibling
run_R10_dynamic_target     # round-10 M-1: a target assembled by command substitution
run_R10_dynamic_target_controls  # round-10 M-1: the everyday dynamic targets that must stay allowed
run_R10_ansi_narrowing     # round-10 M-1: the ANSI-C follow-on narrowing, both sides
run_R10_accepted_overblock # round-10 M-1: reads that now fail closed, pinned as intentional
run_R10_overblock_boundary # round-10 M-1: the #1709 reads that must keep working
run_R13_onunknown_direction   # round-13 scanner C: resolvesUnder's DETECTION fail direction
run_R14_cwd_forward        # round-14: every spelling of "change directory" moves the tracked cwd
run_R14_cwd_inverse        # round-14: popd / `cd -` are real INVERSES, not one-way moves
run_R14_cwd_wrapper        # round-14: `command cd` / `builtin cd` are unwrapped one level
run_R14_cwd_nonmoves       # round-14 CPR-ORTH: `pushd -n` / `pushd +N` must NOT move the tracked cwd
run_R14_cwd_unknown_origin # round-14 CPR-UNV: origin unknown => pop fails CLOSED, bounded to the pop path
run_O_forge_ownership_state # 2053: the three gh-ownership state files join the protected set
run_O8_forge_state_side_effects # 2053 round-2 C5: Pattern 1 — the write is prevented, not just judged

cleanup_tmp "$SANDBOX"
if [ -n "$FIXTURE" ] && [ -d "$FIXTURE" ]; then
    git -C "$MAIN_WT" worktree remove --force "$LINKED_WT" >/dev/null 2>&1 || true
    cleanup_tmp "$FIXTURE"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
