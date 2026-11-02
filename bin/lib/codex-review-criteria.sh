#!/usr/bin/env bash
# Review criteria + severity definition emitter (#2814), sourced by lib/codex-core.sh.
# Both the codex path and bin/review-criteria-block (CC reviewers) call
# codex_core_review_criteria_block, so the two paths receive byte-equal text.

# _codex_core_strip_examples <file>
# Prints <file> with CRs removed and every <!-- example --> … <!-- /example --> block
# (both marker lines included) dropped. A nested, unmatched, or unclosed marker prints
# nothing and returns 1, so a malformed file never leaks an example into a prompt.
_codex_core_strip_examples() {
  awk '
    { sub(/\r$/, "") }
    $0 == "<!-- example -->" { if (inex) { bad = 1; exit } inex = 1; next }
    $0 == "<!-- /example -->" { if (!inex) { bad = 1; exit } inex = 0; next }
    !inex { buf = buf $0 "\n" }
    END { if (bad || inex) exit 1; printf "%s", buf }
  ' "$1"
}

# _codex_core_criteria_body <file>
# Echoes the stripped body of <file>, or one stderr line and return 1.
_codex_core_criteria_body() {
  local f="$1" body
  if [[ ! -f "$f" || ! -r "$f" ]]; then
    printf 'codex_core_review_criteria_block: file unreadable: %s\n' "$f" >&2
    return 1
  fi
  # The trailing x keeps the body's final newline through command substitution.
  if ! body="$(_codex_core_strip_examples "$f" && printf x)"; then
    printf 'codex_core_review_criteria_block: malformed example block: %s\n' "$f" >&2
    return 1
  fi
  printf '%s' "${body%x}"
}

# codex_core_review_criteria_block [project-root]
# Echoes the REVIEW CRITERIA block, the SEVERITY DEFINITION block, then (root given)
# the PROJECT NFR block. Returns 1 when either source is unreadable or malformed.
codex_core_review_criteria_block() {
  local root="${1:-}" _dir crit sev
  _dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
  crit="$(_codex_core_criteria_body "$_dir/../../agents/lib/review-criteria.md" && printf x)" || return 1
  sev="$(_codex_core_criteria_body "$_dir/../../skills/_shared/severity.md" && printf x)" || return 1
  printf '[REVIEW CRITERIA START]\n%s[REVIEW CRITERIA END]\n\n[SEVERITY DEFINITION START]\n%s[SEVERITY DEFINITION END]\n\n' "${crit%x}" "${sev%x}"
  if [[ -n "$root" ]]; then
    codex_core_project_nfr_block "$root"
  fi
  return 0
}
