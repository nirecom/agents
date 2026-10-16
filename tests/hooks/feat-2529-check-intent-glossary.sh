#!/usr/bin/env bash
# tests/hooks/feat-2529-check-intent-glossary.sh
# Tests: bin/check-intent-glossary, hooks/lib/intent-glossary.js
# Tags: glossary, intent, plan-schema, cli, scope:issue-specific, TL1, regression-2529
# lang-check: ignore -- the 用語集 alias fixture is intentionally CJK
# #2529: intent.md must carry `## Glossary` right after `## Issues`; CLI exits 0 ok / 1 violations / 2 usage.
# TL3 gap: no live clarify-intent / workflow-init write; fixtures are hand-written. Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight via bin/check-verification-gate.sh category: skill-orchestration.
# TDD RED until both sources exist; a missing CLI reports rc 99 and exit 1 also needs a `line <n>:` stderr line.
set -u
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

TMP_ROOT="$(make_tmp)"; readonly TMP_ROOT
trap 'rm -rf "$TMP_ROOT" 2>/dev/null || true' EXIT
harness_isolate "$TMP_ROOT/iso"
mkdir -p "$TMP_ROOT/fx" "$TMP_ROOT/cwd"
cd "$TMP_ROOT/cwd" || exit 1

CLI="$SCRIPT_CHECKOUT_ROOT/bin/check-intent-glossary"
LIB_NODE="$(np "$SCRIPT_CHECKOUT_ROOT/hooks/lib/intent-glossary.js")"
[ -f "$CLI" ] || echo "NOTE: source missing (tests-first RED): $CLI"
[ -f "$SCRIPT_CHECKOUT_ROOT/hooks/lib/intent-glossary.js" ] || echo "NOTE: source missing (tests-first RED): hooks/lib/intent-glossary.js"

# fixture <key> — one intent.md body; `## Issues` comes first unless the key says otherwise.
HEAD=$'# Agreed Requirements — fixture\n\n**Title:** fixture\n\n## Issues\n\n- #1: sample issue\n\n'
TAIL=$'\n## Background / Motivation\n\nWhy this matters.\n'
TABLE_HDR=$'| Term | Category | Definition |\n|---|---|---|\n'
fixture() {
  case "$1" in
    no-heading)      printf '%s' "$HEAD$TAIL" ;;
    heading-only)    printf '%s' "$HEAD"$'## Glossary\n'"$TAIL" ;;
    comment-only)    printf '%s' "$HEAD"$'## Glossary\n\n<!-- no new terms yet -->\n'"$TAIL" ;;
    valid-table)     printf '%s' "$HEAD"$'## Glossary\n\n'"$TABLE_HDR"$'| widget | user | A thing the user sees |\n| relint | internal | Re-lint on confirm |\n| sid | session | Session id |\n'"$TAIL" ;;
    tight-spacing)   printf '%s' "$HEAD"$'## Glossary\n\n|Term|Category|Definition|\n|---|---|---|\n|widget|user|A thing|\n'"$TAIL" ;;
    bad-category)    printf '%s' "$HEAD"$'## Glossary\n\n'"$TABLE_HDR"$'| widget | public | A thing |\n'"$TAIL" ;;
    bad-header)      printf '%s' "$HEAD"$'## Glossary\n\n| Name | Category | Definition |\n|---|---|---|\n| widget | user | A thing |\n'"$TAIL" ;;
    bad-cells)       printf '%s' "$HEAD"$'## Glossary\n\n'"$TABLE_HDR"$'| widget | user |\n'"$TAIL" ;;
    empty-term)      printf '%s' "$HEAD"$'## Glossary\n\n'"$TABLE_HDR"$'|  | user | A thing |\n'"$TAIL" ;;
    dup-term)        printf '%s' "$HEAD"$'## Glossary\n\n'"$TABLE_HDR"$'| widget | user | A thing |\n| widget | internal | Same term again |\n'"$TAIL" ;;
    prose-no-table)  printf '%s' "$HEAD"$'## Glossary\n\nA widget is a thing the user sees.\n'"$TAIL" ;;
    before-issues)   printf '%s' $'# Agreed Requirements — fixture\n\n## Glossary\n\n## Issues\n\n- #1: sample issue\n'"$TAIL" ;;
    two-headings)    printf '%s' "$HEAD"$'## Glossary\n\n## Glossary\n'"$TAIL" ;;
    ja-heading)      printf '%s' "$HEAD"$'## 用語集\n\n'"$TABLE_HDR"$'| widget | user | A thing |\n'"$TAIL" ;;
    fenced-heading)  printf '%s' "$HEAD"$'```\n## Glossary\n```\n'"$TAIL" ;;
    after-background) printf '%s' "$HEAD"$'## Background / Motivation\n\nWhy this matters.\n\n## Glossary\n\n'"$TABLE_HDR"$'| widget | user | A thing |\n' ;;
    trailing-prose)  printf '%s' "$HEAD"$'## Glossary\n\n'"$TABLE_HDR"$'| widget | user | A thing |\n\nStray prose after the table.\n'"$TAIL" ;;
    leading-prose)   printf '%s' "$HEAD"$'## Glossary\n\nLeading prose before the table.\n\n'"$TABLE_HDR"$'| widget | user | A thing |\n'"$TAIL" ;;
    empty-def)       printf '%s' "$HEAD"$'## Glossary\n\n'"$TABLE_HDR"$'| widget | user |  |\n'"$TAIL" ;;
    empty-cat)       printf '%s' "$HEAD"$'## Glossary\n\n'"$TABLE_HDR"$'| widget |  | A thing |\n'"$TAIL" ;;
    sep-cell-count)  printf '%s' "$HEAD"$'## Glossary\n\n| Term | Category | Definition |\n|---|---|---|---|\n| widget | user | A thing |\n'"$TAIL" ;;
    *) echo "unknown fixture: $1" >&2; return 1 ;;
  esac
}

# run_cli <args...> — sets CLI_RC / CLI_ERR; a missing CLI is rc 99 so no "want 1" row passes on MODULE_NOT_FOUND.
run_cli() {
  CLI_ERR=""
  if [ ! -f "$CLI" ]; then CLI_RC=99; CLI_ERR="CLI missing: $CLI"; return; fi
  CLI_ERR="$(run_with_timeout 20 node "$CLI" "$@" 2>&1 1>/dev/null)"
  CLI_RC=$?
}

# check_row <name> <want-rc> [stderr-needle] — runs the CLI on fixture <name>.
check_row() {
  local name="$1" want="$2" needle="${3:-}" f
  f="$TMP_ROOT/fx/$name-intent.md"
  fixture "$name" > "$f" || { fail "$name: fixture build failed"; return; }
  run_cli "$(np "$f")"
  if [ "$CLI_RC" != "$want" ]; then
    fail "$name: want exit $want, got $CLI_RC (stderr: $CLI_ERR)"
    return
  fi
  if [ "$want" = 1 ] && ! printf '%s\n' "$CLI_ERR" | grep -qE '^line [0-9]+: '; then
    fail "$name: exit 1 without a 'line <n>: <reason>' stderr line (stderr: $CLI_ERR)"
    return
  fi
  if [ -n "$needle" ] && ! printf '%s' "$CLI_ERR" | grep -qF -- "$needle"; then
    fail "$name: stderr lacks '$needle' (stderr: $CLI_ERR)"
    return
  fi
  pass "$name: exit $want${needle:+ (stderr names $needle)}"
}

# ---- CLI verdicts, table-driven: fixture | want exit | stderr needle (optional)
case_begin "cli-fixture-verdicts" "bin/check-intent-glossary"
while IFS='|' read -r _name _want _needle; do
  [[ -z "$_name" || "$_name" =~ ^[[:space:]]*# ]] && continue
  _name="${_name//[[:space:]]/}"; _want="${_want//[[:space:]]/}"; _needle="${_needle//[[:space:]]/}"
  check_row "$_name" "$_want" "$_needle"
done <<'TABLE'
# fixture       | want | stderr needle
no-heading      | 1    | Issues
heading-only    | 0    |
comment-only    | 0    |
valid-table     | 0    |
tight-spacing   | 0    |
bad-category    | 1    |
bad-header      | 1    |
bad-cells       | 1    |
empty-term      | 1    |
dup-term        | 1    |
prose-no-table  | 1    |
before-issues   | 1    |
two-headings    | 1    |
ja-heading      | 0    |
fenced-heading  | 1    | Glossary
# Glossary must be the H2 directly after Issues; the table must be the whole body and well-formed.
after-background | 1   |
trailing-prose  | 1    |
leading-prose   | 1    | remove
sep-cell-count  | 1    |
empty-def       | 1    |
empty-cat       | 1    |
TABLE
case_end

# ---- CLI usage errors: no argument / missing file / directory → exit 2
case_begin "cli-usage-and-unreadable-exit-2" "bin/check-intent-glossary"
run_cli
if [ "$CLI_RC" = 2 ]; then pass "usage: no argument → exit 2"; else fail "usage: no argument → want 2, got $CLI_RC ($CLI_ERR)"; fi
run_cli "$(np "$TMP_ROOT/fx/does-not-exist-intent.md")"
if [ "$CLI_RC" = 2 ]; then pass "unreadable: missing file → exit 2"; else fail "unreadable: missing file → want 2, got $CLI_RC ($CLI_ERR)"; fi
run_cli "$(np "$TMP_ROOT/fx")"
if [ "$CLI_RC" = 2 ]; then pass "unreadable: directory path → exit 2"; else fail "unreadable: directory path → want 2, got $CLI_RC ($CLI_ERR)"; fi
case_end

# ---- Module contract. JS lives in a heredoc file and reads fixtures from argv.
cat > "$TMP_ROOT/mod.js" <<'JS'
// node mod.js <lib> <mode> [fixture-file] — prints OK or BAD:<why>
const fs = require('fs');
const [lib, mode, file] = process.argv.slice(2);
const m = require(lib);
const text = file ? fs.readFileSync(file, 'utf8') : '';
const bad = [];
if (mode === 'categories') {
  if (JSON.stringify(m.CATEGORIES) !== JSON.stringify(['user', 'internal', 'session'])) bad.push('CATEGORIES=' + JSON.stringify(m.CATEGORIES));
} else if (mode === 'violations') {
  const v = m.checkIntentGlossary(text);
  if (!Array.isArray(v) || v.length === 0) bad.push('expected a non-empty array, got ' + JSON.stringify(v));
  else v.forEach((x, i) => {
    if (typeof x.lineNumber !== 'number') bad.push(i + ':lineNumber=' + JSON.stringify(x.lineNumber));
    if (typeof x.line !== 'string') bad.push(i + ':line=' + JSON.stringify(x.line));
    if (typeof x.reason !== 'string' || x.reason.length === 0) bad.push(i + ':reason=' + JSON.stringify(x.reason));
  });
} else if (mode === 'clean') {
  const v = m.checkIntentGlossary(text);
  if (!Array.isArray(v) || v.length !== 0) bad.push('expected [], got ' + JSON.stringify(v));
} else if (mode === 'parse') {
  if (typeof m.parseIntentGlossary !== 'function') bad.push('parseIntentGlossary is not a function');
  else {
    const s = JSON.stringify(m.parseIntentGlossary(text));
    ['widget', 'relint', 'sid', 'user', 'internal', 'session'].forEach((k) => { if (s.indexOf(k) === -1) bad.push('parse result lacks ' + k + ': ' + s); });
  }
} else if (mode === 'rows') {
  // Prints the parsed rows as sorted "term:category" joined by ",", or "-" for none.
  if (typeof m.parseIntentGlossary !== 'function') { process.stdout.write('BAD:parseIntentGlossary is not a function'); process.exit(0); }
  const r = m.parseIntentGlossary(text);
  const rows = Array.isArray(r) ? r : ((r && (r.rows || r.entries || r.terms)) || []);
  const got = rows.map((x) => String(x.term ?? x.Term) + ':' + String(x.category ?? x.Category)).sort();
  process.stdout.write(got.length ? got.join(',') : '-');
  process.exit(0);
} else bad.push('unknown mode ' + mode);
process.stdout.write(bad.length ? 'BAD:' + bad.join(' | ') : 'OK');
JS
MOD_JS="$(np "$TMP_ROOT/mod.js")"
mod() { run_with_timeout 20 node "$MOD_JS" "$LIB_NODE" "$@" 2>&1; }

case_begin "module-categories-constant" "hooks/lib/intent-glossary.js"
_out="$(mod categories)"
if [ "$_out" = OK ]; then pass "CATEGORIES === ['user','internal','session']"; else fail "CATEGORIES: $_out"; fi
case_end

case_begin "module-check-returns-violation-records" "hooks/lib/intent-glossary.js"
_out="$(mod violations "$(np "$TMP_ROOT/fx/no-heading-intent.md")")"
if [ "$_out" = OK ]; then pass "checkIntentGlossary(no heading) → [{lineNumber,line,reason}]"; else fail "checkIntentGlossary(no heading): $_out"; fi
_out="$(mod violations "$(np "$TMP_ROOT/fx/dup-term-intent.md")")"
if [ "$_out" = OK ]; then pass "checkIntentGlossary(duplicate term) → [{lineNumber,line,reason}]"; else fail "checkIntentGlossary(duplicate term): $_out"; fi
_out="$(mod clean "$(np "$TMP_ROOT/fx/valid-table-intent.md")")"
if [ "$_out" = OK ]; then pass "checkIntentGlossary(valid table) → []"; else fail "checkIntentGlossary(valid table): $_out"; fi
case_end

case_begin "module-parse-reads-table-rows" "hooks/lib/intent-glossary.js"
_out="$(mod parse "$(np "$TMP_ROOT/fx/valid-table-intent.md")")"
if [ "$_out" = OK ]; then pass "parseIntentGlossary(valid table) carries every term and category"; else fail "parseIntentGlossary: $_out"; fi
case_end

# ---- Parser rows, table-driven: fixture | want sorted term:category list ("-" = no rows)
assert_eq() {
  local name="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then pass "$name"
  else fail "$name — want=$(printf '%q' "$want") got=$(printf '%q' "$got")"; fi
}
case_begin "module-parse-rows-table" "hooks/lib/intent-glossary.js"
while IFS='|' read -r _name _want; do
  [[ -z "$_name" || "$_name" =~ ^[[:space:]]*# ]] && continue
  _name="${_name//[[:space:]]/}"; _want="${_want//[[:space:]]/}"
  _f="$TMP_ROOT/fx/rows-$_name-intent.md"
  fixture "$_name" > "$_f" || { fail "parse/$_name: fixture build failed"; continue; }
  assert_eq "parse/$_name" "$_want" "$(mod rows "$(np "$_f")")"
done <<'TABLE'
# fixture       | want
valid-table     | relint:internal,sid:session,widget:user
tight-spacing   | widget:user
ja-heading      | widget:user
heading-only    | -
comment-only    | -
no-heading      | -
TABLE
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
