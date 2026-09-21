#!/usr/bin/env bash
# Assemble a final plan file by injecting mandatory sections from a source file.
# Usage: assemble-mandatory.sh [--source-kind intent|outline] <source.md> <planner-output.md> <out.md>
# <planner-output.md> and <out.md> MAY be the same path (in-place mode, #866): the planner output
# is snapshotted before the final write, so the read and write paths never alias.
# <out.md> must resolve under the plans dir or a system temp root (see the allowlist below).
# Steps: extract `## Issues` (canonical/legacy) + `## Accepted Tradeoffs` and normalize; strip H1
# + mandatory sections (strip still removes planner `## Class members` residue, but Class members
# is no longer injected -- SSOT is intent.md, #2228); assemble into a temp file; verify count,
# order (Issues < Accepted Tradeoffs), verbatim match, and outline first body H2; move temp -> out
# only after every check passes (a failed verify never clobbers a prior valid file).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENTS_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
EXTRACT="$AGENTS_ROOT/bin/extract-mandatory-sections"
STRIP_AWK="$SCRIPT_DIR/strip-mandatory-sections.awk"

# --source-kind is now vestigial (#2228): Class members is no longer injected, so intent vs
# outline no longer branches assembly. The flag is still accepted and validated for CLI
# backward-compat with existing callers; the outline coverage gate keys off the $OUT name instead.
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

# Destination allowlist. $OUT drives both `mktemp -d -p` and the final `mv -f`, so an
# unconstrained third argument is an arbitrary-file-overwrite primitive. Constraining the
# destination ITSELF -- rather than its relation to another argument, which is satisfiable by
# pointing arg2 at any commented file in the target directory -- is what makes the limit
# unreachable by choosing different arguments. Both sides are canonicalised because the path
# spaces differ: under Git Bash `mktemp -d` yields /tmp/... while node's os.tmpdir() yields
# C:/Users/.../Temp/... for that same directory.
_canon() { (CDPATH= cd -- "$1" 2>/dev/null && { pwd -W 2>/dev/null || pwd -P; }); }

_under_root() { # <canonical-dir> <candidate-root>
  local root
  [[ -n "$2" ]] || return 1
  root="$(_canon "$2")"
  [[ -n "$root" ]] || return 1
  [[ "$1" == "$root" || "$1" == "$root"/* ]]
}

OUT_DIR="$(dirname "$OUT")"
OUT_DIR_CANON="$(_canon "$OUT_DIR")"
[[ -n "$OUT_DIR_CANON" ]] || {
  echo "assemble-mandatory: <out.md> directory does not exist or cannot be resolved: $OUT_DIR" >&2
  exit 2
}

NODE_TMPDIR=""
if command -v node > /dev/null 2>&1; then
  NODE_TMPDIR="$(node -e 'process.stdout.write(require("os").tmpdir())' 2>/dev/null || true)"
fi

PLANS_ROOT="${WORKFLOW_PLANS_DIR:-$HOME/.workflow-plans}"
TMP_ROOT="${TMPDIR:-/tmp}"
OUT_ALLOWED=0
for _root in "$PLANS_ROOT" "$TMP_ROOT" "$NODE_TMPDIR"; do
  if _under_root "$OUT_DIR_CANON" "$_root"; then OUT_ALLOWED=1; break; fi
done
[[ "$OUT_ALLOWED" -eq 1 ]] || {
  echo "assemble-mandatory: refusing to write outside the allowed destinations: $OUT" >&2
  echo "assemble-mandatory: <out.md> must resolve under the workflow plans directory ($PLANS_ROOT) or a system temp root ($TMP_ROOT${NODE_TMPDIR:+, $NODE_TMPDIR})" >&2
  exit 2
}

TMP=$(mktemp -d -p "$(dirname "$OUT")" assemble.XXXX)
trap 'rm -rf "$TMP"' EXIT

# In-place detection: when PLANNER_OUT and OUT resolve to the same file (the
# in-place mode used after the drafts/ flatten in #866), the Step 6 final write
# would overwrite the file before the awk passes finish reading it. Snapshot
# the planner output into $TMP so the read path is decoupled from $OUT.
# Argument-driven gate (--source-kind), not inferred from layout.
PLANNER_OUT_READ="$PLANNER_OUT"
if [[ "$(readlink -f "$PLANNER_OUT" 2>/dev/null || echo "$PLANNER_OUT")" == \
      "$(readlink -f "$OUT" 2>/dev/null || echo "$OUT")" ]]; then
  PLANNER_OUT_READ="$TMP/planner_out_snapshot"
  cp -- "$PLANNER_OUT" "$PLANNER_OUT_READ" \
    || { echo "assemble-mandatory: snapshot copy failed" >&2; exit 2; }
fi

# strip awk receives both legacy and canonical heading names so planner-side
# duplicates of either form are removed. Class members stays in the strip set so
# planner-authored residue is removed, even though it is no longer injected (#2228).
MANDATORY_NAMES="Issues|Issue|Class members|Accepted Tradeoffs"

# --- Step 1: Detect issues-section form in source. ---
has_issues_plural=0
has_issue_singular=0
if grep -qE '^## Issues[[:space:]]*$' "$SOURCE"; then
  has_issues_plural=1
fi
if grep -qE '^## Issue[[:space:]]*$' "$SOURCE"; then
  has_issue_singular=1
fi

if [[ "$has_issues_plural" -eq 1 && "$has_issue_singular" -eq 1 ]]; then
  echo "assemble-mandatory: source contains both '## Issue' and '## Issues' — canonical form is '## Issues'; remove the legacy heading: $SOURCE" >&2
  exit 2
fi

if [[ "$has_issues_plural" -eq 1 ]]; then
  ISSUES_SECTION_NAME="Issues"
elif [[ "$has_issue_singular" -eq 1 ]]; then
  ISSUES_SECTION_NAME="Issue"
else
  echo "assemble-mandatory: mandatory section missing: expected '## Issues' (or legacy '## Issue') in $SOURCE" >&2
  exit 2
fi

# --- Step 2: Extract injected block ---
# Class members is intentionally NOT injected (#2228): its SSOT is intent.md.
"$EXTRACT" "$SOURCE" \
  --section "$ISSUES_SECTION_NAME" --section "Accepted Tradeoffs" \
  --with-headers > "$TMP/injected_block"

# --- Step 3: Normalize legacy heading to canonical. ---
if [[ "$ISSUES_SECTION_NAME" == "Issue" ]]; then
  # Use awk to avoid sed -i portability issues on macOS / BSD.
  awk '
    /^## Issue[[:space:]]*$/ { print "## Issues"; next }
    { print }
  ' "$TMP/injected_block" > "$TMP/injected_block_norm"
  mv "$TMP/injected_block_norm" "$TMP/injected_block"
fi

# --- Step 4: Extract H1 from planner output ---
H1_LINE=$(awk '/^# [^#]/ { print; exit }' "$PLANNER_OUT_READ")
if [[ -z "$H1_LINE" ]]; then
  echo "assemble-mandatory: contract violation: planner output has no H1 line: $PLANNER_OUT" >&2
  exit 3
fi

# --- Step 5: Strip H1 + mandatory sections from planner body ---
awk -v names="$MANDATORY_NAMES" -f "$STRIP_AWK" "$PLANNER_OUT_READ" > "$TMP/remaining_body"

# --- Step 6: Assemble ---
# Trim trailing blank lines from injected_block so that section bodies do not
# accumulate extra newlines. We re-add exactly one blank line as separator.
sed -e :a -e '/^$/{$d;N;ba' -e '}' "$TMP/injected_block" > "$TMP/injected_block_trimmed"

# Trim leading blank lines from remaining_body (the stripped planner body) so
# the separator we add doesn't compound with planner-side leading blanks.
awk 'NF { found=1 } found { print }' "$TMP/remaining_body" > "$TMP/remaining_body_trimmed"

# Assemble into a temp file. The move to $OUT happens ONLY after every check
# below passes (#2228 / C5): verifying the temp and moving on success means a
# failed verify never replaces a prior valid $OUT with an invalid artifact.
ASSEMBLED="$TMP/out_assembled"
{
  printf '%s\n\n' "$H1_LINE"
  cat "$TMP/injected_block_trimmed"
  printf '\n'
  cat "$TMP/remaining_body_trimmed"
} > "$ASSEMBLED"

# --- Step 7: Verify (against the temp, before the move) ---
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

# `## Issues` is mandatory in the OUTPUT (always normalized to plural).
# Source-side count is 1 (verified in Step 1 — exactly one of singular/plural).
issues_in_out=$(count_section_headers "$ASSEMBLED" "Issues")
[[ -z "$issues_in_out" ]] && issues_in_out=0
[[ "$issues_in_out" -eq 1 ]] || verify_fail "## Issues appears ${issues_in_out} times outside fences (expected 1)"

# `## Issue` (singular) must NOT appear in the OUTPUT — it is always normalized.
issue_in_out=$(count_section_headers "$ASSEMBLED" "Issue")
[[ -z "$issue_in_out" ]] && issue_in_out=0
[[ "$issue_in_out" -eq 0 ]] || verify_fail "## Issue (singular) appears in output but must be normalized to ## Issues"

acc_count=$(count_section_headers "$ASSEMBLED" "Accepted Tradeoffs")
[[ -z "$acc_count" ]] && acc_count=0
[[ "$acc_count" -eq 1 ]] || verify_fail "## Accepted Tradeoffs appears ${acc_count} times outside fences (expected 1)"

# Fence-aware H1 count: walk the file with awk, toggling fence state.
h1_count=$(awk '
  BEGIN { in_fence=0; n=0 }
  /^```/ || /^~~~/ { in_fence = !in_fence; next }
  !in_fence && /^# [^#]/ { n++ }
  END { print n }
' "$ASSEMBLED")
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

ln_issues=$(order_line "$ASSEMBLED" "Issues")
ln_tradeoffs=$(order_line "$ASSEMBLED" "Accepted Tradeoffs")
[[ -n "$ln_issues" && -n "$ln_tradeoffs" ]] \
  || verify_fail "mandatory section line numbers missing (issues=$ln_issues tradeoffs=$ln_tradeoffs)"
[[ "$ln_issues" -lt "$ln_tradeoffs" ]] || verify_fail "## Issues must appear before ## Accepted Tradeoffs"

# Verbatim match: each mandatory section body must equal the source's body.
# For the issues section, the source-side name may be `Issue` (legacy) while
# the output is always `Issues`. Compare bodies using each side's actual name.
src_issues_body=$("$EXTRACT" "$SOURCE" --section "$ISSUES_SECTION_NAME" 2>/dev/null || true)
out_issues_body=$("$EXTRACT" "$ASSEMBLED" --section "Issues" 2>/dev/null || true)
if [[ "$src_issues_body" != "$out_issues_body" ]]; then
  verify_fail "## Issues body in output does not match source"
fi

src_acc_body=$("$EXTRACT" "$SOURCE" --section "Accepted Tradeoffs" 2>/dev/null || true)
out_acc_body=$("$EXTRACT" "$ASSEMBLED" --section "Accepted Tradeoffs" 2>/dev/null || true)
if [[ "$src_acc_body" != "$out_acc_body" ]]; then
  verify_fail "## Accepted Tradeoffs body in output does not match source"
fi

# --- Step 8: Outline first-body-section hard check (#2228) ---
# For an outline artifact, the first body H2 (the first H2 after the injected
# mandatory block) must be the canonical firstBodySection ("Adopted approach").
# node bridge resolves the expected value from plan-schema.js; fail-open when
# node is unavailable or the body has no H2 (nothing to compare).
if [[ "$OUT" == *-outline.md ]]; then
  EXPECTED_FIRST=""
  if command -v node > /dev/null 2>&1; then
    EXPECTED_FIRST="$(node "$AGENTS_ROOT/hooks/lib/plan-schema.js" --first-body-section outline 2>/dev/null || true)"
  fi
  if [[ -n "$EXPECTED_FIRST" ]]; then
    first_body_h2="$(awk '
      BEGIN { in_fence=0 }
      /^```/ || /^~~~/ { in_fence = !in_fence; next }
      !in_fence && /^## / { sub(/^## /, ""); sub(/[[:space:]]*$/, ""); print; exit }
    ' "$TMP/remaining_body_trimmed")"
    if [[ -n "$first_body_h2" && "$first_body_h2" != "$EXPECTED_FIRST" ]]; then
      verify_fail "first body section is '## $first_body_h2' but must be '## $EXPECTED_FIRST' (importance-first order, #2228)"
    fi
  fi
fi

# --- Gate: outline coverage check (fires whenever OUT is an outline artifact) ---
if [[ "$OUT" == *-outline.md ]]; then
  GATE="$AGENTS_ROOT/bin/check-issues-class-coverage"
  if [[ -x "$GATE" ]]; then
    if ! "$GATE" --mode outline "$SOURCE"; then
      verify_fail "Issues→Class-members coverage gate failed (see stderr above)"
    fi
  fi
fi

# --- Finalize: every check passed — move the verified temp to the destination ---
mv -f "$ASSEMBLED" "$OUT"

exit 0
