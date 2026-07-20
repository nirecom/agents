#!/usr/bin/env bash
# Shared `# Tests:` header classification + fix helpers for audit-tests.sh and
# audit-tests-common.sh (CPR-2: single source, sourced by both).
# Source this file (do not export). Requires FRONTMATTER_TOKEN_VALID_RE.

_TFF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test-frontmatter-constants.sh
source "$_TFF_DIR/test-frontmatter-constants.sh"

# find_renamed_path <old_path> — prints the new path if <old_path> was renamed
# (git rename tracking), else empty.
find_renamed_path() {
  local old_path="$1"
  # Scan all rename records; return the new path of the first commit that
  # renamed exactly <old_path>. `--follow -- <old>` misses this once <old> is
  # gone, so match the rename's source column directly.
  git log -M --diff-filter=R --name-status --format="" 2>/dev/null \
    | awk -v o="$old_path" '$1 ~ /^R[0-9]*$/ && $2 == o { print $3; exit }' \
    || true
}

# normalize_token <raw> — extracts the first path-like part of a malformed token.
# Prints the normalized token, or empty when no path-like part exists.
# When the raw token contains 2+ '(' groups, the output is prefixed with
# "__MULTI_PAREN__:" so callers can block auto-apply.
normalize_token() {
  local raw="$1"
  local paren_str="${raw//[^(]/}"
  local paren_count="${#paren_str}"

  local pre
  if [[ "$raw" == *"("* ]]; then
    pre="${raw%%(*}"
  else
    pre="$raw"
  fi
  # Strip em-dash annotations and trailing text.
  pre="${pre%%—*}"
  pre="$(printf '%s' "$pre" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

  local result="" word
  # shellcheck disable=SC2086
  for word in $pre; do
    [[ "$word" == --* ]] && continue
    [[ "$word" == *"*"* || "$word" == *"?"* ]] && continue
    if [[ "$word" == */* ]] || [[ "$word" =~ \.[a-zA-Z0-9]+$ ]]; then
      if [[ "$word" =~ $FRONTMATTER_TOKEN_VALID_RE ]]; then
        result="$word"
        break
      fi
    fi
  done

  if [[ "$paren_count" -ge 2 ]]; then
    printf '__MULTI_PAREN__:%s' "$result"
  else
    printf '%s' "$result"
  fi
}

# classify_tests_header <file> — classifies each `# Tests:` token into buckets.
# Sets globals:
#   CHR_HAS_A / CHR_HAS_B / CHR_HAS_C : any A(format-bad)/B(renamed)/C(missing) token
#   CHR_ALL_C           : 1 when every token is format-OK + missing + no-rename (delete candidate)
#   CHR_MULTI_PAREN     : 1 when any token has 2+ paren groups
#   CHR_TOKENS_OK       : format-OK, path exists
#   CHR_TOKENS_FIX_A    : format-bad, normalizes to an existing path
#   CHR_TOKENS_FIX_B    : format-OK, renamed  ("old:new")
#   CHR_TOKENS_FIX_AB   : format-bad, renamed ("old:new")
#   CHR_TOKENS_C        : format-OK, missing, no rename
#   CHR_TOKENS_C_A      : format-bad, missing, no rename
#   CHR_TOKENS_MRR      : format-bad, normalizes to empty (manual review)
classify_tests_header() {
  local file="$1"
  CHR_TOKENS_OK=()
  CHR_TOKENS_FIX_A=()
  CHR_TOKENS_FIX_B=()
  CHR_TOKENS_FIX_AB=()
  CHR_TOKENS_C=()
  CHR_TOKENS_C_A=()
  CHR_TOKENS_MRR=()
  CHR_HAS_A=0
  CHR_HAS_B=0
  CHR_HAS_C=0
  CHR_ALL_C=0
  CHR_MULTI_PAREN=0

  local tests_line
  tests_line="$(grep -m1 -E '^# Tests:' "$file" 2>/dev/null || true)"
  [[ -z "$tests_line" ]] && return 0

  local csv="${tests_line#\# Tests:}"
  csv="${csv# }"
  [[ -z "$csv" ]] && return 0

  local raw_tokens raw_tok tok a_flag eff norm
  IFS=',' read -r -a raw_tokens <<< "$csv"
  for raw_tok in "${raw_tokens[@]}"; do
    tok="$(printf '%s' "$raw_tok" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [[ -z "$tok" ]] && continue

    a_flag=0
    eff="$tok"
    if [[ ! "$tok" =~ $FRONTMATTER_TOKEN_VALID_RE ]]; then
      a_flag=1
      CHR_HAS_A=1
      norm="$(normalize_token "$tok")"
      if [[ "$norm" == __MULTI_PAREN__:* ]]; then
        CHR_MULTI_PAREN=1
        eff="${norm#__MULTI_PAREN__:}"
      else
        eff="$norm"
      fi
      if [[ -z "$eff" ]]; then
        CHR_TOKENS_MRR+=("$tok")
        continue
      fi
    fi

    if [[ -e "$eff" ]]; then
      if [[ "$a_flag" -eq 1 ]]; then
        CHR_TOKENS_FIX_A+=("$eff")
      else
        CHR_TOKENS_OK+=("$eff")
      fi
    else
      local renamed
      renamed="$(find_renamed_path "$eff")"
      if [[ -n "$renamed" ]]; then
        CHR_HAS_B=1
        if [[ "$a_flag" -eq 1 ]]; then
          CHR_TOKENS_FIX_AB+=("${eff}:${renamed}")
        else
          CHR_TOKENS_FIX_B+=("${eff}:${renamed}")
        fi
      else
        CHR_HAS_C=1
        if [[ "$a_flag" -eq 1 ]]; then
          CHR_TOKENS_C_A+=("$eff")
        else
          CHR_TOKENS_C+=("$eff")
        fi
      fi
    fi
  done

  if [[ "$CHR_HAS_A" -eq 0 && "$CHR_HAS_B" -eq 0 && "$CHR_HAS_C" -eq 1 && "${#CHR_TOKENS_OK[@]}" -eq 0 ]]; then
    CHR_ALL_C=1
  fi
  return 0
}

# _fix_headers_report <file> — reports what needs fixing; makes no changes.
_fix_headers_report() {
  local file="$1"
  classify_tests_header "$file"

  local t
  for t in "${CHR_TOKENS_MRR[@]:-}"; do
    [[ -z "$t" ]] && continue
    echo "MANUAL_REVIEW_REQUIRED: ${file}: ${t}"
  done
  for t in "${CHR_TOKENS_FIX_A[@]:-}"; do
    [[ -z "$t" ]] && continue
    echo "FIX_A: ${file}: ${t}"
  done
  for t in "${CHR_TOKENS_C_A[@]:-}"; do
    [[ -z "$t" ]] && continue
    echo "FIX_A: ${file}: ${t} (path missing)"
  done
  for t in "${CHR_TOKENS_FIX_B[@]:-}"; do
    [[ -z "$t" ]] && continue
    echo "FIX_B: ${file}: ${t%%:*} -> ${t#*:}"
  done
  for t in "${CHR_TOKENS_FIX_AB[@]:-}"; do
    [[ -z "$t" ]] && continue
    echo "FIX_AB: ${file}: ${t%%:*} -> ${t#*:} (format fix also needed)"
  done
  for t in "${CHR_TOKENS_C[@]:-}"; do
    [[ -z "$t" ]] && continue
    echo "C: ${file}: ${t} (path missing, no rename)"
  done
  if [[ "$CHR_MULTI_PAREN" -eq 1 ]]; then
    echo "MANUAL_REVIEW_REQUIRED: ${file}: multi-paren token (extra parenthesized parts dropped)"
  fi
}

# _rebuild_tests_value <file> — prints the corrected `# Tests:` CSV value.
_rebuild_tests_value() {
  local file="$1"
  local tests_line csv
  tests_line="$(grep -m1 -E '^# Tests:' "$file" 2>/dev/null || true)"
  csv="${tests_line#\# Tests:}"
  csv="${csv# }"
  local toks tok trimmed out=()
  IFS=',' read -r -a toks <<< "$csv"
  for tok in "${toks[@]}"; do
    trimmed="$(printf '%s' "$tok" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [[ -z "$trimmed" ]] && continue
    local eff
    if [[ "$trimmed" =~ $FRONTMATTER_TOKEN_VALID_RE ]]; then
      if [[ -e "$trimmed" ]]; then
        eff="$trimmed"
      else
        local rn; rn="$(find_renamed_path "$trimmed")"
        if [[ -n "$rn" ]]; then eff="$rn"; else eff="$trimmed"; fi
      fi
    else
      local nr; nr="$(normalize_token "$trimmed")"
      eff="${nr#__MULTI_PAREN__:}"
    fi
    [[ -n "$eff" ]] && out+=("$eff")
  done
  local joined="" i
  for i in "${!out[@]}"; do
    if [[ "$i" -eq 0 ]]; then joined="${out[$i]}"; else joined="${joined}, ${out[$i]}"; fi
  done
  printf '%s' "$joined"
}

# _fix_headers_apply <file> — atomically rewrites the `# Tests:` header,
# preserving the file mode. Blocked cases print a SKIP_* line and leave the
# file unchanged.
_fix_headers_apply() {
  local file="$1"
  classify_tests_header "$file"

  if [[ "$CHR_MULTI_PAREN" -eq 1 ]]; then
    echo "SKIP_APPLY_MULTI_PAREN: ${file}"
    return 0
  fi
  if [[ "${#CHR_TOKENS_C_A[@]}" -gt 0 || "${#CHR_TOKENS_MRR[@]}" -gt 0 ]]; then
    echo "SKIP_APPLY_HAS_AC: ${file}"
    return 0
  fi
  if [[ "${#CHR_TOKENS_FIX_A[@]}" -eq 0 && "${#CHR_TOKENS_FIX_B[@]}" -eq 0 && "${#CHR_TOKENS_FIX_AB[@]}" -eq 0 ]]; then
    return 0
  fi

  local new_value
  new_value="$(_rebuild_tests_value "$file")"
  [[ -z "$new_value" ]] && return 0

  local tmp; tmp="$(mktemp)"
  local replaced=0 line
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$replaced" -eq 0 && "$line" == '# Tests:'* ]]; then
      printf '# Tests: %s\n' "$new_value" >> "$tmp"
      replaced=1
    else
      printf '%s\n' "$line" >> "$tmp"
    fi
  done < "$file"

  # Preserve file mode.
  local mode
  mode="$(stat -c '%a' "$file" 2>/dev/null || stat -f '%Lp' "$file" 2>/dev/null || true)"
  if [[ -n "$mode" ]]; then
    chmod "$mode" "$tmp" 2>/dev/null || true
  fi
  [[ -x "$file" ]] && { chmod +x "$tmp" 2>/dev/null || true; }

  mv "$tmp" "$file"
  echo "APPLIED: ${file}: # Tests: ${new_value}"
}
