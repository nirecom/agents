#!/usr/bin/env bash
# tests/hooks/fix-enforce-worktree-rtk-fail-open.sh
# Tests: hooks/lib/bash-write-patterns/segment-utils.js, hooks/lib/bash-write-patterns/git-write-ir.js, hooks/enforce-worktree/write-detector.js, hooks/enforce-worktree.js
# Tags: TL1, hook, enforce, worktree, rtk, wrapper, security, scope:permanent
# #2393: WRAPPER_SPECS lacks an `rtk` entry, so `rtk git commit` is never peeled
# and detectWritePredicate returns null (fail-open ALLOW). The fix registers rtk
# with passthroughDispatchVerbs / shellBodyVerbs / nativeVerbs. Native-verb cases
# (A5-A7) are regression guards that already pass; the rest are RED until the fix.

set -euo pipefail

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
. "$AGENTS_DIR/tests/lib/harness.sh"
# shellcheck source=tests/lib/ew-runner.sh
. "$AGENTS_DIR/tests/lib/ew-runner.sh"

T="$(make_tmp)"
trap 'rm -rf "$T"' EXIT
harness_isolate "$T/iso"

HOOKS_N="$(np "$AGENTS_DIR/hooks")"

# rtk_eval <js-body> [args...] — run a JS body with `H` bound to the hooks dir and
# `argv` bound to the extra args; prints whatever the body prints.
rtk_eval() {
    local body="$1"; shift
    run_with_timeout 30 node -e "
      const H = process.argv[1];
      const argv = process.argv.slice(2);
      const su = require(H + '/lib/bash-write-patterns/segment-utils');
      const gw = require(H + '/lib/bash-write-patterns/git-write-ir');
      const { detectWritePredicate } = require(H + '/enforce-worktree/write-detector');
      const { parse } = require(H + '/lib/command-ir');
      ${body}
    " "$HOOKS_N" "$@" 2>&1 || true
}

# eff_cmd <cmd0> [argv...] — resolveEffectiveCommand for a synthetic segment.
eff_cmd() {
    rtk_eval 'console.log(String(su.resolveEffectiveCommand({ cmd0: argv[0], argv: argv.slice(1) })));' "$@"
}

# detect <command-text> — "WRITE:<name>" or "NULL" from detectWritePredicate(parse(cmd)).
detect() {
    rtk_eval 'const r = detectWritePredicate(parse(argv[0])); console.log(r ? "WRITE:" + r.name : "NULL");' "$1"
}

expect_eq() {
    local label="$1" got="$2" want="$3"
    if [[ "$got" == "$want" ]]; then pass "$label"; else fail "$label" "want=$want got=$got"; fi
}

case_begin "rtk-spec-registration" "hooks/lib/bash-write-patterns/segment-utils.js"
# A1: wrapperSpecFor is module-private; WRAPPER_SPECS is the exported SSOT it reads.
got="$(rtk_eval '
  const s = su.WRAPPER_SPECS.rtk;
  const has = (k, v) => !!s && s[k] instanceof Set && s[k].has(v);
  if (!s) console.log("MISSING");
  else console.log([has("passthroughDispatchVerbs","proxy"), has("shellBodyVerbs","run"),
               has("nativeVerbs","env"), has("nativeVerbs","find"), has("nativeVerbs","read")].join(","));
')"
expect_eq "A1. WRAPPER_SPECS.rtk registered with proxy/run/native(env,find,read) verbs" "$got" "true,true,true,true,true"
case_end

case_begin "rtk-peel-effective-command" "hooks/lib/bash-write-patterns/segment-utils.js"
expect_eq "A2. rtk git commit -m msg → effective command git" "$(eff_cmd rtk git commit -m msg)" "git"
expect_eq "A3. rtk proxy git commit → effective command git (passthroughDispatchVerbs)" "$(eff_cmd rtk proxy git commit)" "git"
expect_eq "A5. rtk read foo → stays rtk (native verb stops peeling)" "$(eff_cmd rtk read foo)" "rtk"
expect_eq "A6. rtk env → stays rtk (no collision with WRAPPER_SPECS.env)" "$(eff_cmd rtk env)" "rtk"
expect_eq "A7. rtk find . -name *.json → stays rtk (no collision with find)" "$(eff_cmd rtk find . -name '*.json')" "rtk"
expect_eq "A9. rtk proxy rtk proxy git commit → double-nest resolves to git" "$(eff_cmd rtk proxy rtk proxy git commit)" "git"
# rtk global flags are all boolean (rtk --help); -vv must not trip AMBIGUOUS.
expect_eq "A10. rtk -vv git commit → effective command git (boolean global flag)" "$(eff_cmd rtk -vv git commit)" "git"
case_end

case_begin "rtk-git-argv" "hooks/lib/bash-write-patterns/git-write-ir.js"
got="$(rtk_eval 'console.log(JSON.stringify(gw.resolveGitArgvForSegment({ cmd0: "rtk", argv: ["git","commit","-m","msg"] })));')"
expect_eq "A2b. resolveGitArgvForSegment(rtk git commit -m msg) → git argv" "$got" '["commit","-m","msg"]'
got="$(rtk_eval 'console.log(String(gw.isGitWriteIR(parse(argv[0]))));' 'rtk git commit -m msg')"
expect_eq "A2c. isGitWriteIR(rtk git commit -m msg) → true" "$got" "true"
case_end

case_begin "rtk-write-predicate" "hooks/enforce-worktree/write-detector.js"
got="$(detect 'rtk git commit -m msg')"
[[ "$got" == WRITE:* ]] && pass "A8. detectWritePredicate(rtk git commit) → non-null ($got)" \
    || fail "A8. detectWritePredicate(rtk git commit) should be non-null (fail-open gap)" "got=$got"

got="$(detect 'rtk run "git commit -m msg"')"
[[ "$got" == WRITE:* ]] && pass "A4. rtk run \"git commit -m msg\" → WRITE via shell body ($got)" \
    || fail "A4. rtk run shell body must be WRITE, not fail-open" "got=$got"

got="$(detect 'rtk proxy rtk proxy git commit -m msg')"
[[ "$got" == WRITE:* ]] && pass "A9b. double-nest rtk proxy … git commit → WRITE ($got)" \
    || fail "A9b. double-nest rtk proxy git commit must be WRITE" "got=$got"

got="$(detect 'rtk git status')"
expect_eq "A11. rtk git status → NULL (read stays read after peel)" "$got" "NULL"

got="$(detect 'rtk read foo')"
expect_eq "A12. rtk read foo → NULL (native verb is not a write)" "$got" "NULL"
case_end

# hooks/rtk-rewrite.js substituteRtkHead rewrites the head to the resolved binary
# (quoted, forward-slashed, .exe on win32), so the guard sees that form, not bare rtk.
case_begin "rtk-absolute-path-head" "hooks/lib/bash-write-patterns/segment-utils.js"
got="$(detect '"C:/x/WinGet/Links/rtk.exe" git commit -m x')"
[[ "$got" == WRITE:* ]] && pass "A18. \"C:/x/WinGet/Links/rtk.exe\" git commit → WRITE ($got)" \
    || fail "A18. quoted absolute rtk.exe head must peel like bare rtk" "got=$got"
expect_eq "A19. /opt/homebrew/bin/rtk git status → NULL" "$(detect '/opt/homebrew/bin/rtk git status')" "NULL"
case_end

# CPR-ORTH: rtk wraps gh as well as git.
case_begin "rtk-gh-write-predicate" "hooks/enforce-worktree/write-detector.js"
# Controls: the unwrapped forms are already WRITE, so A14/A17 isolate the rtk peel.
for c in 'gh issue create -t x -b y' 'npm install'; do
    got="$(detect "$c")"
    [[ "$got" == WRITE:* ]] && pass "A13s. control: $c → WRITE ($got)" \
        || fail "A13s. control: $c must be WRITE" "got=$got"
done
# gh pr create is not a Group B gh write (unwrapped verdict is NULL), so CPR-ORTH
# demands only that the rtk-peeled verdict equal the unwrapped one.
expect_eq "A13. rtk gh pr create → same verdict as gh pr create" \
    "$(detect 'rtk gh pr create -t x -b y')" "$(detect 'gh pr create -t x -b y')"
got="$(detect 'rtk gh issue create -t x -b y')"
[[ "$got" == WRITE:* ]] && pass "A14. rtk gh issue create → WRITE ($got)" \
    || fail "A14. rtk gh issue create must be WRITE" "got=$got"
expect_eq "A15. rtk gh pr view 12 → NULL (read-only)" "$(detect 'rtk gh pr view 12')" "NULL"
case_end

# Fail-closed boundary: an unparseable rtk option must not fail-open.
case_begin "rtk-fail-closed" "hooks/lib/bash-write-patterns/segment-utils.js"
got="$(detect 'rtk --unknown-opt git commit -m x')"
[[ "$got" == WRITE:* ]] && pass "A16. rtk --unknown-opt git commit → WRITE via scanWrappedVerb ($got)" \
    || fail "A16. AMBIGUOUS rtk option must fall back to raw scan (WRITE)" "got=$got"
# Hooks-bypass form: a git global -c option between git and the verb must not hide the write.
got="$(detect 'rtk git -c core.hooksPath=/dev/null commit -m x')"
[[ "$got" == WRITE:* ]] && pass "A20. rtk git -c core.hooksPath=/dev/null commit → WRITE ($got)" \
    || fail "A20. rtk git -c core.hooksPath=... commit must be WRITE" "got=$got"
got="$(detect 'rtk npm install')"
[[ "$got" == WRITE:* ]] && pass "A17. rtk npm install → WRITE ($got)" \
    || fail "A17. rtk npm install must be WRITE" "got=$got"
case_end

# --- Hook-level: hooks/enforce-worktree.js end to end -----------------------
MAIN="$(np "$T/main")"
LINKED="$(np "$T/wt-linked")"
ew_make_repo "$MAIN"
git -C "$MAIN" worktree add -q -b feature/rtk "$LINKED"
EW_CONFIG_DIR="$MAIN"
run() { ew_run "$1" "$(ew_bash_payload test "$2")"; }

case_begin "rtk-hook-enforce-worktree" "hooks/enforce-worktree.js"
ew_expect block "H1. main CWD: git commit -m x → BLOCK (fixture sanity)" "$(run "$MAIN" 'git commit -m x')"
ew_expect block "H2. main CWD: rtk git commit -m x → BLOCK" "$(run "$MAIN" 'rtk git commit -m x')"
ew_expect allow "H3. linked CWD: rtk git commit -m x → ALLOW" "$(run "$LINKED" 'rtk git commit -m x')"
ew_expect block "H4. main CWD: rtk gh issue create -t x -b y → BLOCK" "$(run "$MAIN" 'rtk gh issue create -t x -b y')"
ew_expect allow "H5. main CWD: rtk git status → ALLOW (read-only)" "$(run "$MAIN" 'rtk git status')"
ew_expect block "H7. main CWD: \"C:/x/WinGet/Links/rtk.exe\" git commit -m x → BLOCK" \
    "$(run "$MAIN" '"C:/x/WinGet/Links/rtk.exe" git commit -m x')"
ew_expect allow "H8. main CWD: /opt/homebrew/bin/rtk git status → ALLOW" \
    "$(run "$MAIN" '/opt/homebrew/bin/rtk git status')"
ew_expect block "H9. main CWD: rtk git -c core.hooksPath=/dev/null commit -m x → BLOCK (hooks-bypass)" \
    "$(run "$MAIN" 'rtk git -c core.hooksPath=/dev/null commit -m x')"
case_end

# A linked CWD must not launder a write that -C redirects into the main worktree.
case_begin "rtk-hook-linked-cwd-dash-c-main" "hooks/enforce-worktree.js"
ew_expect block "H6s. linked CWD: git -C <main> commit -m x → BLOCK (fixture sanity)" \
    "$(run "$LINKED" "git -C \"$MAIN\" commit -m x")"
ew_expect block "H6. linked CWD: rtk git -C <main> commit -m x → BLOCK" \
    "$(run "$LINKED" "rtk git -C \"$MAIN\" commit -m x")"
ew_expect block "H6b. linked CWD: rtk proxy git -C <main> commit -m x → BLOCK" \
    "$(run "$LINKED" "rtk proxy git -C \"$MAIN\" commit -m x")"
case_end

echo ""
echo "Results: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[[ "$FAIL" -eq 0 ]]
