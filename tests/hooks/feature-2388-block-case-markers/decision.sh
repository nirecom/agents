# Decision + multi-path MultiEdit cases for hooks/block-case-markers.js (#2388).
# Sourced by tests/hooks/feature-2388-block-case-markers.sh; shares its helpers.

echo ""
echo "=== decision ==="

case_begin "write-new-missing-blocks" "hooks/block-case-markers.js"
P="$REPO_M/tests/hooks/new-missing.sh"
mkpayload Write "$REPO_M" "$P" "content=@$BODIES/missing.sh"
hk_run
assert_decision "write-new-missing-blocks" block
assert_eq "$HK_RC" "0"
assert_reason_has "write-new-missing-blocks" "[block-case-markers]"
assert_reason_has "write-new-missing-blocks" "tests/hooks/new-missing.sh"
assert_reason_has "write-new-missing-blocks" "code=MISSING_CASE_MARKERS"
assert_reason_has "write-new-missing-blocks" "skills/_shared/test-design/case-markers.md"
# The checker ran on a temp copy; its path must be rewritten to the repo rel.
assert_reason_lacks "write-new-missing-blocks" "case-markers-"
assert_eq "$(snap_file "$REPO/tests/hooks/new-missing.sh")" "absent"
case_end

case_begin "write-new-malformed-blocks" "hooks/block-case-markers.js"
mkpayload Write "$REPO_M" "$REPO_M/tests/bin/new-malformed.sh" "content=@$BODIES/malformed.sh"
hk_run
assert_decision "write-new-malformed-blocks" block
assert_reason_has "write-new-malformed-blocks" "tests/bin/new-malformed.sh"
assert_reason_has "write-new-malformed-blocks" "code=MALFORMED_CASE_MARKER"
case_end

case_begin "write-new-conforming-approves" "hooks/block-case-markers.js"
mkpayload Write "$REPO_M" "$REPO_M/tests/hooks/new-conforming.sh" "content=@$BODIES/conforming.sh"
hk_run
assert_decision "write-new-conforming-approves" approve
assert_eq "$HK_RC" "0"
case_end

case_begin "write-new-uncertain-approves" "hooks/block-case-markers.js"
# A multi-line quoted string before a marker is only a WARN (rc 0): never block.
mkpayload Write "$REPO_M" "$REPO_M/tests/hooks/new-uncertain.sh" "content=@$BODIES/uncertain.sh"
hk_run
assert_decision "write-new-uncertain-approves" approve
case_end

case_begin "edit-introduces-indent-blocks" "hooks/block-case-markers.js"
P="$(untracked tests/hooks/edit-indent.sh)"
BEFORE="$(snap_file "$REPO/tests/hooks/edit-indent.sh")"
mkpayload Edit "$REPO_M" "$P" "old_string=@$BODIES/old-begin-a.txt" "new_string=@$BODIES/new-begin-a-indented.txt"
hk_run
assert_decision "edit-introduces-indent-blocks" block
assert_reason_has "edit-introduces-indent-blocks" "tests/hooks/edit-indent.sh"
assert_reason_has "edit-introduces-indent-blocks" "code=MALFORMED_CASE_MARKER"
assert_eq "$(snap_file "$REPO/tests/hooks/edit-indent.sh")" "$BEFORE"
case_end

case_begin "multiedit-sequence-blocks" "hooks/block-case-markers.js"
# The second edit only matches after the first is applied: a hook that applied
# edits independently would see old_string absent and fail open.
P="$(untracked tests/hooks/multi-seq.sh)"
mkpayload MultiEdit "$REPO_M" "$P" "e0.old_string=echo b" "e0.new_string=SEQ_STEP" "e1.old_string=SEQ_STEP" "e1.new_string=if true; then"
hk_run
assert_decision "multiedit-sequence-blocks" block
assert_reason_has "multiedit-sequence-blocks" "code=MALFORMED_CASE_MARKER"
case_end

echo ""
echo "=== multi-path MultiEdit ==="

case_begin "multiedit-per-edit-path-new-test-blocks" "hooks/block-case-markers.js"
# Top-level file_path is a non-target; the per-edit path is a new test entrypoint.
P="$(untracked tests/hooks/mp-new.sh)"
mkpayload MultiEdit "$REPO_M" "$REPO_M/README.md" "e0.file_path=$P" "e0.old_string=echo b" "e0.new_string=if true; then"
hk_run
assert_decision "multiedit-per-edit-path-new-test-blocks" block
assert_reason_has "multiedit-per-edit-path-new-test-blocks" "tests/hooks/mp-new.sh"
case_end

case_begin "multiedit-two-files-one-violating-blocks" "hooks/block-case-markers.js"
PA="$(untracked tests/hooks/two-a.sh)"
PB="$(untracked tests/hooks/two-b.sh)"
mkpayload MultiEdit "$REPO_M" "$PA" "e0.file_path=$PA" "e0.old_string=echo b" "e0.new_string=if true; then" "e1.file_path=$PB" "e1.old_string=echo b" "e1.new_string=echo bb"
hk_run
assert_decision "multiedit-two-files-one-violating-blocks" block
assert_reason_has "multiedit-two-files-one-violating-blocks" "tests/hooks/two-a.sh"
assert_reason_lacks "multiedit-two-files-one-violating-blocks" "tests/hooks/two-b.sh"
case_end

case_begin "multiedit-two-files-both-clean-approves" "hooks/block-case-markers.js"
PA="$(untracked tests/hooks/clean-a.sh)"
PB="$(untracked tests/hooks/clean-b.sh)"
mkpayload MultiEdit "$REPO_M" "$PA" "e0.file_path=$PA" "e0.old_string=echo a" "e0.new_string=echo aa" "e1.file_path=$PB" "e1.old_string=echo b" "e1.new_string=echo bb"
hk_run
assert_decision "multiedit-two-files-both-clean-approves" approve
case_end

case_begin "multiedit-alias-cwd-blocks" "hooks/block-case-markers.js"
# Relative (vs input.cwd) and absolute spellings of one file must group: split
# groups leave e1's old_string absent (fail-open) and e0 alone clean -> approve.
P="$(untracked tests/hooks/alias-new.sh)"
mkpayload MultiEdit "$REPO_M" "$P" "e0.file_path=./tests/hooks/alias-new.sh" "e0.old_string=echo b" "e0.new_string=ALIAS_STEP" "e1.file_path=$P" "e1.old_string=ALIAS_STEP" "e1.new_string=if true; then"
hk_run
assert_decision "multiedit-alias-cwd-blocks" block
assert_reason_has "multiedit-alias-cwd-blocks" "tests/hooks/alias-new.sh"
assert_reason_has "multiedit-alias-cwd-blocks" "code=MALFORMED_CASE_MARKER"
case_end

case_begin "multiedit-alias-cwd-clean-approves" "hooks/block-case-markers.js"
P="$(untracked tests/hooks/alias-clean.sh)"
mkpayload MultiEdit "$REPO_M" "$P" "e0.file_path=tests/hooks/alias-clean.sh" "e0.old_string=echo b" "e0.new_string=ALIAS_STEP" "e1.file_path=$P" "e1.old_string=ALIAS_STEP" "e1.new_string=echo bb"
hk_run
assert_decision "multiedit-alias-cwd-clean-approves" approve
case_end
