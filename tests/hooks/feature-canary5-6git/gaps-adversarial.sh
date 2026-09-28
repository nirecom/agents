#!/usr/bin/env bash
# tests/hooks/feature-canary5-6git/gaps-adversarial.sh
# Tests: hooks/lib/bash-write-patterns/segment-utils.js, hooks/lib/bash-write-patterns/patterns.js, hooks/lib/bash-write-patterns/git-write-ir.js, hooks/lib/bash-write-patterns/classify.js, hooks/lib/bash-write-targets.js, hooks/enforce-worktree/git-repo-detection.js, hooks/enforce-worktree/bash-write-scope.js, hooks/enforce-worktree.js
# Tags: enforce-worktree, git-write, wrapper-peel, interpreter-c, security, scope:issue-specific, hook-registration, pwsh-not-required
# Adversarial re-review gap closures after retiring the broad \bgit\b regex:
# GAP 3 wrapper/env git forms, GAP 1+2 interpreter-c inner writes, GAP 4
# --work-tree/--git-dir parsing, MEDIUM SSOT / bare-string guard, FIX 1-3.
# L3 gap (every L2 case): real PreToolUse dispatch only fires in a live claude -p
# session; live ADDITIONAL_REPOS / payload paths / backslash normalization differ.
# Closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight via bin/check-verification-gate.sh category: hook-registration.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# GAP 3 — `command git`, `env -u X git`, `env -i git`, `nice git`, `nohup git`
# were MISSED by the pre-fix resolver → the git write fast-allowed (L1).
bq_hdr "=== GAP3: isGitWriteIR wrapper/env variants (L1) ==="
bq_table git_write <<'G3_TABLE'
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

# GAP 3 orthogonality: the green file-op predicate shares the resolver (CPR-ORTH).
bq_hdr "=== GAP3b: green file-op predicate wrapper coverage (L1) ==="
bq_table green isFileOpWriteIR <<'G3B_TABLE'
G3b.1 command rm f^command rm f^true
G3b.2 env -u X rm f^env -u X rm f^true
G3b.3 nice cp a b^nice cp a b^true
G3b.n1 command cat f → not file-op^command cat f^false
G3B_TABLE

# GAP 1+2 — ro_interp_c is "true" only when EVERY inner segment is genuinely read.
bq_hdr "=== GAP1+2: isReadOnlyInterpreterC inner-body write detection (L1) ==="
bq_table ro_interp_c <<'IC_TABLE'
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

# GAP 4 — parseGitPathFlag extracts --work-tree / --git-dir (separated + attached)
# so a git write is scoped to THAT repo. Non-empty check: the drive-letter form
# of the path differs by platform, so only presence is asserted.
bq_hdr "=== GAP4: parseGitPathFlag --work-tree / --git-dir extraction (L1) ==="
bq_row "GAP4.1 --work-tree=<path> attached" "true" ppf_nonempty 'git --work-tree=/other commit' --work-tree
bq_row "GAP4.2 --work-tree <path> separated" "true" ppf_nonempty 'git --work-tree /other commit' --work-tree
bq_row "GAP4.3 --git-dir=<path> attached" "true" ppf_nonempty 'git --git-dir=/other/.git commit' --git-dir
bq_row "GAP4.4 --git-dir <path> separated" "true" ppf_nonempty 'git --git-dir /other/.git commit' --git-dir
bq_row "GAP4.n1 no flag → null" "null" ppf 'git commit' --work-tree
# Boundary: the flag after a sequencing operator (different command) must not leak.
bq_row "GAP4.n2 flag after && not attributed to git → null" "null" ppf 'git status && rm --work-tree=/x f' --work-tree

# MEDIUM (SSOT) — git-write-ir.js derives GIT_VALUE_TAKING_GLOBAL_FLAGS from the
# imported FLAGS_WITH_ARG (#1401), never re-declaring it (CPR-SSOT).
bq_hdr "=== MEDIUM SSOT: value-taking git global flag set (L1) ==="
bq_row "SSOT.1 git-write-ir imports FLAGS_WITH_ARG (no re-declare)" "true" ssot_src
# --config-env must be in the shared set (C2 separated form).
bq_row "SSOT.2 --config-env separated form detected (C2)" "true" git_write 'git --config-env core.hooksPath=VAR commit'

# MEDIUM (bare-string guard) — a bare string target (typed-contract violation)
# must not throw; normalizeTarget coerces it to "ancestor".
bq_hdr "=== MEDIUM bare-string guard: no fail-open / no throw (L1) ==="
bq_row "BS.1 bare-string outside-scope does not throw" "true" bs_outside /some/outside/path/f
bq_row "BS.2 bare-string under-plans does not throw" "true" bs_plans /tmp/x

# L2 hook-boundary: wrapper/env/interpreter git writes and env-prefix file-op
# writes from the MAIN worktree must reach the main-checkout block.
bq_hdr "=== L2: wrapper/interpreter writes from MAIN worktree → BLOCK ==="
TMP_ROOT="$(mk_tmp_root gaps)"
trap 'rm -rf "$TMP_ROOT"' EXIT
REPO="$(setup_main_checkout "$TMP_ROOT" main)"
[ -z "$REPO" ] && { bq_flush; skip "L2 fixture unavailable"; report_totals; exit "$FAIL"; }
echo "src" > "$TMP_ROOT/main/src.txt"

bq_row "L2.1 command git commit from main → block" block guard "$REPO" 'command git commit --allow-empty -m x'
bq_row "L2.2 env -u X git commit from main → block" block guard "$REPO" 'env -u X git commit --allow-empty -m x'
bq_row "L2.3 bash -c git status && git commit from main → block" block guard "$REPO" 'bash -c "git status && git commit --allow-empty -m x"'
bq_row "L2.4 bash -c FOO=1 rm in-scope from main → block" block guard "$REPO" 'bash -c "FOO=1 rm src.txt"'
# FIX 1: an unrecognized arg-taking wrapper flag must NOT hide the wrapped write.
bq_row "L2.5 env -Z val git commit from main → block (FIX1 safety net)" block guard "$REPO" 'env -Z val git commit --allow-empty -m x'
bq_row "L2.6 stdbuf -Z git commit from main → block (FIX1 safety net)" block guard "$REPO" 'stdbuf -Z git commit --allow-empty -m x'

bq_hdr "=== L2 controls: read-only forms → ALLOW (no over-block) ==="
bq_row "C.1 command git status from main → allow" allow guard "$REPO" 'command git status'
bq_row "C.2 bash -c cd d && cat from main → allow" allow guard "$REPO" 'bash -c "cd d && cat README.md"'
bq_row "C.3 nice git log from main → allow" allow guard "$REPO" 'nice git log'

# FIX 1 — an undeclared arg-taking wrapper option triggers a fail-closed AMBIGUOUS
# peel-bail; the wrappedWriteVerbScan safety net still catches `<wrapper> git <wv>`.
bq_hdr "=== FIX1: wrapper arg-flag robustness — isGitWriteIR (L1) ==="
bq_table git_write <<'F1_TABLE'
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

bq_hdr "=== FIX1b: wrapper arg-flag robustness — isFileOpWriteIR (L1) ==="
bq_table green isFileOpWriteIR <<'F1B_TABLE'
F1b.1 stdbuf -oL rm f^stdbuf -oL rm f^true
F1b.2 unrecognized stdbuf -Z rm safety net^stdbuf -Z rm f^true
F1b.3 unrecognized env -Z rm safety net^env -Z val rm f^true
F1b.n1 env -Z val cat f → not file-op (no over-block)^env -Z val cat f^false
F1B_TABLE

# FIX 2 — a git self-target is never satisfiable by a file-EXCLUDE glob: a broad
# `**` must NOT mark `<excluded write> && git commit` all-excluded → still BLOCK.
bq_hdr "=== FIX2: sequenced git self-target vs broad file-EXCLUDE (L1) ==="
bq_row "FIX2.1 seq excluded-file && git commit, broad ** → not-all-excluded (block)" \
  false ese 'cp src .worktree-backup/x/f && git commit -m x' '["**"]' "$REPO"
# Control: pure file-op sequence genuinely all-excluded → true (no over-block).
bq_row "FIX2.C1 pure file-op seq all-excluded → true (no over-block)" \
  true ese 'cp a .worktree-backup/x/f && rm .worktree-backup/x/g' '["**"]' "$REPO"

# FIX 3 — normalizeTarget fail-closed: an object missing/with-nonstring `path`
# must NOT fail-open to "outside scope".
bq_hdr "=== FIX3: normalizeTarget malformed-target fail-closed (L1) ==="
bq_row "FIX3.1 malformed target (no path) → not-all-outside-scope" false outside_json '[{"resolveVia":"self"}]' '["/x"]'
bq_row "FIX3.2 malformed target (nonstring path) → not-all-outside-scope" false outside_json '[{"resolveVia":"self","path":123}]' '["/x"]'
bq_row "FIX3.3 null target → not-all-outside-scope" false outside_json '[null]' '["/x"]'
bq_row "FIX3.4 malformed target → not-all-under-plans-dir" false plans_json '[{"resolveVia":"self"}]'
# Control: a valid outside-scope target still resolves to outside (no over-block).
bq_row "FIX3.C1 valid outside-scope self target → all-outside (no over-block)" true outside_json '[{"resolveVia":"self","path":"/other/repo"}]' '["/x"]'
bq_flush

report_totals
exit "$FAIL"
