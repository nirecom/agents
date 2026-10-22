#!/usr/bin/env bash
# tests/bin/feat-2529-glossary-format.sh
# Tests: bin/lib/glossary-format.js, bin/glossary-promote
# Tags: TL1, TL2, docs, glossary, parser, glossary-promote, idempotency, scope:issue-specific, pwsh-not-required
# #2529 shared glossary parser (compare, entry parse, path/range/bucket resolution) and the
# glossary-promote CLI that inserts intent glossary user/internal rows into the glossary files.
# TL3 gap (what this test does NOT catch):
# - /update-docs invoking glossary-promote from the main worktree on a real intent.md.
# Closest-to-action mitigation: the round-trip case feeds promote output through bin/review-doc-glossary.
set -uo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
T="$(make_tmp)"
readonly T
harness_isolate "$T/iso"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/transcripts"
export CLAUDE_TRANSCRIPT_BASE_DIR="$T/transcripts"
unset CLAUDE_CODE_SESSION_ID

MOD="$(np "$SCRIPT_CHECKOUT_ROOT/bin/lib/glossary-format.js")"
WF="$(np "$SCRIPT_CHECKOUT_ROOT/hooks/workflow-state.js")"
PROMOTE="$SCRIPT_CHECKOUT_ROOT/bin/glossary-promote"
GATE="$SCRIPT_CHECKOUT_ROOT/bin/review-doc-glossary"
PROBE="$T/probe.js"
APPROVE="$T/approve.js"

# probe.js <module> <mode> <fn> <arg>... — call one export; '@<path>' args are file text,
# other args are JSON. Modes: sign | empty | terms | path | json.
cat > "$PROBE" <<'EOF'
'use strict';
const fs = require('fs');
let mod;
try { mod = require(process.argv[2]); } catch (e) { console.log('MODULE_NOT_FOUND'); process.exit(4); }
const [mode, fn, ...raw] = process.argv.slice(3);
if (typeof mod[fn] !== 'function') { console.log('NO_EXPORT:' + fn); process.exit(3); }
const args = raw.map((a) => (a.startsWith('@') ? fs.readFileSync(a.slice(1), 'utf8') : JSON.parse(a)));
const r = mod[fn](...args);
if (mode === 'sign') console.log(Math.sign(r));
else if (mode === 'empty') console.log(Array.isArray(r) ? (r.length === 0 ? 'EMPTY' : 'NONEMPTY') : 'NOT_ARRAY');
else if (mode === 'terms') {
  const entries = Array.isArray(r) ? r[0] : r && r.entries;
  console.log((entries || []).map((e) => e.term).join(','));
} else if (mode === 'path') console.log(r == null ? 'null' : r.category + '|' + (r.range ? r.range.from + '-' + r.range.to : 'none'));
else console.log(r == null ? 'null' : JSON.stringify(r));
EOF
PROBE="$(np "$PROBE")"

# approve.js <workflow-state> <sid> — record the CONFIRM_INTENT approval (confirm-sentinel,
# with the sha of <WORKFLOW_PLANS_DIR>/<sid>-intent.md) the way the confirm handler does.
cat > "$APPROVE" <<'EOF'
'use strict';
const wf = require(process.argv[2]);
const sid = process.argv[3];
const sha = wf.computeArtifactSha(sid, 'clarify_intent');
if (!sha) { console.error('approve: intent sha uncomputable for ' + sid); process.exit(1); }
wf.recordPlanApproval(sid, 'clarify_intent', { source: 'confirm-sentinel', reason: '2529 fixture', artifactSha: sha, artifactHashStatus: 'recorded' });
EOF
APPROVE="$(np "$APPROVE")"

# expect_probe <name> <want> <mode> <fn> <arg>...
expect_probe() {
  local name="$1" want="$2" got
  shift 2
  got="$(run_with_timeout 120 node "$PROBE" "$MOD" "$@" 2>&1)"
  if [[ "$got" == "$want" ]]; then pass "$name"
  else fail "$name" "want=[$want] got=[${got:0:400}]"; fi
}

entry() {
  printf '### %s\n- **Definition**: %s is a fixture term.\n- **Related**: [owner](architecture/owner.md)\n\n' "$1" "$1"
}

# gloss <file> <term>... — a valid glossary file holding the terms in the given order.
gloss() {
  local f="$1" t
  shift
  mkdir -p "$(dirname "$f")"
  printf '# Glossary\n\nFixture glossary for the #2529 promotion tests.\n\n' > "$f"
  for t in "$@"; do entry "$t" >> "$f"; done
}

# intent <file> <row>... — intent.md with Issues + Glossary table; each row is "term|category|definition".
intent() {
  local f="$1" row
  shift
  mkdir -p "$(dirname "$f")"
  printf '# Fixture intent\n\n## Issues\n\n- #1: fixture\n\n## Glossary\n\n| Term | Category | Definition |\n|---|---|---|\n' > "$f"
  for row in "$@"; do printf '| %s |\n' "${row//|/ | }" >> "$f"; done
  printf '\n## Background/Motivation\n\nFixture.\n' >> "$f"
}

# approve <sid> — record the approval of the intent already written at the session's path.
approve() {
  run_with_timeout 120 node "$APPROVE" "$WF" "$1" >/dev/null 2>&1 || fail "fixture approval for $1" "approve.js failed"
}

# approved_intent <sid> <row>... — the session's own intent.md (<WORKFLOW_PLANS_DIR>/<sid>-intent.md,
# the only path glossary-promote accepts, #2529) with a confirm-sentinel approval of its bytes;
# sets INTENT to the node-ready path.
approved_intent() {
  local sid="$1"
  shift
  intent "$WORKFLOW_PLANS_DIR/$sid-intent.md" "$@"
  approve "$sid"
  INTENT="$(np "$WORKFLOW_PLANS_DIR/$sid-intent.md")"
}

# run_promote <args...> — sets PROMOTE_OUT / PROMOTE_RC; a missing CLI fails loudly (RED).
run_promote() {
  if [[ ! -f "$PROMOTE" ]]; then
    PROMOTE_OUT="TOOL NOT FOUND: bin/glossary-promote (not yet implemented, #2529)"
    PROMOTE_RC=127
    return 0
  fi
  PROMOTE_RC=0
  PROMOTE_OUT="$(run_with_timeout 120 node "$(np "$PROMOTE")" "$@" 2>&1)" || PROMOTE_RC=$?
}

expect_promote_rc() {
  if [[ "$PROMOTE_RC" == "$2" ]]; then pass "$1 (rc=$2)"
  else fail "$1" "want rc=$2 got rc=$PROMOTE_RC; output: ${PROMOTE_OUT:0:600}"; fi
}

expect_promote_out() {
  if [[ "$PROMOTE_OUT" == *"$2"* ]]; then pass "$1"
  else fail "$1" "expected [$2] in output: ${PROMOTE_OUT:0:600}"; fi
}

# heading_line <file> <term> — line number of '### <term>' (empty when absent).
heading_line() { grep -n -x -F "### $2" "$1" 2>/dev/null | head -n1 | cut -d: -f1; }

expect_has_term() {
  if [[ -n "$(heading_line "$2" "$3")" ]]; then pass "$1"
  else fail "$1" "no '### $3' in $2"; fi
}

expect_no_term() {
  if [[ -z "$(heading_line "$2" "$3")" ]]; then pass "$1"
  else fail "$1" "unexpected '### $3' in $2"; fi
}

expect_same_file() {
  if cmp -s "$2" "$3"; then pass "$1"
  else fail "$1" "$2 differs from $3"; fi
}

D="$T/data"
mkdir -p "$D"

# trim_var <name> — strip leading/trailing whitespace from the named variable in place.
trim_var() { local -n _tv="$1"; _tv="${_tv#"${_tv%%[![:space:]]*}"}"; _tv="${_tv%"${_tv##*[![:space:]]}"}"; }

case_begin "parser-table" "bin/lib/glossary-format.js"
# Fixture files referenced from the table as @<name> (resolved under $D).
gloss "$D/three.md" alpha Beta gamma
printf '# Glossary\n\n### alpha\n- **Definition**: line one\n  line two\n- **Related**: [o](o.md)\n\n### beta\n- **Definition**: b.\n- **Related**: [o](o.md)\n' > "$D/two-lines.md"
printf '# Glossary\n\n### alpha\n- **Definition**: line one\n  line two\n  line three\n- **Related**: [o](o.md)\n' > "$D/three-lines.md"
printf '# Glossary\n\n### alpha\n- **Definition**:\n- **Related**: [o](o.md)\n' > "$D/empty-def.md"
# Columns (';'-separated, since outputs such as "user|none" contain '|'):
# name ; want ; probe mode ; export ; arg1 [; arg2 [; arg3]] — args are JSON or @fixture.
while IFS=';' read -r _name _want _mode _fn _a1 _a2 _a3; do
  [[ -z "${_name//[[:space:]]/}" || "$_name" =~ ^[[:space:]]*# ]] && continue
  for _v in _name _want _mode _fn _a1 _a2 _a3; do trim_var "$_v"; done
  _args=()
  for _a in "$_a1" "$_a2" "$_a3"; do
    [[ -z "$_a" ]] && continue
    [[ "$_a" == @* ]] && _a="@$(np "$D/${_a#@}")"
    _args+=("$_a")
  done
  expect_probe "parse/$_name" "$_want" "$_mode" "$_fn" "${_args[@]}"
done <<'TABLE'
# compareTerms: case-insensitive, then lowercased code-unit order (_ and digits)
Zeta sorts after alpha                       ; 1                            ; sign  ; compareTerms      ; "Zeta"  ; "alpha"
apple equals APPLE                           ; 0                            ; sign  ; compareTerms      ; "apple" ; "APPLE"
Apple sorts before banana                    ; -1                           ; sign  ; compareTerms      ; "Apple" ; "banana"
_x sorts before A (lowercased code units)    ; -1                           ; sign  ; compareTerms      ; "_x"    ; "A"
a_b sorts before ab                          ; -1                           ; sign  ; compareTerms      ; "a_b"   ; "ab"
2fa sorts before _foo                        ; -1                           ; sign  ; compareTerms      ; "2fa"   ; "_foo"
# parseGlossaryFile / checkGlossaryFile: entries and Definition continuation lines
entry terms in file order                    ; alpha,Beta,gamma             ; terms ; parseGlossaryFile ; @three.md
well-formed file has no findings             ; EMPTY                        ; empty ; checkGlossaryFile ; @three.md
one continuation line (2 lines) passes       ; EMPTY                        ; empty ; checkGlossaryFile ; @two-lines.md
two continuation lines (3 lines) blocks      ; NONEMPTY                     ; empty ; checkGlossaryFile ; @three-lines.md
empty Definition text blocks                 ; NONEMPTY                     ; empty ; checkGlossaryFile ; @empty-def.md
# parseGlossaryPath: category|range, or null when unparseable
unsplit user                                 ; user|none                    ; path  ; parseGlossaryPath ; "docs/glossary/user.md"
unsplit internal                             ; internal|none                ; path  ; parseGlossaryPath ; "docs/glossary/internal.md"
ranged user a-m                              ; user|a-m                     ; path  ; parseGlossaryPath ; "docs/glossary/user-a-m.md"
ranged internal n-z                          ; internal|n-z                 ; path  ; parseGlossaryPath ; "docs/glossary/internal-n-z.md"
single-letter range                          ; user|q-q                     ; path  ; parseGlossaryPath ; "docs/glossary/user-q-q.md"
word suffix is unparseable                   ; null                         ; path  ; parseGlossaryPath ; "docs/glossary/user-foo.md"
reversed range is unparseable                ; null                         ; path  ; parseGlossaryPath ; "docs/glossary/user-m-a.md"
multi-letter bound is unparseable            ; null                         ; path  ; parseGlossaryPath ; "docs/glossary/user-a-mm.md"
index page is not a glossary file            ; null                         ; path  ; parseGlossaryPath ; "docs/glossary.md"
nested directory is not a glossary file      ; null                         ; path  ; parseGlossaryPath ; "docs/glossary/sub/user.md"
# termBucket: first letter, non a-z leading terms go to a
underscore-leading term goes to a            ; "a"                          ; json  ; termBucket        ; "_foo"
digit-leading term goes to a                 ; "a"                          ; json  ; termBucket        ; "2fa"
upper-case term is lowercased                ; "z"                          ; json  ; termBucket        ; "Zeta"
plain term keeps its first letter            ; "m"                          ; json  ; termBucket        ; "mike"
# fileForTerm: route a term to the file of its category and range
zulu routes to n-z                           ; "docs/glossary/user-n-z.md"  ; json  ; fileForTerm       ; ["docs/glossary/user-a-m.md","docs/glossary/user-n-z.md","docs/glossary/internal.md"] ; "user"     ; "zulu"
Beta routes to a-m                           ; "docs/glossary/user-a-m.md"  ; json  ; fileForTerm       ; ["docs/glossary/user-a-m.md","docs/glossary/user-n-z.md","docs/glossary/internal.md"] ; "user"     ; "Beta"
m boundary stays in a-m                      ; "docs/glossary/user-a-m.md"  ; json  ; fileForTerm       ; ["docs/glossary/user-a-m.md","docs/glossary/user-n-z.md","docs/glossary/internal.md"] ; "user"     ; "mike"
_priv routes to the range starting at a      ; "docs/glossary/user-a-m.md"  ; json  ; fileForTerm       ; ["docs/glossary/user-a-m.md","docs/glossary/user-n-z.md","docs/glossary/internal.md"] ; "user"     ; "_priv"
internal routes to the unsplit internal file ; "docs/glossary/internal.md"  ; json  ; fileForTerm       ; ["docs/glossary/user-a-m.md","docs/glossary/user-n-z.md","docs/glossary/internal.md"] ; "internal" ; "xray"
absent category has no file                  ; null                         ; json  ; fileForTerm       ; ["docs/glossary/user.md"]                                                               ; "internal" ; "xray"
TABLE
case_end

case_begin "promote-inserts-in-order-and-skips-session" "bin/glossary-promote"
R="$T/promote-order"
gloss "$R/docs/glossary/user.md" alpha omega
gloss "$R/docs/glossary/internal.md" kilo
approved_intent "f2529-fmt-order" "Gamma|user|The third fixture term." "delta|internal|An internal fixture term." "scratch|session|Session-only word."
run_promote "$INTENT" "$(np "$R")"
expect_promote_rc "promote with user/internal/session rows" 0
expect_promote_out "summary line" "ADDED=2 DELETED=0 REDEFINED=0 SKIPPED_EXISTING=0 SKIPPED_SESSION=1"
a="$(heading_line "$R/docs/glossary/user.md" alpha)"
g="$(heading_line "$R/docs/glossary/user.md" Gamma)"
o="$(heading_line "$R/docs/glossary/user.md" omega)"
if [[ -n "$a" && -n "$g" && -n "$o" ]] && ((a < g && g < o)); then pass "Gamma inserted between alpha and omega"
else fail "Gamma inserted between alpha and omega" "lines alpha=$a Gamma=$g omega=$o"; fi
d="$(heading_line "$R/docs/glossary/internal.md" delta)"
k="$(heading_line "$R/docs/glossary/internal.md" kilo)"
if [[ -n "$d" && -n "$k" ]] && ((d < k)); then pass "delta inserted before kilo in internal"
else fail "delta inserted before kilo in internal" "lines delta=$d kilo=$k"; fi
if grep -q -x -F -- "- **Definition**: The third fixture term." "$R/docs/glossary/user.md" && grep -q -x -F -- "- **Related**: TODO" "$R/docs/glossary/user.md"; then pass "generated entry carries Definition and Related TODO"
else fail "generated entry carries Definition and Related TODO" "$(cat "$R/docs/glossary/user.md")"; fi
expect_no_term "session row not in user file" "$R/docs/glossary/user.md" scratch
expect_no_term "session row not in internal file" "$R/docs/glossary/internal.md" scratch
case_end

case_begin "promote-is-idempotent" "bin/glossary-promote"
R="$T/promote-idem"
gloss "$R/docs/glossary/user.md" alpha omega
gloss "$R/docs/glossary/internal.md" kilo
approved_intent "f2529-fmt-idem" "Gamma|user|The third fixture term." "delta|internal|An internal fixture term." "scratch|session|Session-only word."
run_promote "$INTENT" "$(np "$R")"
cp "$R/docs/glossary/user.md" "$T/idem-user.1"
cp "$R/docs/glossary/internal.md" "$T/idem-internal.1"
run_promote "$INTENT" "$(np "$R")"
expect_promote_rc "second run" 0
expect_promote_out "second run adds nothing" "ADDED=0 DELETED=0 REDEFINED=0 SKIPPED_EXISTING=2 SKIPPED_SESSION=1"
expect_same_file "user file unchanged by second run" "$T/idem-user.1" "$R/docs/glossary/user.md"
expect_same_file "internal file unchanged by second run" "$T/idem-internal.1" "$R/docs/glossary/internal.md"
case_end

case_begin "promote-never-creates-missing-glossary-file" "bin/glossary-promote"
R="$T/promote-missing"
gloss "$R/docs/glossary/user.md" alpha
approved_intent "f2529-fmt-missing" "delta|internal|An internal fixture term."
run_promote "$INTENT" "$(np "$R")"
expect_promote_rc "internal row with no internal file" 0
expect_promote_out "missing internal file warns not promoted" "not promoted"
expect_promote_out "missing internal file adds nothing" "ADDED=0"
if [[ ! -e "$R/docs/glossary/internal.md" ]]; then pass "glossary/internal.md not created"
else fail "glossary/internal.md not created" "file was created"; fi
R="$T/promote-none"
mkdir -p "$R"
approved_intent "f2529-fmt-none" "Gamma|user|A user fixture term."
run_promote "$INTENT" "$(np "$R")"
expect_promote_rc "repo with no glossary files" 0
expect_promote_out "glossary-less repo warns not promoted" "not promoted"
expect_promote_out "glossary-less repo adds nothing" "ADDED=0"
if [[ ! -e "$R/docs" ]]; then pass "no docs/ tree created in a glossary-less repo"
else fail "no docs/ tree created in a glossary-less repo" "$(ls -R "$R/docs")"; fi
case_end

case_begin "promote-invalid-intent-table-exits-1" "bin/glossary-promote"
R="$T/promote-invalid"
gloss "$R/docs/glossary/user.md" alpha
cp "$R/docs/glossary/user.md" "$T/invalid-user.before"
approved_intent "f2529-fmt-invalid" "Gamma|bogus|Unknown category."
run_promote "$INTENT" "$(np "$R")"
expect_promote_rc "unknown category value" 1
expect_same_file "glossary untouched on invalid table" "$T/invalid-user.before" "$R/docs/glossary/user.md"
case_end

case_begin "promote-usage-error-exits-2" "bin/glossary-promote"
run_promote
expect_promote_rc "no arguments" 2
case_end

case_begin "promote-missing-intent-file-changes-nothing" "bin/glossary-promote"
R="$T/promote-no-intent"
gloss "$R/docs/glossary/user.md" alpha
gloss "$R/docs/glossary/internal.md" kilo
cp "$R/docs/glossary/user.md" "$T/no-intent-user.before"
cp "$R/docs/glossary/internal.md" "$T/no-intent-internal.before"
run_promote "$(np "$R/does-not-exist-intent.md")" "$(np "$R")"
# 127 is the harness's missing-CLI code, so it must not count as the expected refusal.
if [[ "$PROMOTE_RC" != 0 && "$PROMOTE_RC" != 127 ]]; then pass "missing intent file exits non-zero (rc=$PROMOTE_RC)"
else fail "missing intent file exits non-zero" "rc=$PROMOTE_RC; output: ${PROMOTE_OUT:0:600}"; fi
expect_same_file "user file untouched without an intent file" "$T/no-intent-user.before" "$R/docs/glossary/user.md"
expect_same_file "internal file untouched without an intent file" "$T/no-intent-internal.before" "$R/docs/glossary/internal.md"
case_end

# A lone add of a term that already lives in the other category is refused before any
# write (category-conflict, #2529); a category move needs the paired delete row.
case_begin "promote-term-in-opposite-category-changes-nothing" "bin/glossary-promote"
R="$T/promote-cross"
gloss "$R/docs/glossary/user.md" alpha
gloss "$R/docs/glossary/internal.md" kilo
cp "$R/docs/glossary/user.md" "$T/cross-user.before"
cp "$R/docs/glossary/internal.md" "$T/cross-internal.before"
approved_intent "f2529-fmt-cross" "kilo|user|Already defined as an internal term."
run_promote "$INTENT" "$(np "$R")"
expect_promote_rc "term in the opposite category is refused" 1
expect_promote_out "refusal names category-conflict" "category-conflict"
expect_same_file "user file untouched by a cross-category term" "$T/cross-user.before" "$R/docs/glossary/user.md"
expect_same_file "internal file untouched by a cross-category term" "$T/cross-internal.before" "$R/docs/glossary/internal.md"
case_end

case_begin "promote-routes-into-range-split-files" "bin/glossary-promote"
R="$T/promote-ranged"
gloss "$R/docs/glossary/user-a-m.md" alpha mike
gloss "$R/docs/glossary/user-n-z.md" november
approved_intent "f2529-fmt-ranged" "beta|user|A fixture term." "zulu|user|A fixture term." "_priv|user|A fixture term."
run_promote "$INTENT" "$(np "$R")"
expect_promote_rc "ranged insert" 0
expect_has_term "beta in a-m" "$R/docs/glossary/user-a-m.md" beta
expect_has_term "_priv in a-m (non a-z leading)" "$R/docs/glossary/user-a-m.md" _priv
expect_has_term "zulu in n-z" "$R/docs/glossary/user-n-z.md" zulu
expect_no_term "zulu not in a-m" "$R/docs/glossary/user-a-m.md" zulu
case_end

case_begin "promote-refuses-invalid-file-set" "bin/glossary-promote"
R="$T/promote-overlap"
gloss "$R/docs/glossary/user-a-m.md" alpha
gloss "$R/docs/glossary/user-m-z.md" zulu
cp "$R/docs/glossary/user-a-m.md" "$T/overlap-am.before"
cp "$R/docs/glossary/user-m-z.md" "$T/overlap-mz.before"
approved_intent "f2529-fmt-overlap" "beta|user|A fixture term."
run_promote "$INTENT" "$(np "$R")"
expect_promote_rc "overlapping ranges" 1
expect_same_file "a-m untouched" "$T/overlap-am.before" "$R/docs/glossary/user-a-m.md"
expect_same_file "m-z untouched" "$T/overlap-mz.before" "$R/docs/glossary/user-m-z.md"
case_end

# The pre-promote glossary is committed so the staged change holds exactly the promoted adds;
# the gate's glossary provenance check then matches them against the same approved session (#2529).
case_begin "promote-round-trip-passes-gate" "bin/glossary-promote"
R="$T/promote-roundtrip"
harness_git_init "$R"
git -C "$R" config core.autocrlf false
git -C "$R" config user.email "test@example.com"
git -C "$R" config user.name "test"
gloss "$R/docs/glossary/user-a-m.md" alpha mike
gloss "$R/docs/glossary/user-n-z.md" november
git -C "$R" add docs
git -C "$R" commit -q -m "glossary before promote"
approved_intent "f2529-fmt-roundtrip" "beta|user|A fixture term." "zulu|user|A fixture term." "_priv|user|A fixture term."
run_promote "$INTENT" "$(np "$R")"
expect_promote_rc "round-trip promotion" 0
sed -i 's#^- \*\*Related\*\*: TODO$#- **Related**: [owner](architecture/owner.md)#' "$R/docs/glossary/user-a-m.md" "$R/docs/glossary/user-n-z.md"
git -C "$R" add docs
GATE_RC=127
if [[ -f "$GATE" ]]; then
  GATE_RC=0
  GATE_OUT="$(cd "$R" && run_with_timeout 120 bash "$GATE" --staged --session f2529-fmt-roundtrip 2>&1)" || GATE_RC=$?
else
  GATE_OUT="TOOL NOT FOUND: bin/review-doc-glossary"
fi
if [[ "$GATE_RC" == 0 ]]; then pass "promoted files pass the glossary gate after Related is filled"
else fail "promoted files pass the glossary gate after Related is filled" "rc=$GATE_RC: ${GATE_OUT:0:600}"; fi
case_end

case_begin "promote-empty-glossary-section-is-noop" "bin/glossary-promote"
R="$T/promote-empty"
gloss "$R/docs/glossary/user.md" alpha
gloss "$R/docs/glossary/internal.md" kilo
cp "$R/docs/glossary/user.md" "$T/empty-user.before"
cp "$R/docs/glossary/internal.md" "$T/empty-internal.before"
# The intent() helper always emits a table; an empty-bodied heading is written directly.
printf '# Fixture intent\n\n## Issues\n\n- #1: fixture\n\n## Glossary\n\n## Background/Motivation\n\nFixture.\n' > "$WORKFLOW_PLANS_DIR/f2529-fmt-empty-intent.md"
approve "f2529-fmt-empty"
run_promote "$(np "$WORKFLOW_PLANS_DIR/f2529-fmt-empty-intent.md")" "$(np "$R")"
expect_promote_rc "empty Glossary section" 0
expect_promote_out "empty section adds nothing" "ADDED=0 DELETED=0 REDEFINED=0 SKIPPED_EXISTING=0 SKIPPED_SESSION=0"
expect_same_file "user file untouched by an empty section" "$T/empty-user.before" "$R/docs/glossary/user.md"
expect_same_file "internal file untouched by an empty section" "$T/empty-internal.before" "$R/docs/glossary/internal.md"
case_end

case_begin "promote-validates-whole-table-before-writing" "bin/glossary-promote"
R="$T/promote-partial"
gloss "$R/docs/glossary/user.md" alpha
gloss "$R/docs/glossary/internal.md" kilo
cp "$R/docs/glossary/user.md" "$T/partial-user.before"
cp "$R/docs/glossary/internal.md" "$T/partial-internal.before"
# Valid user/internal rows precede a 2-cell row: a row-by-row writer would promote them first.
approved_intent "f2529-fmt-partial" "Gamma|user|A valid user term." "delta|internal|A valid internal term." "broken|user"
run_promote "$INTENT" "$(np "$R")"
expect_promote_rc "malformed row after valid rows" 1
expect_same_file "user file untouched when a later row is malformed" "$T/partial-user.before" "$R/docs/glossary/user.md"
expect_same_file "internal file untouched when a later row is malformed" "$T/partial-internal.before" "$R/docs/glossary/internal.md"
case_end

case_begin "promote-table-with-trailing-prose-exits-1" "bin/glossary-promote"
R="$T/promote-trailing-prose"
gloss "$R/docs/glossary/user.md" alpha
gloss "$R/docs/glossary/internal.md" kilo
cp "$R/docs/glossary/user.md" "$T/prose-user.before"
cp "$R/docs/glossary/internal.md" "$T/prose-internal.before"
printf '# Fixture intent\n\n## Issues\n\n- #1: fixture\n\n## Glossary\n\n| Term | Category | Definition |\n|---|---|---|\n| Gamma | user | A valid user term. |\n\nStray prose after the table.\n\n## Background/Motivation\n\nFixture.\n' > "$WORKFLOW_PLANS_DIR/f2529-fmt-prose-intent.md"
approve "f2529-fmt-prose"
run_promote "$(np "$WORKFLOW_PLANS_DIR/f2529-fmt-prose-intent.md")" "$(np "$R")"
expect_promote_rc "valid table followed by stray prose" 1
expect_same_file "user file untouched by a table with trailing prose" "$T/prose-user.before" "$R/docs/glossary/user.md"
expect_same_file "internal file untouched by a table with trailing prose" "$T/prose-internal.before" "$R/docs/glossary/internal.md"
case_end

case_begin "promote-empty-cell-row-exits-1" "bin/glossary-promote"
R="$T/promote-empty-cell"
gloss "$R/docs/glossary/user.md" alpha
gloss "$R/docs/glossary/internal.md" kilo
cp "$R/docs/glossary/user.md" "$T/cell-user.before"
cp "$R/docs/glossary/internal.md" "$T/cell-internal.before"
approved_intent "f2529-fmt-cell-def" "Gamma|user| "
run_promote "$INTENT" "$(np "$R")"
expect_promote_rc "row with an empty Definition cell" 1
expect_same_file "user file untouched by an empty Definition cell" "$T/cell-user.before" "$R/docs/glossary/user.md"
expect_same_file "internal file untouched by an empty Definition cell" "$T/cell-internal.before" "$R/docs/glossary/internal.md"
approved_intent "f2529-fmt-cell-cat" "delta| |An internal fixture term."
run_promote "$INTENT" "$(np "$R")"
expect_promote_rc "row with an empty Category cell" 1
expect_same_file "user file untouched by an empty Category cell" "$T/cell-user.before" "$R/docs/glossary/user.md"
expect_same_file "internal file untouched by an empty Category cell" "$T/cell-internal.before" "$R/docs/glossary/internal.md"
case_end

case_begin "promote-existing-term-matches-case-insensitively" "bin/glossary-promote"
R="$T/promote-case"
gloss "$R/docs/glossary/user.md" alpha "Combined Glossary" omega
cp "$R/docs/glossary/user.md" "$T/case-user.before"
approved_intent "f2529-fmt-case" "combined glossary|user|Differs from the existing entry only in case."
run_promote "$INTENT" "$(np "$R")"
expect_promote_rc "case-only variant of an existing term" 0
expect_promote_out "case-only variant counted as existing" "ADDED=0 DELETED=0 REDEFINED=0 SKIPPED_EXISTING=1 SKIPPED_SESSION=0"
expect_same_file "no duplicate entry for a case-only variant" "$T/case-user.before" "$R/docs/glossary/user.md"
case_end

echo ""
echo "Total: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
