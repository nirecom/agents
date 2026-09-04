#!/usr/bin/env bash
# Tests: hooks/preuse-auto-approve/scratchpad-script.js, hooks/lib/claude-scratchpad-base.js
# Tags: capture-echo-guard, scratchpad-allow, symlink-traversal, security, protection-fix, scope:issue-specific, pwsh-not-required
# Section D-5 — symlink traversal (protection-fix patterns 1-4).
# The fix under test replaces lexical path containment with fs.realpathSync()-based
# containment. Each attack case first asserts the PRECONDITION that the lexical path
# is inside the allowed root (so a path.resolve-only implementation would ALLOW it),
# then asserts the predicate denies — Pattern 2: the case fails against unpatched code.
# Symlink creation is skipped PER CASE (not file-wide) when the platform denies it.

set -uo pipefail

# TL3 gap (what this test does NOT catch):
# - NTFS junctions, WSL bind mounts, and macOS firmlinks as the traversal vector
# - whether Claude Code actually prompts on the deny verdicts asserted here
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration.

AGENTS_DIR="${1:-$(cd "$(dirname "$0")/../.." && pwd)}"
export AGENTS_DIR
HERE="$(cd "$(dirname "$0")" && pwd)"
DRIVER="$HERE/scratchpad-driver.js"
command -v node >/dev/null 2>&1 || exit 77

PASS=0
FAIL=0
SKIP=0

assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then
        echo "PASS: $name"; PASS=$((PASS + 1))
    else
        echo "FAIL: $name — want=$(printf '%q' "$want") got=$(printf '%q' "$got")"; FAIL=$((FAIL + 1))
    fi
}

TMPROOT_RAW="$(mktemp -d)"
trap 'rm -rf "$TMPROOT_RAW"' EXIT
to_node_path() {
    if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi
}
TMPROOT="$(to_node_path "$TMPROOT_RAW")"

export TMPDIR="$TMPROOT" TEMP="$TMPROOT" TMP="$TMPROOT"
unset CLAUDE_CODE_SESSION_ID
export CLAUDE_WORKFLOW_DIR="$TMPROOT/workflow" WORKFLOW_PLANS_DIR="$TMPROOT/plans"
mkdir -p "$CLAUDE_WORKFLOW_DIR" "$WORKFLOW_PLANS_DIR"

BASE="$TMPROOT/claude"
SLUG="c--fixture-project"
SESS="2170aaaa-bbbb-cccc-dddd-eeeeffff0001"
SP="$BASE/$SLUG/$SESS/scratchpad"
EXT="$TMPROOT/external"
mkdir -p "$SP/sub" "$EXT"
# Execution markers, not content checks: an escape target whose CONTENT is unchanged
# proves nothing about execution (running it would not rewrite it either). Each escape
# target instead creates a sentinel as a SIDE EFFECT, so "marker absent" is direct
# evidence the judgment path never ran the script it was asked to judge.
# The sentinel is a DIRECTORY made with `mkdir -p`, which the body scan classifies safe.
# That is deliberate: every escape target's BODY is innocuous, so the only thing that can
# produce a deny below is the containment check under test, never the body scan.
MARK_EXT="$TMPROOT_RAW/executed-external"
MARK_ROOT="$TMPROOT_RAW/executed-outside-root"
printf 'echo pwned\nmkdir -p %s\n' "$MARK_EXT" >"$EXT/evil.sh"
printf 'echo hi\n' >"$SP/sub/real.sh"

marker_state() {
    if [ -e "$1" ]; then printf 'exists'; else printf 'absent'; fi
}

mk_link() {
    node "$HERE/mk-symlink.js" "$1" "$2" file
}

inv_path() { env -u CLAUDE_SESSION_ID SCRATCHPAD="$SP" node "$DRIVER" --invoke "$1" 2>&1; }
inv_sess() { env -u SCRATCHPAD CLAUDE_SESSION_ID="$SESS" node "$DRIVER" --invoke "$1" 2>&1; }
lexical()  { node "$DRIVER" --lexical-under "$SP" "$1" 2>&1; }
# --invoke-exec ACTS ON an allow verdict: $2 is really run. Every marker assertion below
# uses these, so "absent" means the predicate denied, not merely that nothing ever ran.
xinv_path() { env -u CLAUDE_SESSION_ID SCRATCHPAD="$SP" node "$DRIVER" --invoke-exec "$1" "$2" 2>&1; }
xinv_sess() { env -u SCRATCHPAD CLAUDE_SESSION_ID="$SESS" node "$DRIVER" --invoke-exec "$1" "$2" 2>&1; }

# --- SP-21: the executor itself works (control for every marker assertion) ----
# Without this row an "absent" marker could equally mean a broken driver. A genuinely
# in-root script, allowed and therefore run, must leave its own marker behind.
MARK_OK="$TMPROOT_RAW/executed-in-root"
printf 'mkdir -p %s\n' "$MARK_OK" >"$SP/sub/marker.sh"
assert_eq "SP-21a-allow-in-root-script" "allow" "$(xinv_path "bash $SP/sub/marker.sh" "$SP/sub/marker.sh")"
assert_eq "SP-21b-executor-really-runs-allowed-script" "exists" "$(marker_state "$MARK_OK")"

# --- SP-22: escaping symlink, SCRATCHPAD (path) branch ----------------------
LINK="$SP/evilink.sh"
if mk_link "$EXT/evil.sh" "$LINK"; then
    assert_eq "SP-22a-precondition-lexically-inside" "yes" "$(lexical "$LINK")"
    assert_eq "SP-22b-deny-escaping-symlink-path-branch" "deny" "$(xinv_path "bash $LINK" "$LINK")"
    # Pattern 1 negative assertion, made non-vacuous by --invoke-exec above: an allow
    # would have RUN the link, and evil.sh drops a sentinel when it runs. SP-21b proves
    # the executor does fire, so "absent" here can only mean the predicate denied.
    assert_eq "SP-22c-escape-target-not-executed" "absent" "$(marker_state "$MARK_EXT")"
else
    # SKIPPED: SP-22 (3 cases) when the platform refuses symlink creation.
    # Because: an unprivileged Windows host without Developer Mode cannot create one,
    # and a fabricated stand-in would not exercise realpathSync at all.
    # L3 gap: symlink traversal stays unverified on such hosts — covered on any host
    # with Developer Mode/admin, and on CI (Linux), where these cases do run.
    echo "SKIP: SP-22 — platform denied symlink creation (no Developer Mode / admin)"
    SKIP=$((SKIP + 3))
fi

# --- SP-23: same escape via the CLAUDE_SESSION_ID (session) branch -----------
# Pins the realpath fix on BOTH branches (CPR-ORTH), not just the path branch.
LINK2="$SP/evilink2.sh"
if mk_link "$EXT/evil.sh" "$LINK2"; then
    assert_eq "SP-23a-precondition-lexically-inside" "yes" "$(lexical "$LINK2")"
    assert_eq "SP-23b-deny-escaping-symlink-session-branch" "deny" "$(xinv_sess "bash $LINK2" "$LINK2")"
    # Same Pattern 1 negative on the session branch (CPR-ORTH), also executing: the deny
    # verdict must not have been reached by running the target.
    assert_eq "SP-23c-escape-target-not-executed" "absent" "$(marker_state "$MARK_EXT")"
else
    # SKIPPED: SP-23 (3 cases) — same platform condition as SP-22.
    # Because: symlink creation is refused, so the session branch cannot be exercised.
    # L3 gap: identical to SP-22 — closed on Developer-Mode hosts and on CI.
    echo "SKIP: SP-23 — platform denied symlink creation"
    SKIP=$((SKIP + 3))
fi

# --- SP-24: broken/dangling symlink -> realpathSync throws -> fail-to-ask ----
LINK3="$SP/broken.sh"
if mk_link "$TMPROOT/nowhere/absent.sh" "$LINK3"; then
    # Must be exactly "deny": "ERROR:..." would mean the exception escaped the
    # predicate, and "allow" would mean a silent fallback to the lexical path.
    assert_eq "SP-24a-deny-dangling-symlink" "deny" "$(inv_path "bash $LINK3")"
    assert_eq "SP-24b-deny-dangling-symlink-session-branch" "deny" "$(inv_sess "bash $LINK3")"
else
    # SKIPPED: SP-24 (2 cases) — same platform condition as SP-22.
    # Because: a dangling link is the only way to make realpathSync throw here.
    # L3 gap: the fail-to-ask path on a realpath exception is unverified on such hosts.
    echo "SKIP: SP-24 — platform denied symlink creation"
    SKIP=$((SKIP + 2))
fi

# --- SP-25: in-root symlink must NOT be over-rejected (Pattern 4) -----------
LINK4="$SP/good.sh"
if mk_link "$SP/sub/real.sh" "$LINK4"; then
    assert_eq "SP-25a-allow-in-root-symlink-path-branch" "allow" "$(inv_path "bash $LINK4")"
    assert_eq "SP-25b-allow-in-root-symlink-session-branch" "allow" "$(inv_sess "bash $LINK4")"
else
    # SKIPPED: SP-25 (2 cases) — same platform condition as SP-22.
    # Because: this is the over-blocking control and needs a real in-root link.
    # L3 gap: on such hosts nothing here would catch a fix that denied ALL links; the
    # non-symlink allow path is still covered by SP-21a and SP-26c.
    echo "SKIP: SP-25 — platform denied symlink creation"
    SKIP=$((SKIP + 2))
fi

# --- SP-26: the ROOT itself is a symlink escaping the claude base ------------
# SP-22..SP-25 move the SCRIPT through a link while the root stays real. Here the root
# is the link. A lexical-only validation of SCRATCHPAD would let a link that merely looks
# like .../<slug>/<uuid>/scratchpad pass, and the later realpath would then relocate the
# whole containment window onto the external directory — script and root would agree and
# the invocation would auto-approve with no prompt. getCurrentSessionScratchpadRootNorm
# realpaths SCRATCHPAD before applying isUnderClaudeBase, so the escape is denied.
SESS3="2170aaaa-bbbb-cccc-dddd-eeeeffff0003"
SESS4="2170aaaa-bbbb-cccc-dddd-eeeeffff0004"
OUTROOT="$TMPROOT/outside-root"
REALSP="$BASE/$SLUG/$SESS4/scratchpad"
mkdir -p "$OUTROOT" "$BASE/$SLUG/$SESS3" "$REALSP"
printf 'echo hi\nmkdir -p %s\n' "$MARK_ROOT" >"$OUTROOT/probe.sh"
printf 'echo hi\n' >"$REALSP/probe.sh"
LINKROOT="$BASE/$SLUG/$SESS3/scratchpad"
inv_path_root() { env -u CLAUDE_SESSION_ID SCRATCHPAD="$2" node "$DRIVER" --invoke "$1" 2>&1; }
inv_sess_root() { env -u SCRATCHPAD CLAUDE_SESSION_ID="$2" node "$DRIVER" --invoke "$1" 2>&1; }
# Executing variants, for the same reason as xinv_path/xinv_sess: $3 is the script an
# allow verdict would really run.
xinv_path_root() { env -u CLAUDE_SESSION_ID SCRATCHPAD="$2" node "$DRIVER" --invoke-exec "$1" "$3" 2>&1; }
xinv_sess_root() { env -u SCRATCHPAD CLAUDE_SESSION_ID="$2" node "$DRIVER" --invoke-exec "$1" "$3" 2>&1; }
if node "$HERE/mk-symlink.js" "$OUTROOT" "$LINKROOT" dir; then
    # DANGEROUS direction, now correctly denied: the root resolver in
    # hooks/lib/claude-scratchpad-base.js realpaths SCRATCHPAD before applying
    # isUnderClaudeBase, so a link that merely LOOKS like .../<slug>/<uuid>/scratchpad no
    # longer relocates the containment window onto the external directory.
    # TL3 gap: real NTFS junction and WSL bind-mount semantics for the ROOT path.
    assert_eq "SP-26a-deny-symlinked-root-path-branch" "deny" \
        "$(xinv_path_root "bash $LINKROOT/probe.sh" "$LINKROOT" "$LINKROOT/probe.sh")"
    # The session branch never consults SCRATCHPAD and was always correct — the two rows
    # together show both branches now answering the escaping root identically.
    assert_eq "SP-26b-deny-symlinked-root-session-branch" "deny" \
        "$(xinv_sess_root "bash $LINKROOT/probe.sh" "$SESS3" "$LINKROOT/probe.sh")"
    # Pattern 4 control: a genuinely in-root script under a REAL root still auto-
    # approves, so a later fix must not answer this whole shape with a blanket deny.
    assert_eq "SP-26c-allow-real-root-control" "allow" \
        "$(inv_path_root "bash $REALSP/probe.sh" "$REALSP")"
    # Non-vacuous for the same reason as SP-22c: SP-26a/b would have RUN probe.sh had
    # they allowed, and probe.sh drops MARK_ROOT when it runs.
    assert_eq "SP-26d-escape-target-not-executed" "absent" "$(marker_state "$MARK_ROOT")"
else
    # SKIPPED: SP-26 (4 cases) — the platform refuses DIRECTORY symlink creation.
    # Because: only a real directory link can relocate the containment window; a plain
    # directory would test nothing about realpath on the root.
    # L3 gap: the symlinked-ROOT escape is unverified on such hosts, and the escaping
    # root is exactly the shape a lexical-only resolver would auto-approve. Covered on
    # Developer-Mode hosts and on CI.
    echo "SKIP: SP-26 — platform denied directory symlink creation"
    SKIP=$((SKIP + 4))
fi

# --- SP-27: CROSS-SESSION escape — a link into ANOTHER session's scratchpad ---
# SP-22..SP-26 all escape the claude base entirely. This one never leaves it: session A
# links to a script that really lives under session B's scratchpad, so isUnderClaudeBase
# is satisfied and only the per-session window can refuse it. Both branches must: the
# path branch compares against realpath(SCRATCHPAD) segment-wise, and the session branch
# requires segs[1] to equal the CURRENT session id.
SESSB="2170aaaa-bbbb-cccc-dddd-eeeeffff0002"
SPB="$BASE/$SLUG/$SESSB/scratchpad"
mkdir -p "$SPB"
MARK_XS="$TMPROOT_RAW/executed-cross-session"
printf 'echo other\nmkdir -p %s\n' "$MARK_XS" >"$SPB/other.sh"
LINK5="$SP/xsession.sh"
if mk_link "$SPB/other.sh" "$LINK5"; then
    # Precondition (Pattern 1): lexically the link sits inside session A's own root, so a
    # path.resolve-only implementation would have allowed it.
    assert_eq "SP-27a-precondition-lexically-inside" "yes" "$(lexical "$LINK5")"
    assert_eq "SP-27b-deny-cross-session-path-branch" "deny" "$(xinv_path "bash $LINK5" "$LINK5")"
    assert_eq "SP-27c-deny-cross-session-session-branch" "deny" "$(xinv_sess "bash $LINK5" "$LINK5")"
    assert_eq "SP-27d-cross-session-target-not-executed" "absent" "$(marker_state "$MARK_XS")"
    # Pattern 4 controls: the denial must come from the SESSION boundary, not from the
    # file. The same script is allowed when session B is the current session, and an
    # unlinked script in session A's own root is allowed too (SP-21a already, repeated
    # here on the session branch so both branches carry an allow).
    assert_eq "SP-27e-allow-same-file-from-owning-session" "allow" \
        "$(env -u SCRATCHPAD CLAUDE_SESSION_ID="$SESSB" node "$DRIVER" --invoke "bash $SPB/other.sh" 2>&1)"
    assert_eq "SP-27f-allow-own-session-script" "allow" "$(inv_sess "bash $SP/sub/real.sh")"
else
    # SKIPPED: SP-27 (6 cases) — same platform condition as SP-22.
    # Because: the cross-session escape needs a real link from one session root to another.
    # L3 gap: session-to-session isolation is unverified on such hosts; the base-escape
    # cases share the same mechanism and are also skipped there. Covered on CI.
    echo "SKIP: SP-27 — platform denied symlink creation"
    SKIP=$((SKIP + 6))
fi

echo ""
echo "Section D-5: PASS=$PASS FAIL=$FAIL SKIPPED-CASES=$SKIP"
exit "$FAIL"
