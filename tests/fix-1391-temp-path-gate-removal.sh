#!/bin/bash
# tests/fix-1391-temp-path-gate-removal.sh
# Tests: hooks/lib/bash-write-patterns/classify.js, hooks/enforce-worktree.js, hooks/lib/bash-write-patterns/patterns.js
# Tags: enforce-worktree, classify, temp-path, gh-retire, scope:issue-specific
#
# Bug #1391 + retire #1296 (gh group). Fail-before-fix suite (BUGFIX session).
#
# What the fix does (source NOT yet applied when this file is first run):
#   1. classify.js:98-111 temp-path redirect gate is REMOVED. isOsTempPath()
#      returns true for ANY /tmp/ path — including repo paths under /tmp/ — so the
#      gate demotes redirects into temp-located repos to "read", fast-allowing
#      them past enforce-worktree.js:202 before the real IR scope pipeline runs.
#      After removal classify() returns "write" for temp-path redirects, letting
#      collectBashWriteTargets → areAllBashTargetsOutsideSessionScope decide.
#   2. enforce-worktree.js:202 fast-allow gains a gh exception:
#      `if (classify(ir) !== "write" && !isGhWriteCommand(ir)) done();`
#   3. patterns.js: the 8 kind:"gh" WRITE_PATTERNS entries are removed;
#      STRIP_KINDS loses "gh"; isGhWriteIR (IR-based) is the sole SSOT. Without
#      the L202 exception, classify("gh pr merge") would become "read" and
#      fast-allow gh writes past the gh session-scope gate at enforce-worktree.js:246.
#
# Fail-before-fix expectation (pre-fix run):
#   Section A (A1/A2/A4/A5): classify currently returns "read" → these FAIL now,
#     pass after the gate removal. THIS is the correct fail-before-fix evidence.
#   A3 (tee, no redirect): "write" both before/after — sanity, always green.
#   Sections B, C: green both before and after (guard that behavior is preserved).
#   Section E (retire proof): classify("gh ...") is "write" pre-retire → the
#     classify-"read" rows FAIL now, pass after the kind:"gh" group is removed.
#     The WRITE_PATTERNS / STRIP_KINDS structural rows also FAIL now (gh entries
#     still present) and pass after retire. isGhWriteIR rows are green both sides.
#
# L3 gap (what this test does NOT catch):
#   - Real PreToolUse surface: only a live `claude -p` session fires
#     enforce-worktree.js via the Anthropic hook protocol. Section D uses
#     `node GUARD_JS` over stdin JSON, not the real hook dispatch.
#   - Live-session env resolution (ENFORCE_WORKTREE, ADDITIONAL_REPOS) sourced
#     from dotfiles / .env.local / system env — here injected as process env.
#   - Windows path normalization of model-emitted backslash paths passed through
#     the real shell to Node differs from the shell-normalized fixtures here.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED
# preflight via bin/check-verification-gate.sh category: hook-registration.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi
GUARD_JS="${_AGENTS_DIR_NODE}/hooks/enforce-worktree.js"

PASS=0
FAIL=0
SKIP=0

assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then echo "PASS: $name"; PASS=$((PASS + 1))
    else echo "FAIL: $name — want=$(printf '%q' "$want") got=$(printf '%q' "$got")"; FAIL=$((FAIL + 1)); fi
}
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    fi
}

# Subject drivers — one node process per call, IR-based (matches production path).
classify_ir() {
    node -e "const {classify}=require('${_AGENTS_DIR_NODE}/hooks/lib/bash-write-patterns'); const {parse}=require('${_AGENTS_DIR_NODE}/hooks/lib/command-ir'); process.stdout.write(classify(parse(process.argv[1])))" -- "$1" 2>/dev/null
}
gh_write_ir() {
    node -e "const {isGhWriteIR}=require('${_AGENTS_DIR_NODE}/hooks/lib/bash-write-patterns/patterns'); const {parse}=require('${_AGENTS_DIR_NODE}/hooks/lib/command-ir'); process.stdout.write(String(isGhWriteIR(parse(process.argv[1]))))" -- "$1" 2>/dev/null
}

echo "=== Section A: classify temp-path gate removal (fail-before-fix) ==="
# A1/A2/A4/A5 expect "write" — they FAIL pre-fix (gate demotes to "read") and
# pass after the gate is removed. A3 is handled as a standalone assertion below
# (it contains a literal pipe, which the IFS='|' table cannot carry as one field).
while IFS='|' read -r name input want; do
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name//[[:space:]]/}"
    want="${want//[[:space:]]/}"
    got="$(classify_ir "$input")"
    assert_eq "$name" "$want" "$got"
done <<'TABLE'
A1 | echo x > /tmp/foo                    | write
A2 | echo x > /tmp/r8/.claude/foo-r8      | write
A4 | echo x > /var/tmp/foo                | write
A5 | echo x > /dev/shm/foo                | write
TABLE

# A3 stands outside the IFS='|' table: its input `ls | tee /tmp/out` contains a
# literal pipe, which would be split as a field separator inside the table loop.
# `tee` is a write both before and after the fix (sanity row, always green).
assert_eq "A3" "write" "$(classify_ir 'ls | tee /tmp/out')"

# A6/A7 (review C4): temp-path redirect classify edge cases with quoting / special
# chars / Windows temp. Fail-before-fix like A1 — the gate currently demotes these
# to "read" (isOsTempPath returns true for the redirect target), and the gate
# removal restores "write". Kept as standalone assert_eq lines (not table rows)
# because the quoted path with spaces contains characters awkward for IFS='|'.
# A6: quoted temp path containing a space. isOsTempPath('/tmp/dir with space/foo')
#   is true → pre-fix classify demotes to "read"; post-fix "write". FAILs now.
assert_eq "A6: quoted /tmp path with space" "write" "$(classify_ir 'echo x > "/tmp/dir with space/foo"')"
# A7: Windows AppData/Local/Temp redirect target. isOsTempPath matches the
#   appdata[/\\]local[/\\]temp[/\\] branch (command-ir.js:177) → true → pre-fix
#   classify demotes to "read"; post-fix "write". FAILs now (fail-before-fix).
assert_eq "A7: Windows AppData/Local/Temp path" "write" "$(classify_ir 'echo x > C:/Users/u/AppData/Local/Temp/foo')"

echo "=== Section B: classify sanity (green before and after) ==="
while IFS='|' read -r name input want; do
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name//[[:space:]]/}"
    want="${want//[[:space:]]/}"
    got="$(classify_ir "$input")"
    assert_eq "$name" "$want" "$got"
done <<'TABLE'
B1 | cat /tmp/foo | read
B2 | ls -la       | read
B3 | git status   | read
TABLE

echo "=== Section C: gh IR extractor coverage (isGhWriteIR — green now) ==="
# Guards that the IR replacement covers every gh write form BEFORE the
# kind:"gh" WRITE_PATTERNS group is removed. Positive + negative rows.
# C11-C14: gh-api-mutate flag-form edge cases (C3). The removed regex used
#   (?:-X[\s=]*|--method[\s=]+) which accepted `-X=DELETE`. isGhWriteIR NOW
#   accepts `-X=DELETE` too — its second branch was widened to
#   /^-X=?(POST|PUT|PATCH|DELETE)$/ in the #1296 retire to preserve the old
#   regex's `-X=` gating coverage (fail-closed). So C12 asserts true, matching
#   the retired regex. All other forms (-XDELETE no-space, --method=PATCH,
#   lowercase `-X delete`) ARE covered → true.
# C15-C16: env/assignment-prefixed gh writes (review C2). isGhWriteIR's segment
#   loop resolves `env VAR=val gh ...` (synthetic seg via resolveEffectiveCommand)
#   and `VAR=val gh ...` (inline-assignment cmd0). Both prefixes strip to the gh
#   segment, so the write form is still detected → true. Verified against actual
#   isGhWriteIR (patterns.js:230-250).
# C17-C18: gh write NOT at argv position zero — sequenced after `;`, `&&`
#   (review C3). isGhWriteIR iterates ir.segments to find the gh segment, so a gh
#   write in a later segment is detected regardless of leading commands → true.
#   Verified against actual isGhWriteIR (the `for (const seg of ir.segments)` loop).
# C19-C22: gh GLOBAL FLAGS before the subcommand (#1296 retire bypass class).
#   gh accepts `-R owner/repo` / `--repo o/r` / `--hostname h` before the
#   subcommand, shifting argv so sub0 becomes the flag. Pre-FIX-1 the positional
#   sub0/sub1 checks saw sub0="-R" → returned false → the gh mutation fast-allowed
#   at enforce-worktree.js:202 with NO session-scope enforcement against the
#   arbitrary `-R owner/repo` target. resolveGhSubArgv now skips leading global
#   flags so C19-C21 (write subcommands behind a global flag) → true. C22 guards
#   against over-block: a READ subcommand (`pr view`) behind a global flag stays
#   false — the flag-skip must not blanket-flag every `-R`-prefixed gh command.
while IFS='|' read -r name input want; do
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name//[[:space:]]/}"
    want="${want//[[:space:]]/}"
    got="$(gh_write_ir "$input")"
    assert_eq "$name" "$want" "$got"
done <<'TABLE'
C1  | gh pr merge 5                             | true
C2  | gh issue delete 5                         | true
C3  | gh repo delete o/r                        | true
C4  | gh release create v1                      | true
C5  | gh issue create --title x                 | true
C6  | gh api -X DELETE repos/o/r/issues/1       | true
C7  | gh api --method POST repos/o/r/git/blobs  | true
C8  | gh api PUT repos/o/r/contents/f           | true
C9  | gh pr view 5                              | false
C10 | gh issue list                            | false
C11 | gh api -XDELETE repos/o/r/x               | true
C12 | gh api -X=DELETE repos/o/r/x              | true
C13 | gh api --method=PATCH repos/o/r/x         | true
C14 | gh api -X delete repos/o/r/x              | true
C15 | env GH_TOKEN=x gh pr merge 5              | true
C16 | GH_HOST=github.com gh api --method=PATCH repos/o/r/x | true
C17 | echo ok; gh pr merge 5                    | true
C18 | true && gh api -X DELETE repos/o/r/issues/1 | true
C19 | gh -R o/r pr merge 5                      | true
C20 | gh --repo o/r issue delete 5             | true
C21 | gh -R o/r release upload v1 f            | true
C22 | gh -R o/r pr view 5                      | false
TABLE

echo "=== Section D: L2 enforce-worktree gh skill-gate integration ==="
# Protection-fix Pattern 1 (negative assertion) + Pattern 2 (attack scenario).
# The regression this guards: after the kind:"gh" WRITE_PATTERNS group is
# removed, classify("gh issue create") becomes "read". WITHOUT the L202
# `!isGhWriteCommand(ir)` exception, the fast-allow at enforce-worktree.js:202
# fires first and the command never reaches the gh gate at L246 — so a bare
# `gh issue create` from a MAIN worktree would leak past the /issue-create
# skill-context gate (L252) as a bare allow {}.
#
# We assert at the hook boundary that a bare `gh issue create` from main is
# BLOCKED (reaches the gate), and that the sanctioned ISSUE_CREATE_SKILL=1 form
# is allowed. A single-repo fixture suffices: the cwd repo is always a session
# root, so the block here comes from the skill gate, not session-scope.
#
# Pre-fix state (group still present, L202 unchanged): classify is "write" →
# reaches the gate → bare form blocks, sanctioned form allows → both PASS now.
# These stay green after the fix ONLY because of the L202 gh exception; without
# it the bare form would bare-allow → D1 would FAIL. That is the regression
# these cases lock in.
#
# C1 note (gh writes beyond issue-create): the L202 exception is
# `!isGhWriteCommand(ir)`, which covers ALL gh writes — not just issue-create.
# A single-repo `gh pr merge` from a main worktree would be gate-ALLOWED (the
# cwd repo is its own session root — indistinguishable from a bare fast-allow by
# decision alone), so a hook-boundary assertion cannot prove the L202 exception
# specifically fired for it. We prove the exception's necessity + sufficiency at
# the classify/IR layer instead in Section E (E-C1a..E-C1d).

# Temp git repo (main worktree) via Node for Windows-safe path resolution.
TMPDIR_BASE="$(node -e "
const os=require('os'),path=require('path'),fs=require('fs');
const d=path.join(os.tmpdir(),'fix1391-'+process.pid).replace(/\\\\/g,'/');
fs.mkdirSync(d,{recursive:true});
console.log(d);
" 2>/dev/null)"
[ -z "$TMPDIR_BASE" ] && TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

setup_main_checkout() {
    local repo="$TMPDIR_BASE/$1"
    mkdir -p "$repo"
    git -C "$repo" init -q -b main
    git -C "$repo" config user.email "test@example.com"
    git -C "$repo" config user.name "Test"
    git -C "$repo" config core.hooksPath /dev/null
    echo "init" > "$repo/README.md"
    git -C "$repo" add README.md
    git -C "$repo" commit -q -m "initial"
    if command -v cygpath >/dev/null 2>&1; then cygpath -m "$repo"; else echo "$repo"; fi
}

run_bash_guard() {
    local cmd="$1"; shift
    local cwd="$1"; shift
    local payload
    payload="$(node -e "
      const j = { session_id:'test', tool_name:'Bash', tool_input:{ command: process.argv[1] } };
      console.log(JSON.stringify(j));
    " -- "$cmd" 2>/dev/null)"
    (cd "$cwd" && echo "$payload" | run_with_timeout 30 env "$@" node "$GUARD_JS" 2>/dev/null)
}

# D1: bare `gh issue create` from a main worktree must NOT bare-allow — it must
# reach the gh gate and be blocked by the /issue-create skill-context gate.
test_d1_bare_gh_issue_create_from_main_blocked() {
    local repo; repo="$(setup_main_checkout "d1-main")"
    local out
    out="$(run_bash_guard "gh issue create --title x" "$repo" ENFORCE_WORKTREE=on)"
    if echo "$out" | grep -q '"decision":"block"'; then
        pass "D1: bare gh issue create from main → block (reaches gh skill gate, not bare-allowed)"
    else
        fail "D1: bare gh issue create from main bare-allowed — L202 fast-allow leaked past gh gate ($out)"
    fi
}
test_d1_bare_gh_issue_create_from_main_blocked

# D2: sanctioned `ISSUE_CREATE_SKILL=1 gh issue create` from main → allow.
# Confirms the block in D1 is the skill gate specifically, not a blanket gh
# block — the gh gate is genuinely reached and evaluated.
test_d2_sanctioned_gh_issue_create_from_main_allowed() {
    local repo; repo="$(setup_main_checkout "d2-main")"
    local out
    out="$(run_bash_guard "ISSUE_CREATE_SKILL=1 gh issue create --title x" "$repo" ENFORCE_WORKTREE=on)"
    if echo "$out" | grep -q '"decision":"block"'; then
        fail "D2: sanctioned gh issue create from main should allow, got block ($out)"
    else
        pass "D2: sanctioned ISSUE_CREATE_SKILL=1 gh issue create from main → allow"
    fi
}
test_d2_sanctioned_gh_issue_create_from_main_allowed

# D3 (review C1): a NON-issue-create gh write (`gh pr merge`) must reach the gh
# session-scope gate at enforce-worktree.js:246 rather than being fast-allowed at
# L202. We exercise this by running it from a NON-git directory: there `repoRoot`
# is null, so the gate's `if (!detected)` branch (L281) blocks with "cannot
# determine repo root". That block message is ONLY reachable from inside the
# `if (isGhWriteCommand(ir))` block — i.e. it proves isGhWriteCommand returned
# true and the command entered the gh session-scope gate. If L202 had
# fast-allowed instead, the decision would be a bare allow {} with no reason.
#
# Green both sides: pre-fix classify("gh pr merge")="write" → L202 no fast-allow
# → gate reached → block. Post-fix classify="read" but the L202
# `!isGhWriteCommand(ir)` exception keeps it reaching the gate → same block. This
# is exactly the C1 regression: it locks in that a non-issue-create gh write
# still hits the session-scope gate after the retire.
#
# FINDING (review C1 hypothesis correction): the gate keys session scope on the
# CWD repo root (getSessionRepoRoots + repoRoot=findRepoRootForBash), NOT on the
# gh `-R owner/repo` target. `gh pr merge -R otherowner/otherrepo` from an
# in-session cwd is ALLOWED — the -R target does not participate in scope. So the
# "target repo not in sessionRoots" framing does not apply; the reachable
# self-contained block is the non-git-dir "cannot determine repo root" path.
test_d3_non_issue_create_gh_write_reaches_session_gate() {
    # Non-git directory: no repoRoot resolves → gate's !detected branch fires.
    local nongit; nongit="$(node -e "
      const os=require('os'),path=require('path'),fs=require('fs');
      const d=path.join(os.tmpdir(),'fix1391-d3-'+process.pid).replace(/\\\\/g,'/');
      fs.mkdirSync(d,{recursive:true}); console.log(d);
    " 2>/dev/null)"
    [ -z "$nongit" ] && { skip "D3: could not create non-git fixture dir"; return; }
    local out
    out="$(run_bash_guard "gh pr merge 5" "$nongit" ENFORCE_WORKTREE=on)"
    rm -rf "$nongit"
    if echo "$out" | grep -q '"decision":"block"' && echo "$out" | grep -q 'cannot determine repo root'; then
        pass "D3: non-issue-create gh write (gh pr merge) from non-git dir → blocked at gh session-scope gate (reached L246, not L202 fast-allow)"
    else
        fail "D3: gh pr merge did not reach the gh session-scope gate — bare-allowed or wrong block reason ($out)"
    fi
}
test_d3_non_issue_create_gh_write_reaches_session_gate

# SKIPPED: out-of-session gh write from a LINKED worktree blocked at the gh
#   session-scope gate's !sessionRoots.has(detected) branch (enforce-worktree.js:289).
# Because: D3 above reaches the gate via the sibling !detected branch (L281) with
#   a self-contained non-git fixture. Exercising the DISTINCT !sessionRoots.has()
#   branch (L289) needs a real repo whose CWD root resolves but is deliberately
#   excluded from getSessionRepoRoots — impossible in a single-process fixture,
#   because getSessionRepoRoots always adds the CWD repo root (session-scope.js:32-33),
#   so any real git cwd is by construction in scope. Producing an out-of-session
#   detected root requires the live hook's payload-derived-path wiring (issue #321)
#   or ENFORCE_WORKTREE_ADDITIONAL_REPOS pointing elsewhere while cwd is a repo NOT
#   auto-added — a state the current getSessionRepoRoots contract cannot manufacture
#   in-process. That multi-repo/session-root wiring is covered by refactor-1045 R-20
#   and is orthogonal to the #1391 gate/L202 regression under test here.
# L3 gap: only a live claude -p session with real ADDITIONAL_REPOS env + payload-
#   derived paths proves the !sessionRoots.has(detected) branch fires across repos
#   under the true hook dispatch.

echo "=== Section E: retire proof (fail-before-fix) ==="
# These prove the kind:"gh" retire actually happened. Current source (group
# still present, STRIP_KINDS still has "gh") makes the structural + classify
# rows FAIL now; they pass only after the retire. The isGhWriteIR rows are green
# both sides (isGhWriteIR is already the SSOT — retire does not change it).
#
# C2 structural rows (E1/E2) require patterns.js and assert on its exports.
# C2 classify rows (E3, E-C1a, E-C1c) expect "read": pre-retire classify still
#   matches the kind:"gh" group → "write" → these FAIL now (correct fbf), pass
#   after retire.
# C1 pairs (E-C1a/E-C1b for gh pr merge; E-C1c/E-C1d for gh release delete):
#   together prove the L202 `!isGhWriteCommand` exception is BOTH necessary
#   (classify no longer returns "write" after retire → fast-allow would fire)
#   AND sufficient (isGhWriteIR still true → the gate is still reached) for a
#   non-issue-create gh write, not just issue-create.

# E1: WRITE_PATTERNS contains NO entry with kind === "gh".
e1_gh_pattern_count() {
    node -e "const {WRITE_PATTERNS}=require('${_AGENTS_DIR_NODE}/hooks/lib/bash-write-patterns/patterns'); process.stdout.write(String(WRITE_PATTERNS.filter(p => p.kind === 'gh').length))" 2>/dev/null
}
assert_eq "E1: WRITE_PATTERNS has zero kind:gh entries" "0" "$(e1_gh_pattern_count)"

# E2: STRIP_KINDS does NOT contain "gh".
e2_strip_kinds_has_gh() {
    node -e "const {STRIP_KINDS}=require('${_AGENTS_DIR_NODE}/hooks/lib/bash-write-patterns/patterns'); process.stdout.write(String(STRIP_KINDS.has('gh')))" 2>/dev/null
}
assert_eq "E2: STRIP_KINDS does not contain gh" "false" "$(e2_strip_kinds_has_gh)"

# E3: classify("gh issue create --title x") === "read" (was "write" pre-retire).
assert_eq "E3: classify(gh issue create) === read (post-retire)" "read" "$(classify_ir 'gh issue create --title x')"
# E4: isGhWriteIR("gh issue create --title x") === true (SSOT retained).
assert_eq "E4: isGhWriteIR(gh issue create) === true" "true" "$(gh_write_ir 'gh issue create --title x')"

# C1 — gh pr merge (non-issue-create gh write).
# E-C1a (necessary): classify === "read" after retire → without the L202
#   exception, fast-allow would fire → gate never reached. FAILs now ("write").
assert_eq "E-C1a: classify(gh pr merge 5) === read (post-retire → fast-allow would fire without L202 exc)" "read" "$(classify_ir 'gh pr merge 5')"
# E-C1b (sufficient): isGhWriteIR === true → the L202 !isGhWriteCommand exception
#   still recognizes it → the gate IS reached. Green both sides.
assert_eq "E-C1b: isGhWriteIR(gh pr merge 5) === true (L202 exc reaches gate)" "true" "$(gh_write_ir 'gh pr merge 5')"

# C1 — gh release delete v1 (second non-issue-create gh write).
assert_eq "E-C1c: classify(gh release delete v1) === read (post-retire)" "read" "$(classify_ir 'gh release delete v1')"
assert_eq "E-C1d: isGhWriteIR(gh release delete v1) === true (L202 exc reaches gate)" "true" "$(gh_write_ir 'gh release delete v1')"

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"

[ "$FAIL" -gt 0 ] && exit 1
exit 0
