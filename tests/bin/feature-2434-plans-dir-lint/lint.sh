#!/usr/bin/env bash
# Tests: bin/check-plans-artifacts, hooks/lib/plans-artifact-registry.js, .github/workflows/migration-blocks-audit.yml, hooks/lib/precommit-agents-repo-gates.sh
# Tags: scope:issue-specific, TL2, plans-dir-lint, feature-2434, plans-dir, table-driven, pwsh-not-required
# Part file of tests/bin/feature-2434-plans-dir-lint.sh (sourced; uses its T, LINT,
# make_tree, table_tree, edit_table, run_source, run_source_gate, run_dir, check and
# pass/fail helpers). The lint's --source and --dir modes, the judged tree's table,
# the registry exception reasons, and the static consumer wiring.

case_begin "source-scan-matrix" "bin/check-plans-artifacts"
# C11: table-driven matrix over artifact/control/unregistered/token-spelling/malformed-path.
# Columns: label | content written to fixture file | expected exit code | file extension.
# The lint scans all files regardless of extension per plan Step 7-2 ("all files").
while IFS='|' read -r LABEL CONTENT WANT_RC EXT; do
  FX="$T/scan-$LABEL"; make_tree "$FX"
  printf '%s\n' "$CONTENT" > "$FX/bin/m.$EXT"
  run_source "$FX"
  if [ "$L_RC" = "127" ]; then
    fail "source-scan/$LABEL" "implementation absent"
  elif [ "$L_RC" = "$WANT_RC" ]; then
    pass "source-scan/$LABEL"
  else
    fail "source-scan/$LABEL" "want exit $WANT_RC; got $L_RC"
  fi
done <<'MATRIX'
artifact-allowed|$PLANS_DIR/$SID-detail.md|0|sh
control-terminal|$PLANS_DIR/$SID-detail-plan-terminal.txt|1|sh
control-carrier-md|${PLANS_DIR}/${SESSION_ID}-test-review-concern-carrier.md|1|sh
unregistered-json|$PLANS_DIR/$SID-new-state.json|1|sh
dynamic-kind|$PLANS_DIR/$SID-$kind|1|sh
token-workflow-plans-alt|${WORKFLOW_PLANS_DIR:-$HOME/.workflow-plans}/$SID-detail-plan-terminal.txt|1|sh
token-plansdir-js|path.join(plansDir, sid + "-security-code-terminal.txt")|1|js
token-artifact-dir|$artifact_dir/$SID-test-review-terminal.txt|1|sh
token-log-dir|$LOG_DIR/$SID-detail-plan-round-number.txt|1|sh
token-placeholder-md|<PLANS_DIR>/<session-id>-detail-plan-terminal.txt|1|md
malformed-path-traversal|$PLANS_DIR/$SID-../../etc/passwd|1|sh
MATRIX
case_end

# #2638: the pre-commit gate runs the checkout's lint with cwd = the commit worktree, so the
# verdict follows the table of the tree being judged, not the table next to the lint.
NEW_KIND_REF='Write the result to $PLANS_DIR/$SID-new-state.json before the next step.'

case_begin "judged-tree-new-kind-registered-same-tree" "bin/check-plans-artifacts"
FX="$T/judged-new-kind"
if table_tree "judged-new-kind: fixture tree with the data file" "$FX"; then
  mkdir -p "$FX/skills/x"
  printf '%s\n' "$NEW_KIND_REF" > "$FX/skills/x/SKILL.md"
  run_source_gate "$FX"
  check "judged-new-kind: control — the reference is unregistered under the copied table (exit 1)" "1" "$L_RC"
  if edit_table "$FX" add-kind artifactKinds new-state 'new-state\.json' non-plan 2>/dev/null; then
    run_source_gate "$FX"
    check "judged-new-kind: a kind registered and referenced in the same tree passes (exit 0)" "0" "$L_RC"
    check "judged-new-kind: no fallback notice while the judged tree carries its table" \
      "no" "$(printf '%s\n' "$L_ERR" | grep -qi -- "$FALLBACK_WORD" && printf yes || printf no)"
  else
    fail "judged-new-kind: fixture edit" "add-kind did not apply"
  fi
fi
case_end

case_begin "judged-tree-without-table-falls-back" "bin/check-plans-artifacts"
FX="$T/judged-no-table"; make_tree "$FX"
mkdir -p "$FX/skills/x"
printf '%s\n' "$NEW_KIND_REF" > "$FX/skills/x/SKILL.md"
run_source_gate "$FX"
check "judged-no-table: the same reference fails under the checker-side table (exit 1)" "1" "$L_RC"
check "judged-no-table: stderr names the data file the judged tree lacks" \
  "yes" "$(printf '%s\n' "$L_ERR" | grep -qF -- "$TABLE_REL" && printf yes || printf no)"
check "judged-no-table: the fallback notice is exactly one stderr line" \
  "1" "$(printf '%s\n' "$L_ERR" | grep -ci -- "$FALLBACK_WORD" || true)"
case_end

case_begin "static-registry-exceptions-have-reason" "hooks/lib/plans-artifact-registry.js"
REG="$(np "$SCRIPT_CHECKOUT_ROOT/hooks/lib/plans-artifact-registry.js")"
REG_RC=0
REG_OUT="$(run_with_timeout 15 node "$T/check-reg.js" "$REG" 2>&1)" || REG_RC=$?
if [ "$REG_RC" = "0" ]; then
  pass "static-registry-exceptions-have-reason"
else
  fail "static-registry-exceptions-have-reason" "exit $REG_RC: $REG_OUT"
fi
case_end

case_begin "dir-unregistered-warning" "bin/check-plans-artifacts"
FX="$T/fx-dir-unk"; mkdir -p "$FX"
UNK_NAME="ffffffff-0000-0000-0000-000000000000-unknown-custom.txt"
printf '%s\n' 'content' > "$FX/$UNK_NAME"
# Evidence that the prefix is a session (plan Step 7-1: unregistered needs it);
# an artifact never produces a diagnostic line of its own.
printf '%s\n' '# context' > "$FX/ffffffff-0000-0000-0000-000000000000-context.md"
run_dir "$FX"
if [ "$L_RC" = "0" ]; then
  pass "dir-unregistered-warning"
elif [ "$L_RC" = "127" ]; then
  fail "dir-unregistered-warning" "implementation absent"
else
  fail "dir-unregistered-warning" "want exit 0; got $L_RC: $L_OUT"
fi
# A lint that exits 0 without detecting anything must not pass: the warning names
# the file, its classification, and the count (plan Step 7-1 "show the count").
UNK_LINE="$(printf '%s\n' "$L_OUT" | grep -F "$UNK_NAME" | head -n 1)"
check "dir-unregistered-warning: the diagnostic names the unregistered file" \
  "yes" "$([ -n "$UNK_LINE" ] && printf yes || printf no)"
check "dir-unregistered-warning: the file's line classifies it as unregistered" \
  "yes" "$(printf '%s' "$UNK_LINE" | grep -qi 'unregistered' && printf yes || printf no)"
check "dir-unregistered-warning: the count of unregistered entries is 1" \
  "yes" "$(printf '%s\n' "$L_OUT" | grep -i 'unregistered' | grep -Eq '(^|[^0-9])1([^0-9]|$)' && printf yes || printf no)"
check "dir-unregistered-warning: the artifact is not reported" \
  "no" "$(printf '%s\n' "$L_OUT" | grep -qF -- '-context.md' && printf yes || printf no)"
case_end

case_begin "dir-control-error" "bin/check-plans-artifacts"
FX="$T/fx-dir-ctrl"; mkdir -p "$FX"
printf '%s\n' 'content' > "$FX/ffffffff-0000-0000-0000-000000000001-detail-plan-terminal.txt"
run_dir "$FX"
if [ "$L_RC" = "1" ]; then
  pass "dir-control-error"
elif [ "$L_RC" = "127" ]; then
  fail "dir-control-error" "implementation absent"
else
  fail "dir-control-error" "want exit 1; got $L_RC: $L_OUT"
fi
case_end

case_begin "repo-source-clean" "bin/check-plans-artifacts"
if [ ! -f "$LINT" ]; then
  fail "repo-source-clean" "implementation absent"
else
  R_RC=0
  R_OUT="$(cd "$SCRIPT_CHECKOUT_ROOT" && run_with_timeout 60 node "$(np "$LINT")" --source 2>&1)" || R_RC=$?
  if [ "$R_RC" = "0" ]; then
    pass "repo-source-clean"
  else
    fail "repo-source-clean" "want exit 0; got $R_RC: $R_OUT"
  fi
fi
case_end

case_begin "static-migration-blocks-audit-has-lint" ".github/workflows/migration-blocks-audit.yml"
YML="$SCRIPT_CHECKOUT_ROOT/.github/workflows/migration-blocks-audit.yml"
FOUND_CALL=0
grep -qF "check-plans-artifacts --source" "$YML" 2>/dev/null && FOUND_CALL=1
HAS_OR_TRUE=0
grep -F "check-plans-artifacts --source" "$YML" 2>/dev/null | grep -qF "|| true" && HAS_OR_TRUE=1
if [ "$FOUND_CALL" = "1" ] && [ "$HAS_OR_TRUE" = "0" ]; then
  pass "static-migration-blocks-audit-has-lint"
else
  fail "static-migration-blocks-audit-has-lint" "found_call=$FOUND_CALL has_or_true=$HAS_OR_TRUE"
fi
case_end

case_begin "static-precommit-gates-has-lint" "hooks/lib/precommit-agents-repo-gates.sh"
GATES="$SCRIPT_CHECKOUT_ROOT/hooks/lib/precommit-agents-repo-gates.sh"
GATES_OK=0
grep -qF "check-plans-artifacts --source" "$GATES" 2>/dev/null && GATES_OK=1
if [ "$GATES_OK" = "1" ]; then
  pass "static-precommit-gates-has-lint"
else
  fail "static-precommit-gates-has-lint" "check-plans-artifacts --source not in precommit-agents-repo-gates.sh"
fi
case_end
true
