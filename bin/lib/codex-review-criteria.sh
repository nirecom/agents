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

# codex_core_sha12 — the first 12 hex of the sha256 of stdin (#2020 criteria hash).
codex_core_sha12() {
  local h
  if command -v sha256sum >/dev/null 2>&1; then h="$(sha256sum)"; else h="$(shasum -a 256)"; fi
  printf '%s\n' "${h:0:12}"
}

# _codex_core_boundary_version <block> — the first `Version: v<N>` line after `## Threat boundary`
# (#2020 boundary version), else `unknown`.
_codex_core_boundary_version() {
  local v
  v="$(printf '%s\n' "$1" | awk '$0 == "## Threat boundary" { f = 1; next } f && /^Version: v[0-9]+$/ { print $2; exit }')"
  printf '%s\n' "${v:-unknown}"
}

# codex_core_review_criteria_block [project-root]
# Echoes the REVIEW CRITERIA block, the SEVERITY DEFINITION block, then (root given)
# the PROJECT NFR block. Returns 1 when either source is unreadable or malformed, or when the
# PROJECT NFR could not be read (a review without it would judge the boundary without the NFR).
# With REVIEW_CRITERIA_HASH_OUT set, also writes to that file codex_core_sha12 of the output
# (line 1), the boundary version (line 2) and whether a PROJECT NFR block was delivered
# (line 3: nfr:present | nfr:absent).
codex_core_review_criteria_block() {
  local root="${1:-}" _dir crit sev nfr="x" out
  _dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
  crit="$(_codex_core_criteria_body "$_dir/../../skills/_shared/review-criteria.md" && printf x)" || return 1
  sev="$(_codex_core_criteria_body "$_dir/../../skills/_shared/severity.md" && printf x)" || return 1
  if [[ -n "$root" ]] && ! nfr="$(_codex_core_project_nfr_fetch "$root" && printf x)"; then
    printf 'codex_core_review_criteria_block: PROJECT_NFR could not be read under %s\n' "$root" >&2
    return 1
  fi
  out="$(printf '[REVIEW CRITERIA START]\n%s[REVIEW CRITERIA END]\n\n[SEVERITY DEFINITION START]\n%s[SEVERITY DEFINITION END]\n\n%sx' "${crit%x}" "${sev%x}" "${nfr%x}")"
  out="${out%x}"
  printf '%s' "$out"
  if [[ -n "${REVIEW_CRITERIA_HASH_OUT:-}" ]]; then
    { printf '%s' "$out" | codex_core_sha12; _codex_core_boundary_version "$out"
      if [[ -n "${nfr%x}" ]]; then printf 'nfr:present\n'; else printf 'nfr:absent\n'; fi; } \
      > "$REVIEW_CRITERIA_HASH_OUT" 2>/dev/null || true
  fi
  return 0
}
