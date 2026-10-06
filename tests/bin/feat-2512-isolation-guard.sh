#!/usr/bin/env bash
# Tests: bin/check-plans-dir-isolation.sh, hooks/lib/precommit-agents-repo-gates.sh, .github/workflows/migration-blocks-audit.yml
# Tags: isolation, classifier, gate, pre-commit, ci, bin, scope:issue-specific, TL2
# #2512 stage 4: the isolation classifier becomes a recursive gate (pin order,
# source inheritance, residual old-name token) wired into pre-commit and CI.
# Fixture trees are scanned with --root; the classifier never runs them.
# TL3 gap: the CI step is verified structurally only; a real GitHub Actions run
# (ubuntu runner, fresh checkout) is what proves the job fails on a violation.
set -euo pipefail

AGENTS_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
source "$AGENTS_DIR/tests/lib/harness.sh"
T="$(make_tmp)"
readonly T
harness_isolate "$T/iso"
export WORKFLOW_STATE_DIR="$T/iso/workflow-state"
trap 'rm -rf "$T"' EXIT

CLS="$AGENTS_DIR/bin/check-plans-dir-isolation.sh"
VIOLATION_RE='^(STATE-UNPINNED|STATE-INLINE-ONLY|STATE-PIN-LATE|HALF-PIN-REVERSE|W-candidate|RESIDUAL-TOKEN):'
# The retired variable name, assembled so this file never carries the literal.
OLD_TOKEN="CLAUDE_""WORKFLOW_DIR"

# Fixture line vocabulary (single-quoted: fixtures are text, never run here).
EXEC_RO='node "$AGENTS_DIR/hooks/block-history-direct.js" </dev/null'
EXEC_BIN='bash "$AGENTS_DIR/bin/workflow-control-dir" --session s1'
PIN_BOTH='export WORKFLOW_STATE_DIR=/tmp/s WORKFLOW_PLANS_DIR=/tmp/p'
TPL_B=(
  '#!/usr/bin/env bash'
  'set -euo pipefail'
  '# isolation (#2512): pin state and plans dirs once for this file'
  '_ISOLATION_TMP_ROOT="$(mktemp -d)"; readonly _ISOLATION_TMP_ROOT'
  'mkdir -p "$_ISOLATION_TMP_ROOT/workflow-state" "$_ISOLATION_TMP_ROOT/plans"'
  'export WORKFLOW_STATE_DIR="$_ISOLATION_TMP_ROOT/workflow-state" WORKFLOW_PLANS_DIR="$_ISOLATION_TMP_ROOT/plans"'
  "trap 'rm -rf \"\$_ISOLATION_TMP_ROOT\"' EXIT"
)

# fx <file> <line>... — write a fixture file, one argument per line.
fx() {
  local f="$1"
  shift
  mkdir -p "$(dirname "$f")"
  printf '%s\n' "$@" > "$f"
}

# run_cls <args...> — classifier from the repo root; sets CLS_OUT / CLS_RC.
run_cls() {
  CLS_RC=0
  CLS_OUT="$(cd "$AGENTS_DIR" && run_with_timeout 120 bash "$CLS" "$@" 2>&1)" || CLS_RC=$?
}

# run_cls_in <dir> <classifier> <args...> — same, from another cwd and copy.
run_cls_in() {
  local dir="$1" bin="$2"
  shift 2
  CLS_RC=0
  CLS_OUT="$(cd "$dir" && run_with_timeout 120 bash "$bin" "$@" 2>&1)" || CLS_RC=$?
}

# label_hits <label> <fragment> — a <label>: line names the fragment.
label_hits() {
  local hits
  hits="$(grep -E "^$1:" <<<"$CLS_OUT" || true)"
  [[ -n "$hits" && "$hits" == *"$2"* ]]
}

violation_for() {
  local hits
  hits="$(grep -E "$VIOLATION_RE" <<<"$CLS_OUT" || true)"
  [[ -n "$hits" && "$hits" == *"$1"* ]]
}

no_violation_for() { ! violation_for "$1"; }

rc_is() { [[ "$CLS_RC" == "$1" ]]; }

# expect <name> <command...> — record PASS when the command succeeds.
expect() {
  local name="$1"
  shift
  if "$@"; then
    pass "$name"
  else
    fail "$name" "rc=${CLS_RC:-} out=$(head -c 600 <<<"${CLS_OUT:-}")"
  fi
}

new_root() {
  local r="$T/roots/$1"
  mkdir -p "$r"
  np "$r"
}

. "$(dirname "$0")/feat-2512-isolation-guard/scan-cases.sh"
. "$(dirname "$0")/feat-2512-isolation-guard/source-cases.sh"
. "$(dirname "$0")/feat-2512-isolation-guard/mode-cases.sh"
. "$(dirname "$0")/feat-2512-isolation-guard/wiring-cases.sh"

case_begin "i1-subdir-unpinned-exec" "bin/check-plans-dir-isolation.sh"
c_i1_subdir_unpinned
case_end

case_begin "i2-pinned-parent-child-inherits" "bin/check-plans-dir-isolation.sh"
c_i2_pinned_parent
case_end

case_begin "i3-two-parents-one-unpinned" "bin/check-plans-dir-isolation.sh"
c_i3_two_parents_one_unpinned
case_end

case_begin "i4-plans-only-half-pin" "bin/check-plans-dir-isolation.sh"
c_i4_plans_only
case_end

case_begin "i5-inline-only-pin" "bin/check-plans-dir-isolation.sh"
c_i5_inline_only
case_end

case_begin "i6-env-u-default-path" "bin/check-plans-dir-isolation.sh"
c_i6_env_u_default_path
case_end

case_begin "i7-static-only-test" "bin/check-plans-dir-isolation.sh"
c_i7_static_only
case_end

case_begin "i8-excluded-dirs" "bin/check-plans-dir-isolation.sh"
c_i8_excluded_dirs
case_end

case_begin "i9-residual-token" "bin/check-plans-dir-isolation.sh"
c_i9_residual_token
case_end

case_begin "i10-staged-skips-scan" "bin/check-plans-dir-isolation.sh"
c_i10_staged_skips_scan
case_end

case_begin "i11-usage-errors" "bin/check-plans-dir-isolation.sh"
c_i11_usage_errors
case_end

case_begin "i12-whole-repo-clean" "bin/check-plans-dir-isolation.sh"
c_i12_repo_clean
case_end

case_begin "i13-precommit-gate-blocks" "hooks/lib/precommit-agents-repo-gates.sh"
c_i13_precommit_gate
case_end

case_begin "i14-ci-step-present" ".github/workflows/migration-blocks-audit.yml"
c_i14_ci_step
case_end

case_begin "i17-same-name-helpers" "bin/check-plans-dir-isolation.sh"
c_i17_same_name_helpers
case_end

case_begin "i18-unresolvable-source" "bin/check-plans-dir-isolation.sh"
c_i18_unresolvable_source
case_end

case_begin "i19-script-dir-variable" "bin/check-plans-dir-isolation.sh"
c_i19_script_dir_variable
case_end

case_begin "i20-templates-contract" "bin/check-plans-dir-isolation.sh"
c_i20_templates_contract
c_i20_template_b_runtime
case_end

case_begin "i21-pin-between-execs" "bin/check-plans-dir-isolation.sh"
c_i21_pin_between_execs
case_end

case_begin "i22-function-before-pin" "bin/check-plans-dir-isolation.sh"
c_i22_function_defined_before_pin
case_end

case_begin "i23-source-before-pin" "bin/check-plans-dir-isolation.sh"
c_i23_source_before_pin
case_end

case_begin "i24-pin-inside-function" "bin/check-plans-dir-isolation.sh"
c_i24_pin_inside_function
case_end

case_begin "i25-plans-pin-late" "bin/check-plans-dir-isolation.sh"
c_i25_plans_pin_late
case_end

case_begin "heredoc-lexing" "bin/check-plans-dir-isolation.sh"
c_heredoc_lexing
case_end

case_begin "files-mode-classifies-named" "bin/check-plans-dir-isolation.sh"
c_gap_pinned_ok_and_files_mode
case_end

case_begin "crlf-verdict-symmetry" "bin/check-plans-dir-isolation.sh"
c_gap_crlf_symmetry
case_end

case_begin "scan-never-executes" "bin/check-plans-dir-isolation.sh"
c_gap_never_executes_fixture
case_end

case_begin "scan-idempotent" "bin/check-plans-dir-isolation.sh"
c_gap_idempotent
case_end

case_begin "exec-signal-var-forms" "bin/check-plans-dir-isolation.sh"
c_exec_signal_forms
case_end

case_begin "pin-recognition-boundary" "bin/check-plans-dir-isolation.sh"
c_pin_boundary
case_end

case_begin "quoted-literal-vs-substitution" "bin/check-plans-dir-isolation.sh"
c_quoted_literal_vs_substitution
case_end

case_begin "source-grandchild-inherits" "bin/check-plans-dir-isolation.sh"
c_grandchild_inherits
case_end

case_begin "source-cycle-terminates" "bin/check-plans-dir-isolation.sh"
c_source_cycle
case_end

case_begin "source-grandparent-pin-late" "bin/check-plans-dir-isolation.sh"
c_grandparent_pin_late
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[[ "$FAIL" -eq 0 ]]
