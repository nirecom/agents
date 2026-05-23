#!/usr/bin/env bash
# Assemble a final plan file by injecting mandatory sections from a source file.
# Usage: assemble-mandatory.sh [--source-kind intent|outline] <source.md> <planner-output.md> <out.md>
#
# Algorithm:
# 1. Extract ## Issue, ## Class members, ## Accepted Tradeoffs from source.md (with headers)
#    - Legacy soft-fail (--source-kind intent only): if ## Class members absent,
#      auto-inject legacy stub between Issue and Accepted Tradeoffs.
#    - Hard-fail (--source-kind outline): if ## Class members absent, exit 2 with
#      "contract violation".
# 2. Extract H1 line from planner output.
# 3. Strip H1 + mandatory sections from planner body (fence-aware).
# 4. Assemble: H1 + injected block + remaining body.
# 5. Verify: count==1 per section / H1, order, verbatim match against source.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENTS_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
EXTRACT="$AGENTS_ROOT/bin/extract-mandatory-sections"
STRIP_AWK="$SCRIPT_DIR/strip-mandatory-sections.awk"

SOURCE_KIND="intent"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source-kind)
      [[ $# -ge 2 ]] || { echo "assemble-mandatory: --source-kind requires an argument" >&2; exit 2; }
      SOURCE_KIND="$2"
      shift 2
      ;;
    *)
      break
      ;;
  esac
done

if [[ "$SOURCE_KIND" != "intent" && "$SOURCE_KIND" != "outline" ]]; then
  echo "assemble-mandatory: invalid --source-kind '$SOURCE_KIND' (expected: intent|outline)" >&2
  exit 2
fi

SOURCE="${1:?assemble-mandatory: <source.md> required}"
PLANNER_OUT="${2:?assemble-mandatory: <planner-output.md> required}"
OUT="${3:?assemble-mandatory: <out.md> required}"

[[ -f "$SOURCE" ]] || { echo "assemble-mandatory: source file not found: $SOURCE" >&2; exit 2; }
[[ -f "$PLANNER_OUT" ]] || { echo "assemble-mandatory: planner output not found: $PLANNER_OUT" >&2; exit 2; }
[[ -x "$EXTRACT" ]] || { echo "assemble-mandatory: extract-mandatory-sections not executable: $EXTRACT" >&2; exit 2; }
[[ -f "$STRIP_AWK" ]] || { echo "assemble-mandatory: strip awk not found: $STRIP_AWK" >&2; exit 2; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

MANDATORY_NAMES="Issue|Class members|Accepted Tradeoffs"
LEGACY_STUB_TEXT="- (none — legacy intent.md, pre-#462)"

# --- Step 1: Extract injected block ---
"$EXTRACT" "$SOURCE" \
  --section Issue --section "Class members" --section "Accepted Tradeoffs" \
  --with-headers > "$TMP/injected_block"

if ! grep -q "^## Class members$" "$TMP/injected_block"; then
  if [[ "$SOURCE_KIND" == "intent" ]]; then
    # Soft-fail: inject legacy stub between Issue and Accepted Tradeoffs
    echo "assemble-mandatory: WARNING: '## Class members' absent from $SOURCE (pre-#462 intent.md). Injecting legacy stub." >&2

    awk -v stub="$LEGACY_STUB_TEXT" '
      BEGIN { inserted = 0 }
      # Insert stub right before ## Accepted Tradeoffs (if found and not yet inserted)
      /^## Accepted Tradeoffs$/ && !inserted {
        print "## Class members"
        print ""
        print stub
        print ""
        inserted = 1
      }
      { print }
      END {
        # If Accepted Tradeoffs was not found either, append stub at the very end
        if (!inserted) {
          print ""
          print "## Class members"
          print ""
          print stub
        }
      }
    ' "$TMP/injected_block" > "$TMP/injected_block_new"
    mv "$TMP/injected_block_new" "$TMP/injected_block"
  else
    # Hard-fail: outline must have Class members
    echo "assemble-mandatory: contract violation: '## Class members' is absent from $SOURCE (source-kind=outline). outline.md must contain all 3 mandatory sections." >&2
    exit 2
  fi
fi

# --- Step 2: Extract H1 from planner output ---
H1_LINE=$(awk '/^# [^#]/ { print; exit }' "$PLANNER_OUT")
if [[ -z "$H1_LINE" ]]; then
  echo "assemble-mandatory: contract violation: planner output has no H1 line: $PLANNER_OUT" >&2
  exit 3
fi

# --- Step 3: Strip H1 + mandatory sections from planner body ---
awk -v names="$MANDATORY_NAMES" -f "$STRIP_AWK" "$PLANNER_OUT" > "$TMP/remaining_body"

# --- Step 4: Assemble ---
# Trim trailing blank lines from injected_block so that section bodies do not
# accumulate extra newlines. We re-add exactly one blank line as separator.
sed -e :a -e '/^$/{$d;N;ba' -e '}' "$TMP/injected_block" > "$TMP/injected_block_trimmed"

# Trim leading blank lines from remaining_body (the stripped planner body) so
# the separator we add doesn't compound with planner-side leading blanks.
awk 'NF { found=1 } found { print }' "$TMP/remaining_body" > "$TMP/remaining_body_trimmed"

{
  printf '%s\n\n' "$H1_LINE"
  cat "$TMP/injected_block_trimmed"
  printf '\n'
  cat "$TMP/remaining_body_trimmed"
} > "$OUT"

# --- Step 5: Verify ---
verify_fail() {
  echo "assemble-mandatory: verify FAILED: $1" >&2
  exit 4
}

# Fence-aware H2/H1 counting via the extract CLI (which honors code fences).
# We compute counts as "headers found outside of fences". For each section we
# parse the --with-headers output and count `^## <name>$` boundaries.
count_section_headers() {
  local file="$1" section="$2"
  "$EXTRACT" "$file" --section "$section" --with-headers 2>/dev/null \
    | grep -c "^## ${section}$" 2>/dev/null || true
}

# ## Issue is optional: verify count matches source presence.
# ## Class members and ## Accepted Tradeoffs are always required exactly once.
issue_in_src=$(count_section_headers "$SOURCE" "Issue")
[[ -z "$issue_in_src" ]] && issue_in_src=0
issue_in_out=$(count_section_headers "$OUT" "Issue")
[[ -z "$issue_in_out" ]] && issue_in_out=0
if [[ "$issue_in_src" -gt 0 ]]; then
  [[ "$issue_in_out" -eq 1 ]] || verify_fail "## Issue appears ${issue_in_out} times outside fences (expected 1)"
else
  [[ "$issue_in_out" -eq 0 ]] || verify_fail "## Issue appears in output but was absent from source"
fi
for section in "Class members" "Accepted Tradeoffs"; do
  count=$(count_section_headers "$OUT" "$section")
  [[ -z "$count" ]] && count=0
  if [[ "$count" -ne 1 ]]; then
    verify_fail "## ${section} appears ${count} times outside fences (expected 1)"
  fi
done

# Fence-aware H1 count: walk the file with awk, toggling fence state.
h1_count=$(awk '
  BEGIN { in_fence=0; n=0 }
  /^```/ || /^~~~/ { in_fence = !in_fence; next }
  !in_fence && /^# [^#]/ { n++ }
  END { print n }
' "$OUT")
if [[ "$h1_count" -ne 1 ]]; then
  verify_fail "H1 appears ${h1_count} times outside fences (expected 1)"
fi

# Order check: first non-fenced occurrence of each H2.
order_line() {
  local file="$1" section="$2"
  awk -v target="$section" '
    BEGIN { in_fence=0 }
    /^```/ || /^~~~/ { in_fence = !in_fence; next }
    !in_fence && $0 == ("## " target) { print NR; exit }
  ' "$file"
}

ln_issue=$(order_line "$OUT" "Issue")
ln_class=$(order_line "$OUT" "Class members")
ln_tradeoffs=$(order_line "$OUT" "Accepted Tradeoffs")
[[ -n "$ln_class" && -n "$ln_tradeoffs" ]] \
  || verify_fail "mandatory section line numbers missing (class=$ln_class tradeoffs=$ln_tradeoffs)"
# ## Issue is optional; when present it must precede ## Class members.
if [[ -n "$ln_issue" ]]; then
  [[ "$ln_issue" -lt "$ln_class" ]] || verify_fail "## Issue must appear before ## Class members"
fi
[[ "$ln_class" -lt "$ln_tradeoffs" ]] || verify_fail "## Class members must appear before ## Accepted Tradeoffs"

# Verbatim match: each section body must equal the source's body (or the
# injected legacy stub for Class members under intent kind).
for section in "Issue" "Class members" "Accepted Tradeoffs"; do
  src_body=$("$EXTRACT" "$SOURCE" --section "$section" 2>/dev/null || true)
  out_body=$("$EXTRACT" "$OUT" --section "$section" 2>/dev/null || true)
  if [[ "$section" == "Class members" && -z "$src_body" ]]; then
    # Legacy stub case — verify the stub line is present, then skip strict compare.
    if grep -q "legacy intent.md, pre-#462" "$OUT"; then
      continue
    fi
  fi
  if [[ "$src_body" != "$out_body" ]]; then
    verify_fail "## ${section} body in output does not match source"
  fi
done

exit 0
