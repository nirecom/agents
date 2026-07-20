#!/usr/bin/env bash
# bin/select-tests.sh
# Tests: bin/select-tests.sh
# Tags: test-selection, pr-scoped, stem-match
#
# Tier 1 test selector: mechanical stem-based selection only.
# Usage: bin/select-tests.sh <merge-base-ref>
# Output: newline-separated test file paths (may be empty), exit 0.
# Exit 1 on missing arg or git error.
# Never reads frontmatter — frontmatter is Tier 2 (LLM in run-tests/SKILL.md).
# Never returns tests/_archive/ entries.

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: bin/select-tests.sh <merge-base-ref>" >&2
  exit 1
fi

MERGE_BASE="$1"
AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TESTS_DIR="${AGENTS_DIR}/tests"

changed=$(git diff --name-only "${MERGE_BASE}...HEAD" 2>/dev/null) || exit 1

stems=()
while IFS= read -r path; do
  [[ -z "${path}" ]] && continue
  stem=""
  case "${path}" in
    skills/*/SKILL.md)
      stem="${path#skills/}"
      stem="${stem%/SKILL.md}"
      ;;
    skills/*/scripts/*)
      area="${path#skills/}"
      area="${area%%/*}"
      file="${path##*/}"
      file="${file%.*}"
      stems+=("${area}")
      stem="${file}"
      ;;
    agents/*.md)
      stem="${path#agents/}"
      stem="${stem%.md}"
      ;;
    hooks/*.js)
      stem="${path#hooks/}"
      stem="${stem%.js}"
      ;;
    bin/*)
      stem="${path#bin/}"
      stem="${stem%.*}"
      stem="${stem##*/}"
      ;;
    *)
      continue
      ;;
  esac
  [[ ${#stem} -lt 3 ]] && continue
  stems+=("${stem}")
done <<< "${changed}"

# Portable seen-set: temp file; compatible with bash 3.x (macOS default).
_seen=$(mktemp)
trap 'rm -f "$_seen"' EXIT

_emit_if_new() {
  local path="$1"
  grep -qxF "${path}" "${_seen}" 2>/dev/null && return
  echo "${path}"
  printf '%s\n' "${path}" >> "${_seen}"
}

# Stem-match selection (skipped when the diff produced no stems, e.g. docs-only).
if [[ ${#stems[@]} -gt 0 ]]; then
  while IFS= read -r test; do
    [[ -f "${test}" ]] || continue
    fname="${test##*/}"
    for stem in "${stems[@]}"; do
      if [[ "${fname}" == *"${stem}"* ]]; then
        _emit_if_new "${test}"
        break
      fi
    done
  done < <(find "${TESTS_DIR}" -maxdepth 1 -name "*.sh" | sort)
fi

# RUN_TL3=on: always append TL3-*.sh (real-environment tier), even on docs-only diffs.
if [[ -x "${AGENTS_DIR}/bin/get-config-var" ]]; then
  if ! "${AGENTS_DIR}/bin/get-config-var" --is-off RUN_TL3 off 2>/dev/null; then
    while IFS= read -r tl3; do
      [[ -f "${tl3}" ]] || continue
      _emit_if_new "${tl3}"
    done < <(find "${TESTS_DIR}" -maxdepth 1 -name "TL3-*.sh" | sort)
  fi
fi

exit 0
