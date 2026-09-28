#!/usr/bin/env bash
# tests/hooks/feature-canary5-6git/commit2-green-retire.sh
# Tests: hooks/lib/bash-write-patterns/patterns.js, hooks/lib/bash-write-patterns/classify.js, hooks/lib/bash-write-targets.js, hooks/enforce-worktree.js
# Tags: enforce-worktree, classify, green-retire, write-patterns, ir-predicate, scope:issue-specific, hook-registration, pwsh-not-required
#
# Commit 2 — retire the green group (posix-redir + pwsh + rm/cp/mv): structure
# counts, green IR predicates, classify → read, interpreter-c guard, L2 blocks.
# L3 gap (what this test does NOT catch):
# - real PreToolUse dispatch only fires in a live claude -p session (these L2 cases drive node enforce-worktree.js via stdin JSON)
# - ADDITIONAL_REPOS / payload-derived path + Windows backslash normalization differ from in-process fixtures
# Closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight via bin/check-verification-gate.sh category: hook-registration

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

bq_hdr "=== ST: WRITE_PATTERNS / STRIP_KINDS structure (RED-pending-impl) ==="
bq_row "ST1 WRITE_PATTERNS posix-redir count == 0" "0" kind_count posix-redir
bq_row "ST2 WRITE_PATTERNS pwsh count == 0"        "0" kind_count pwsh
bq_row "ST3 WRITE_PATTERNS file-op count == 0"     "0" kind_count file-op
bq_row "ST4 STRIP_KINDS has no posix-redir"        "false" strip_has posix-redir
bq_row "ST5 STRIP_KINDS has no pwsh"               "false" strip_has pwsh
bq_row "ST6 STRIP_KINDS has no file-op"            "false" strip_has file-op

bq_hdr "=== PR: green fast-allow IR predicates (RED-pending-impl) ==="
# isPosixRedirWriteIR — true for write redirect / tee; FALSE for read redirect
# and (regression pin) /dev/null-only redirect.
bq_table green isPosixRedirWriteIR <<'POSIX_TABLE'
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
bq_table green isPwshWriteIR <<'PWSH_TABLE'
PW1 Set-Content true^Set-Content /tmp/foo -Value x^true
PW2 Out-File true^Out-File -FilePath /tmp/foo^true
PW3 plain read false^cat /tmp/foo^false
PW4 rm not pwsh false^rm /tmp/foo^false
PWSH_TABLE

# isFileOpWriteIR — true for rm/cp/mv, false for others.
bq_table green isFileOpWriteIR <<'FILEOP_TABLE'
FO1 rm true^rm /tmp/foo^true
FO2 cp true^cp a /tmp/dest^true
FO3 mv true^mv a /tmp/dest^true
FO4 plain read false^cat /tmp/foo^false
FO5 redirect not file-op false^echo x > /tmp/foo^false
FILEOP_TABLE

bq_hdr "=== CL: classify fail-before-fix (RED-pending-impl) ==="
# After the green retire these classify to "read" (were "write"). The fast-allow
# IR exceptions keep them reaching the scope pipeline.
bq_table classify <<'CL_TABLE'
CL1 classify rm → read^rm /f^read
CL2 classify cp → read^cp a b^read
CL3 classify redirect → read^echo x > f^read
CL4 classify Set-Content → read^Set-Content f -Value x^read
CL_TABLE

bq_hdr "=== SANITY: file-op commands classify 'read' post-canary-7 retire ==="
# canary-7 retired sed-inplace..bunzip2 from WRITE_PATTERNS into IR predicates.
# classify() returns "read"; isExtendedFileOpWriteIR handles detection at hook level.
bq_table classify <<'SAN_TABLE'
SAN1 sed -i classify read post-canary-7^sed -i s/a/b/ f^read
SAN2 touch classify read post-canary-7^touch f^read
SAN3 chmod classify read post-canary-7^chmod +x f^read
SAN_TABLE

bq_hdr "=== IC: isReadOnlyInterpreterC write-verb inner-body guard (RED-pending-impl) ==="
# After rm/cp/mv leave WRITE_PATTERNS, `bash -c 'rm /f'` would demote to read →
# the Commit-2 guard rejects write-verb inner bodies (isReadOnlyInterpreterC false).
bq_table ro_interp_c <<'IC_TABLE'
IC1 bash -c rm body → not read-only^bash -c "rm /f"^false
IC2 bash -c cp body → not read-only^bash -c "cp a b"^false
IC3 bash -c mv body → not read-only^bash -c "mv a b"^false
IC4 bash -c tee body → not read-only^bash -c "echo x | tee /f"^false
IC5 bash -c redirect body → not read-only^bash -c "echo x > /f"^false
IC7 bash -c cat redirect body → not read-only^bash -c "cat f > out"^false
IC8 bash -c echo tee body → not read-only^bash -c "echo hi | tee out"^false
IC_TABLE
# Read body still demotes to read (PASS now — preserved).
bq_row "IC6 read body still demotes to read" "true" ro_interp_c 'bash -c "cd x && git status"'
# /dev/null contrast (step 14): a redirect whose only target is /dev/null is NOT
# a write, so the body stays read-eligible — the guard keys on the redirect
# TARGET, not the mere presence of a redirect operator.
bq_row "IC9 bash -c echo x > /dev/null body → read-only (dev/null excluded)" "true" ro_interp_c 'bash -c "echo x > /dev/null"'

bq_hdr "=== L2: hook-boundary green retire (RED-pending / preservation) ==="
# MAIN-worktree green writes into an in-scope repo must still BLOCK via the
# fast-allow IR exception routing them to the scope pipeline (L2-7 needs the
# interpreter-c guard).
TMP_ROOT="$(mk_tmp_root c2)"
trap 'rm -rf "$TMP_ROOT"' EXIT
REPO="$(setup_main_checkout "$TMP_ROOT" main)"
OUT_REPO="$(setup_main_checkout "$TMP_ROOT" outrepo)"
[ -z "$REPO" ] && { bq_flush; skip "L2 fixture unavailable"; report_totals; exit "$FAIL"; }

bq_row "L2-1 rm in-scope main → block"          block guard "$REPO" 'rm README.md'
bq_row "L2-2 cp in-scope main → block"          block guard "$REPO" 'cp README.md dst.md'
bq_row "L2-3 echo-redirect in-scope main → block" block guard "$REPO" 'echo x > README.md'
bq_row "L2-4 Set-Content in-scope main → block" block guard "$REPO" 'Set-Content README.md -Value x'
bq_row "L2-7 bash -c rm in-scope main → block (interpreter-c guard)" block guard "$REPO" 'bash -c "rm README.md"'

# Out-of-session ALLOW: a green write provably under plans-dir, issued from a
# NON-git CWD, is allowed via areAllBashTargetsUnderPlansDir (#878). A bare /tmp
# target from non-git CWD is fail-closed DENIED, so plans-dir is the reachable
# out-of-session-allow proxy (see fix-1391 Section D SKIP note).
NONGIT="$(mk_tmp_root c2-nongit)"
PLANS_DIR="$(run_with_timeout 30 node -e 'try{const{getWorkflowPlansDir}=require(process.argv[1]);process.stdout.write(getWorkflowPlansDir())}catch(e){process.stdout.write("")}' -- "${WT_NODE}/hooks/lib/workflow-plans-dir" 2>/dev/null)"
if [ -n "$PLANS_DIR" ]; then
  bq_row "L2-5 rm plans-dir target from non-git CWD → allow (out-of-session)" allow guard "$NONGIT" "rm $PLANS_DIR/canary56-oos.tmp"
  bq_flush
else
  bq_flush
  skip "L2-5 plans-dir unavailable — cannot exercise out-of-session allow path"
fi
rm -rf "$NONGIT"

report_totals
exit "$FAIL"
