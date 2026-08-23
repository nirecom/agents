#!/bin/bash
# tests/fix-2098-template-scan-quoting.sh
# Tests: .github/ISSUE_TEMPLATE/task.yml, .github/ISSUE_TEMPLATE/incident.yml
# Tags: github, issues, templates, issue-forms, yaml-scan, quoting, parser, scope:issue-specific, layer:TL1, dup-group-keep:size-hard-limit
#
# fix-2098-issue-template-schema.sh's offline fallback scanner tests
# `seg !~ /^[[:blank:]]*textarea/`, which never matches a quoted VALUE
# (`type: "textarea"`), so such an item is skipped whole and a required textarea
# carrying a `value:` prefill passes without uv/PyYAML. Same hole in
# `required: "true"`. That file is exactly on the 500-line HARD limit, so both
# scanner shapes are reproduced below.

set -u

PASS=0
FAIL=0
SKIP=0

# TL3 gap (what this test does NOT catch):
# - GitHub's hosted renderer actually honouring `value:` on a `type: "textarea"`
#   item, and actually accepting `required: "true"` as required.
# - The scanner text in fix-2098-issue-template-schema.sh itself is covered by
#   the A1/A2 anchors AND by the B rows, which lift that file's own
#   `fallback_scan` and run the mutants through it; what stays uncovered is that
#   file's surrounding main body (its Y5/Y6 wiring), which is not re-executed here.
# Closest-to-action mitigation: bin/check-verification-gate.sh has no category
# for .github/ISSUE_TEMPLATE/*.yml, so no preflight ask fires; the residue
# closes at the manual post-merge render check on github.com.

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE_DIR="$AGENTS_DIR/.github/ISSUE_TEMPLATE"
TASK_YML="$TEMPLATE_DIR/task.yml"
INCIDENT_YML="$TEMPLATE_DIR/incident.yml"
SIBLING="$AGENTS_DIR/tests/fix-2098-issue-template-schema.sh"

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then pass "$name"
    else fail "$name — want=$(printf '%q' "$want") got=$(printf '%q' "$got")"; fi
}

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

TMP="$(mktemp -d)"
cleanup() { [ -n "${TMP:-}" ] && rm -rf "$TMP"; }
trap cleanup EXIT

for f in "$TASK_YML" "$INCIDENT_YML"; do
    [ -f "$f" ] || fail "precondition missing — $f"
done
TASK_CK_BEFORE="$(cksum <"$TASK_YML")"
INCIDENT_CK_BEFORE="$(cksum <"$INCIDENT_YML")"

# ---------------------------------------------------------------------------
# The two scanner variants. `strip_block_scalars` is shared verbatim with the
# sibling file: the templates' markdown guidance block says `**Title**:` in
# prose, and scanning the raw file would read that as a key.
# ---------------------------------------------------------------------------
strip_block_scalars() {
    awk '
        { match($0, /^[ \t]*/); ind = RLENGTH }
        inblk {
            if ($0 ~ /^[ \t]*$/) { print ""; next }
            if (ind > blkind) { print ""; next }
            inblk = 0
        }
        /^[ \t]*[^ \t#][^:]*:[ \t]*[|>][0-9+-]*[ \t]*$/ { blkind = ind; inblk = 1; print; next }
        { print }
    ' "$1"
}

# UNHARDENED — reproduces the current sibling shape: the textarea and required
# tests accept only an UNQUOTED value.
scan_unhardened() {
    strip_block_scalars "$1" | awk '
        { doc = doc " " $0 }
        END {
            n = split(doc, parts, "[-{][[:blank:]]*[\"\047]?type[\"\047]?[[:blank:]]*:")
            for (i = 2; i <= n; i++) {
                seg = parts[i]
                if (seg !~ /^[[:blank:]]*textarea/) continue
                if (seg !~ /["\047]?required["\047]?[[:blank:]]*:[[:blank:]]*true/) continue
                if (seg !~ /["\047]?value["\047]?[[:blank:]]*:/) continue
                print "VALUE-ON-REQUIRED|item" (i - 1)
            }
        }
    '
}

# HARDENED — the same scan with every VALUE position allowed to be quoted, in
# both the block and the flow spelling. A quoted scalar is the identical YAML
# node, so a stand-in for the parser must read it identically.
scan_hardened() {
    strip_block_scalars "$1" | awk '
        { doc = doc " " $0 }
        END {
            n = split(doc, parts, "[-{][[:blank:]]*[\"\047]?type[\"\047]?[[:blank:]]*:")
            for (i = 2; i <= n; i++) {
                seg = parts[i]
                if (seg !~ /^[[:blank:]]*["\047]?textarea/) continue
                if (seg !~ /["\047]?required["\047]?[[:blank:]]*:[[:blank:]]*["\047]?true/) continue
                if (seg !~ /["\047]?value["\047]?[[:blank:]]*:/) continue
                id = "item" (i - 1)
                if (match(seg, /["\047]?id["\047]?[[:blank:]]*:[[:blank:]]*[A-Za-z0-9_-]+/)) {
                    id = substr(seg, RSTART, RLENGTH)
                    sub(/^.*:[[:blank:]]*/, "", id)
                }
                print "VALUE-ON-REQUIRED|" id
            }
        }
    '
}

count_findings() {  # count_findings <scanner-fn> <file>
    "$1" "$2" | grep -c 'VALUE-ON-REQUIRED' || true
}

# ---------------------------------------------------------------------------
# A1 — anchor. scan_unhardened reproduces the pre-fix shape that let a quoted
# type value through; the sibling has since been hardened to tolerate quotes.
# This pins that fix: revert it and the suite goes red here, not silently in a
# PyYAML-less environment where the fallback path is the only scanner running.
# ---------------------------------------------------------------------------
if [ ! -f "$SIBLING" ]; then
    fail "A1-anchor — $SIBLING is missing"
elif grep -qF 'ctx_key("type") "[[:blank:]]*[\"\047]?textarea"' "$SIBLING"; then
    pass "A1-anchor the sibling scanner tolerates a quoted type value"
else
    fail "A1-anchor — the quote-tolerant textarea test is gone from $SIBLING; the quoted-value hole is back"
fi

# ---------------------------------------------------------------------------
# A2 — the OTHER half of the same fix. `required` was hardened in the same edit,
# and every Q/P mutant below spells `required: true` UNQUOTED, so reverting that
# half alone would leave A1 and all of them green. Pin its text too.
# ---------------------------------------------------------------------------
if [ ! -f "$SIBLING" ]; then
    fail "A2-anchor — $SIBLING is missing"
elif grep -qF 'ctx_key("required") "[[:blank:]]*[\"\047]?true"' "$SIBLING"; then
    pass "A2-anchor the sibling scanner tolerates a quoted required value"
else
    fail "A2-anchor — the quote-tolerant required test is gone from $SIBLING; the quoted-value hole is back"
fi

# ---------------------------------------------------------------------------
# Fixtures. Every mutant is a self-contained Issue Forms document under $TMP;
# .github/ is never written to (asserted by I2 below).
# ---------------------------------------------------------------------------
MUT="$TMP/mutants"
mkdir -p "$MUT"

block_mutant() {  # block_mutant <dst> <type-scalar> <required-scalar> <value-line|"">
    {
        printf 'name: Task\ndescription: d\nbody:\n'
        printf '  - type: %s\n    id: background\n    attributes:\n' "$2"
        printf '      label: Background\n      placeholder: "Background of the task"\n'
        [ -n "$4" ] && printf '%s\n' "$4"
        printf '    validations:\n      required: %s\n' "$3"
    } >"$MUT/$1"
}

block_mutant q-dquote-type.yml      '"textarea"' 'true'   '      value: "Background: seeded"'
block_mutant q-squote-type.yml      "'textarea'" 'true'   '      value: "Background: seeded"'
block_mutant q-required-quoted.yml  '"textarea"' '"true"' '      value: "Background: seeded"'
block_mutant q-value-key-quoted.yml 'textarea'   'true'   '      "value": "Background: seeded"'
block_mutant q-type-and-key.yml     '"textarea"' 'true'   '      "value": "Background: seeded"'
block_mutant p-plain.yml            'textarea'   'true'   '      value: "Background: seeded"'
block_mutant c-required-false.yml   '"textarea"' 'false'  '      value: "Background: seeded"'
block_mutant c-no-value.yml         '"textarea"' 'true'   ''

flow_mutant() {  # flow_mutant <dst> <type-scalar-plus-rest-of-the-item>
    printf '{name: Task, description: d, body: [{type: %s}]}\n' "$2" >"$MUT/$1"
}
flow_mutant q-flow-dquote.yml \
  '"textarea", id: background, attributes: {label: Background, placeholder: p, value: "Background: seeded"}, validations: {required: true}'
flow_mutant q-flow-squote.yml \
  "'textarea', id: background, attributes: {label: Background, placeholder: p, value: 'Background: seeded'}, validations: {required: true}"
flow_mutant c-flow-no-value.yml \
  '"textarea", id: background, attributes: {label: Background, placeholder: p}, validations: {required: true}'

# A harmless comment appended to the real template must stay clean under both.
cp "$TASK_YML" "$MUT/c-comment.yml"
printf '# harmless control comment, plants no key\n' >>"$MUT/c-comment.yml"

# Liveness: a REAL value key planted into the real template's required textarea.
# If strip_block_scalars over-blanked, this would go undetected and every clean
# verdict below would be worthless.
awk '
    { print }
    /^[ \t]+label[ \t]*:[ \t]*Background[ \t]*$/ && !seeded { print "      value: \"Background: seeded\""; seeded = 1 }
' "$TASK_YML" >"$MUT/live-planted-task.yml"
if cmp -s "$MUT/live-planted-task.yml" "$TASK_YML"; then
    fail "L1-gen — the planted-value insertion did not happen; the liveness probe is vacuous"
else
    pass "L1-gen the planted-value mutant differs from task.yml"
fi

# ---------------------------------------------------------------------------
# Q — the mutation table. want_un / want_ha are finding counts.
#   0 / 1  => the hole is real AND the hardening kills it.
#   1 / 1  => the unhardened reproduction is a working scanner, not a no-op.
#   0 / 0  => control: the hardening does not over-fire.
# Columns: name | file | want_un | want_ha
# ---------------------------------------------------------------------------
while IFS='|' read -r name file want_un want_ha; do
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name//[[:space:]]/}"; file="${file//[[:space:]]/}"
    want_un="${want_un//[[:space:]]/}"; want_ha="${want_ha//[[:space:]]/}"
    assert_eq "Q-$name-unhardened" "$want_un" "$(count_findings scan_unhardened "$MUT/$file")"
    assert_eq "Q-$name-hardened"   "$want_ha" "$(count_findings scan_hardened   "$MUT/$file")"
done <<'TABLE'
# --- the defect: quoted VALUE positions, block and flow spelling ---
dquote-type       | q-dquote-type.yml       | 0 | 1
squote-type       | q-squote-type.yml       | 0 | 1
flow-dquote       | q-flow-dquote.yml       | 0 | 1
flow-squote       | q-flow-squote.yml       | 0 | 1
required-quoted   | q-required-quoted.yml   | 0 | 1
type-and-key      | q-type-and-key.yml      | 0 | 1
# --- quoted `"value":` KEY alone (unquoted type): the sibling already tolerates
# --- this spelling, so BOTH variants must fire; it isolates the key axis. ---
value-key-quoted  | q-value-key-quoted.yml  | 1 | 1
# --- liveness: the unhardened scanner is not a no-op ---
plain             | p-plain.yml             | 1 | 1
live-planted      | live-planted-task.yml   | 1 | 1
# --- controls: the hardening must not over-fire ---
required-false    | c-required-false.yml    | 0 | 0
no-value          | c-no-value.yml          | 0 | 0
flow-no-value     | c-flow-no-value.yml     | 0 | 0
comment           | c-comment.yml           | 0 | 0
TABLE

# ---------------------------------------------------------------------------
# B (Cross-file mutation) — the sibling's OWN scanner, not a reproduction. Q
# above drives local copies, so reverting fix-2098-issue-template-schema.sh
# would leave every Q row green. Here its `fallback_scan` is lifted out of the
# file text at runtime, re-bound under a distinct name, and fed the same
# mutants: revert EITHER half of the quoting fix and the matching B row goes
# red. B0 guards the lift itself — a silently empty extraction would be a false
# green across the whole group.
# ---------------------------------------------------------------------------
SIB_SRC=""
if [ -f "$SIBLING" ]; then
    SIB_SRC="$(awk '
        /^fallback_scan\(\)[[:blank:]]*\{/ { f = 1 }
        f { print }
        f && /^\}[[:blank:]]*$/ { exit }
    ' "$SIBLING")"
fi

SIB_OK=0
if [ -z "$SIB_SRC" ]; then
    fail "B0-extract — no fallback_scan() body could be lifted from $SIBLING; the B rows below would prove nothing"
elif ! printf '%s\n' "$SIB_SRC" | grep -q 'VALUE-ON-REQUIRED'; then
    fail "B0-extract — the lifted block carries no VALUE-ON-REQUIRED emit; the extraction grabbed the wrong text"
else
    # The lifted body references the sibling's TITLE_ERE / TITLE_FLOW_ERE, so
    # those are lifted the same way rather than re-typed here.
    eval "$(awk '/^TITLE(_FLOW)?_ERE=/ { print }' "$SIBLING")"
    eval "${SIB_SRC/fallback_scan()/sibling_fallback_scan()}"
    if declare -F sibling_fallback_scan >/dev/null 2>&1 \
        && [ -n "$(sibling_fallback_scan "$MUT/p-plain.yml")" ]; then
        SIB_OK=1
        pass "B0-extract the sibling's own fallback_scan is bound as sibling_fallback_scan and fires on a known-dirty fixture"
    else
        fail "B0-extract — sibling_fallback_scan did not bind, or found nothing in a known-dirty fixture"
    fi
fi

while IFS='|' read -r name file want; do
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name//[[:space:]]/}"; file="${file//[[:space:]]/}"; want="${want//[[:space:]]/}"
    if [ "$SIB_OK" != "1" ]; then skip "B-$name — the sibling scanner could not be lifted (see B0-extract)"; continue; fi
    got="$(sibling_fallback_scan "$MUT/$file" | grep -c 'VALUE-ON-REQUIRED' || true)"
    assert_eq "B-$name the sibling's own scanner sees the quoted spelling" "$want" "$got"
done <<'TABLE'
# --- quoted VALUE positions: each must be caught by the SIBLING's scanner ---
dquote-type      | q-dquote-type.yml      | 1
squote-type      | q-squote-type.yml      | 1
required-quoted  | q-required-quoted.yml  | 1
type-and-key     | q-type-and-key.yml     | 1
value-key-quoted | q-value-key-quoted.yml | 1
flow-dquote      | q-flow-dquote.yml      | 1
flow-squote      | q-flow-squote.yml      | 1
# --- liveness: the lifted scanner is not a no-op ---
plain            | p-plain.yml            | 1
live-planted     | live-planted-task.yml  | 1
# --- controls: it must not over-fire ---
required-false   | c-required-false.yml   | 0
no-value         | c-no-value.yml         | 0
flow-no-value    | c-flow-no-value.yml    | 0
comment          | c-comment.yml          | 0
TABLE

# ---------------------------------------------------------------------------
# R — both real templates scan clean under the HARDENED scanner. This is what
# keeps the hardening honest: a stricter scanner that turned the shipped
# templates red would be a false alarm, not a fix.
# ---------------------------------------------------------------------------
while IFS='|' read -r name file; do
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name//[[:space:]]/}"; file="${file//[[:space:]]/}"
    findings="$(scan_hardened "$TEMPLATE_DIR/$file")"
    if [ -z "$findings" ]; then
        pass "R-$name $file scans clean under the hardened scanner"
    else
        fail "R-$name $file — hardened scanner found: $(printf '%s' "$findings" | tr '\n' ' ')"
    fi
done <<'TABLE'
task     | task.yml
incident | incident.yml
TABLE

if strip_block_scalars "$TASK_YML" | grep -q 'Title'; then
    fail "R-strip — the markdown guidance block survived strip_block_scalars; the R rows prove nothing"
else
    pass "R-strip the markdown guidance block is blanked before scanning"
fi

# ---------------------------------------------------------------------------
# S (Security — input injection, CWE-78). Templates are edited by anyone who
# opens a PR; a `value:` whose text is shell metacharacters must be reported as
# inert data, never executed by the awk/grep pipeline. The scan runs from $TMP so
# an artefact would land where the assertion can see it.
# ---------------------------------------------------------------------------
block_mutant s-metachars.yml '"textarea"' 'true' '      value: "$(touch PWNED-SCAN) `touch PWNED-TICK`; rm -rf ."'
assert_eq "S1-metachars a metacharacter value is reported as an inert finding" \
    "1" "$(cd "$TMP" && count_findings scan_hardened "$MUT/s-metachars.yml")"
if compgen -G "$TMP/PWNED*" >/dev/null 2>&1 || compgen -G "$AGENTS_DIR/PWNED*" >/dev/null 2>&1; then
    fail "S2-no-execution — the injected payload EXECUTED: $(ls -d "$TMP"/PWNED* "$AGENTS_DIR"/PWNED* 2>/dev/null)"
else
    pass "S2-no-execution no artefact from the injected payload exists"
fi

# ---------------------------------------------------------------------------
# I (Idempotency) + E (edge). Re-scanning must be deterministic and read-only,
# and degenerate documents must neither crash nor fabricate a finding.
# ---------------------------------------------------------------------------
I1_FIRST="$(scan_hardened "$MUT/q-dquote-type.yml")"
I1_SECOND="$(scan_hardened "$MUT/q-dquote-type.yml")"
assert_eq "I1-deterministic re-scanning the same file yields the same findings" "$I1_FIRST" "$I1_SECOND"
assert_eq "I1-id the finding carries the item id, not a positional stand-in" \
    "VALUE-ON-REQUIRED|background" "$I1_FIRST"

: >"$MUT/e-empty.yml"
printf '\n\n\n' >"$MUT/e-blank.yml"
printf 'name: x\ndescription: d\nbody: []\n' >"$MUT/e-nobody.yml"
while IFS='|' read -r name file; do
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name//[[:space:]]/}"; file="${file//[[:space:]]/}"
    assert_eq "E-$name a degenerate document yields no finding" "0" \
        "$(count_findings scan_hardened "$MUT/$file")"
done <<'TABLE'
empty  | e-empty.yml
blank  | e-blank.yml
nobody | e-nobody.yml
TABLE

assert_eq "I2-untouched-task task.yml is byte-identical after the probes" \
    "$TASK_CK_BEFORE" "$(cksum <"$TASK_YML")"
assert_eq "I2-untouched-incident incident.yml is byte-identical after the probes" \
    "$INCIDENT_CK_BEFORE" "$(cksum <"$INCIDENT_YML")"

INDEPENDENT="$PASS"  # every assertion so far needs neither uv nor PyYAML

# ---------------------------------------------------------------------------
# P (Parser cross-check). When uv + PyYAML are available the SAME mutants go
# through a real YAML load, pinning the hardened scanner's verdicts to what a
# parser sees rather than to their own regex. `required` is read truthily
# ("true" as well as True): a text scanner cannot tell the two apart, and a
# quoted `true` is exactly the ambiguity that must stay caught, not dropped.
# Unavailable => SKIP, counted separately, never folded into PASS.
# ---------------------------------------------------------------------------
CHECKER="$TMP/required_value.py"
cat >"$CHECKER" <<'PY_EOF'
"""Count required textareas carrying a `value:` prefill (test-only)."""
import sys
import yaml

def truthy(v):
    return v is True or (isinstance(v, str) and v.strip().lower() == "true")

with open(sys.argv[1], encoding="utf-8") as fh:
    doc = yaml.safe_load(fh) or {}
n = 0
body = doc.get("body") if isinstance(doc, dict) else None
for item in (body or []):
    if not isinstance(item, dict) or item.get("type") != "textarea":
        continue
    val = item.get("validations")
    if not (isinstance(val, dict) and truthy(val.get("required"))):
        continue
    attrs = item.get("attributes")
    if isinstance(attrs, dict) and "value" in attrs.keys():
        n += 1
print(n)
PY_EOF

UV_OK=0
SKIP_REASON=""
if command -v uv >/dev/null 2>&1 \
    && run_with_timeout 120 uv run --quiet --with pyyaml python -c 'import yaml' >/dev/null 2>&1; then
    UV_OK=1
else
    SKIP_REASON="uv run --with pyyaml unavailable (no uv on PATH, or the pyyaml resolve failed offline)"
fi

while IFS='|' read -r name file want; do
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name//[[:space:]]/}"; file="${file//[[:space:]]/}"; want="${want//[[:space:]]/}"
    if [ "$UV_OK" != "1" ]; then skip "P-$name — $SKIP_REASON"; continue; fi
    # tr -d '\015': python's print() emits CRLF on Windows.
    got="$(run_with_timeout 60 uv run --quiet --with pyyaml python "$CHECKER" "$MUT/$file" 2>&1 | tr -d '\015')"
    assert_eq "P-$name the parser agrees with the hardened scanner" "$want" "$got"
done <<'TABLE'
dquote-type      | q-dquote-type.yml      | 1
squote-type      | q-squote-type.yml      | 1
flow-dquote      | q-flow-dquote.yml      | 1
flow-squote      | q-flow-squote.yml      | 1
required-quoted  | q-required-quoted.yml  | 1
value-key-quoted | q-value-key-quoted.yml | 1
type-and-key     | q-type-and-key.yml     | 1
plain            | p-plain.yml            | 1
live-planted     | live-planted-task.yml  | 1
required-false   | c-required-false.yml   | 0
no-value         | c-no-value.yml         | 0
flow-no-value    | c-flow-no-value.yml    | 0
comment          | c-comment.yml          | 0
TABLE

# A run whose entire evidence was parser-gated would report "0 failed" with zero
# coverage on an offline machine. Guard that explicitly.
if [ "$INDEPENDENT" -gt 0 ]; then
    pass "G1-independent the parser-independent group contributed $INDEPENDENT assertions"
else
    fail "G1-independent — no parser-independent assertion ran; this file proves nothing offline"
fi

echo ""
if [ "$UV_OK" = "1" ]; then
    echo "Parser path: RAN — uv run --with pyyaml"
else
    echo "Parser path: SKIPPED — $SKIP_REASON"
fi
echo "Parser-independent assertions: $INDEPENDENT"
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
