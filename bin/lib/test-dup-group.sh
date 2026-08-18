#!/usr/bin/env bash
# bin/lib/test-dup-group.sh — source-only; not executable. Read-only `# Tests:`
# duplicate-group inventory shared by bin/audit-tests.sh and audit-tests-common.sh
# (#2065) so both entrypoints emit byte-identical TSV (CPR-ORTH). Headers are read
# only through tfm_parse_tests_line / tfm_token_format_ok (CPR-SSOT).
# TSV: `#axis<TAB>key<TAB>count<TAB>files`; axis is full|token|skip. Each element
# of key/files is escaped `\`->`\\`, TAB->`\t`, LF->`\n`, CR->`\r`, `,`->`\,`
# (backslash first), then joined with `,`. To decode: take `\` plus the following
# character as one unit and split only on unescaped `,`. Rows come out full,
# token, skip; inside an axis by count descending then escaped key ascending.

_TDG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test-frontmatter-fix.sh
source "$_TDG_DIR/test-frontmatter-fix.sh"

# Output globals (set by tdg_classify; readable after a non-subshell call).
TDG_VERDICT=""

# tdg_escape_field <string> — the reversible per-element transform above.
tdg_escape_field() {
  local s="${1-}"
  s="${s//\\/\\\\}"
  s="${s//$'\t'/\\t}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//,/\\,}"
  printf '%s' "$s"
}

# tdg_classify <file> — thin wrapper over the shared parser. Prints and sets
# TDG_VERDICT to ok | no_tests_header | duplicate_header | late_header |
# malformed_header. Priority is duplicate > late > malformed so one file is
# counted under exactly one skip reason (S1-1). No regex and no root-like list
# live here; format validity is tfm_token_format_ok's answer alone.
tdg_classify() {
  local file="${1:?tdg_classify: file required}"
  local tok
  tfm_parse_tests_line "$file"
  if [[ "$TFM_HEADER_COUNT" -ge 2 ]]; then
    TDG_VERDICT="duplicate_header"
  elif [[ "$TFM_PRESENT" -eq 0 || -z "$TFM_TESTS_CSV" || "${#TFM_TOKENS[@]}" -eq 0 ]]; then
    TDG_VERDICT="no_tests_header"
  elif [[ "$TFM_HEADER_LINENO" -gt "$FRONTMATTER_HEADER_MAX_LINE" ]]; then
    TDG_VERDICT="late_header"
  elif [[ "$TFM_EMPTY_ELEMENT" -eq 1 ]]; then
    # codex C2: `a,,b` / `,a` / `a,` is a malformed value, not a shorter one —
    # silently dropping the hole would seed a key no reviewer can act on.
    TDG_VERDICT="malformed_header"
  else
    TDG_VERDICT="ok"
    for tok in "${TFM_TOKENS[@]}"; do
      if ! tfm_token_format_ok "$tok"; then
        TDG_VERDICT="malformed_header"
        break
      fi
    done
  fi
  printf '%s\n' "$TDG_VERDICT"
}

# tdg_scan_corpus <repo-root> — emits `axis<TAB>key<TAB>escaped-file` per
# membership. The scan range is `<repo-root>/tests/*.sh` only: `*` does not cross
# `/`, so sibling fragments (tests/<stem>/*.sh) and tests/_archive/ are outside
# it by construction. That exclusion is a contract, not an accident.
tdg_scan_corpus() {
  local root="${1:?tdg_scan_corpus: repo root required}"
  local f rel esc_file full_key tok
  for f in "$root"/tests/*.sh; do
    [[ -f "$f" ]] || continue
    rel="tests/${f##*/}"
    esc_file="$(tdg_escape_field "$rel")"
    tdg_classify "$f" >/dev/null
    if [[ "$TDG_VERDICT" != "ok" ]]; then
      printf 'skip\t%s\t%s\n' "$TDG_VERDICT" "$esc_file"
      continue
    fi
    full_key=""
    for tok in "${TFM_TOKENS[@]}"; do
      full_key="${full_key:+$full_key,}$(tdg_escape_field "$tok")"
    done
    printf 'full\t%s\t%s\n' "$full_key" "$esc_file"
    printf 'token\t%s\t%s\n' "$(tdg_escape_field "${TFM_TOKENS[0]}")" "$esc_file"
  done
}

# tdg_group_rows <repo-root> — the aggregated data rows, without the header.
# Sorting runs on the escaped representation, which by construction carries no
# TAB, LF or CR, so `sort` sees a clean 5-column grid.
tdg_group_rows() {
  local root="${1:?tdg_group_rows: repo root required}"
  local tab
  tab="$(printf '\t')"
  tdg_scan_corpus "$root" | awk -F'\t' '
    {
      k = $1 SUBSEP $2
      if (!(k in cnt)) { cnt[k] = 0; files[k] = ""; ax[k] = $1; ky[k] = $2; ord[++n] = k }
      cnt[k]++
      files[k] = (files[k] == "" ? $3 : files[k] "," $3)
    }
    END {
      for (i = 1; i <= n; i++) {
        k = ord[i]
        r = (ax[k] == "full") ? 1 : ((ax[k] == "token") ? 2 : 3)
        if (r < 3 && cnt[k] < 2) continue
        printf "%d\t%d\t%s\t%s\t%s\n", r, cnt[k], ky[k], ax[k], files[k]
      }
    }' | sort -t"$tab" -k1,1n -k2,2nr -k3,3 | awk -F'\t' '{ printf "%s\t%s\t%s\t%s\n", $4, $3, $2, $5 }'
}

# tdg_emit_tsv <repo-root> — the column-name comment plus the data rows.
tdg_emit_tsv() {
  local root="${1:?tdg_emit_tsv: repo root required}"
  printf '#axis\tkey\tcount\tfiles\n'
  tdg_group_rows "$root"
}

# tdg_run <repo-root> — emit, then decide the exit contract: 0 when at least one
# full/token group exists, 1 when there is none (skip-only counts as none).
tdg_run() {
  local root="${1:?tdg_run: repo root required}"
  local out
  out="$(tdg_emit_tsv "$root")"
  printf '%s\n' "$out"
  if printf '%s\n' "$out" \
    | awk -F'\t' 'substr($0,1,1)=="#" { next } $1=="full" || $1=="token" { f=1 } END { exit f ? 0 : 1 }'; then
    return 0
  fi
  return 1
}

# tdg_mode_guard <dup_groups> <explicit_apply> <fix_headers> <format> — mode
# exclusivity, identical from both entrypoints. <explicit_apply> must be the
# caller's FIX_APPLY: $APPLY is 1 by default under apply-by-default and would
# invert the check (bare --dup-groups rejected, --dry-run accepted).
tdg_mode_guard() {
  local dup="${1:-0}" explicit_apply="${2:-0}" fix_headers="${3:-0}" format="${4:-text}"
  [[ "$dup" -eq 1 ]] || return 0
  if [[ "$explicit_apply" -eq 1 ]]; then
    echo "ERROR: --dup-groups is read-only; --apply is not applicable" >&2
    return 1
  fi
  if [[ "$fix_headers" -eq 1 ]]; then
    echo "ERROR: --dup-groups and --fix-headers are separate modes" >&2
    return 1
  fi
  if [[ "$format" == "json" ]]; then
    echo "ERROR: --dup-groups emits TSV only (--format json is not supported)" >&2
    return 1
  fi
  return 0
}
