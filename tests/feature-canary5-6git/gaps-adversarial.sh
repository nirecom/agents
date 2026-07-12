#!/usr/bin/env bash
# tests/feature-canary5-6git/gaps-adversarial.sh
# Tests: hooks/lib/bash-write-patterns/segment-utils.js, hooks/lib/bash-write-patterns/patterns.js, hooks/lib/bash-write-patterns/git-write-ir.js, hooks/lib/bash-write-patterns/classify.js, hooks/lib/bash-write-targets.js, hooks/enforce-worktree/git-repo-detection.js, hooks/enforce-worktree/bash-write-scope.js, hooks/enforce-worktree.js
# Tags: enforce-worktree, git-write, wrapper-peel, interpreter-c, security, scope:issue-specific, hook-registration, pwsh-not-required
#
# Adversarial security re-review gap closures (net REGRESSIONS from retiring the
# broad \bgit\b WRITE_PATTERNS regex; the IR detectors missed wrapper/env forms
# the regex caught). Four gaps + controls:
#   GAP 3  — isGitWriteIR resolves ALL wrapper/env forms (command/env-flags/nice/
#            nohup) via the shared effective-command resolver.
#   GAP 1+2 — isReadOnlyInterpreterC fails-closed on ANY inner-segment write
#            (multi-segment, env-prefix, wrapper git inside body).
#   GAP 4  — findRepoRootForBash honors --work-tree / --git-dir (sep + attached).
#   MEDIUM — SSOT (GIT_VALUE_TAKING_GLOBAL_FLAGS === parse-git-args FLAGS_WITH_ARG),
#            git self-target vs staged-file EXCLUDE interaction, bare-string guard.
#
# L3 gap (applies to every L2 case): real PreToolUse dispatch only fires in a live
# claude -p session. These L2 cases drive `node hooks/enforce-worktree.js` over
# stdin JSON; live-session ADDITIONAL_REPOS / payload-derived path / Windows
# backslash normalization of model-emitted paths differ from in-process fixtures.
# Closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: hook-registration.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# ---------------------------------------------------------------------------
# GAP 3 — isGitWriteIR wrapper/env variants (L1).
# The pre-fix resolver only handled `git` / `env VAR=val git` / `VAR=val git`.
# `command git`, `env -u X git`, `env -i git`, `nice git`, `nohup git` were
# MISSED → the git write fast-allowed past the main-worktree guard.
# ---------------------------------------------------------------------------
echo "=== GAP3: isGitWriteIR wrapper/env variants (L1) ==="
while IFS='^' read -r name cmd want; do
  [ -z "$name" ] && continue
  assert_eq "$name" "$want" "$(git_write_ir "$cmd")"
done <<'G3_TABLE'
G3.1 command git commit^command git commit -m x^true
G3.2 env -u X git commit^env -u X git commit -m x^true
G3.3 env -i git commit^env -i git commit -m x^true
G3.4 nice git push^nice git push^true
G3.5 nohup git commit^nohup git commit -m x^true
G3.6 env VAR=1 git commit (regression)^env VAR=1 git commit -m x^true
G3.7 VAR=1 git commit (regression)^VAR=1 git commit -m x^true
G3.8 plain git commit (regression)^git commit -m x^true
G3.n1 command git status → read^command git status^false
G3.n2 env -u X git log → read^env -u X git log^false
G3.n3 nice git status → read^nice git status^false
G3_TABLE

# GAP 3 orthogonality: the green file-op predicate benefits from the SAME shared
# resolver — wrappers must not hide rm/cp/mv either (CPR-5).
echo "=== GAP3b: green file-op predicate wrapper coverage (L1) ==="
while IFS='^' read -r name cmd want; do
  [ -z "$name" ] && continue
  assert_eq "$name" "$want" "$(green_pred isFileOpWriteIR "$cmd")"
done <<'G3B_TABLE'
G3b.1 command rm f^command rm f^true
G3b.2 env -u X rm f^env -u X rm f^true
G3b.3 nice cp a b^nice cp a b^true
G3b.n1 command cat f → not file-op^command cat f^false
G3B_TABLE

# ---------------------------------------------------------------------------
# GAP 1+2 — isReadOnlyInterpreterC inner-body fail-closed (L1).
# ro_interp_c returns "true" only when EVERY inner segment is genuinely read.
# ---------------------------------------------------------------------------
echo "=== GAP1+2: isReadOnlyInterpreterC inner-body write detection (L1) ==="
while IFS='^' read -r name cmd want; do
  [ -z "$name" ] && continue
  assert_eq "$name" "$want" "$(ro_interp_c "$cmd")"
done <<'IC_TABLE'
IC.1 multi-seg later git write^bash -c "git status && git commit"^false
IC.2 env-prefix hides rm^bash -c "FOO=1 rm f"^false
IC.3 cd then git write^bash -c "cd d && git commit"^false
IC.4 pipe tee then git status^bash -c "echo x | tee f && git status"^false
IC.5 wrapper git inside body^bash -c "command git commit"^false
IC.6 env-flag wrapper inside body^bash -c "env -u X rm f"^false
IC.7 inner write redirect^bash -c "echo x > f"^false
IC.C1 all-read git status && log^bash -c "git status && git log"^true
IC.C2 all-read cd && cat^bash -c "cd d && cat f"^true
IC.C3 dev-null redirect (control)^bash -c "echo x >/dev/null"^true
IC_TABLE

# ---------------------------------------------------------------------------
# GAP 4 — findRepoRootForBash honors --work-tree / --git-dir (L1 path parse).
# parseGitPathFlag extracts the path (separated + attached, quoted + bare) so a
# git write with --git-dir/--work-tree is scoped to THAT repo, not the CWD repo.
# ---------------------------------------------------------------------------
echo "=== GAP4: parseGitPathFlag --work-tree / --git-dir extraction (L1) ==="
parse_path_flag() {
  local cmd="$1" flag="$2"
  run_with_timeout 30 node -e "
    const m=require('${WT_NODE}/hooks/enforce-worktree/git-repo-detection');
    const r=m.parseGitPathFlag(process.argv[1], process.argv[2]);
    process.stdout.write(r===null?'null':String(r));
  " -- "$cmd" "$flag" 2>/dev/null
}
# Attached and separated forms; POSIX-absolute paths (toWindowsPath leaves /x as-is
# off-win32, uppercases drive on win32 — assert on the tail which is stable).
assert_eq "GAP4.1 --work-tree=<path> attached" "true" \
  "$([ -n "$(parse_path_flag 'git --work-tree=/other commit' --work-tree)" ] && echo true || echo false)"
assert_eq "GAP4.2 --work-tree <path> separated" "true" \
  "$([ -n "$(parse_path_flag 'git --work-tree /other commit' --work-tree)" ] && echo true || echo false)"
assert_eq "GAP4.3 --git-dir=<path> attached" "true" \
  "$([ -n "$(parse_path_flag 'git --git-dir=/other/.git commit' --git-dir)" ] && echo true || echo false)"
assert_eq "GAP4.4 --git-dir <path> separated" "true" \
  "$([ -n "$(parse_path_flag 'git --git-dir /other/.git commit' --git-dir)" ] && echo true || echo false)"
assert_eq "GAP4.n1 no flag → null" "null" \
  "$(parse_path_flag 'git commit' --work-tree)"
# Boundary: the flag after a sequencing operator (different command) must not leak.
assert_eq "GAP4.n2 flag after && not attributed to git → null" "null" \
  "$(parse_path_flag 'git status && rm --work-tree=/x f' --work-tree)"

# ---------------------------------------------------------------------------
# MEDIUM (SSOT) — GIT_VALUE_TAKING_GLOBAL_FLAGS is derived from parse-git-args
# FLAGS_WITH_ARG (imported, not re-declared). Assert the two sets are identical
# so drift is impossible (CPR-2). Also assert no hardcoded re-declaration remains.
# ---------------------------------------------------------------------------
echo "=== MEDIUM SSOT: value-taking git global flag set (L1) ==="
# git-write-ir.js (extracted from patterns.js at the 500-line file-split, #1401)
# derives GIT_VALUE_TAKING_GLOBAL_FLAGS from the imported FLAGS_WITH_ARG (SSOT),
# never re-declaring the set — so the two cannot drift (CPR-2).
assert_eq "SSOT.1 git-write-ir imports FLAGS_WITH_ARG (no re-declare)" "true" \
  "$(run_with_timeout 30 node -e "
    const fs=require('fs');
    const src=fs.readFileSync('${WT_NODE}/hooks/lib/bash-write-patterns/git-write-ir.js','utf8');
    const noRedeclare = !/GIT_VALUE_TAKING_GLOBAL_FLAGS\s*=\s*new Set/.test(src);
    const imports = /GIT_VALUE_TAKING_GLOBAL_FLAGS\s*=\s*FLAGS_WITH_ARG/.test(src);
    process.stdout.write(String(noRedeclare && imports));
  " 2>/dev/null)"
# --config-env must be in the shared set (C2: separated form `--config-env k=v git`
# must be skipped so the write subcommand is not missed).
assert_eq "SSOT.2 --config-env separated form detected (C2)" "true" \
  "$(git_write_ir 'git --config-env core.hooksPath=VAR commit')"

# ---------------------------------------------------------------------------
# MEDIUM (bare-string guard) — areAllBashTargetsOutsideSessionScope /
# areAllBashTargetsUnderPlansDir must not fail-open when handed a bare string
# target (typed-contract violation). normalizeTarget coerces to "ancestor".
# ---------------------------------------------------------------------------
echo "=== MEDIUM bare-string guard: no fail-open / no throw (L1) ==="
assert_eq "BS.1 bare-string outside-scope does not throw" "true" \
  "$(run_with_timeout 30 node -e "
    const s=require('${WT_NODE}/hooks/enforce-worktree/bash-write-scope');
    try { s.areAllBashTargetsOutsideSessionScope(['/some/outside/path/f'], new Set()); process.stdout.write('true'); }
    catch(e){ process.stdout.write('THREW'); }
  " 2>/dev/null)"
assert_eq "BS.2 bare-string under-plans does not throw" "true" \
  "$(run_with_timeout 30 node -e "
    const s=require('${WT_NODE}/hooks/enforce-worktree/bash-write-scope');
    try { s.areAllBashTargetsUnderPlansDir(['/tmp/x']); process.stdout.write('true'); }
    catch(e){ process.stdout.write('THREW'); }
  " 2>/dev/null)"

# ---------------------------------------------------------------------------
# L2 hook-boundary (MAIN worktree → BLOCK). Wrapper/env/interpreter git writes
# and env-prefix file-op writes must reach the main-checkout block, not fast-allow.
# ---------------------------------------------------------------------------
echo "=== L2: wrapper/interpreter writes from MAIN worktree → BLOCK ==="
TMP_ROOT="$(mk_tmp_root gaps)"
trap 'rm -rf "$TMP_ROOT"' EXIT
REPO="$(setup_main_checkout "$TMP_ROOT" main)"
[ -z "$REPO" ] && { skip "L2 fixture unavailable"; report_totals; exit "$FAIL"; }
echo "src" > "$TMP_ROOT/main/src.txt"

l2_decision() {
  local cmd="$1" cwd="$2"; shift 2
  local out; out="$(run_bash_guard "$cmd" "$cwd" ENFORCE_WORKTREE=on "$@")"
  echo "$out" | grep -q '"decision":"block"' && { echo block; return; }
  echo allow
}

assert_eq "L2.1 command git commit from main → block" \
  "block" "$(l2_decision 'command git commit --allow-empty -m x' "$REPO")"
assert_eq "L2.2 env -u X git commit from main → block" \
  "block" "$(l2_decision 'env -u X git commit --allow-empty -m x' "$REPO")"
assert_eq "L2.3 bash -c git status && git commit from main → block" \
  "block" "$(l2_decision 'bash -c "git status && git commit --allow-empty -m x"' "$REPO")"
assert_eq "L2.4 bash -c FOO=1 rm in-scope from main → block" \
  "block" "$(l2_decision 'bash -c "FOO=1 rm src.txt"' "$REPO")"
# FIX 1 hook-boundary: unrecognized arg-taking wrapper flag must NOT hide the
# wrapped git write (fail-closed AMBIGUOUS peel-bail + wrappedWriteVerbScan).
assert_eq "L2.5 env -Z val git commit from main → block (FIX1 safety net)" \
  "block" "$(l2_decision 'env -Z val git commit --allow-empty -m x' "$REPO")"
assert_eq "L2.6 stdbuf -Z git commit from main → block (FIX1 safety net)" \
  "block" "$(l2_decision 'stdbuf -Z git commit --allow-empty -m x' "$REPO")"

# ---------------------------------------------------------------------------
# Controls (must NOT over-block). All-read wrappers/interpreters ALLOW.
# ---------------------------------------------------------------------------
echo "=== L2 controls: read-only forms → ALLOW (no over-block) ==="
assert_eq "C.1 command git status from main → allow" \
  "allow" "$(l2_decision 'command git status' "$REPO")"
assert_eq "C.2 bash -c cd d && cat from main → allow" \
  "allow" "$(l2_decision 'bash -c "cd d && cat README.md"' "$REPO")"
assert_eq "C.3 nice git log from main → allow" \
  "allow" "$(l2_decision 'nice git log' "$REPO")"

# ---------------------------------------------------------------------------
# FIX 1 (convergence) — peelWrappers flag-argument robustness.
# A wrapper option that TAKES AN ARGUMENT, if not declared, mis-peels and can
# HIDE the wrapped write verb (BYPASS). Declared arg-taking flags are consumed
# correctly; an UNRECOGNIZED option triggers a fail-closed AMBIGUOUS peel-bail,
# and the wrappedWriteVerbScan safety net still catches `<wrapper> ... git <wv>`.
# ---------------------------------------------------------------------------
echo "=== FIX1: wrapper arg-flag robustness — isGitWriteIR (L1) ==="
while IFS='^' read -r name cmd want; do
  [ -z "$name" ] && continue
  assert_eq "$name" "$want" "$(git_write_ir "$cmd")"
done <<'F1_TABLE'
F1.1 stdbuf -oL attached git commit^stdbuf -oL git commit -m x^true
F1.2 stdbuf -o L separated git commit^stdbuf -o L git commit -m x^true
F1.3 ionice -c 2 git commit^ionice -c 2 git commit -m x^true
F1.4 nice -n 5 git commit^nice -n 5 git commit -m x^true
F1.5 env -S X=1 git commit^env -S "X=1" git commit -m x^true
F1.6 command git commit^command git commit -m x^true
F1.7 env -u X git commit^env -u X git commit -m x^true
F1.8 setsid -w git commit^setsid -w git commit -m x^true
F1.9 nohup git commit^nohup git commit -m x^true
F1.10 unrecognized env -Z arg-taking safety net^env -Z val git commit -m x^true
F1.11 unrecognized stdbuf -Z safety net^stdbuf -Z git commit -m x^true
F1.12 ionice -p pid then git commit^ionice -p 123 git commit -m x^true
F1.n1 command git status → read (no over-block)^command git status^false
F1.n2 nice git log → read (no over-block)^nice git log^false
F1.n3 env -u X git log → read (no over-block)^env -u X git log^false
F1_TABLE

echo "=== FIX1b: wrapper arg-flag robustness — isFileOpWriteIR (L1) ==="
while IFS='^' read -r name cmd want; do
  [ -z "$name" ] && continue
  assert_eq "$name" "$want" "$(green_pred isFileOpWriteIR "$cmd")"
done <<'F1B_TABLE'
F1b.1 stdbuf -oL rm f^stdbuf -oL rm f^true
F1b.2 unrecognized stdbuf -Z rm safety net^stdbuf -Z rm f^true
F1b.3 unrecognized env -Z rm safety net^env -Z val rm f^true
F1b.n1 env -Z val cat f → not file-op (no over-block)^env -Z val cat f^false
F1B_TABLE

# ---------------------------------------------------------------------------
# FIX 2 (convergence) — isEverySegmentExcluded git self-target must NEVER be
# satisfiable by a file-EXCLUDE glob (symmetry with isWriteTargetAllExcluded).
# A broad exclude (`**`) matching the repo root must NOT mark a sequenced
# `<excluded file write> && git commit` as all-excluded → still BLOCK.
# ---------------------------------------------------------------------------
echo "=== FIX2: sequenced git self-target vs broad file-EXCLUDE (L1) ==="
every_seg_excl() {
  local cmd="$1" pats="$2" repo="$3"
  run_with_timeout 30 node -e "
    const {isEverySegmentExcluded}=require('${WT_NODE}/hooks/enforce-worktree/bash-write-scope');
    const {parse}=require('${WT_NODE}/hooks/lib/command-ir');
    process.stdout.write(String(isEverySegmentExcluded(parse(process.argv[1]), process.argv[3], JSON.parse(process.argv[2]))));
  " -- "$cmd" "$pats" "$repo" 2>/dev/null
}
assert_eq "FIX2.1 seq excluded-file && git commit, broad ** → not-all-excluded (block)" \
  "false" "$(every_seg_excl 'cp src .worktree-backup/x/f && git commit -m x' '["**"]' "$REPO")"
# Control: pure file-op sequence genuinely all-excluded → true (no over-block).
assert_eq "FIX2.C1 pure file-op seq all-excluded → true (no over-block)" \
  "true" "$(every_seg_excl 'cp a .worktree-backup/x/f && rm .worktree-backup/x/g' '["**"]' "$REPO")"

# ---------------------------------------------------------------------------
# FIX 3 (convergence) — normalizeTarget fail-closed on malformed typed target.
# An object missing/with-nonstring `path` must NOT fail-open to "outside scope".
# ---------------------------------------------------------------------------
echo "=== FIX3: normalizeTarget malformed-target fail-closed (L1) ==="
assert_eq "FIX3.1 malformed target (no path) → not-all-outside-scope" "false" \
  "$(run_with_timeout 30 node -e "
    const s=require('${WT_NODE}/hooks/enforce-worktree/bash-write-scope');
    process.stdout.write(String(s.areAllBashTargetsOutsideSessionScope([{resolveVia:'self'}], new Set(['/x']))));
  " 2>/dev/null)"
assert_eq "FIX3.2 malformed target (nonstring path) → not-all-outside-scope" "false" \
  "$(run_with_timeout 30 node -e "
    const s=require('${WT_NODE}/hooks/enforce-worktree/bash-write-scope');
    process.stdout.write(String(s.areAllBashTargetsOutsideSessionScope([{resolveVia:'self',path:123}], new Set(['/x']))));
  " 2>/dev/null)"
assert_eq "FIX3.3 null target → not-all-outside-scope" "false" \
  "$(run_with_timeout 30 node -e "
    const s=require('${WT_NODE}/hooks/enforce-worktree/bash-write-scope');
    process.stdout.write(String(s.areAllBashTargetsOutsideSessionScope([null], new Set(['/x']))));
  " 2>/dev/null)"
assert_eq "FIX3.4 malformed target → not-all-under-plans-dir" "false" \
  "$(run_with_timeout 30 node -e "
    const s=require('${WT_NODE}/hooks/enforce-worktree/bash-write-scope');
    process.stdout.write(String(s.areAllBashTargetsUnderPlansDir([{resolveVia:'self'}])));
  " 2>/dev/null)"
# Control: a valid outside-scope target still resolves to outside (no over-block).
assert_eq "FIX3.C1 valid outside-scope self target → all-outside (no over-block)" "true" \
  "$(run_with_timeout 30 node -e "
    const s=require('${WT_NODE}/hooks/enforce-worktree/bash-write-scope');
    process.stdout.write(String(s.areAllBashTargetsOutsideSessionScope([{resolveVia:'self',path:'/other/repo'}], new Set(['/x']))));
  " 2>/dev/null)"

report_totals
exit "$FAIL"
