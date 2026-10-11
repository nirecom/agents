#!/usr/bin/env bash
# tests/bin/argparse-flag-value-guard.sh
# Tests: bin/github-issues/issue-to-history.sh, skills/issue-reconcile/scripts/backfill-batch.sh
# Tags: argparse, shift-2, unknown-flag, static-guard, class-guard, scope:common, TL1
# Class guard over every tracked shell file under bin/, skills/, hooks/, install/:
# - a branch running `shift 2` checks the value in the same branch (`$#` count, `${2:?`,
#   `-n/-z` on `${2:-}` or its variable, a need_value/require_value helper) and the check
#   guards it (`|| exit`, `|| { ...; exit; }`, if/then); else a valueless last flag spins forever.
# - a `*)` branch whose whole body is `shift` drops an unknown argument silently; an intended
#   positional branch is a file:line exception. A nested case is read as part of its branch.

set -uo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

TMP_ROOT="$(make_tmp)"
[[ -n "$TMP_ROOT" && -d "$TMP_ROOT" ]] || { echo "cannot create a temp root" >&2; exit 1; }
readonly TMP_ROOT
trap 'rm -rf "$TMP_ROOT"' EXIT
harness_isolate "$TMP_ROOT/iso"

# Intended positional branches that only shift (file:line). Empty until S6-4 verifies each one.
readonly SILENT_DROP_EXCEPTIONS=''

# The detector: prints `<line>:<kind>` per violation, kind = shift2-no-value-check | silent-drop.
DETECTOR_AWK="$(cat <<'AWK'
function checked(body,   rest, name) {
  if (guarded(body, "\\$#\"?[ \t]+-(ge[ \t]+2|gt[ \t]+1)", 1)) return 1
  if (guarded(body, "\\$#\"?[ \t]+-(lt[ \t]+2|le[ \t]+1)", 0)) return 1
  if (body ~ /\$\{2:\?/) return 1
  if (stops(body, "\\$\\{2:-\\}")) return 1
  if (body ~ /(^|[ \t;{(!])(need|require|requires|ensure|expect)_?(a_)?(value|val|arg)[ \t]/) return 1
  rest = body
  while (match(rest, /[A-Za-z_][A-Za-z0-9_]*="?\$\{2:-\}/)) {
    name = substr(rest, RSTART, RLENGTH)
    rest = substr(rest, RSTART + RLENGTH)
    sub(/=.*/, "", name)
    if (stops(body, "\\$\\{?" name "\\}?")) return 1
  }
  return 0
}
# stops(body, ref) — the value test on ref actually guards: `-n ref` passes, `-z ref` stops.
function stops(body, ref) {
  return guarded(body, "-n[ \t]+\"?" ref "\"?", 1) || guarded(body, "-z[ \t]+\"?" ref "\"?", 0)
}
# guarded(body, cond, pos) — a `[ cond ]` test that really guards `shift 2`. pos=1 (cond
# true = value present): `] || <stop>` or `if [ cond ]; then` whose branch holds shift 2.
# pos=0 (cond true = value missing): `] && <stop>` or `if [ cond ]; then` whose branch stops.
# A test followed by anything else (`&& echo ok; shift 2`) guards nothing.
function guarded(body, cond, pos,   rest, after, op, conj) {
  rest = body
  conj = pos ? "([ \t]+&&[ \t]+[^]\n|]*)?" : ""
  while (match(rest, cond conj "[ \t]*\\]\\]?")) {
    after = substr(rest, RSTART + RLENGTH)
    rest = after
    op = pos ? "\\|\\|" : "&&"
    if (after ~ ("^[ \t]*" op)) {
      sub("^[ \t]*" op, "", after)
      if (stop_after(after)) return 1
    } else if (pos) {
      if (then_body(after) ~ /(^|[^0-9A-Za-z_])shift[ \t]+2([^0-9]|$)/) return 1
    } else if (stop_in(then_body(after))) return 1
  }
  return 0
}
function is_stop(s) { return s ~ /^([A-Za-z0-9_]*_)?(exit|return|usage|die|fail|abort|bail)[A-Za-z0-9_]*([ \t;\n)]|$)/ }
# stop_after(s) — s follows `||`/`&&`: a stop word, or a `{ ...; }` group holding one.
function stop_after(s,   g) {
  sub(/^[ \t]*/, "", s)
  if (is_stop(s)) return 1
  if (substr(s, 1, 1) != "{") return 0
  g = substr(s, 2); gsub(/\$\{[^}]*\}/, "", g); sub(/\}.*/, "", g)
  return stop_in(g)
}
function stop_in(s) { return s ~ /(^|[;\n{])[ \t]*([A-Za-z0-9_]*_)?(exit|return|usage|die|fail|abort|bail)[A-Za-z0-9_]*([ \t;\n)]|$)/ }
# then_body(s) — s follows the test's `]`: the text of `; then ... fi`, or "" when no then.
function then_body(s) {
  if (!match(s, /^[ \t]*(;[ \t\n]*|\n[ \t\n]*)then([ \t\n;]|$)/)) return ""
  s = substr(s, RLENGTH + 1)
  if (match(s, /(^|[ \t;\n])fi([ \t;\n)]|$)/)) s = substr(s, 1, RSTART)
  return s
}
function flush(   body, b) {
  if (!inb) return
  body = buf
  if (body ~ /(^|[^0-9A-Za-z_])shift[ \t]+2([^0-9]|$)/ && !checked(body)) print start ":shift2-no-value-check"
  if (label == "*") {
    b = body
    gsub(/;;.*/, "", b); gsub(/[ \t\n;]+/, " ", b); sub(/^ /, "", b); sub(/ $/, "", b)
    if (b == "shift") print start ":silent-drop"
  }
  inb = 0; buf = ""; label = ""; nest = 0
}
{
  line = $0
  if (line ~ /^[ \t]*#/) next
  sub(/[ \t]#.*$/, "", line)
  opens = (line ~ /(^|[ \t;])case[ \t].*[ \t]in([ \t]|$)/)
  closes = (line ~ /(^|[ \t;])esac([ \t;)]|$)/)
  if (inb && (nest > 0 || (opens && !closes))) {
    buf = buf "\n" line
    if (opens && !closes) nest++
    else if (closes && !opens) nest--
    next
  }
  if (match(line, /^[ \t]*\(?[^ \t()#$`]+([ \t]*\|[ \t]*[^ \t()#$`]+)*\)/)) {
    if (line !~ /^[ \t]*case[ \t]/) {
      flush()
      inb = 1; start = NR
      lab = substr(line, RSTART, RLENGTH)
      gsub(/[ \t()]/, "", lab)
      label = lab
      buf = substr(line, RSTART + RLENGTH)
      if (buf ~ /;;/ || buf ~ /(^|[ \t;])esac([ \t;]|$)/) flush()
      next
    }
  }
  if (inb) {
    buf = buf "\n" line
    if (line ~ /;;/ || line ~ /(^|[ \t;])esac([ \t;]|$)/) flush()
  }
}
END { flush() }
AWK
)"
readonly DETECTOR_AWK

# scan_file <path> — violations of one file, `<line>:<kind>` per line.
scan_file() { awk "$DETECTOR_AWK" "$1"; }

# is_shell_file <path> — *.sh, or an extensionless file whose shebang names sh or bash.
is_shell_file() {
  case "$1" in
    *.sh|*.bash) return 0 ;;
    */*.*) return 1 ;;
  esac
  head -n 1 "$1" 2>/dev/null | grep -qE '^#!.*[/ ](ba)?sh([[:space:]]|$)'
}

case_begin "detector-flags-valueless-shift2-and-silent-drop" "bin/github-issues/issue-to-history.sh"
mkdir -p "$TMP_ROOT/fixtures"
# Columns: name | fixture body (\n = newline, <bar> = a literal pipe) | expected detector output (- = none).
while IFS='|' read -r name body want; do
  [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
  name="${name//[[:space:]]/}"
  want="${want//[[:space:]]/}"
  body="${body# }"; body="${body% }"; body="${body//<bar>/|}"
  f="$TMP_ROOT/fixtures/$name.sh"
  printf '%b\n' "$body" >"$f"
  got="$(scan_file "$f" | tr '\n' ' ')"
  got="${got% }"
  [[ -z "$got" ]] && got="-"
  if [[ "$got" == "$want" ]]; then pass "$name"; else fail "$name" "want=$want got=$got"; fi
done <<'TABLE'
valueless-multiline-branch | case "$1" in\n  --x)\n    X="${2:-}"\n    shift 2\n    ;;\nesac | 2:shift2-no-value-check
valueless-one-line-branch | case "$1" in\n  --x) X="${2:-}"; shift 2 ;;\nesac | 2:shift2-no-value-check
alternation-label-valueless | case "$1" in\n  -x<bar>--xx) X="$2"; shift 2 ;;\nesac | 2:shift2-no-value-check
check-in-another-branch-does-not-count | case "$1" in\n  --a) [ $# -ge 2 ] <bar><bar> exit 1; A="$2"; shift 2 ;;\n  --b) B="$2"; shift 2 ;;\nesac | 3:shift2-no-value-check
silent-drop-one-line | case "$1" in\n  --x) shift ;;\n  *) shift ;;\nesac | 3:silent-drop
silent-drop-multiline | case "$1" in\n  *)\n    shift\n    ;;\nesac | 2:silent-drop
count-check-ge | case "$1" in\n  --x)\n    [ $# -ge 2 ] <bar><bar> { echo "--x needs a value" >&2; exit 1; }\n    X="$2"; shift 2 ;;\nesac | -
count-check-quoted-ge | case "$1" in\n  --x) [[ "$#" -ge 2 ]] <bar><bar> exit 1; X="$2"; shift 2 ;;\nesac | -
count-check-lt | case "$1" in\n  --x) if [ $# -lt 2 ]; then exit 1; fi; X="$2"; shift 2 ;;\nesac | -
required-value-expansion | case "$1" in\n  --x) X="${2:?--x needs a value}"; shift 2 ;;\nesac | -
nonempty-value-check | case "$1" in\n  --x) [ -n "${2:-}" ] <bar><bar> exit 1; X="$2"; shift 2 ;;\nesac | -
assigned-then-checked | case "$1" in\n  -C)\n    ROOT="${2:-}"\n    [[ -n "$ROOT" ]] <bar><bar> exit 2\n    shift 2\n    ;;\nesac | -
empty-value-check-with-z | case "$1" in\n  --x) X="${2:-}"; if [ -z "$X" ]; then exit 1; fi; shift 2 ;;\nesac | -
nonempty-test-that-does-not-stop | case "$1" in\n  --c)\n    C="${2:-}"\n    if [ -n "$C" ] && ! valid "$C"; then exit 1; fi\n    shift 2\n    ;;\nesac | 2:shift2-no-value-check
assigned-other-var-checked-is-not-enough | case "$1" in\n  -C) ROOT="${2:-}"; [[ -n "$OTHER" ]] <bar><bar> exit 2; shift 2 ;;\nesac | 2:shift2-no-value-check
need-value-helper | case "$1" in\n  --x) need_value "$#" "$1"; X="$2"; shift 2 ;;\nesac | -
require-value-helper | case "$1" in\n  --x)\n    require_value "--x" "${2:-}"\n    X="$2"; shift 2 ;;\nesac | -
nested-case-checked-in-outer-branch | case "$1" in\n  --a<bar>--b)\n    [[ "$#" -ge 2 ]] <bar><bar> exit 2\n    case "$1" in\n      --a) A="$2" ;;\n      --b) B="$2" ;;\n    esac\n    shift 2\n    ;;\nesac | -
nested-case-valueless-outer-branch | case "$1" in\n  --a<bar>--b)\n    case "$1" in\n      --a) A="${2:-}" ;;\n      --b) B="${2:-}" ;;\n    esac\n    shift 2\n    ;;\nesac | 2:shift2-no-value-check
positional-branch-keeps-the-arg | case "$1" in\n  *) ARGS+=("$1"); shift ;;\nesac | -
unknown-flag-is-an-error | case "$1" in\n  *) echo "unknown: $1" >&2; exit 1 ;;\nesac | -
shift-one-is-not-shift-two | case "$1" in\n  --x) X=1; shift ;;\nesac | -
commented-branch-is-ignored | # --x) X="$2"; shift 2 ;;\necho done | -
function-definition-is-not-a-branch | usage() {\n  shift 2\n} | -
count-check-and-does-not-guard | case "$1" in\n  --x) [[ $# -ge 2 ]] && echo ok; X="$2"; shift 2 ;;\nesac | 2:shift2-no-value-check
count-check-or-without-stop | case "$1" in\n  --x) [ $# -ge 2 ] <bar><bar> echo "--x needs a value" >&2; X="$2"; shift 2 ;;\nesac | 2:shift2-no-value-check
count-check-group-without-stop | case "$1" in\n  --x) [ $# -ge 2 ] <bar><bar> { echo "--x needs a value" >&2; }; X="$2"; shift 2 ;;\nesac | 2:shift2-no-value-check
count-check-then-not-around-shift | case "$1" in\n  --x) if [ $# -ge 2 ]; then X="$2"; fi; shift 2 ;;\nesac | 2:shift2-no-value-check
count-check-then-around-shift | case "$1" in\n  --x)\n    if [ $# -ge 2 ]; then\n      X="$2"; shift 2\n    else\n      exit 1\n    fi\n    ;;\nesac | -
count-lt-then-without-stop | case "$1" in\n  --x) if [ $# -lt 2 ]; then echo "--x needs a value" >&2; fi; X="$2"; shift 2 ;;\nesac | 2:shift2-no-value-check
count-lt-and-usage | case "$1" in\n  --x) [ $# -lt 2 ] && usage; X="$2"; shift 2 ;;\nesac | -
nonempty-check-or-without-stop | case "$1" in\n  --x) [ -n "${2:-}" ] <bar><bar> echo warn; X="$2"; shift 2 ;;\nesac | 2:shift2-no-value-check
empty-check-and-without-stop | case "$1" in\n  --x) X="${2:-}"; [ -z "$X" ] && echo warn; shift 2 ;;\nesac | 2:shift2-no-value-check
group-with-braced-expansion-then-exit | case "$1" in\n  --x) [ $# -ge 2 ] <bar><bar> { echo "${1} needs a value" >&2; exit 2; }; X="$2"; shift 2 ;;\nesac | -
count-and-nonempty-conjunction | case "$1" in\n  --x) [[ "$#" -ge 2 && -n "$2" ]] <bar><bar> vce_usage "--x needs a value"; X="$2"; shift 2 ;;\nesac | -
prefixed-stop-helper | case "$1" in\n  --x)\n    [ "$#" -ge 2 ] <bar><bar> co_usage_error "--x needs a value"\n    X="$2"; shift 2 ;;\nesac | -
stop-word-as-substring-is-not-a-stop | case "$1" in\n  --x) [ $# -ge 2 ] <bar><bar> exited=1; X="$2"; shift 2 ;;\nesac | 2:shift2-no-value-check
TABLE
case_end

# The real issue-to-history.sh and backfill-batch.sh are members the detector must reach.
case_begin "issue-to-history-flags-take-a-checked-value" "bin/github-issues/issue-to-history.sh"
got="$(scan_file "$SCRIPT_CHECKOUT_ROOT/bin/github-issues/issue-to-history.sh" | tr '\n' ' ')"
if [[ -z "$got" ]]; then pass "issue-to-history.sh: every shift 2 is checked and no argument is dropped"; else fail "issue-to-history.sh: violations" "$got"; fi
case_end

case_begin "backfill-batch-flags-take-a-checked-value" "skills/issue-reconcile/scripts/backfill-batch.sh"
got="$(scan_file "$SCRIPT_CHECKOUT_ROOT/skills/issue-reconcile/scripts/backfill-batch.sh" | tr '\n' ' ')"
if [[ -z "$got" ]]; then pass "backfill-batch.sh: every shift 2 is checked"; else fail "backfill-batch.sh: violations" "$got"; fi
case_end

case_begin "every-tracked-shell-file-passes-the-class-guard" "bin/github-issues/issue-to-history.sh"
VIOLATIONS="$TMP_ROOT/violations.txt"
: >"$VIOLATIONS"
scanned=0
while IFS= read -r rel; do
  abs="$SCRIPT_CHECKOUT_ROOT/$rel"
  [[ -f "$abs" ]] || continue
  is_shell_file "$abs" || continue
  scanned=$((scanned + 1))
  while IFS= read -r v; do
    [[ -z "$v" ]] && continue
    lineno="${v%%:*}"
    kind="${v#*:}"
    if [[ "$kind" == silent-drop ]] && grep -qxF "$rel:$lineno" <<<"$SILENT_DROP_EXCEPTIONS"; then continue; fi
    printf '%s:%s:%s\n' "$rel" "$lineno" "$kind" >>"$VIOLATIONS"
  done < <(scan_file "$abs")
done < <(git -C "$SCRIPT_CHECKOUT_ROOT" ls-files -- bin skills hooks install)
if [[ "$scanned" -gt 100 ]]; then pass "the scan reached the tracked shell files ($scanned)"; else fail "the scan reached the tracked shell files" "only $scanned"; fi
if [[ ! -s "$VIOLATIONS" ]]; then
  pass "no shift 2 without a value check and no silent drop of an unknown argument"
else
  fail "class guard violations ($(grep -c . "$VIOLATIONS"))" "$(cat "$VIOLATIONS")"
fi
case_end

echo ""
echo "Results: PASS=$PASS  FAIL=$FAIL  SKIP=$SKIP"
[[ "$FAIL" -eq 0 ]]
