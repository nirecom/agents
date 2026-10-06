# shellcheck shell=bash
# bin/lib/test-embed-cases.sh — `sweep-tests --embed-cases` for bin/audit-tests.sh and
# bin/audit-tests-common.sh (both call tec_dispatch "$@" right after their source lines).
# Source only. tec_dispatch returns at once unless an embed flag is present; otherwise it
# runs tec_main and exits with its status. Modules: bin/lib/test-embed-cases/.
# Stage protocol contract: docs/architecture/claude-code/sweep-tests-embed-cases.md.

_TEC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEC_TOOL="$(cd "$_TEC_DIR/../.." && pwd)"
# Category list kept per tool, like test-dup-group.sh (consolidation: #2473).
TEC_CATEGORIES="hooks bin skills agents install tests"

tec_usage() {
  printf '%s\n' \
    'Usage: audit-tests.sh --embed-cases [--band-size N] [--order frequency|priority] [--dry-run] [--fix-headers]' \
    '       audit-tests.sh --embed-apply <workdir>' \
    '  --embed-cases         Stage 1: pick one band of tests to wrap in case markers (default: write the workdir).' \
    '  --band-size N         Band size, a positive integer (default 5).' \
    '  --order VALUE         frequency (run-all ledger count, then git churn) or priority (header shape).' \
    '  --dry-run             Print the BAND / SKIP plan only; write nothing.' \
    '  --embed-apply DIR     Stage 3: verify the stage-2 outputs of DIR and apply the passing ones.' \
    'Contract: docs/architecture/claude-code/sweep-tests-embed-cases.md'
}

tec_die() { printf 'ERROR: embed-cases: %s\n' "$1" >&2; return 2; }

tec_dispatch() {
  local a
  for a in "$@"; do
    case "$a" in
      --embed-cases | --embed-apply | --band-size | --order)
        tec_main "$@"
        exit 0
        ;;
    esac
  done
  return 0
}

tec_main() {
  local embed=0 apply_dir="" band="" order="" fix=0 dry=0 help=0 format=text conflict="" root
  sweep_write_mode_init
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --embed-cases) embed=1; shift ;;
      --embed-apply | --band-size | --order | --format | --stale-months)
        [[ "$#" -ge 2 ]] || { tec_die "$1 needs a value"; return 2; }
        case "$1" in
          --embed-apply) apply_dir="$2" ;;
          --band-size) band="$2" ;;
          --order) order="$2" ;;
          --format) format="$2" ;;
          --stale-months) conflict="${conflict:-$1}" ;;
        esac
        shift 2
        ;;
      --fix-headers) fix=1; shift ;;
      --dry-run) sweep_write_mode_dry_run; dry=1; shift ;;
      --apply) sweep_write_mode_apply; shift ;;
      --dup-groups | --offline) conflict="${conflict:-$1}"; shift ;;
      -h | --help) help=1; shift ;;
      *) tec_die "unrecognized option: $1"; return 2 ;;
    esac
  done
  if [[ "$help" -eq 1 ]]; then tec_usage; return 0; fi
  if [[ -n "$apply_dir" ]]; then
    if [[ "$embed" -eq 1 || -n "$band$order" || "$dry" -eq 1 || "$fix" -eq 1 ]]; then
      tec_die "--embed-apply takes no other stage flag"; return 2
    fi
  elif [[ "$embed" -eq 0 ]]; then
    tec_die "--band-size and --order need --embed-cases"; return 2
  fi
  [[ -z "$conflict" ]] || { tec_die "$conflict has no meaning with the embed stages"; return 2; }
  [[ "$format" == text ]] || { tec_die "--format $format is not supported (text only)"; return 2; }
  order="${order:-frequency}"
  case "$order" in frequency | priority) ;; *) tec_die "--order must be frequency or priority (got: $order)"; return 2 ;; esac
  band="${band:-5}"
  # shellcheck source=sweep-band-loop.sh
  . "$_TEC_DIR/sweep-band-loop.sh"
  sweep_band_count 0 "$band" >/dev/null || return 2
  [[ "$fix" -eq 0 ]] || printf 'NOTE: --fix-headers is subsumed by --embed-cases (selected files only)\n' >&2

  root="$(trp_require_repo_root)" || { tec_die "not inside a git repository"; return 2; }
  cd "$root" || return 2
  [[ -d tests ]] || { tec_die "tests/ directory not found under $root"; return 2; }
  tec_load_modules || { tec_die "embed-cases modules unreadable"; return 2; }

  TEC_TMP="$(mktemp -d "${TMPDIR:-/tmp}/tec.XXXXXX")"
  trap 'rm -rf "$TEC_TMP"' EXIT
  # Called bare (no `||`) so errexit stays armed inside the stages.
  if [[ -n "$apply_dir" ]]; then
    tec_stage_apply "$apply_dir"
  else
    tec_stage_plan "$band" "$order"
  fi
}

tec_load_modules() {
  local m
  for m in select order stage-plan stage-apply retry-record; do
    # shellcheck disable=SC1090 # module list above
    . "$_TEC_DIR/test-embed-cases/$m.sh" || return 1
  done
  declare -F crr_read >/dev/null || . "$_TEC_DIR/case-record-reader.sh" || return 1
  declare -F sts_stems_of_path >/dev/null || . "$_TEC_DIR/select-tests-stem.sh" || return 1
  declare -F run_all_dur_counts >/dev/null || . "$_TEC_DIR/run-all-duration-counts.sh" || return 1
  return 0
}

# tec_plans_root — prints <PLANS_DIR>/sweep-tests-embed (no trailing slash).
tec_plans_root() {
  local d
  d="$(bash "$TEC_TOOL/bin/workflow-plans-dir")" || return 1
  [[ -n "$d" ]] || return 1
  printf '%s/sweep-tests-embed\n' "${d%/}"
}
