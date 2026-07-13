#!/usr/bin/env bash
# tests/feature-canary5-6git/commit2-green-retire.sh
# Tests: hooks/lib/bash-write-patterns/patterns.js, hooks/lib/bash-write-patterns/classify.js, hooks/lib/bash-write-targets.js, hooks/enforce-worktree.js
# Tags: enforce-worktree, classify, green-retire, write-patterns, ir-predicate, scope:issue-specific, hook-registration, pwsh-not-required
#
# Commit 2 — retire the green group (posix-redir 2 + pwsh 7 from WRITE_PATTERNS
# and STRIP_KINDS; rm/cp/mv from WRITE_PATTERNS only).
# RED-pending-impl (fail-before-fix):
#   - structural counts (posix-redir/pwsh = 0, file-op = 11) FAIL now (entries
#     still present).
#   - isPosixRedirWriteIR/isPwshWriteIR/isFileOpWriteIR rows FAIL now (functions
#     not exported yet — bridge emits ERROR:not-exported).
#   - classify(rm/cp/redirect/Set-Content) === "read" rows FAIL now (still
#     "write" pre-retire); pass after removal.
#   - isReadOnlyInterpreterC write-verb inner-body guard rows FAIL now (the guard
#     is added in this commit; pre-impl `bash -c "rm /f"` still classifies its
#     body via WRITE_PATTERNS so it does not demote — actually depends, see rows).
# PASS-now: file-op regression pins, read-body demotion, L2 in-scope blocks that
#   are preserved by the fast-allow IR exceptions.
#
# L3 gap (what this test does NOT catch):
# - real PreToolUse dispatch only fires in a live claude -p session (these L2 cases drive node enforce-worktree.js via stdin JSON)
# - ADDITIONAL_REPOS / payload-derived path + Windows backslash normalization differ from in-process fixtures
# Closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight via bin/check-verification-gate.sh category: hook-registration

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "=== ST: WRITE_PATTERNS / STRIP_KINDS structure (RED-pending-impl) ==="
assert_eq "ST1 WRITE_PATTERNS posix-redir count == 0" "0" "$(kind_count posix-redir)"
assert_eq "ST2 WRITE_PATTERNS pwsh count == 0"        "0" "$(kind_count pwsh)"
assert_eq "ST3 WRITE_PATTERNS file-op count == 11"    "11" "$(kind_count file-op)"
assert_eq "ST4 STRIP_KINDS has no posix-redir"        "false" "$(strip_has posix-redir)"
assert_eq "ST5 STRIP_KINDS has no pwsh"               "false" "$(strip_has pwsh)"
assert_eq "ST6 STRIP_KINDS keeps file-op"             "true"  "$(strip_has file-op)"

echo "=== PR: green fast-allow IR predicates (RED-pending-impl) ==="
# isPosixRedirWriteIR — true for write redirect / tee; FALSE for read redirect
# and (regression pin) /dev/null-only redirect.
while IFS='^' read -r name cmd want; do
  [ -z "$name" ] && continue
  assert_eq "$name" "$want" "$(green_pred isPosixRedirWriteIR "$cmd")"
done <<'POSIX_TABLE'
PR1 redirect write true^echo x > /tmp/foo^true
PR2 tee write true^cat x | tee /tmp/foo^true
PR3 read redirect false^cat < /tmp/foo^false
PR4 /dev/null-only redirect FALSE (regression pin)^echo x >/dev/null^false
PR5 plain read false^ls -la^false
PR-BUG3 sub/dev/null suffix is a real write (exact-match only)^echo x > sub/dev/null^true
PR-BUG3b exact /dev/null stays read^echo x > /dev/null^false
PR-BUG-FD2 FD-to-FD 2>&1 is not a write (regression pin #1436)^ls 2>&1^false
PR-BUG-FD3 output FD-to-FD >&2 is not a write (regression pin #1436)^cmd >&2^false
PR-BUG-FDQ quoted &1 path is a write not FD-dup (regression pin #1436)^echo x > '&1'^true
PR-BUG-FDQ2 quoted &1file path is a write not FD-dup (regression pin #1436)^echo x > '&1file'^true
POSIX_TABLE

# isPwshWriteIR — true for cmdlets, false for non-pwsh.
while IFS='^' read -r name cmd want; do
  [ -z "$name" ] && continue
  assert_eq "$name" "$want" "$(green_pred isPwshWriteIR "$cmd")"
done <<'PWSH_TABLE'
PW1 Set-Content true^Set-Content /tmp/foo -Value x^true
PW2 Out-File true^Out-File -FilePath /tmp/foo^true
PW3 plain read false^cat /tmp/foo^false
PW4 rm not pwsh false^rm /tmp/foo^false
PWSH_TABLE

# isFileOpWriteIR — true for rm/cp/mv, false for others.
while IFS='^' read -r name cmd want; do
  [ -z "$name" ] && continue
  assert_eq "$name" "$want" "$(green_pred isFileOpWriteIR "$cmd")"
done <<'FILEOP_TABLE'
FO1 rm true^rm /tmp/foo^true
FO2 cp true^cp a /tmp/dest^true
FO3 mv true^mv a /tmp/dest^true
FO4 plain read false^cat /tmp/foo^false
FO5 redirect not file-op false^echo x > /tmp/foo^false
FILEOP_TABLE

echo "=== CL: classify fail-before-fix (RED-pending-impl) ==="
# After the green retire these classify to "read" (were "write"). The fast-allow
# IR exceptions keep them reaching the scope pipeline.
while IFS='^' read -r name cmd want; do
  [ -z "$name" ] && continue
  assert_eq "$name" "$want" "$(classify_ir "$cmd")"
done <<'CL_TABLE'
CL1 classify rm → read^rm /f^read
CL2 classify cp → read^cp a b^read
CL3 classify redirect → read^echo x > f^read
CL4 classify Set-Content → read^Set-Content f -Value x^read
CL_TABLE

echo "=== SANITY: file-op regression pins that survive the retire (PASS now) ==="
# sed-inplace..bunzip2 remain in WRITE_PATTERNS → still classify write.
while IFS='^' read -r name cmd want; do
  [ -z "$name" ] && continue
  assert_eq "$name" "$want" "$(classify_ir "$cmd")"
done <<'SAN_TABLE'
SAN1 sed -i still write^sed -i s/a/b/ f^write
SAN2 touch still write^touch f^write
SAN3 chmod still write^chmod +x f^write
SAN_TABLE

echo "=== IC: isReadOnlyInterpreterC write-verb inner-body guard (RED-pending-impl) ==="
# After rm/cp/mv leave WRITE_PATTERNS, `bash -c 'rm /f'` inner body would demote
# to read → the wrapper fast-allows. The Commit-2 guard rejects write-verb inner
# bodies so isReadOnlyInterpreterC returns false. These FAIL now (pre-impl the
# body still matches WRITE_PATTERNS OR the guard is absent) and pass after.
while IFS='^' read -r name cmd want; do
  [ -z "$name" ] && continue
  assert_eq "$name" "$want" "$(ro_interp_c "$cmd")"
done <<'IC_TABLE'
IC1 bash -c rm body → not read-only^bash -c "rm /f"^false
IC2 bash -c cp body → not read-only^bash -c "cp a b"^false
IC3 bash -c mv body → not read-only^bash -c "mv a b"^false
IC4 bash -c tee body → not read-only^bash -c "echo x | tee /f"^false
IC5 bash -c redirect body → not read-only^bash -c "echo x > /f"^false
IC7 bash -c cat redirect body → not read-only^bash -c "cat f > out"^false
IC8 bash -c echo tee body → not read-only^bash -c "echo hi | tee out"^false
IC_TABLE
# Read body still demotes to read (PASS now — preserved).
assert_eq "IC6 read body still demotes to read" "true" "$(ro_interp_c 'bash -c "cd x && git status"')"
# /dev/null contrast (step 14): the inner-body redirect guard mirrors the
# extractor's /dev/null exclusion — a redirect whose only target is /dev/null is
# NOT a write, so the body stays read-eligible and may demote to read. This is the
# read counterpart that proves the guard keys on the redirect TARGET, not the mere
# presence of a redirect operator.
assert_eq "IC9 bash -c echo x > /dev/null body → read-only (dev/null excluded)" "true" "$(ro_interp_c 'bash -c "echo x > /dev/null"')"

echo "=== L2: hook-boundary green retire (RED-pending / preservation) ==="
# MAIN-worktree green writes into an in-scope repo must still BLOCK via the
# fast-allow IR exception routing them to the scope pipeline. Pre-impl they block
# because classify()=="write"; post-impl they block via the IR exception. Either
# way the assertion is BLOCK — but pre-impl the interpreter-c row (L2-7) FAILs
# without the guard.
TMP_ROOT="$(mk_tmp_root c2)"
trap 'rm -rf "$TMP_ROOT"' EXIT
REPO="$(setup_main_checkout "$TMP_ROOT" main)"
OUT_REPO="$(setup_main_checkout "$TMP_ROOT" outrepo)"
[ -z "$REPO" ] && { skip "L2 fixture unavailable"; report_totals; exit "$FAIL"; }

assert_l2() {
  local name="$1" cmd="$2" cwd="$3" want="$4"
  local out; out="$(run_bash_guard "$cmd" "$cwd" ENFORCE_WORKTREE=on)"
  local got="allow"; echo "$out" | grep -q '"decision":"block"' && got="block"
  if [ "$got" = "$want" ]; then pass "$name"; else fail "$name — want=$want got=$got ($out)"; fi
}
assert_l2 "L2-1 rm in-scope main → block"          'rm README.md'                 "$REPO" block
assert_l2 "L2-2 cp in-scope main → block"          'cp README.md dst.md'          "$REPO" block
assert_l2 "L2-3 echo-redirect in-scope main → block" 'echo x > README.md'         "$REPO" block
assert_l2 "L2-4 Set-Content in-scope main → block" 'Set-Content README.md -Value x' "$REPO" block
assert_l2 "L2-7 bash -c rm in-scope main → block (interpreter-c guard)" 'bash -c "rm README.md"' "$REPO" block

# Out-of-session ALLOW: a green write whose target is provably under plans-dir,
# issued from a NON-git CWD, is allowed via areAllBashTargetsUnderPlansDir (#878)
# — the reachable out-of-scope allow path in a single-process fixture. A bare
# /tmp target from non-git CWD is fail-closed DENIED (cannot determine repo root),
# so plans-dir is the correct out-of-session-allow proxy (see fix-1391 Section D
# SKIP note: a true out-of-session detected git root cannot be manufactured
# in-process). Pre- and post-retire the decision is ALLOW → this rm still routes
# to the scope pipeline and is allowed only because the target is under plans-dir.
NONGIT="$(mk_tmp_root c2-nongit)"
PLANS_DIR="$(run_with_timeout 30 node -e 'try{const{getWorkflowPlansDir}=require(process.argv[1]);process.stdout.write(getWorkflowPlansDir())}catch(e){process.stdout.write("")}' -- "${WT_NODE}/hooks/lib/workflow-plans-dir" 2>/dev/null)"
if [ -n "$PLANS_DIR" ]; then
  assert_l2 "L2-5 rm plans-dir target from non-git CWD → allow (out-of-session)" "rm $PLANS_DIR/canary56-oos.tmp" "$NONGIT" allow
else
  skip "L2-5 plans-dir unavailable — cannot exercise out-of-session allow path"
fi
node -e 'require("fs").rmSync(process.argv[1],{recursive:true,force:true})' "$NONGIT" 2>/dev/null || true

report_totals
exit "$FAIL"
