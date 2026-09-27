# Scope, failure and disk cases for hooks/block-case-markers.js (#2388).
# Sourced by tests/hooks/feature-2388-block-case-markers.sh; shares its helpers.
# shellcheck source=tests/lib/harness.sh
source "$AGENTS_DIR/tests/lib/harness.sh"

echo ""
echo "=== scope ==="

case_begin "existing-head-file-approves" "hooks/block-case-markers.js"
# Files already in HEAD are out of scope (existing-file debt is #2372).
mkpayload Edit "$REPO_M" "$REPO_M/tests/hooks/existing.sh" "old_string=@$BODIES/old-begin-a.txt" "new_string=@$BODIES/new-begin-a-indented.txt"
hk_run
assert_decision "existing-head-file-approves" approve
case_end

case_begin "env-file-off-still-blocks" "hooks/block-case-markers.js"
# The gate has no disable switch: an off value in the config dir .env is ignored.
printf 'CASE_MARKERS_ENFORCE=off\n' > "$CFG_DIR/.env"
mkpayload Write "$REPO_M" "$REPO_M/tests/hooks/new-env-off.sh" "content=@$BODIES/missing.sh"
hk_run
rm -f "$CFG_DIR/.env"
assert_decision "env-file-off-still-blocks" block
case_end

case_begin "non-entrypoint-path-approves" "hooks/block-case-markers.js"
for rel in tests/hooks/suite/sub.sh tests/lib/extra.sh tests/run-all.sh tests/_archive/old.sh tests/hooks/x.Tests.ps1 bin/tool.sh; do
  mkpayload Write "$REPO_M" "$REPO_M/$rel" "content=@$BODIES/missing.sh"
  hk_run
  assert_decision "non-entrypoint-path-approves $rel" approve
done
case_end

case_begin "no-harness-repo-approves" "hooks/block-case-markers.js"
mkpayload Write "$REPO_NH_M" "$REPO_NH_M/tests/hooks/new-missing.sh" "content=@$BODIES/missing.sh"
hk_run
assert_decision "no-harness-repo-approves" approve
case_end

case_begin "single-path-approves" "hooks/block-case-markers.js"
mkpayload Write "$REPO_M" "$REPO_M/tests/hooks/new-single.sh" "content=@$BODIES/single-path.sh"
hk_run
assert_decision "single-path-approves" approve
case_end

echo ""
echo "=== failure (fail-open) ==="

case_begin "old-string-absent-approves" "hooks/block-case-markers.js"
# The Edit would fail anyway; with no post-edit content the hook cannot judge.
P="$(untracked tests/hooks/absent-old.sh)"
mkpayload Edit "$REPO_M" "$P" "old_string=NO_SUCH_TEXT" "new_string=if true; then"
hk_run
assert_decision "old-string-absent-approves" approve
case_end

case_begin "checker-missing-approves" "hooks/block-case-markers.js"
# A copy of the hook whose sibling bin/check-case-markers.sh does not exist.
NOCHK="$TMPBASE/nochk"
mkdir -p "$NOCHK/hooks"
cp -R "$AGENTS_DIR/hooks/lib" "$NOCHK/hooks/lib"
if [ -f "$HOOK" ]; then
  cp "$HOOK" "$NOCHK/hooks/block-case-markers.js"
fi
HK_HOOK="$NOCHK/hooks/block-case-markers.js"
mkpayload Write "$REPO_M" "$REPO_M/tests/hooks/new-nochk.sh" "content=@$BODIES/missing.sh"
hk_run
HK_HOOK="$HOOK"
assert_decision "checker-missing-approves" approve
assert_eq "$HK_RC" "0"
case_end

case_begin "malformed-stdin-approves" "hooks/block-case-markers.js"
printf 'not json {' > "$PAYLOAD_FILE"
hk_run
assert_decision "malformed-stdin-approves" approve
assert_eq "$HK_RC" "0"
case_end

echo ""
echo "=== disk ==="

case_begin "target-untouched" "hooks/block-case-markers.js"
P="$(untracked tests/hooks/untouched.sh)"
BEFORE="$(snap_file "$REPO/tests/hooks/untouched.sh")"
mkpayload Edit "$REPO_M" "$P" "old_string=@$BODIES/old-begin-a.txt" "new_string=@$BODIES/new-begin-a-indented.txt"
hk_run
assert_decision "target-untouched" block
assert_eq "$(snap_file "$REPO/tests/hooks/untouched.sh")" "$BEFORE"
mkpayload Write "$REPO_M" "$REPO_M/tests/hooks/never-created.sh" "content=@$BODIES/missing.sh"
hk_run
assert_eq "$(snap_file "$REPO/tests/hooks/never-created.sh")" "absent"
case_end

case_begin "tmp-cleaned" "hooks/block-case-markers.js"
# os.tmpdir() is pointed at a fixture dir; the per-run temp copy must be gone.
TMPC="$TMPBASE/tmp-clean"
mkdir -p "$TMPC"
TMPC_M="$(np "$TMPC")"
mkpayload Write "$REPO_M" "$REPO_M/tests/hooks/new-tmp.sh" "content=@$BODIES/missing.sh"
hk_run "TMPDIR=$TMPC_M" "TMP=$TMPC_M" "TEMP=$TMPC_M"
assert_decision "tmp-cleaned" block
LEFT="$(find "$TMPC" -mindepth 1 -print -quit)"
assert_eq "$LEFT" ""
case_end
