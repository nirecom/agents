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
#
# --auto only: on a branch with NO commits of its own the resolver's base IS HEAD, so
# `<base>...HEAD` is empty by construction while the whole change sits in the working tree
# (#1779). In that case the selection is built from the working tree instead — `git diff HEAD`
# (tracked, staged and unstaged alike) unioned with `git ls-files --others` (untracked) — and a
# note saying so is printed on stderr. The degraded path keeps the same contract as the ordinary
# one: a git failure is exit 1, never a quietly empty selection.

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: bin/select-tests.sh --auto | bin/select-tests.sh <merge-base-ref>" >&2
  exit 1
fi

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TESTS_DIR="${AGENTS_DIR}/tests"

# Initialised for BOTH invocation forms: the positional form is defined as "the caller already
# resolved the range", so it never degrades, but it reaches the same reference below under `set -u`.
MB_ZERO_COMMIT=0

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
  mb_base_is_head=""
  while IFS='=' read -r mb_k mb_v; do
    [[ "$mb_v" == "-" || "$mb_v" == "none" ]] && mb_v=""
    case "$mb_k" in
      base)   mb_base="$mb_v" ;;
      state)  mb_state="$mb_v" ;;
      warn)   mb_warn="$mb_v" ;;
      alt_base) mb_alt="$mb_v" ;;
      detail) mb_detail="$mb_v" ;;
      base_is_head) mb_base_is_head="$mb_v" ;;
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
      # #1779. Asked only in the two TRUSTWORTHY states: SUSPECT/FALLBACK abort below, and an
      # observation derived from a base we do not believe is not worth acting on.
      case "$mb_base_is_head" in
        true)  MB_ZERO_COMMIT=1 ;;
        false) : ;;
        *)
          # Absent (a resolver older than the fix, or a stub), or a value this parser does not
          # recognise. Neither is evidence of anything, and reading it as `false` would restore
          # the #1779 bug permanently and silently — so the one-line observation is made here
          # instead. Only the observation is duplicated; what to do about it stays in one place.
          _head_sha="$(git rev-parse --verify --quiet HEAD 2>/dev/null)" || _head_sha=""
          _base_sha="$(git rev-parse --verify --quiet "${MERGE_BASE}^{commit}" 2>/dev/null)" || _base_sha=""
          if [[ -n "$_head_sha" && "$_head_sha" == "$_base_sha" ]]; then
            MB_ZERO_COMMIT=1
            echo "[select-tests] note: the resolver did not report base_is_head; observed locally" >&2
          fi
          ;;
      esac
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

if [[ "$MB_ZERO_COMMIT" -eq 1 ]]; then
  echo "[select-tests] note: this branch has no commits yet (base == HEAD); selecting from the working tree" >&2
  # Each git call keeps the documented contract: a git failure is exit 1, never an empty
  # selection. `|| true` here would turn an unreadable working tree into "0 tests, all green",
  # and running both inside one `{ ...; } | sort -u` would lose the failure the same way.
  #
  # `--full-name -- :/` because `git ls-files` is cwd-relative and cwd-limited by default while
  # `git diff --name-only` is repo-root-relative over the whole tree; without it the two halves
  # would use different path spellings when the selector is invoked from a subdirectory.
  #
  # No union with `<base>...HEAD` is needed: base == HEAD makes that range empty by definition.
  tracked_changed=$(git diff HEAD --name-only 2>/dev/null) || exit 1
  untracked_changed=$(git ls-files --others --exclude-standard --full-name -- :/ 2>/dev/null) || exit 1
  # `sed '/^$/d'`: when either half is empty, `printf '%s\n'` still emits a blank line, and a
  # `changed` that is blank-but-not-empty would make the TL3 gate below fire on nothing.
  changed=$({ printf '%s\n' "$tracked_changed"; printf '%s\n' "$untracked_changed"; } | sed '/^$/d' | sort -u)
else
  changed=$(git diff --name-only "${MERGE_BASE}...HEAD" -- 2>/dev/null) || exit 1
fi

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
