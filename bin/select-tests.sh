#!/usr/bin/env bash
# bin/select-tests.sh
# Tests: bin/select-tests.sh
# Tags: test-selection, pr-scoped, stem-match
#
# Tier 1 test selector: mechanical stem-based selection only.
# Usage: bin/select-tests.sh --auto            (resolve via bin/resolve-merge-base.sh)
#        bin/select-tests.sh <merge-base-ref>  (caller has already resolved; leaves no session record)
# Output: newline-separated test file paths (may be empty), exit 0.
# Exit 1 on missing arg or git error.
# Exit 4 (--auto only) the merge-base is not trustworthy, or could not be asked for at all.
#        Nothing is selected. Selecting from a wrong base produces an ordinary-looking list
#        drawn from the wrong range, and an empty one reads as "0 tests, all green" — so the
#        only honest outcome is to stop and say what to run to recover.
# Never reads frontmatter — frontmatter is Tier 2 (LLM in run-tests/SKILL.md).
# Never returns tests/_archive/ entries.

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: bin/select-tests.sh --auto | bin/select-tests.sh <merge-base-ref>" >&2
  exit 1
fi

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TESTS_DIR="${AGENTS_DIR}/tests"

# --auto: ask bin/resolve-merge-base.sh instead of trusting whatever the caller computed.
# The resolver answers with a STATE as well as a base, and the states are not interchangeable —
# the whole point of #1638 is that "resolved" and "resolved to something implausible" used to
# be the same value here.
if [[ "$1" == "--auto" ]]; then
  resolver="${AGENTS_DIR}/bin/resolve-merge-base.sh"
  if [[ ! -r "$resolver" ]]; then
    # basename only — $resolver is rooted at $AGENTS_DIR, an absolute host filesystem path,
    # and this message reaches operator-visible output.
    echo "[select-tests] the merge-base resolver is missing at bin/$(basename "$resolver"); test selection aborted." >&2
    echo "[select-tests] this is a broken install, not an empty diff — reinstall, then re-run." >&2
    exit 4
  fi
  mb_out=""
  mb_rc=0
  mb_out=$(bash "$resolver" -C . --format kv 2>/dev/null) || mb_rc=$?

  # Exit 3 is the resolver reporting that there is NO base — a single-commit repository, say.
  # Nothing can be selected and nothing is broken, so this stays exit 0 with an empty selection.
  if [[ "$mb_rc" -eq 3 ]]; then
    echo "[select-tests] cannot resolve merge-base; empty selection" >&2
    exit 0
  fi
  # Any other non-zero is the resolver failing to answer (exit 2 = we called it wrongly).
  # Folding that into the empty-selection path would hide a caller defect forever.
  if [[ "$mb_rc" -ne 0 ]]; then
    echo "[select-tests] the merge-base resolver exited ${mb_rc}; test selection aborted." >&2
    echo "[select-tests] run: bin/resolve-merge-base.sh --explain   to see what it could not answer" >&2
    exit 4
  fi

  mb_state=""
  mb_base=""
  mb_warn=""
  mb_alt=""
  mb_detail=""
  while IFS='=' read -r mb_k mb_v; do
    [[ "$mb_v" == "-" || "$mb_v" == "none" ]] && mb_v=""
    case "$mb_k" in
      base)   mb_base="$mb_v" ;;
      state)  mb_state="$mb_v" ;;
      warn)   mb_warn="$mb_v" ;;
      alt_base) mb_alt="$mb_v" ;;
      detail) mb_detail="$mb_v" ;;
    esac
  done <<< "$mb_out"

  case "$mb_state" in
    RECORDED|RESOLVED)
      if [[ -z "$mb_base" ]]; then
        echo "## merge-base: ${mb_state} — the resolver reported no base; test selection aborted." >&2
        echo "[select-tests] run: bin/resolve-merge-base.sh --explain   then record the confirmed base with bin/workflow/record-merge-base-baseline" >&2
        exit 4
      fi
      MERGE_BASE="$mb_base"
      ;;
    *)
      # SUSPECT, FALLBACK, and anything unrecognised. FALLBACK gets the same treatment as
      # SUSPECT deliberately: HEAD~1 is a guess about where a branch started, not an answer.
      echo "## merge-base: ${mb_state:-UNKNOWN} — ${mb_detail:-the resolved merge-base is not trustworthy}" >&2
      echo "[select-tests] merge-base is not trustworthy; test selection aborted." >&2
      echo "[select-tests] run: bin/resolve-merge-base.sh --explain   then record the confirmed base with bin/workflow/record-merge-base-baseline" >&2
      exit 4
      ;;
  esac

  # A warn is a NOTE, not an abort. The recorded base is still where the branch started;
  # aborting because HEAD moved since would refuse to select tests for every session that is
  # still committing — which is all of them.
  if [[ -n "$mb_warn" ]]; then
    echo "[select-tests] note: merge-base warn=${mb_warn} (alt base: ${mb_alt:-unknown}) — proceeding with ${MERGE_BASE}" >&2
  fi
else
  MERGE_BASE="$1"
  # Validate before use in any git command: an unvalidated leading '-' is parsed by git as
  # an option (argument injection), same class of issue bin/review-code-codex already guards
  # its --base ref against.
  if ! [[ "$MERGE_BASE" =~ ^[A-Za-z0-9._/-]+$ ]]; then
    echo "[select-tests] invalid merge-base ref (rejected to prevent injection): '${MERGE_BASE}'" >&2
    exit 1
  fi
fi

changed=$(git diff --name-only "${MERGE_BASE}...HEAD" -- 2>/dev/null) || exit 1

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

# RUN_TL3=on: append TL3-*.sh (real-environment tier) — but only when the diff could
# plausibly break it. The append used to be unconditional, so a docs-only or empty diff pulled
# in the whole expensive tier and any unrelated TL3 failure stopped run_tests dead (#1689).
# The `changed` set from above is reused, so this applies equally to --auto and the positional
# form rather than only to the new path.
_tl3_wanted() {
  [[ -n "${changed}" ]] || return 1   # empty diff: nothing to break
  local helper="${AGENTS_DIR}/bin/is-docs-only" rc=0
  [[ -r "${helper}" ]] || return 0    # cannot ask: run it (see below)
  printf '%s\n' "${changed}" | bash "${helper}" || rc=$?
  case "${rc}" in
    0) return 1 ;;  # docs-only: no code path can regress
    2) return 1 ;;  # no paths to classify
    # exit 1 (not docs-only) and exit 3 (classifier unavailable) both run the tier. The two
    # errors are not symmetric: a needless TL3 run costs minutes, a skipped one ships a
    # regression — so anything we cannot rule out resolves toward running.
    *) return 0 ;;
  esac
}

if [[ -x "${AGENTS_DIR}/bin/get-config-var" ]]; then
  if ! "${AGENTS_DIR}/bin/get-config-var" --is-off RUN_TL3 off 2>/dev/null; then
    if _tl3_wanted; then
      while IFS= read -r tl3; do
        [[ -f "${tl3}" ]] || continue
        _emit_if_new "${tl3}"
      done < <(find "${TESTS_DIR}" -maxdepth 1 -name "TL3-*.sh" | sort)
    fi
  fi
fi

exit 0
