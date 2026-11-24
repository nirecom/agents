#!/usr/bin/env bash
# tests/bin/feature-2814-review-criteria-block.sh
# Tests: bin/lib/codex-review-criteria.sh, bin/review-criteria-block, bin/lib/codex-core.sh, skills/_shared/review-criteria.md, skills/_shared/severity.md
# Tags: TL2, codex, review, review-criteria, severity, nfr, prompt, fail-closed, issue-2814, scope:issue-specific, pwsh-not-required, issue-2020, threat-boundary, criteria-hash
# #2814 reopen R1 (T2, T10): codex_core_review_criteria_block emits [REVIEW CRITERIA], then
# [SEVERITY DEFINITION], then the PROJECT NFR block; example blocks are stripped before delivery
# (CRLF tag lines too); a malformed example block or a missing file fails closed; the CLI is
# byte-equal to the function; HIGH is defined in severity.md only.
# TL3 gap (what this test does NOT catch):
# - a live codex or CC reviewer applying the criteria; only the delivered text is checked here.
set -uo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
RC_ROOT="$(make_tmp)"
readonly RC_ROOT
trap 'cd / 2>/dev/null; rm -rf "$RC_ROOT"' EXIT
harness_isolate "$RC_ROOT/iso"
unset CLAUDE_CODE_SESSION_ID PROJECT_NFR
cd "$RC_ROOT" || exit 1

REAL="$SCRIPT_CHECKOUT_ROOT"
CRIT_SRC="$REAL/skills/_shared/review-criteria.md"
SEV_SRC="$REAL/skills/_shared/severity.md"
ck() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "want=$(printf '%q' "$2") got=$(printf '%q' "${3:0:300}")"; fi; }
yn() { if "$@"; then printf yes; else printf no; fi; }
# same <a> <b> — "same" only for two equal non-empty files (two empty outputs are no match).
same() { if [ ! -s "$1" ] || [ ! -s "$2" ]; then printf empty; elif cmp -s "$1" "$2"; then printf same; else printf differs; fi; }

# The global .env the NFR lookup falls back to: pinned empty, never the ambient one.
CFG="$RC_ROOT/cfg"; mkdir -p "$CFG"; : > "$CFG/.env"
LOCAL_ENV_BASENAME=".env"".local"
NFR_MARKER="CRITNFRMARKER9ZT"
PROJ="$RC_ROOT/proj"; mkdir -p "$PROJ/.git"
printf 'PROJECT_NFR=%s single-user workstation\n' "$NFR_MARKER" > "$PROJ/$LOCAL_ENV_BASENAME"
PROJ_BARE="$RC_ROOT/proj-bare"; mkdir -p "$PROJ_BARE/.git"

OUT="$RC_ROOT/out.txt"; ERR="$RC_ROOT/err.txt"; FN_RC=0; CLI_RC=0
# fn <tree> <function> [args...] — codex-core.sh of <tree> sourced, then one function; stdout to
# $OUT, stderr to $ERR, rc to FN_RC (97 = the library did not source).
fn() {
  local tree="$1"; shift
  FN_RC=0
  AGENTS_MAIN_ROOT="$CFG" run_with_timeout 60 bash -c '. "$1/bin/lib/codex-core.sh" >/dev/null 2>&1 || exit 97; shift; "$@"' _ "$tree" "$@" > "$OUT" 2> "$ERR" || FN_RC=$?
}
# cli <tree> <out> [root] — bin/review-criteria-block of <tree>.
cli() {
  CLI_RC=0
  AGENTS_MAIN_ROOT="$CFG" run_with_timeout 60 bash "$1/bin/review-criteria-block" ${3:+"$3"} > "$2" 2> "$ERR" || CLI_RC=$?
}
line_of() { local n; n="$(grep -n -m1 -x -F -- "$2" "$1" 2>/dev/null | cut -d: -f1)"; printf '%s' "${n:-0}"; }
# between <file> <start> <end> — the lines strictly between two exact delimiter lines.
between() { awk -v s="$2" -v e="$3" '$0==e{f=0} f{print} $0==s{f=1}' "$1"; }

case_begin "block-order-three-frames" "bin/lib/codex-review-criteria.sh"
fn "$REAL" codex_core_review_criteria_block "$PROJ"
ck "order: exits 0" "0" "$FN_RC"
rcs="$(line_of "$OUT" '[REVIEW CRITERIA START]')"; rce="$(line_of "$OUT" '[REVIEW CRITERIA END]')"
sds="$(line_of "$OUT" '[SEVERITY DEFINITION START]')"; sde="$(line_of "$OUT" '[SEVERITY DEFINITION END]')"
nfs="$(line_of "$OUT" '[PROJECT NFR START]')"
ck "order: criteria opens on line 1" "1" "$rcs"
ck "order: criteria closes after it opens" "yes" "$(yn [ "$rce" -gt "$rcs" ])"
ck "order: a blank line follows the criteria end" "" "$(sed -n "$((rce + 1))p" "$OUT")"
ck "order: then the severity definition opens" "$((rce + 2))" "$sds"
ck "order: severity closes after it opens" "yes" "$(yn [ "$sde" -gt "$sds" ])"
ck "order: a blank line follows the severity end" "" "$(sed -n "$((sde + 1))p" "$OUT")"
ck "order: then the NFR block opens" "$((sde + 2))" "$nfs"
for t in '[REVIEW CRITERIA START]' '[REVIEW CRITERIA END]' '[SEVERITY DEFINITION START]' '[SEVERITY DEFINITION END]' '[PROJECT NFR START]'; do
  ck "order: '$t' appears once" "1" "$(grep -c -x -F -- "$t" "$OUT")"
done
case_end

# A copied tree whose two canonical files are fixtures; root stays empty (no NFR lookup).
TREE="$RC_ROOT/tree"
mkdir -p "$TREE/bin" "$TREE/skills/_shared"
cp -r "$REAL/bin/lib" "$TREE/bin/lib"
[ -f "$REAL/bin/review-criteria-block" ] && cp "$REAL/bin/review-criteria-block" "$TREE/bin/review-criteria-block"
T_CRIT="$TREE/skills/_shared/review-criteria.md"; T_SEV="$TREE/skills/_shared/severity.md"
printf '# Fixture criteria\n## Scope\nkeep-1\n<!-- example -->\nEXSECRET-A\n<!-- /example -->\nkeep-2\n<!-- example -->\r\nEXSECRET-B\r\n<!-- /example -->\r\nkeep-3\r\nInline <!-- example --> mention stays\n' > "$T_CRIT"
printf '# Fixture severity\n- HIGH: fixture\n<!-- example -->\nEXSECRET-C\n<!-- /example -->\n' > "$T_SEV"
WANT_CRIT="$RC_ROOT/want-crit.txt"
printf '# Fixture criteria\n## Scope\nkeep-1\nkeep-2\nkeep-3\nInline <!-- example --> mention stays\n' > "$WANT_CRIT"
WANT_BLOCK="$RC_ROOT/want-block.txt"
printf '[REVIEW CRITERIA START]\n' > "$WANT_BLOCK"
cat "$WANT_CRIT" >> "$WANT_BLOCK"
printf '[REVIEW CRITERIA END]\n\n[SEVERITY DEFINITION START]\n# Fixture severity\n- HIGH: fixture\n[SEVERITY DEFINITION END]\n\n' >> "$WANT_BLOCK"

case_begin "strip-examples-lf-and-crlf" "bin/lib/codex-review-criteria.sh"
fn "$TREE" _codex_core_strip_examples "$T_CRIT"
ck "strip: exits 0" "0" "$FN_RC"
ck "strip: output equals the fixture minus its example blocks, CRs removed" "same" "$(same "$OUT" "$WANT_CRIT")"
ck "strip: no example body survives" "0" "$(grep -c 'EXSECRET' "$OUT")"
ck "strip: no CR survives" "0" "$(tr -cd '\r' < "$OUT" | wc -c | tr -d ' ')"
fn "$TREE" codex_core_review_criteria_block ""
ck "strip via block: exits 0" "0" "$FN_RC"
ck "strip via block: the whole block equals the expected bytes" "same" "$(same "$OUT" "$WANT_BLOCK")"
case_end

printf 'a\n<!-- example -->\n<!-- example -->\nx\n<!-- /example -->\n<!-- /example -->\nb\n' > "$RC_ROOT/bad-nested.md"
printf 'a\nx\n<!-- /example -->\nb\n' > "$RC_ROOT/bad-lone-end.md"
printf 'a\n<!-- example -->\nx\nb\n' > "$RC_ROOT/bad-unclosed.md"

case_begin "strip-malformed-fails-closed" "bin/lib/codex-review-criteria.sh"
for label in nested lone-end unclosed; do
  fn "$TREE" _codex_core_strip_examples "$RC_ROOT/bad-$label.md"
  ck "malformed ($label): rc 1" "1" "$FN_RC"
  ck "malformed ($label): no output" "0" "$(wc -c < "$OUT" | tr -d ' ')"
done
cp "$T_CRIT" "$T_CRIT.good"
printf 'a\n<!-- example -->\nEXSECRET-D\n' > "$T_CRIT"
fn "$TREE" codex_core_review_criteria_block ""
ck "malformed via block: rc 1" "1" "$FN_RC"
ck "malformed via block: no stdout" "0" "$(wc -c < "$OUT" | tr -d ' ')"
ck "malformed via block: one stderr line naming the function and the criteria path" "1" \
  "$(grep -c -E '^codex_core_review_criteria_block: .+: .*skills/_shared/review-criteria\.md' "$ERR")"
mv "$T_CRIT.good" "$T_CRIT"
case_end

case_begin "empty-root-no-nfr-frame" "bin/lib/codex-review-criteria.sh"
fn "$REAL" codex_core_review_criteria_block ""
ck "empty root: exits 0" "0" "$FN_RC"
ck "empty root: no NFR frame" "0" "$(grep -c -F '[PROJECT NFR' "$OUT")"
ck "empty root: the severity definition still closes the block" "yes" "$(yn grep -q -x -F '[SEVERITY DEFINITION END]' "$OUT")"
fn "$REAL" codex_core_review_criteria_block "$PROJ_BARE"
ck "root without PROJECT_NFR: exits 0" "0" "$FN_RC"
ck "root without PROJECT_NFR: no NFR frame" "0" "$(grep -c -F '[PROJECT NFR' "$OUT")"
case_end

case_begin "missing-file-fails-closed" "bin/review-criteria-block"
for leg in crit sev; do
  f="$T_CRIT"; want='skills/_shared/review-criteria\.md'
  [ "$leg" = sev ] && f="$T_SEV" && want='skills/_shared/severity\.md'
  mv "$f" "$f.hidden"
  fn "$TREE" codex_core_review_criteria_block ""
  ck "missing $leg: the function returns 1" "1" "$FN_RC"
  ck "missing $leg: no stdout" "0" "$(wc -c < "$OUT" | tr -d ' ')"
  ck "missing $leg: one stderr line '<fn>: <reason>: <path>'" "1" "$(grep -c -E "^codex_core_review_criteria_block: [^:]+: .*$want" "$ERR")"
  cli "$TREE" "$RC_ROOT/cli-missing.txt"
  ck "missing $leg: the CLI exits 1" "1" "$CLI_RC"
  mv "$f.hidden" "$f"
done
case_end

case_begin "cli-byte-equal-to-function" "bin/review-criteria-block"
for root in "" "$PROJ"; do
  tag="root=${root:+proj}"
  fn "$REAL" codex_core_review_criteria_block "$root"
  cp "$OUT" "$RC_ROOT/fn.txt"
  cli "$REAL" "$RC_ROOT/cli.txt" "$root"
  ck "cli ($tag): exits 0" "0" "$CLI_RC"
  ck "cli ($tag): non-empty output (precondition)" "yes" "$(yn [ -s "$RC_ROOT/cli.txt" ])"
  ck "cli ($tag): byte-equal to the function" "same" "$(same "$RC_ROOT/fn.txt" "$RC_ROOT/cli.txt")"
  cli "$REAL" "$RC_ROOT/cli2.txt" "$root"
  ck "cli ($tag): a second call is byte-identical" "same" "$(same "$RC_ROOT/cli.txt" "$RC_ROOT/cli2.txt")"
done
case_end

case_begin "real-output-has-no-example" "skills/_shared/review-criteria.md"
ck "real: the criteria source keeps its examples in example blocks" "yes" "$(yn grep -q -x -F '<!-- example -->' "$CRIT_SRC")"
fn "$REAL" codex_core_review_criteria_block "$PROJ"
ck "real: exits 0" "0" "$FN_RC"
ck "real: non-empty output (precondition)" "yes" "$(yn [ -s "$OUT" ])"
ck "real: no '<!-- example' in the delivered block" "0" "$(grep -c -F '<!-- example' "$OUT")"
ck "real: no '<!-- /example' in the delivered block" "0" "$(grep -c -F '<!-- /example' "$OUT")"
case_end

case_begin "criteria-sections-no-distribution" "skills/_shared/review-criteria.md"
ck "criteria: the file exists" "yes" "$(yn [ -f "$CRIT_SRC" ])"
for h in "Scope" "Coverage" "Reporting minimum" "Severity" "NFR compliance" "Neutral framing" "Copies of a canonical source" "Examples"; do
  ck "criteria: has the '## $h' section once" "1" "$(grep -c -x -F "## $h" "$CRIT_SRC" 2>/dev/null)"
done
ck "criteria: Severity defers to the delivered SEVERITY DEFINITION and PROJECT NFR blocks" "yes" \
  "$(yn grep -q -F 'Judge severity by the SEVERITY DEFINITION block delivered with these criteria, weighing it against the PROJECT NFR block.' "$CRIT_SRC")"
ck "criteria: Scope refers to core.md in one line" "yes" \
  "$(yn grep -q -F 'Review scope and round rules: `skills/_shared/priority-hierarchy/core.md`.' "$CRIT_SRC")"
ck "criteria: Examples states the stripping rule" "yes" \
  "$(yn grep -q -F 'Example blocks are stripped before delivery; never put a definition inside one.' "$CRIT_SRC")"
for f in "$CRIT_SRC" "$SEV_SRC"; do
  b="${f#"$REAL"/}"
  ck "$b: exists (precondition)" "yes" "$(yn [ -f "$f" ])"
  ck "$b: no 'distribution'" "0" "$(grep -c -i -E 'distribution' "$f" 2>/dev/null)"
  ck "$b: no percentage" "0" "$(grep -c -E '[0-9]+%' "$f" 2>/dev/null)"
  ck "$b: no 'at least <n>'" "0" "$(grep -c -i -E 'at least [0-9]+' "$f" 2>/dev/null)"
done
case_end

case_begin "nfr-marker-only-in-nfr-frame" "bin/lib/codex-review-criteria.sh"
fn "$REAL" codex_core_review_criteria_block "$PROJ"
ck "nfr: exits 0" "0" "$FN_RC"
cp "$OUT" "$RC_ROOT/out-nfr.txt"
all="$(grep -c -F "$NFR_MARKER" "$OUT")"
inside="$(between "$OUT" '[PROJECT NFR START]' '[PROJECT NFR END]' | grep -c -F "$NFR_MARKER")"
ck "nfr: the marker is delivered once" "1" "$all"
ck "nfr: every marker line sits inside the NFR frame" "$all" "$inside"
between "$OUT" '[SEVERITY DEFINITION START]' '[SEVERITY DEFINITION END]' > "$RC_ROOT/sev-got.txt"
between "$OUT" '[REVIEW CRITERIA START]' '[REVIEW CRITERIA END]' > "$RC_ROOT/crit-got.txt"
fn "$REAL" _codex_core_strip_examples "$SEV_SRC"
cp "$OUT" "$RC_ROOT/sev-want.txt"
fn "$REAL" _codex_core_strip_examples "$CRIT_SRC"
cp "$OUT" "$RC_ROOT/crit-want.txt"
ck "nfr: the severity body is non-empty (precondition)" "yes" "$(yn [ -s "$RC_ROOT/sev-want.txt" ])"
ck "nfr: SEVERITY DEFINITION equals the example-stripped severity.md byte for byte" "same" "$(same "$RC_ROOT/sev-got.txt" "$RC_ROOT/sev-want.txt")"
ck "nfr: REVIEW CRITERIA equals the example-stripped criteria byte for byte" "same" "$(same "$RC_ROOT/crit-got.txt" "$RC_ROOT/crit-want.txt")"
ck "nfr: severity.md carries no project NFR content" "0" "$(grep -c -F "$NFR_MARKER" "$SEV_SRC" 2>/dev/null)"
ck "nfr: the NFR frame closes" "1" "$(grep -c -x -F '[PROJECT NFR END]' "$RC_ROOT/out-nfr.txt" 2>/dev/null)"
case_end

# The HIGH bullets: from the line naming HIGH (heading or top-level bullet) up to the one naming MEDIUM.
HIGH_SENT="$RC_ROOT/high-sentences.txt"
awk '/^(#+|[-*])[[:space:]].*MEDIUM/{if(f)exit} f && /^[[:space:]]*[-*][[:space:]]/{print} /^(#+|[-*])[[:space:]].*HIGH/{f=1}' "$SEV_SRC" 2>/dev/null \
  | sed -E 's/^[[:space:]]*[-*][[:space:]]+//; s/\*\*//g' | sed 's/\. /.\n/g' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' \
  | awk 'length($0) >= 25' > "$HIGH_SENT"

case_begin "high-defined-in-severity-md-only" "skills/_shared/severity.md"
ck "high: severity.md has HIGH bullet sentences (precondition)" "yes" "$(yn [ -s "$HIGH_SENT" ])"
while IFS= read -r sent; do
  hits="$(cd "$REAL" && grep -rlF -- "$sent" skills agents rules bin .github 2>/dev/null | tr -d '\r' | sort | paste -sd ' ' -)"
  ck "high: only severity.md says '${sent:0:60}'" "skills/_shared/severity.md" "$hits"
done < "$HIGH_SENT"
case_end

# #2020: the Threat boundary section survives the example strip; line 1 of REVIEW_CRITERIA_HASH_OUT
# carries the sha256 prefix (12 hex) of the delivered bytes.
sha12() { sha256sum "$1" 2>/dev/null | cut -c1-12; }
rd() { [ -f "$1" ] && sed -n 1p "$1" | tr -d '\r\n'; }

case_begin "threat-boundary-delivered" "skills/_shared/review-criteria.md"
fn "$REAL" codex_core_review_criteria_block ""
between "$OUT" '[REVIEW CRITERIA START]' '[REVIEW CRITERIA END]' > "$RC_ROOT/tb-crit.txt"
ck "boundary: the delivered criteria carry '## Threat boundary' once" "1" "$(grep -c -x -F '## Threat boundary' "$RC_ROOT/tb-crit.txt")"
# axis-A class | its handling cell (I4: in = A1/A4/A5, out = A2/A3/A6, no-path = A0)
for pair in A0:no-path A1:in A2:out A3:out A4:in A5:in A6:out; do
  a="${pair%%:*}"; h="${pair#*:}"
  ck "boundary: the axis-A table row $a is handled '$h'" "1" \
    "$(grep -cE "^\|[[:space:]]*${a}[[:space:]]*\|.*\|[[:space:]]*${h}[[:space:]]*\|[[:space:]]*\$" "$RC_ROOT/tb-crit.txt")"
done
for b in B0 B1 B2 B3; do
  ck "boundary: axis B names $b" "yes" "$(yn grep -qE "(^|[^A-Za-z0-9])$b([^0-9]|\$)" "$RC_ROOT/tb-crit.txt")"
done
for tok in '[NOT-CONCERN]' 'axis:' 'cat:' 'security' 'APPROVED'; do
  ck "boundary: the section states the '$tok' format or rule" "yes" \
    "$(yn grep -qF -- "$tok" <(awk '/^## Threat boundary$/{f=1;next} /^## /{f=0} f' "$RC_ROOT/tb-crit.txt"))"
done
case_end

case_begin "hash-out-env-keeps-bytes" "bin/lib/codex-review-criteria.sh"
fn "$REAL" codex_core_review_criteria_block ""
cp "$OUT" "$RC_ROOT/plain.txt"
HO="$RC_ROOT/hash-out.txt"; rm -f "$HO"
export REVIEW_CRITERIA_HASH_OUT="$HO"
fn "$REAL" codex_core_review_criteria_block ""
unset REVIEW_CRITERIA_HASH_OUT
ck "hash out: exits 0" "0" "$FN_RC"
ck "hash out: stdout is byte-equal to the call without the env" "same" "$(same "$RC_ROOT/plain.txt" "$OUT")"
ck "hash out: the file holds 12 hex" "yes" "$(yn grep -sqxE '[0-9a-f]{12}' "$HO")"
ck "hash out: the value is the sha256 prefix of the delivered block" "$(sha12 "$OUT")" "$(rd "$HO")"
rm -f "$HO"
fn "$REAL" codex_core_review_criteria_block ""
ck "hash out: without the env no hash file appears" "no" "$(yn [ -e "$HO" ])"
case_end

case_begin "hash-out-nonce-files-isolated" "bin/lib/codex-review-criteria.sh"
for t in real tree; do rm -f "$RC_ROOT/h-$t.txt"; done
( export REVIEW_CRITERIA_HASH_OUT="$RC_ROOT/h-real.txt"
  AGENTS_MAIN_ROOT="$CFG" run_with_timeout 60 bash -c '. "$1/bin/lib/codex-core.sh" >/dev/null 2>&1 && codex_core_review_criteria_block ""' _ "$REAL" > "$RC_ROOT/o-real.txt" 2>/dev/null ) &
( export REVIEW_CRITERIA_HASH_OUT="$RC_ROOT/h-tree.txt"
  AGENTS_MAIN_ROOT="$CFG" run_with_timeout 60 bash -c '. "$1/bin/lib/codex-core.sh" >/dev/null 2>&1 && codex_core_review_criteria_block ""' _ "$TREE" > "$RC_ROOT/o-tree.txt" 2>/dev/null ) &
wait
ck "nonce: the two blocks differ (precondition)" "differs" "$(same "$RC_ROOT/o-real.txt" "$RC_ROOT/o-tree.txt")"
for t in real tree; do
  got_h="$(rd "$RC_ROOT/h-$t.txt")"; want_h="$(sha12 "$RC_ROOT/o-$t.txt")"
  ck "nonce: the $t file holds its own block's hash" "yes" \
    "$(if [ -n "$got_h" ] && [ "$got_h" = "$want_h" ]; then echo yes; else echo no; fi)"
done
case_end

# #2020: the boundary version. The block declares `Version: v<N>` under `## Threat boundary`, and
# REVIEW_CRITERIA_HASH_OUT carries it as line 2 (line 1 stays the hash).
tb_section() { awk '/^## Threat boundary$/{f=1;next} /^## /{f=0} f' "$1"; }

case_begin "boundary-version-delivered-and-recorded" "bin/lib/codex-review-criteria.sh"
fn "$REAL" codex_core_review_criteria_block ""
between "$OUT" '[REVIEW CRITERIA START]' '[REVIEW CRITERIA END]' > "$RC_ROOT/v-crit.txt"
ck "version: the delivered Threat boundary section carries 'Version: v1'" "1" "$(tb_section "$RC_ROOT/v-crit.txt" | grep -c -x -F 'Version: v1')"
HO="$RC_ROOT/hash-out-v.txt"; rm -f "$HO"
export REVIEW_CRITERIA_HASH_OUT="$HO"
fn "$REAL" codex_core_review_criteria_block ""
unset REVIEW_CRITERIA_HASH_OUT
ck "version: hash out line 1 is still the block hash" "$(sha12 "$OUT")" "$(sed -n 1p "$HO" 2>/dev/null | tr -d '\r')"
ck "version: hash out line 2 is the boundary version" "v1" "$(sed -n 2p "$HO" 2>/dev/null | tr -d '\r')"
case_end

# The pin: sha256 of the delivered Threat boundary body minus its Version line, keyed by the version.
# A meaning change bumps Version and re-pins; a wording-only edit keeps Version and re-pins.
BOUNDARY_PIN="v1=49c92030153c1001273303c990a914910d80d4364efd8c11d56e70924cc4a88f"
case_begin "boundary-body-pinned-to-version" "skills/_shared/review-criteria.md"
fn "$REAL" codex_core_review_criteria_block ""
between "$OUT" '[REVIEW CRITERIA START]' '[REVIEW CRITERIA END]' | tb_section /dev/stdin > "$RC_ROOT/pin-sec.txt"
ck "pin: the Threat boundary section is delivered (precondition)" "yes" "$(yn [ -s "$RC_ROOT/pin-sec.txt" ])"
pin_ver="$(grep -m1 -xE 'Version: v[0-9]+' "$RC_ROOT/pin-sec.txt" | sed 's/^Version: //')"
pin_hash="$(grep -vxE 'Version: v[0-9]+' "$RC_ROOT/pin-sec.txt" | sha256sum | cut -c1-64)"
if [ "${pin_ver:-none}=$pin_hash" = "$BOUNDARY_PIN" ]; then
  pass "pin: the Threat boundary body matches the pin of its version"
else
  fail "pin: the Threat boundary body matches the pin of its version" \
    "pin=$BOUNDARY_PIN got=${pin_ver:-none}=$pin_hash — the section changed: bump 'Version:' in skills/_shared/review-criteria.md when the meaning changed, then (either way) update BOUNDARY_PIN in this test"
fi
case_end

# #2020: a review whose PROJECT NFR could not be read is refused (rc 1), never sent without it; the
# side record's line 3 says whether an NFR block was delivered. TREE gets an env-effective-kv stub.
case_begin "nfr-fetch-failure-refuses-and-line3-records-delivery" "bin/lib/codex-review-criteria.sh"
EEK="$TREE/bin/env-effective-kv"; HO3="$RC_ROOT/hash-out-nfr.txt"
printf '#!/usr/bin/env bash\nexit 3\n' > "$EEK"
rm -f "$HO3"; export REVIEW_CRITERIA_HASH_OUT="$HO3"
fn "$TREE" codex_core_review_criteria_block "$PROJ"
ck "nfr fail: the block returns 1" "1" "$FN_RC"
ck "nfr fail: no block on stdout" "0" "$(wc -c < "$OUT" | tr -d ' ')"
ck "nfr fail: one stderr line names the PROJECT_NFR failure" "1" "$(grep -c -F 'PROJECT_NFR could not be read' "$ERR")"
ck "nfr fail: no side record is written" "no" "$(yn [ -e "$HO3" ])"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "small single-user"\n' > "$EEK"
fn "$TREE" codex_core_review_criteria_block "$PROJ"
ck "nfr ok: exits 0" "0" "$FN_RC"
ck "nfr ok: line 3 is nfr:present" "nfr:present" "$(sed -n 3p "$HO3" 2>/dev/null | tr -d '\r')"
printf '#!/usr/bin/env bash\nexit 0\n' > "$EEK"
fn "$TREE" codex_core_review_criteria_block "$PROJ"
ck "nfr empty: exits 0" "0" "$FN_RC"
ck "nfr empty: line 3 is nfr:absent" "nfr:absent" "$(sed -n 3p "$HO3" 2>/dev/null | tr -d '\r')"
unset REVIEW_CRITERIA_HASH_OUT; rm -f "$EEK"
case_end

echo ""
echo "Total: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
