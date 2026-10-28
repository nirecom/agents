#!/usr/bin/env bash
# tests/bin/core-principles-format.sh
# Tests: rules/core-principles.md
# Tags: core-principles, format, static-guard, scope:common, TL1
#
# Format-only guard: never pins the principle count, their order, a heading or body wording.
# F1 every `## ` line is `## CPR-<code> <Title>` (code: 2+ of A-Z0-9 with a letter) — F2 a heading
# is followed by one blank line and a body line — F3 codes are unique — F4 every CPR-<code> token
# in a tracked file names an existing code (append-only history and changelog records excluded).
# The fixture cases first prove each checker rejects bad input.

set -uo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

TMP_ROOT="$(make_tmp)"
[[ -n "$TMP_ROOT" && -d "$TMP_ROOT" ]] || { echo "cannot create a temp root" >&2; exit 1; }
readonly TMP_ROOT
trap 'rm -rf "$TMP_ROOT"' EXIT
harness_isolate "$TMP_ROOT/iso"

CORE_REL="rules/core-principles.md"
# Built at runtime so this file never carries a literal token for F4 to read.
P="CPR"

# check_headings <file> — `<line>:<F1|F2|F3>:<kind>` per violation of the heading format.
check_headings() {
  awk '
    { sub(/\r$/, ""); line[NR] = $0 }
    END {
      n = 0
      for (i = 1; i <= NR; i++) {
        if (substr(line[i], 1, 3) != "## ") continue
        n++
        if (line[i] !~ /^## CPR-[A-Z0-9]+ [^ \t]/) { print i ":F1:malformed-heading"; continue }
        code = line[i]; sub(/^## CPR-/, "", code); sub(/ .*/, "", code)
        if (length(code) < 2 || code !~ /[A-Z]/) { print i ":F1:bad-code"; continue }
        if (seen[code]++) print i ":F3:duplicate-code"
        if (!((i + 1) in line) || line[i + 1] != "") print i ":F2:no-blank-after-heading"
        else if (!((i + 2) in line) || line[i + 2] ~ /^[ \t]*$/ || substr(line[i + 2], 1, 3) == "## ") print i ":F2:no-body"
      }
      if (n == 0) print "0:F1:no-headings"
    }' "$1"
}

# heading_codes <file> — the codes of the well-formed headings, space-separated.
heading_codes() {
  awk '{ sub(/\r$/, "") } /^## CPR-[A-Z0-9]+ [^ \t]/ { c = $2; sub(/^CPR-/, "", c); printf "%s ", c }' "$1"
}

# dangling_refs <codes> — reads `path:line:text` lines; prints `path:line:token` for each
# word-bounded token whose code (2+ of A-Z0-9 with a letter) is not in <codes>.
dangling_refs() {
  awk -v codes="$1" '
    BEGIN { n = split(codes, a, " "); for (i = 1; i <= n; i++) ok[a[i]] = 1 }
    {
      p = index($0, ":"); file = substr($0, 1, p - 1); rest = substr($0, p + 1)
      q = index(rest, ":"); ln = substr(rest, 1, q - 1); s = substr(rest, q + 1)
      sub(/\r$/, "", s); prev = ""
      while (match(s, /CPR-[A-Z0-9]+/)) {
        pre = RSTART > 1 ? substr(s, RSTART - 1, 1) : prev
        post = substr(s, RSTART + RLENGTH, 1)
        tok = substr(s, RSTART + 4, RLENGTH - 4)
        prev = substr(s, RSTART + RLENGTH - 1, 1)
        s = substr(s, RSTART + RLENGTH)
        if (pre ~ /[A-Za-z0-9_-]/ || post ~ /[a-z_]/) continue
        if (length(tok) < 2 || tok !~ /[A-Z]/) continue
        if (!(tok in ok)) print file ":" ln ":CPR-" tok
      }
    }'
}

# repo_refs <root> — `path:line:text` for every tracked text line carrying the token prefix.
repo_refs() {
  git -C "$1" grep -nIE "${P}-[A-Z0-9]" -- . \
    ':!docs/history.md' ':!docs/history/' ':!CHANGELOG.md' ':!changelog/' || true
}

# expect_kinds <file> <want> — the sorted `<F*>:<kind>` list check_headings reports.
expect_kinds() {
  local got
  got="$(check_headings "$1" | cut -d: -f2- | sort | tr '\n' ' ')"
  got="${got% }"
  [[ -z "$got" ]] && got="-"
  if [[ "$got" == "$2" ]]; then pass "$(basename "$1" .md)"; else fail "$(basename "$1" .md)" "want=$2 got=$got"; fi
}

case_begin "heading-checker-rejects-bad-fixtures" "$CORE_REL"
FIX="$TMP_ROOT/fixtures"
mkdir -p "$FIX"
printf '# T\n\n## %s-UO User\n\nBody.\n\n## %s-E2C Class\n\nBody.\n' "$P" "$P" >"$FIX/well-formed.md"
printf '## %s-UO User\n\nBody.\n## Plain\n\nBody.\n' "$P" >"$FIX/no-code.md"
printf '## %s-12 Digits\n\nBody.\n' "$P" >"$FIX/digits-only.md"
printf '## %s-U Short\n\nBody.\n' "$P" >"$FIX/one-char-code.md"
printf '## %s-uo Lower\n\nBody.\n' "$P" >"$FIX/lowercase-code.md"
printf '## %s-UO\n\nBody.\n' "$P" >"$FIX/no-title.md"
printf '## %s-UO  Two spaces\n\nBody.\n' "$P" >"$FIX/double-space.md"
printf '## %s-UO User\nBody.\n' "$P" >"$FIX/no-blank.md"
printf '## %s-UO User\n\n\nBody.\n' "$P" >"$FIX/two-blanks.md"
printf '## %s-UO User\n\n## %s-SC Split\n\nBody.\n' "$P" "$P" >"$FIX/empty-body.md"
printf '## %s-UO User\n' "$P" >"$FIX/heading-at-eof.md"
printf '## %s-UO User\n\nBody.\n\n## %s-UO Again\n\nBody.\n' "$P" "$P" >"$FIX/duplicate.md"
printf '# T\n\nNo sections.\n' >"$FIX/no-headings.md"
printf '## %s-UO User\r\n\r\nBody.\r\n' "$P" >"$FIX/crlf.md"
expect_kinds "$FIX/well-formed.md" "-"
expect_kinds "$FIX/crlf.md" "-"
expect_kinds "$FIX/no-code.md" "F1:malformed-heading"
expect_kinds "$FIX/digits-only.md" "F1:bad-code"
expect_kinds "$FIX/one-char-code.md" "F1:bad-code"
expect_kinds "$FIX/lowercase-code.md" "F1:malformed-heading"
expect_kinds "$FIX/no-title.md" "F1:malformed-heading"
expect_kinds "$FIX/double-space.md" "F1:malformed-heading"
expect_kinds "$FIX/no-blank.md" "F2:no-blank-after-heading"
expect_kinds "$FIX/two-blanks.md" "F2:no-body"
expect_kinds "$FIX/empty-body.md" "F2:no-body"
expect_kinds "$FIX/heading-at-eof.md" "F2:no-blank-after-heading"
expect_kinds "$FIX/duplicate.md" "F3:duplicate-code"
expect_kinds "$FIX/no-headings.md" "F1:no-headings"
case_end

case_begin "reference-checker-rejects-dangling-fixtures" "$CORE_REL"
REPO="$TMP_ROOT/repo"
harness_git_init "$REPO"
git -C "$REPO" config core.autocrlf false
mkdir -p "$REPO/rules" "$REPO/docs/history" "$REPO/changelog"
printf '## %s-UO User\n\nBody.\n\n## %s-E2C Class\n\nBody.\n' "$P" "$P" >"$REPO/rules/core-principles.md"
{
  printf 'ok %s-UO and %s-E2C, (%s-UO) %s-UO-adjacent\n' "$P" "$P" "$P" "$P"
  printf 'prefix %s-E2 drift\n' "$P"
  printf 'pair %s-UO %s-ZZQ\n' "$P" "$P"
  printf 'not tokens: %s-4 %s-N %s-<code> X%s-ZZQ %s-UOs %s-ZZQ_x\n' "$P" "$P" "$P" "$P" "$P" "$P"
} >"$REPO/notes.md"
for rec in docs/history.md docs/history/old.md CHANGELOG.md changelog/2026.md; do
  printf 'record %s-ZZQ\n' "$P" >"$REPO/$rec"
done
git -C "$REPO" add -A
codes="$(heading_codes "$REPO/rules/core-principles.md")"
got="$(repo_refs "$REPO" | dangling_refs "$codes" | sort | tr '\n' ' ')"
got="${got% }"
want="notes.md:2:${P}-E2 notes.md:3:${P}-ZZQ"
if [[ "$got" == "$want" ]]; then pass "dangling tokens reported, valid / non-token / history ones not"; else fail "dangling fixture" "want=$want got=$got"; fi
case_end

case_begin "F1-F3-core-principles-heading-format" "$CORE_REL"
CORE="$SCRIPT_CHECKOUT_ROOT/$CORE_REL"
if [[ -f "$CORE" ]]; then
  for kind in F1 F2 F3; do
    v="$(check_headings "$CORE" | grep ":$kind:" | tr '\n' ' ')"
    if [[ -z "$v" ]]; then pass "$kind: $CORE_REL conforms"; else fail "$kind: $CORE_REL violations" "$v"; fi
  done
else
  fail "$CORE_REL not found"
fi
case_end

case_begin "F4-every-cpr-reference-names-a-heading" "$CORE_REL"
codes="$(heading_codes "$CORE")"
if [[ -n "$codes" ]]; then
  v="$(repo_refs "$SCRIPT_CHECKOUT_ROOT" | dangling_refs "$codes")"
  if [[ -z "$v" ]]; then pass "F4: every tracked reference names a heading code"; else fail "F4: dangling references ($(grep -c . <<<"$v"))" "$v"; fi
else
  fail "F4: no heading codes read from $CORE_REL"
fi
case_end

echo ""
echo "Results: PASS=$PASS  FAIL=$FAIL  SKIP=$SKIP"
[[ "$FAIL" -eq 0 ]]
