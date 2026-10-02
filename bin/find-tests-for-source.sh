#!/usr/bin/env bash
# bin/find-tests-for-source.sh — read-only. Answers "does this source set already
# have a test file to append to?" for write-tests (WT-5) and review-tests (RT-1a).
# Usage: find-tests-for-source.sh --sources <path>[,<path>...] [--sources ...] | --test-file <path>
#                                 [--root <repo-root>] [--hard-max <n>]
# One TSV row per query, no header:
#   query verdict reason target target_lines candidates viable excluded
# Exit 0 = a decision was made (`new` / `skipped` are decisions, not failures),
# 2 = usage error, 3 = environment error, 4 = no host test lane freed within the
# wait cap (see docs/architecture/claude-code/test-host-lanes.md). The criteria
# themselves live in skills/_shared/test-design/append-vs-new.md.

set -uo pipefail

_FTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/test-route-destination.sh
source "$_FTS_DIR/lib/test-route-destination.sh"
# shellcheck source=lib/run-all-parallelism.sh
source "$_FTS_DIR/lib/run-all-parallelism.sh"
# shellcheck source=lib/test-corpus-cache.sh
source "$_FTS_DIR/lib/test-corpus-cache.sh"
# shellcheck source=lib/test-host-lanes.sh
source "$_FTS_DIR/lib/test-host-lanes.sh"

usage_error() {
  printf 'ERROR: %s\n' "$1" >&2
  printf 'Usage: find-tests-for-source.sh --sources <csv> [--sources ...] | --test-file <path> [--root <dir>] [--hard-max <n>]\n' >&2
  exit 2
}

env_error() {
  printf 'ERROR: %s\n' "$1" >&2
  exit 3
}

declare -a SOURCES=() TESTFILES=() SPLIT_OUT=()
declare -a QKEYS=() QCOLS=()
ROOT_OPT=""
HARD_MAX="$TRD_HARD_MAX_DEFAULT"

# split_csv <csv> — splits on every `,`, KEEPING empty elements so `a,,b`, `,a`
# and `a,` stay usage errors instead of silently shrinking the query set.
split_csv() {
  local rest="${1-}" part
  SPLIT_OUT=()
  while true; do
    if [[ "$rest" == *,* ]]; then
      part="${rest%%,*}"
      rest="${rest#*,}"
      SPLIT_OUT+=("$part")
    else
      SPLIT_OUT+=("$rest")
      break
    fi
  done
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --sources)
      [[ "$#" -ge 2 ]] || usage_error "--sources requires a value"
      SOURCES+=("$2")
      shift 2 ;;
    --test-file)
      [[ "$#" -ge 2 ]] || usage_error "--test-file requires a value"
      TESTFILES+=("$2")
      shift 2 ;;
    --root)
      [[ "$#" -ge 2 ]] || usage_error "--root requires a value"
      ROOT_OPT="$2"
      shift 2 ;;
    --hard-max)
      [[ "$#" -ge 2 ]] || usage_error "--hard-max requires a value"
      HARD_MAX="$2"
      shift 2 ;;
    *)
      usage_error "unknown option: $1" ;;
  esac
done

if [[ "${#SOURCES[@]}" -gt 0 && "${#TESTFILES[@]}" -gt 0 ]]; then
  usage_error "--sources and --test-file are mutually exclusive"
fi
if [[ "${#SOURCES[@]}" -eq 0 && "${#TESTFILES[@]}" -eq 0 ]]; then
  usage_error "one of --sources or --test-file is required"
fi
[[ "$HARD_MAX" =~ ^[0-9]+$ ]] || usage_error "--hard-max must be a non-negative integer: $HARD_MAX"

# Query validation precedes root resolution: a usage error must win over an
# environment error whichever way the two are combined.
for _csv in "${SOURCES[@]+"${SOURCES[@]}"}"; do
  split_csv "$_csv"
  declare -a _CSET=()
  trd_canonicalize_set _CSET "${SPLIT_OUT[@]}" \
    || usage_error "--sources holds an empty or unsafe token: $_csv"
  _QK=""
  _QC=""
  for _t in "${_CSET[@]}"; do
    if [[ -z "$_QK" ]]; then _QK="$_t"; else _QK="$_QK"$'\n'"$_t"; fi
    tdg_escape_field "$_t" >/dev/null
    _QC="${_QC:+$_QC,}$TDG_ESCAPED"
  done
  QKEYS+=("$_QK")
  QCOLS+=("$_QC")
done

if [[ -n "$ROOT_OPT" ]]; then
  [[ -d "$ROOT_OPT" ]] || env_error "--root is not a directory: $ROOT_OPT"
  git -C "$ROOT_OPT" rev-parse --show-toplevel >/dev/null 2>&1 \
    || env_error "--root is not inside a git repository: $ROOT_OPT"
  ROOT="$ROOT_OPT"
else
  ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  [[ -n "$ROOT" && -d "$ROOT" ]] || env_error "could not resolve the repository root"
fi
[[ -d "$ROOT/tests" ]] || env_error "no tests/ directory under $ROOT"

# The lease and the cache dir resolve against the caller's cwd, so both run
# before the cd; the EXIT trap releases the lane on every exit path.
thl_init_dir
trap 'thl_release_all' EXIT
trap 'exit 130' INT TERM
if ! thl_find_tests_lease; then
  printf '[find-tests] no test lane freed within %ss; inspect holders with: bash bin/test-lanes-status.sh\n' "$THL_WAIT_CAP_USED" >&2
  exit 4
fi
cd "$ROOT" || env_error "could not enter $ROOT"

tcc_load_corpus_cached "$ROOT"

emit_flat() {
  printf '%s\t%s\t%s\t-\t-\t-\t-\t-\n' "$1" "$2" "$3"
}

for _i in "${!QKEYS[@]}"; do
  trd_decide "${QKEYS[$_i]}" "" "$HARD_MAX"
  trd_row "${QCOLS[$_i]}"
done

# Pass 1 collects the in-corpus test files so ONE _tdg_batch_matches (one awk)
# serves every --test-file query; pass 2 answers in input order.
declare -a _TESC=() _TBATCH=() _TIDX=()
for _i in "${!TESTFILES[@]}"; do
  tdg_escape_field "${TESTFILES[$_i]}" >/dev/null
  _TESC[_i]="$TDG_ESCAPED"
  _TIDX[_i]=-1
  if trd_is_in_corpus "${TESTFILES[$_i]}"; then
    _TIDX[_i]="${#_TBATCH[@]}"
    _TBATCH+=("${TESTFILES[$_i]}")
  fi
done
TDG_MATCHES=()
[[ "${#_TBATCH[@]}" -gt 0 ]] && _tdg_batch_matches "${_TBATCH[@]}"

for _i in "${!TESTFILES[@]}"; do
  _tf="${TESTFILES[$_i]}"
  _ESC="${_TESC[$_i]}"
  if [[ "${_TIDX[$_i]}" -lt 0 ]]; then
    emit_flat "$_ESC" "skipped" "not-top-level"
    continue
  fi
  if ! trd_validate_test_matches "${TDG_MATCHES[${_TIDX[$_i]}]-}"; then
    emit_flat "$_ESC" "new" "query-unparsable:$TRD_CLASSIFY_VERDICT"
    continue
  fi
  declare -a _TSET=()
  if ! trd_canonicalize_set _TSET "${TFM_TOKENS[@]}"; then
    emit_flat "$_ESC" "new" "query-unparsable:malformed_header"
    continue
  fi
  _TK=""
  for _t in "${_TSET[@]}"; do
    if [[ -z "$_TK" ]]; then _TK="$_t"; else _TK="$_TK"$'\n'"$_t"; fi
  done
  trd_decide "$_TK" "$_tf" "$HARD_MAX"
  trd_row "$_ESC"
done

exit 0
