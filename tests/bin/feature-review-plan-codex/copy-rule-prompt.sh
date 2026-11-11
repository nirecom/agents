# tests/bin/feature-review-plan-codex/copy-rule-prompt.sh
# Sub-file sourced by feature-review-plan-codex.sh (Pattern A).
# Tests: bin/lib/review-plan-codex/prompts.sh, bin/review-plan-codex
# Tags: codex, review, no-upstream-copy, outline, detail, scope:issue-specific, TL2
# #2924 test 9: outline/detail Round 1 prompts carry the copy-ban SSOT block and sentences;
# security-plan/test-review do not; an unreadable SSOT is FAILED before codex runs.
# TL3 gap: whether a live codex actually reports copied or crammed plan text.
# CR_ prefix guards all locals from colliding with variables in the parent script.

CR_RPC="$AGENTS_ROOT/bin/review-plan-codex"
CR_RWT="$AGENTS_ROOT/bin/run-with-timeout.sh"
CR_SSOT="$AGENTS_ROOT/skills/_shared/no-upstream-copy.md"
CR_TMP="$TMPDIR_BASE/cr-copy-rule"
mkdir -p "$CR_TMP/mock-bin" "$CR_TMP/cwd"
CR_CAP="$CR_TMP/codex-prompt.txt"
printf '#!/usr/bin/env bash\ncat > "%s"\necho "APPROVED"\nexit 0\n' "$CR_CAP" > "$CR_TMP/mock-bin/codex"
chmod +x "$CR_TMP/mock-bin/codex"
if command -v cygpath >/dev/null 2>&1; then CR_MOCK_PATH="$(cygpath -u "$CR_TMP/mock-bin")"; else CR_MOCK_PATH="$CR_TMP/mock-bin"; fi
case "$(PATH="$CR_MOCK_PATH:$PATH" command -v codex)" in
  *mock-bin*) : ;;
  *) fail "CR-harness: mock codex not first on PATH"; return ;;
esac

CR_INPUT="$CR_TMP/plan.md"
printf '# Plan\n\n## Adopted approach\n\n- do the work\n' > "$CR_INPUT"

# cr_run <rpc-path> <format> — run review-plan-codex once from a neutral cwd; sets CR_RC / CR_OUT.
cr_run() {
  rm -f "$CR_CAP"
  CR_RC=0
  CR_OUT="$CR_TMP/out-$2.txt"
  (
    cd "$CR_TMP/cwd" || exit 1
    unset CLAUDE_CODE_SESSION_ID
    export PATH="$CR_MOCK_PATH:$PATH"
    "$CR_RWT" 60 bash "$1" --input "$CR_INPUT" --format "$2" --no-log > "$CR_OUT" 2>&1
  ) || CR_RC=$?
}
cr_has() { [[ -f "$CR_CAP" ]] && grep -qF -- "$1" "$CR_CAP"; }
cr_check() { if [[ "$2" = "$3" ]]; then pass "$1"; else fail "$1 (want=$2 got=$3; rc=$CR_RC; out: $(tail -n 2 "$CR_OUT" 2>/dev/null | tr '\n' ' '))"; fi; }
# cr_const <name> — the value prompts.sh gives the named constant ("" when undefined).
cr_const() { ( SCRIPT_DIR="$AGENTS_ROOT/bin"; . "$AGENTS_ROOT/bin/lib/review-plan-codex/prompts.sh" >/dev/null 2>&1; printf '%s' "${!1:-}" ); }
case_begin "copy-rule-constants-defined" "bin/lib/review-plan-codex/prompts.sh"
CR_RC=0; CR_OUT=/dev/null
CR_COPY_SENT="$(cr_const RPC_COPY_SENTENCE)"
CR_STRUCT_SENT="$(cr_const RPC_OUTLINE_STRUCTURE_SENTENCE)"
cr_check "CR0: prompts.sh defines RPC_COPY_SENTENCE and RPC_OUTLINE_STRUCTURE_SENTENCE" "yes yes" \
  "$([[ -n "$CR_COPY_SENT" ]] && printf yes || printf no) $([[ -n "$CR_STRUCT_SENT" ]] && printf yes || printf no)"
case_end

# cr_block — the text between the copy-rule markers of the captured prompt.
cr_block() { awk '/^\[UPSTREAM COPY RULE START\]$/{f=1;next} /^\[UPSTREAM COPY RULE END\]$/{f=0} f' "$CR_CAP" 2>/dev/null; }

case_begin "plan-prompts-carry-copy-rule" "bin/lib/review-plan-codex/prompts.sh"
for CR_FMT in outline-plan detail-plan; do
  cr_run "$CR_RPC" "$CR_FMT"
  cr_check "CR1 $CR_FMT: codex received a prompt" "yes" "$([[ -f "$CR_CAP" ]] && printf yes || printf no)"
  cr_check "CR2 $CR_FMT: Round 1 prompt carries the copy-rule markers" "yes yes" \
    "$(cr_has '[UPSTREAM COPY RULE START]' && printf yes || printf no) $(cr_has '[UPSTREAM COPY RULE END]' && printf yes || printf no)"
  cr_check "CR3 $CR_FMT: the copy block is the full text of no-upstream-copy.md" "same" \
    "$([[ -s "$CR_SSOT" && "$(cr_block)" = "$(cat "$CR_SSOT")" ]] && printf same || printf differs)"
  cr_check "CR4 $CR_FMT: Round 1 prompt carries RPC_COPY_SENTENCE" "yes" \
    "$([[ -n "$CR_COPY_SENT" ]] && cr_has "$CR_COPY_SENT" && printf yes || printf no)"
  if [[ "$CR_FMT" = outline-plan ]]; then CR_WANT=yes; else CR_WANT=no; fi
  cr_check "CR5 $CR_FMT: RPC_OUTLINE_STRUCTURE_SENTENCE present only in outline (want $CR_WANT)" "$CR_WANT" \
    "$([[ -n "$CR_STRUCT_SENT" ]] && cr_has "$CR_STRUCT_SENT" && printf yes || printf no)"
  if [[ "$CR_FMT" = outline-plan ]]; then
    CR_MA="$(grep -F 'Only use MISSING_ALTERNATIVE' "$CR_CAP" 2>/dev/null | head -n 1)"
    cr_check "CR6 outline: the MISSING_ALTERNATIVE allowance names upstream copy and cramming" "yes yes" \
      "$(printf '%s' "$CR_MA" | grep -qiE 'cop(y|ied)' && printf yes || printf no) $(printf '%s' "$CR_MA" | grep -qiE 'cram|single paragraph|one paragraph' && printf yes || printf no)"
  fi
done
# CR6b/c: the prose definitions of MISSING_ALTERNATIVE carry the same two allowances.
for CR_DEF in "skills/_shared/priority-hierarchy/core.md|verdict \`MISSING_ALTERNATIVE\` means" \
  "agents/outline-reviewer.md|\`MISSING_ALTERNATIVE\` means"; do
  CR_DEF_FILE="${CR_DEF%%|*}"
  CR_DEF_LINE="$(grep -F -- "${CR_DEF#*|}" "$AGENTS_ROOT/$CR_DEF_FILE" 2>/dev/null | head -n 1)"
  cr_check "CR6 $CR_DEF_FILE: the MISSING_ALTERNATIVE definition names upstream copy and cramming" "found yes yes" \
    "$([[ -n "$CR_DEF_LINE" ]] && printf found || printf absent) $(printf '%s' "$CR_DEF_LINE" | grep -qiE 'cop(y|ied)' && printf yes || printf no) $(printf '%s' "$CR_DEF_LINE" | grep -qiE 'cram' && printf yes || printf no)"
done
case_end

case_begin "other-prompts-carry-no-copy-rule" "bin/lib/review-plan-codex/prompts.sh"
for CR_FMT in security-plan test-review; do
  cr_run "$CR_RPC" "$CR_FMT"
  cr_check "CR7 $CR_FMT: codex received a prompt (anti-vacuity)" "yes" "$([[ -f "$CR_CAP" ]] && printf yes || printf no)"
  cr_check "CR7 $CR_FMT: no copy block in the prompt" "no" "$(cr_has '[UPSTREAM COPY RULE START]' && printf yes || printf no)"
done
case_end

# CR8: a checkout copy whose no-upstream-copy.md is missing fails closed (FAILED, no codex call).
case_begin "missing-copy-rule-ssot-fails-closed" "bin/review-plan-codex"
CR_TREE="$CR_TMP/tree"
mkdir -p "$CR_TREE"
for CR_D in bin skills hooks rules; do cp -R "$AGENTS_ROOT/$CR_D" "$CR_TREE/$CR_D"; done
cr_run "$CR_TREE/bin/review-plan-codex" outline-plan
cr_check "CR8 control: the same copied tree with the SSOT kept does not report FAILED" "no" "$(grep -q 'FAILED' "$CR_OUT" && printf yes || printf no)"
rm -f "$CR_TREE/skills/_shared/no-upstream-copy.md"
cr_run "$CR_TREE/bin/review-plan-codex" outline-plan
cr_check "CR8 outline-plan: unreadable no-upstream-copy.md reports FAILED" "yes" "$(grep -q 'FAILED' "$CR_OUT" && printf yes || printf no)"
cr_check "CR8 outline-plan: the failure names no-upstream-copy.md" "yes" "$(grep -qF 'no-upstream-copy.md' "$CR_OUT" && printf yes || printf no)"
cr_check "CR8 outline-plan: unreadable no-upstream-copy.md never calls codex" "no" "$([[ -f "$CR_CAP" ]] && printf yes || printf no)"
case_end
