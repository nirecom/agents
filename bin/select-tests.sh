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

if [[ ${#stems[@]} -eq 0 ]]; then
  exit 0
fi

declare -A seen
while IFS= read -r test; do
  [[ -f "${test}" ]] || continue
  fname="${test##*/}"
  for stem in "${stems[@]}"; do
    if [[ "${fname}" == *"${stem}"* ]]; then
      if [[ -z "${seen[${test}]+x}" ]]; then
        echo "${test}"
        seen[${test}]=1
      fi
      break
    fi
  done
done < <(find "${TESTS_DIR}" -maxdepth 1 -name "*.sh" | sort)

exit 0
