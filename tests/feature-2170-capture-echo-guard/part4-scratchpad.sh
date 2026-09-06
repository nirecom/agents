#!/usr/bin/env bash
# Tests: hooks/preuse-auto-approve/scratchpad-script.js, hooks/lib/claude-scratchpad-base.js, hooks/preuse-auto-approve.js
# Tags: capture-echo-guard, scratchpad-allow, session-scoping, path-containment, classifier, scope:issue-specific, pwsh-not-required
# Section D (D-1..D-4) — isAllowedScratchpadInvocation judgment (TL2: real fs fixtures).
# Fixture isolation per rules/test/fixture-isolation.md: TMPDIR/TEMP/TMP point at an
# isolated temp root so os.tmpdir()-derived claude base never touches the real one.
# Config-dependent branches are pinned explicitly per case: SCRATCHPAD set (D-1),
# only CLAUDE_SESSION_ID set (D-2), neither set (D-3). Nothing is inherited ambiently.
# D-5 (symlink traversal) lives in part5-symlink.sh.

# lang-check: ignore — SP-44..SP-46 assert non-ASCII scratchpad paths, so the
# fixture literals must stay Japanese.

set -uo pipefail

# TL3 gap (what this test does NOT catch):
# - whether Claude Code actually suppresses the prompt on an allow decision
# - whether settings.json's matcher reaches this hook at all (part6-settings.sh
#   checks that statically; tests/TL3-hook-capture-echo-registration.sh live)
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration.

AGENTS_DIR="${1:-$(cd "$(dirname "$0")/../.." && pwd)}"
export AGENTS_DIR
HERE="$(cd "$(dirname "$0")" && pwd)"
DRIVER="$HERE/scratchpad-driver.js"
command -v node >/dev/null 2>&1 || exit 77

PASS=0
FAIL=0

assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then
        echo "PASS: $name"; PASS=$((PASS + 1))
    else
        echo "FAIL: $name — want=$(printf '%q' "$want") got=$(printf '%q' "$got")"; FAIL=$((FAIL + 1))
    fi
}

TMPROOT_RAW="$(mktemp -d)"
REPOROOT_RAW="$(mktemp -d)"
trap 'rm -rf "$TMPROOT_RAW" "$REPOROOT_RAW"' EXIT
to_node_path() {
    if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi
}
TMPROOT="$(to_node_path "$TMPROOT_RAW")"
REPOROOT="$(to_node_path "$REPOROOT_RAW")"

export TMPDIR="$TMPROOT" TEMP="$TMPROOT" TMP="$TMPROOT"
unset CLAUDE_CODE_SESSION_ID
export CLAUDE_WORKFLOW_DIR="$TMPROOT/workflow" WORKFLOW_PLANS_DIR="$TMPROOT/plans"
mkdir -p "$CLAUDE_WORKFLOW_DIR" "$WORKFLOW_PLANS_DIR"

BASE="$TMPROOT/claude"
SLUG="c--fixture-project"
SESS="2170aaaa-bbbb-cccc-dddd-eeeeffff0001"
OTHER="2170aaaa-bbbb-cccc-dddd-eeeeffff0002"
SP="$BASE/$SLUG/$SESS/scratchpad"

mkdir -p "$SP/sub" \
         "$BASE/$SLUG/$OTHER/scratchpad" \
         "$BASE/$SLUG/${SESS}-evil/scratchpad" \
         "$BASE/$SESS/scratchpad" \
         "$BASE/$SLUG/x/$SESS/scratchpad" \
         "$BASE/$SLUG/$SESS/notscratchpad" \
         "$BASE/$SLUG/${SESS}/scratchpad-evil"
printf 'echo hi\n' >"$SP/probe.sh"
printf 'echo hi\n' >"$SP/sub/probe.sh"
printf 'not a script\n' >"$SP/probe.txt"
printf 'echo hi\n' >"$BASE/$SLUG/$OTHER/scratchpad/x.sh"
printf 'echo hi\n' >"$BASE/$SLUG/${SESS}-evil/scratchpad/probe.sh"
printf 'echo hi\n' >"$BASE/$SESS/scratchpad/probe.sh"
printf 'echo hi\n' >"$BASE/$SLUG/x/$SESS/scratchpad/probe.sh"
printf 'echo hi\n' >"$BASE/$SLUG/$SESS/notscratchpad/probe.sh"
printf 'echo hi\n' >"$BASE/$SLUG/${SESS}/scratchpad-evil/probe.sh"
printf 'echo pwned\n' >"$TMPROOT/evil.sh"

# F1 fixture: a TEMP poisoned to sit INSIDE a git repo. Same shape as the good
# fixture, so the only reason to reject it is the repo-exclusion clause.
git -C "$REPOROOT_RAW" init -q
git -C "$REPOROOT_RAW" config core.hooksPath /dev/null
RBASE="$REPOROOT/claude"
RSP="$RBASE/$SLUG/$SESS/scratchpad"
mkdir -p "$RSP"
printf 'echo hi\n' >"$RSP/probe.sh"

inv_path()  { env -u CLAUDE_SESSION_ID SCRATCHPAD="$SP" node "$DRIVER" --invoke "$1" 2>&1; }
inv_sess()  { env -u SCRATCHPAD CLAUDE_SESSION_ID="$SESS" node "$DRIVER" --invoke "$1" 2>&1; }
inv_none()  { env -u SCRATCHPAD -u CLAUDE_SESSION_ID node "$DRIVER" --invoke "$1" 2>&1; }

# --- D-1: SCRATCHPAD set (existing H2 session-scoping path) -----------------
assert_eq "SP-1-allow-real-script"        "allow" "$(inv_path "bash $SP/probe.sh")"
assert_eq "SP-1b-allow-quoted-arg"        "allow" "$(inv_path "bash \"$SP/probe.sh\"")"
assert_eq "SP-1c-deny-non-bash"           "deny"  "$(inv_path "node $SP/probe.sh")"
assert_eq "SP-1d-deny-extra-argv"         "deny"  "$(inv_path "bash $SP/probe.sh extra")"
assert_eq "SP-1e-deny-redirect"           "deny"  "$(inv_path "bash $SP/probe.sh > $TMPROOT/out.txt")"
assert_eq "SP-1f-deny-assignment-cmd0"    "deny"  "$(inv_path "A=1 bash $SP/probe.sh")"
assert_eq "SP-1g-deny-here-input"         "deny"  "$(inv_path "bash $SP/probe.sh <<EOF
hi
EOF")"
assert_eq "SP-2-deny-chaining"            "deny"  "$(inv_path "bash $SP/probe.sh && rm -rf /")"
assert_eq "SP-2b-deny-pipe"               "deny"  "$(inv_path "bash $SP/probe.sh | cat")"
assert_eq "SP-2c-deny-subshell"           "deny"  "$(inv_path "( bash $SP/probe.sh )")"
assert_eq "SP-3-deny-other-session"       "deny"  "$(inv_path "bash $BASE/$SLUG/$OTHER/scratchpad/x.sh")"
assert_eq "SP-4-deny-outside-temp-root"   "deny"  "$(inv_path "bash /home/evil/claude/x/scratchpad/y.sh")"
assert_eq "SP-5-deny-dotdot-escape"       "deny"  "$(inv_path "bash \"$SP/../../evil.sh\"")"
assert_eq "SP-6a-deny-expansion"          "deny"  "$(inv_path 'bash "$SOMEVAR/x.sh"')"
assert_eq "SP-6b-deny-glob"               "deny"  "$(inv_path "bash $SP/*.sh")"
assert_eq "SP-6c-deny-backtick"           "deny"  "$(inv_path "bash \`echo $SP/probe.sh\`")"
assert_eq "SP-6d-deny-question-glob"      "deny"  "$(inv_path "bash $SP/probe.s?")"
assert_eq "SP-7-deny-non-sh-extension"    "deny"  "$(inv_path "bash $SP/probe.txt")"
assert_eq "SP-8-deny-absent-file"         "deny"  "$(inv_path "bash $SP/absent.sh")"
assert_eq "SP-8b-deny-directory-target"   "deny"  "$(inv_path "bash $SP/sub")"
# Segment-array containment, never naive string prefix: sibling dir "scratchpad-evil".
assert_eq "SP-8c-deny-sibling-prefix-dir" "deny"  "$(inv_path "bash $BASE/$SLUG/$SESS/scratchpad-evil/probe.sh")"

# SP-9 (F1): SCRATCHPAD legitimately under a poisoned TEMP that lands in a git repo.
assert_eq "SP-9-deny-repo-polluted-temp" "deny" \
    "$(env -u CLAUDE_SESSION_ID TMPDIR="$REPOROOT" TEMP="$REPOROOT" TMP="$REPOROOT" SCRATCHPAD="$RSP" node "$DRIVER" --invoke "bash $RSP/probe.sh" 2>&1)"

# --- D-2: no SCRATCHPAD, CLAUDE_SESSION_ID set (structural session match) ----
assert_eq "SP-11-allow-session-structural" "allow" "$(inv_sess "bash $SP/probe.sh")"
assert_eq "SP-12-deny-different-session"   "deny"  "$(inv_sess "bash $BASE/$SLUG/$OTHER/scratchpad/x.sh")"
assert_eq "SP-13-deny-session-prefix"      "deny"  "$(inv_sess "bash $BASE/$SLUG/${SESS}-evil/scratchpad/probe.sh")"
assert_eq "SP-14-deny-missing-slug"        "deny"  "$(inv_sess "bash $BASE/$SESS/scratchpad/probe.sh")"
assert_eq "SP-15-deny-extra-depth"         "deny"  "$(inv_sess "bash $BASE/$SLUG/x/$SESS/scratchpad/probe.sh")"
assert_eq "SP-16-deny-wrong-leaf-dir"      "deny"  "$(inv_sess "bash $BASE/$SLUG/$SESS/notscratchpad/probe.sh")"
assert_eq "SP-17-allow-subdirectory"       "allow" "$(inv_sess "bash $SP/sub/probe.sh")"
assert_eq "SP-18-deny-repo-polluted-temp"  "deny" \
    "$(env -u SCRATCHPAD CLAUDE_SESSION_ID="$SESS" TMPDIR="$REPOROOT" TEMP="$REPOROOT" TMP="$REPOROOT" node "$DRIVER" --invoke "bash $RSP/probe.sh" 2>&1)"

# --- D-3: neither set -> fail-to-ask, never a base-wide fallback -------------
assert_eq "SP-19-deny-no-session-context" "deny" "$(inv_none "bash $SP/probe.sh")"
assert_eq "SP-20-root-is-null"            "null" "$(env -u SCRATCHPAD -u CLAUDE_SESSION_ID node "$DRIVER" --root 2>&1)"
# Config-dependent branch coverage for the other two states of the same resolver.
assert_eq "SP-20b-root-kind-session"      "session:$SESS" "$(env -u SCRATCHPAD CLAUDE_SESSION_ID="$SESS" node "$DRIVER" --root 2>&1)"
root_kind() { case "$1" in path:*) printf 'path' ;; *) printf '%s' "$1" ;; esac; }
assert_eq "SP-20c-root-kind-path"         "path" "$(root_kind "$(env -u CLAUDE_SESSION_ID SCRATCHPAD="$SP" node "$DRIVER" --root 2>&1)")"
# SCRATCHPAD pointing outside the claude base must NOT become {kind:"path"}.
assert_eq "SP-20d-root-rejects-outside-scratchpad" "session:$SESS" \
    "$(env SCRATCHPAD="$TMPROOT/not-claude" CLAUDE_SESSION_ID="$SESS" node "$DRIVER" --root 2>&1)"

# --- D-4: existing write-path semantics unchanged by this work ---------------
# isAllowedScratchpadTarget is the EXISTING function; with no SCRATCHPAD it still
# falls back to the whole claude base for WRITES. This must PASS today and after.
assert_eq "SP-21-legacy-write-path-invariance" "true" \
    "$(env -u SCRATCHPAD -u CLAUDE_SESSION_ID node "$DRIVER" --legacy-target "$BASE/$SLUG/$OTHER/scratchpad/f.txt" 2>&1)"
assert_eq "SP-21b-legacy-still-rejects-outside-base" "false" \
    "$(env -u SCRATCHPAD -u CLAUDE_SESSION_ID node "$DRIVER" --legacy-target "$TMPROOT/evil.sh" 2>&1)"

# --- SP-10: AUTO_APPROVE_TOOLS kill switch (hook process boundary) -----------
EV="$TMPROOT_RAW/event.json"
OUT="$TMPROOT_RAW/out.json"
HOOK="$AGENTS_DIR/hooks/preuse-auto-approve.js"
node "$HERE/mk-event.js" Bash "bash $SP/probe.sh" >"$EV"
run_auto() {
    env -u CLAUDE_SESSION_ID SCRATCHPAD="$SP" AUTO_APPROVE_TOOLS="$1" node "$HOOK" <"$EV" >"$OUT" 2>/dev/null
    node "$HERE/hook-out.js" "$OUT"
}
assert_eq "SP-10-kill-switch-off-not-allowed" "passthrough" "$(run_auto off)"
# Pattern 4 both-direction: with the switch on, the SAME event must be auto-approved.
assert_eq "SP-10b-kill-switch-on-allows"      "allow"       "$(run_auto on)"

# SKIPPED: real permission-prompt suppression in a live Claude Code session.
# Because: requires a TL3 real-session run; this layer can only observe the hook's
# JSON decision, not the harness's reaction to it.
# TL3 gap: a correct allow decision that Claude Code ignores (matcher not extended
# in settings.json) is invisible here — part6-settings.sh checks that statically.

# --- D-7: legitimate-but-awkward path spellings (C12) ------------------------
# The reject condition is SHELL METACHARACTERS, not "unusual characters": a scratchpad
# under a directory with a space or with non-ASCII names is a normal Windows/Japanese
# workstation reality (CPR-UNV) and must be auto-approved when properly quoted, while
# the same path written so the shell would expand or split it must not be.
mkdir -p "$SP/with space" "$SP/日本語"
printf 'echo hi\n' >"$SP/with space/probe.sh"
printf 'echo hi\n' >"$SP/日本語/プローブ.sh"

trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    printf '%s' "${s%"${s##*[![:space:]]}"}"
}
run_inv_table() {
    local name input want
    while IFS='|' read -r name input want; do
        [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
        name="${name//[[:space:]]/}"
        want="${want//[[:space:]]/}"
        assert_eq "$name" "$want" "$(inv_path "$(trim "$input")")"
    done
}
run_inv_table <<TABLE
SP-42-allow-space-path-quoted    | bash "$SP/with space/probe.sh"          | allow
# Unquoted, the space splits argv: bash sees two arguments, not one script path.
SP-43-deny-space-path-unquoted   | bash $SP/with space/probe.sh            | deny
SP-44-allow-unicode-path-quoted  | bash "$SP/日本語/プローブ.sh"           | allow
# Non-ASCII alone is not a hazard, so the unquoted form is still one argv token.
SP-45-allow-unicode-path-bare    | bash $SP/日本語/プローブ.sh             | allow
SP-46-deny-unicode-path-glob     | bash "$SP/日本語/*.sh"                  | deny
SP-47-deny-space-path-then-chain | bash "$SP/with space/probe.sh"; rm -rf / | deny
SP-48-deny-space-path-in-braces  | bash "$SP/{with space,x}/probe.sh"      | deny
TABLE

# SKIPPED: direct unit assertions on resolveScriptPath(seg) for each spelling above.
# Because: it is module-private in scratchpad-script.js, so reaching it means changing
# the source to suit the test; the spellings are pinned through the exported predicate
# and, below, through the hook process that actually decides the permission.
# TL3 gap: how a real shell tokenizes these spellings — the ground truth the predicate
# approximates — is only observable in a live session.

# --- D-8: every command tool reaches the same decision (C6, CPR-ORTH) --------
# preuse-auto-approve.js reads the command through tool-command-text.js, so Bash,
# runInTerminal and runCommands must all earn the auto-approve — and a multi-element
# runCommands array must NOT: only a single execution unit is one invocation.
run_auto_tool() {
    node "$HERE/mk-event.js" "$@" >"$EV"
    env -u CLAUDE_SESSION_ID SCRATCHPAD="$SP" AUTO_APPROVE_TOOLS=on node "$HOOK" <"$EV" >"$OUT" 2>/dev/null
    node "$HERE/hook-out.js" "$OUT"
}
assert_eq "SP-50-runinterminal-allow"     "allow"       "$(run_auto_tool runInTerminal "bash $SP/probe.sh")"
assert_eq "SP-51-runcommands-single-allow" "allow"      "$(run_auto_tool runCommands "bash $SP/probe.sh")"
assert_eq "SP-52-runcommands-multi-passthrough" "passthrough" "$(run_auto_tool runCommands "bash $SP/probe.sh" "ls")"
# Third state of the kill switch (SP-10/SP-10b cover off/on): UNSET must behave as on,
# or the auto-approve would silently never fire on a machine that never exports it.
node "$HERE/mk-event.js" Bash "bash $SP/probe.sh" >"$EV"
assert_eq "SP-54-kill-switch-unset-allows" "allow" \
    "$(env -u CLAUDE_SESSION_ID -u AUTO_APPROVE_TOOLS SCRATCHPAD="$SP" node "$HOOK" <"$EV" >"$OUT" 2>/dev/null; node "$HERE/hook-out.js" "$OUT")"
# C12 at the process boundary: the quoted space path must survive JSON transport too.
assert_eq "SP-55-space-path-quoted-hook-allow" "allow" \
    "$(run_auto_tool Bash "bash \"$SP/with space/probe.sh\"")"
assert_eq "SP-56-space-path-unquoted-hook-passthrough" "passthrough" \
    "$(run_auto_tool Bash "bash $SP/with space/probe.sh")"

echo ""
echo "Section D (D-1..D-4): PASS=$PASS FAIL=$FAIL"
exit "$FAIL"
