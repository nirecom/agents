#!/usr/bin/env bash
# bin/lib/test-retire-predicate.sh — source-only; not executable.
# SSOT for the survival-first retire predicate shared by bin/audit-tests.sh and
# bin/audit-tests-common.sh (#1833) — neither may inline a copy (CPR-SSOT).
# Two axes stay explicitly apart (CPR-SC): SURVIVAL (do the `# Tests:` targets
# still exist? decides candidacy) and ISSUE METADATA (is the issue closed and
# stale? decides only whether a candidate may be deleted).
# Every path resolves against an explicit <repo-root>, never the caller's CWD:
# classify_tests_header() tests `[[ -e ]]` relative to $PWD, and with
# apply-by-default a wrong CWD would delete a live tests/ tree.

_TRP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test-frontmatter-constants.sh
source "$_TRP_DIR/test-frontmatter-constants.sh"
# shellcheck source=test-frontmatter-fix.sh
source "$_TRP_DIR/test-frontmatter-fix.sh"

# Configuration globals (callers may override before use).
TRP_GH_TIMEOUT="${GH_TIMEOUT:-30}"
TRP_OFFLINE=0
TRP_REPO_SLUG=""
TRP_CUTOFF_DATE=""

# Output globals (set by the functions below; readable after a non-subshell call).
TRP_VERDICT=""
TRP_GATE=""
TRP_ISSUE_META=""
TRP_TESTS_CSV=""
TRP_TOKENS_ALL=()
TRP_TOKENS_MISSING=()
TRP_SIBLING=""
TRP_SIBLING_COUNT=0
TRP_UNIT_PATHS=()

# ── repo root ───────────────────────────────────────────────────────────────

# trp_require_repo_root — prints the repo root, or returns 1 (fail closed).
trp_require_repo_root() {
  local root
  root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  if [[ -z "$root" || ! -d "$root" ]]; then
    return 1
  fi
  printf '%s\n' "$root"
}

# ── filename axes ───────────────────────────────────────────────────────────

# trp_scope_of <filename> — issue-specific | common. Pure filename shape;
# independent of whether the name carries an issue reference at all.
trp_scope_of() {
  local name="${1##*/}"
  if [[ "$name" =~ ^feature-[0-9]+- ]]; then
    printf 'issue-specific\n'
  else
    printf 'common\n'
  fi
}

# trp_issue_ref <filename> — explicit | ambiguous | none.
# explicit  : `<feature|fix|feat>-<N>-` prefix — a real issue number.
# ambiguous : any OTHER hyphen-delimited all-digit segment (`…-<N>-…` or a
#             trailing `…-<N>`); fail closed regardless of digit count.
# none      : no hyphen-delimited all-digit segment at all. Digits fused into a
#             word segment (`canary5`, `layer3`) are part of the name.
# The boundary is DELIMITATION, not digit count: a length threshold would make
# `feat-foo-7` (a real reference) indistinguishable from `feat-foo-bar` (none)
# and delete it without ever checking issue state.
trp_issue_ref() {
  local name="${1##*/}"
  local stem="${name%.sh}"
  if [[ "$stem" =~ ^(feature|fix|feat)-([0-9]+)- ]]; then
    printf 'explicit\n'
    return 0
  fi
  if [[ "$stem" =~ (^|-)[0-9]+(-|$) ]]; then
    printf 'ambiguous\n'
    return 0
  fi
  printf 'none\n'
}

# trp_issue_number <filename> — the explicit issue number, or empty.
trp_issue_number() {
  local name="${1##*/}"
  local stem="${name%.sh}"
  if [[ "$stem" =~ ^(feature|fix|feat)-([0-9]+)- ]]; then
    printf '%s' "${BASH_REMATCH[2]}"
  fi
}

# ── survival predicate ──────────────────────────────────────────────────────

# trp_survival_verdict <repo-root> <test-file> — the primary filter.
# Prints and sets $TRP_VERDICT to one of:
#   no-header      — no `# Tests:` line, or the line carries no token
#   malformed      — at least one token is not a bare path (prose, glob, …)
#   renamed        — at least one missing token resolves through git rename
#   alive          — at least one token's target still exists
#   orphan         — every token is well-formed, missing, and un-renamed
#   undeterminable — none of the above could be established
# Also sets $TRP_TESTS_CSV, $TRP_TOKENS_ALL[], $TRP_TOKENS_MISSING[].
trp_survival_verdict() {
  local repo_root="${1:?trp_survival_verdict: repo root required}"
  local file="${2:?trp_survival_verdict: test file required}"
  local abs="$file"
  [[ "$abs" != /* ]] && abs="$repo_root/$file" || true

  TRP_TESTS_CSV=""
  TRP_TOKENS_ALL=()
  TRP_TOKENS_MISSING=()

  # Tokenizing is the shared parser's job (CPR-SSOT); this predicate only decides
  # survival. Run it BEFORE classify_tests_header, which re-parses and overwrites
  # the TFM_* globals.
  tfm_parse_tests_line "$abs"
  if [[ "$TFM_PRESENT" -eq 0 || -z "$TFM_TESTS_CSV" ]]; then
    TRP_VERDICT="no-header"; printf '%s\n' "$TRP_VERDICT"; return 0
  fi
  TRP_TESTS_CSV="$TFM_TESTS_CSV"

  local trimmed
  for trimmed in "${TFM_TOKENS[@]:+${TFM_TOKENS[@]}}"; do
    TRP_TOKENS_ALL+=("$trimmed")
  done
  if [[ "${#TRP_TOKENS_ALL[@]}" -eq 0 ]]; then
    TRP_VERDICT="no-header"; printf '%s\n' "$TRP_VERDICT"; return 0
  fi

  # classify_tests_header() sets destructive globals, so it must NOT run in a
  # subshell; the CWD is switched around it and restored instead.
  local saved_pwd="$PWD"
  if ! cd "$repo_root" 2>/dev/null; then
    TRP_VERDICT="undeterminable"; printf '%s\n' "$TRP_VERDICT"; return 0
  fi
  classify_tests_header "$abs"
  cd "$saved_pwd" 2>/dev/null || true

  local tok
  for tok in "${CHR_TOKENS_C[@]:-}"; do
    if [[ -n "$tok" ]]; then TRP_TOKENS_MISSING+=("$tok"); fi
  done
  for tok in "${CHR_TOKENS_C_A[@]:-}"; do
    if [[ -n "$tok" ]]; then TRP_TOKENS_MISSING+=("$tok"); fi
  done

  if [[ "$CHR_HAS_A" -eq 1 ]]; then
    TRP_VERDICT="malformed"
  elif [[ "$CHR_HAS_B" -eq 1 ]]; then
    TRP_VERDICT="renamed"
  elif [[ "$CHR_ALL_C" -eq 1 ]]; then
    TRP_VERDICT="orphan"
  elif [[ "${#CHR_TOKENS_OK[@]}" -gt 0 ]]; then
    TRP_VERDICT="alive"
  else
    TRP_VERDICT="undeterminable"
  fi
  printf '%s\n' "$TRP_VERDICT"
}

# ── issue metadata ──────────────────────────────────────────────────────────

# trp_init_gh <offline-flag> — resolves the repo slug once per run. A missing or
# broken gh CLI is a degraded mode (announced on stderr), never a hard error.
trp_init_gh() {
  TRP_OFFLINE="${1:-0}"
  TRP_REPO_SLUG=""
  if [[ "$TRP_OFFLINE" -eq 1 ]]; then return 0; fi
  if ! command -v gh >/dev/null 2>&1; then
    echo "WARNING: gh CLI not found — issue metadata unavailable (offline mode)" >&2
    TRP_OFFLINE=1
    return 0
  fi
  if ! TRP_REPO_SLUG="$(gh repo view --json owner,name --jq '.owner.login + "/" + .name' 2>/dev/null)"; then
    echo "WARNING: gh repo view failed — issue metadata unavailable (offline mode)" >&2
    TRP_OFFLINE=1
    TRP_REPO_SLUG=""
    return 0
  fi
  if [[ -z "$TRP_REPO_SLUG" ]]; then
    echo "WARNING: gh repo view returned no repository slug — offline mode" >&2
    TRP_OFFLINE=1
  fi
  return 0
}

# trp_fetch_issue_meta <issue-number> — prints and sets $TRP_ISSUE_META to one of
#   unavailable | open | closed:<YYYY-MM-DD> | closed: | state:<other>
# `gh` absent, `gh` failing and `gh` timing out are all the same answer:
# the metadata could not be obtained.
trp_fetch_issue_meta() {
  local num="$1"
  local result="unavailable" raw state closed
  if [[ "$TRP_OFFLINE" -eq 0 && -n "$TRP_REPO_SLUG" && -n "$num" ]]; then
    raw="$("$_TRP_DIR/../run-with-timeout.sh" "$TRP_GH_TIMEOUT" \
      gh api "repos/${TRP_REPO_SLUG}/issues/${num}" \
      --jq '.state + " " + (.closed_at // "")' 2>/dev/null | head -1 || true)"
    if [[ -n "$raw" ]]; then
      state="$(printf '%s' "$raw" | cut -d' ' -f1 | tr '[:upper:]' '[:lower:]')"
      closed="$(printf '%s' "$raw" | cut -d' ' -f2-)"
      closed="${closed%%T*}"
      closed="${closed//[[:space:]]/}"
      case "$state" in
        closed) result="closed:${closed}" ;;
        open) result="open" ;;
        "") result="unavailable" ;;
        *) result="state:${state}" ;;
      esac
    fi
  fi
  TRP_ISSUE_META="$result"
  printf '%s\n' "$result"
}

# ── delete gate ─────────────────────────────────────────────────────────────

# trp_delete_gate <survival-verdict> <scope> <issue-ref> <issue-meta>
# Prints and sets $TRP_GATE to one of:
#   ok-no-issue-ref | ok-closed-stale
#   hold-issue-active | hold-metadata-unavailable | hold-ambiguous-issue-ref
# Compares against $TRP_CUTOFF_DATE; STRICTLY older than the cutoff authorises.
trp_delete_gate() {
  local verdict="$1" scope="$2" ref="$3" meta="$4"
  local closed_date
  : "$scope"
  if [[ "$verdict" != "orphan" ]]; then
    TRP_GATE="hold-metadata-unavailable"; printf '%s\n' "$TRP_GATE"; return 0
  fi
  case "$ref" in
    none)
      TRP_GATE="ok-no-issue-ref" ;;
    ambiguous)
      TRP_GATE="hold-ambiguous-issue-ref" ;;
    *)
      case "$meta" in
        unavailable|"closed:")
          TRP_GATE="hold-metadata-unavailable" ;;
        closed:*)
          closed_date="${meta#closed:}"
          if [[ "$closed_date" < "$TRP_CUTOFF_DATE" ]]; then
            TRP_GATE="ok-closed-stale"
          else
            TRP_GATE="hold-issue-active"
          fi ;;
        *)
          TRP_GATE="hold-issue-active" ;;
      esac ;;
  esac
  printf '%s\n' "$TRP_GATE"
}

# trp_gate_line_token <gate> — the report token that states the gate outcome,
# or empty when the gate authorises deletion.
trp_gate_line_token() {
  case "$1" in
    hold-issue-active) printf 'SKIP_DELETE_ISSUE_ACTIVE' ;;
    hold-metadata-unavailable) printf 'SKIP_DELETE_METADATA_UNAVAILABLE' ;;
    hold-ambiguous-issue-ref) printf 'SKIP_DELETE_AMBIGUOUS_REF' ;;
    *) printf '' ;;
  esac
}

# ── deletion unit ───────────────────────────────────────────────────────────

# trp_unit_of <repo-root> <test-relpath> — a test file and its populated
# tests/<stem>/ sibling folder are ONE retire unit. Sets $TRP_SIBLING (relative,
# no trailing slash, empty when absent), $TRP_SIBLING_COUNT and $TRP_UNIT_PATHS[].
trp_unit_of() {
  local repo_root="$1" rel="$2"
  local stem="${rel%.sh}"
  TRP_SIBLING=""
  TRP_SIBLING_COUNT=0
  TRP_UNIT_PATHS=("$rel")
  if [[ -d "$repo_root/$stem" ]]; then
    TRP_SIBLING="$stem"
    TRP_SIBLING_COUNT="$(find "$repo_root/$stem" -type f 2>/dev/null | wc -l | tr -d ' ')"
    TRP_UNIT_PATHS+=("$stem")
  fi
}

# trp_git_rm_unit <path...> — stages the whole unit in one call. On failure the
# error is surfaced on stderr and 1 is returned; nothing is swallowed.
trp_git_rm_unit() {
  local err
  if err="$(git rm -q -r -- "$@" 2>&1)"; then
    return 0
  fi
  if [[ -n "$err" ]]; then printf '%s\n' "$err" >&2; fi
  printf 'ERROR: git rm failed for: %s\n' "$*" >&2
  return 1
}

# ── misc helpers ────────────────────────────────────────────────────────────

# trp_compute_cutoff <stale-months> — prints and sets $TRP_CUTOFF_DATE.
# The argument reaches an arithmetic-expansion context, where an unquoted
# substitution is a code-execution sink (`x[$(cmd)]` runs `cmd`). Both current
# callers pre-validate, but this module is the shared boundary: validate here so
# no future caller inherits the sink. Non-numeric input fails closed (return 1),
# the same idiom as trp_require_repo_root.
trp_compute_cutoff() {
  if [[ ! "${1:-3}" =~ ^[0-9]+$ ]]; then
    printf 'ERROR: trp_compute_cutoff: stale-months must be a non-negative integer: %s\n' "${1:-3}" >&2
    return 1
  fi
  local days=$(( ${1:-3} * 30 ))
  if date -d "${days} days ago" +%Y-%m-%d >/dev/null 2>&1; then
    TRP_CUTOFF_DATE="$(date -d "${days} days ago" +%Y-%m-%d)"
  elif date -v-"${days}"d +%Y-%m-%d >/dev/null 2>&1; then
    TRP_CUTOFF_DATE="$(date -v-"${days}"d +%Y-%m-%d)"
  else
    TRP_CUTOFF_DATE="$(uv run python -c "import datetime; print((datetime.date.today() - datetime.timedelta(days=${days})).isoformat())")"
  fi
  printf '%s\n' "$TRP_CUTOFF_DATE"
}

# trp_json_escape <string> — JSON string-body escaping. Both the filename and
# the `# Tests:` token are attacker-controlled; neither may be interpolated raw.
trp_json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  s="${s//$'\b'/\\b}"
  s="${s//$'\f'/\\f}"
  printf '%s' "$s"
}

# trp_json_array <item...> — a JSON array of escaped strings.
trp_json_array() {
  local out="[" first=1 item
  for item in "$@"; do
    [[ "$first" -eq 1 ]] && first=0 || out+=","
    out+="\"$(trp_json_escape "$item")\""
  done
  printf '%s]' "$out"
}
