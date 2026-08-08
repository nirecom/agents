#!/usr/bin/env bash
# lang-check: ignore
# tests/feat-1761-review-verdict-validate.sh
# Tests: bin/github-issues/lib/validate-review-verdict.js, bin/lib/last-json-object.js
# Tags: issue-create, verdict, review, validator, table-driven, scope:issue-specific, pwsh-not-required, TL1
# TL3 gap (what this test does NOT catch):
# - Real `codex exec` output shape (here the raw review text is a fixture file).
# - The shell wrapper's fail-folding (that is tests/feat-1761-verdict-replacement.sh).
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: skill-orchestration.
#
# CLI contract fixed by this test (S13 detail plan):
#   node bin/github-issues/lib/validate-review-verdict.js --artifact <survey.json> --review-raw <raw.txt>
#     stdout line 1 = "valid" | "invalid"; line 2 = reason (invalid only). exit 0 always.
#   node bin/github-issues/lib/validate-review-verdict.js --format-note \
#        --survey-verdict A --review-verdict B --status S --reason "<free text>"
#     stdout = one single-line note. exit 0.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
VALIDATOR="$AGENTS_DIR/bin/github-issues/lib/validate-review-verdict.js"
LASTJSON="$AGENTS_DIR/bin/lib/last-json-object.js"
RWT="$AGENTS_DIR/bin/run-with-timeout.sh"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1 — $2"; FAIL=$((FAIL + 1)); }
assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then pass "$name"
    else fail "$name" "want=$(printf '%q' "$want") got=$(printf '%q' "$got")"; fi
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------------------
# Fixtures: two schema-v2 survey artifacts.
#
#   batched → CAND = {10, 11, 12, 13}, PARENTS = {99}, ORPHANS = {11, 12}
#     #10  open   resolved, parent #99 (meta)      → parented, and the sub-of allowlist
#     #11  closed resolved, no parent              → orphan
#     #12  open   resolved, no parent              → orphan
#     #13  closed resolved, parent #88 (NOT meta)  → parented, and #88 stays OUT of
#                                                    PARENTS: a non-meta parent is not
#                                                    something a new issue may be filed
#                                                    under (IC-C2)
#     Two orphans exist deliberately: IC-C3 aggregates a CLASS, so make-parent needs
#     at least two resolved parentless candidates before it is even expressible.
#
#   unavail → CAND = {10, 20}, PARENTS = {}  (relations_mode: unavailable)
#     Both candidates are `unresolved`, so IC-C2/IC-C3 may not be evaluated for either.
#     Note the artifact schema forbids parent data on an unresolved candidate, so
#     "unresolved parent" can only ever appear as "no admissible relation data".
# ---------------------------------------------------------------------------
cat > "$WORK/batched.json" <<'JSON'
{ "schema_version": 2,
  "proposal": { "title": "T", "background": "B", "changes": "C" },
  "verdict": "none", "target": null, "children": [], "related": [],
  "reason": "survey found nothing",
  "relations_mode": "batched", "relation_errors": [],
  "candidates": [
    { "number": 10, "title": "c10", "state": "open", "labels": [], "body": "b10",
      "relation_status": "resolved", "parent_number": 99, "parent_is_meta": true, "has_sub_issues": false },
    { "number": 11, "title": "c11", "state": "closed", "labels": [], "body": "b11",
      "relation_status": "resolved", "parent_number": null, "parent_is_meta": false, "has_sub_issues": false },
    { "number": 12, "title": "c12", "state": "open", "labels": [], "body": "b12",
      "relation_status": "resolved", "parent_number": null, "parent_is_meta": false, "has_sub_issues": false },
    { "number": 13, "title": "c13", "state": "closed", "labels": [], "body": "b13",
      "relation_status": "resolved", "parent_number": 88, "parent_is_meta": false, "has_sub_issues": false }
  ] }
JSON

cat > "$WORK/unavail.json" <<'JSON'
{ "schema_version": 2,
  "proposal": { "title": "T", "background": "B", "changes": "C" },
  "verdict": "none", "target": null, "children": [], "related": [],
  "reason": "survey found nothing",
  "relations_mode": "unavailable", "relation_errors": [10, 20],
  "candidates": [
    { "number": 10, "title": "c10", "state": "open", "labels": [], "body": "b10",
      "relation_status": "unresolved", "parent_number": null, "parent_is_meta": false, "has_sub_issues": false },
    { "number": 20, "title": "c20", "state": "open", "labels": [], "body": "b20",
      "relation_status": "unresolved", "parent_number": null, "parent_is_meta": false, "has_sub_issues": false }
  ] }
JSON

# ---------------------------------------------------------------------------
# State-casing fixtures (#1862). `gh issue view --json state` answers in UPPER
# CASE (`OPEN` / `CLOSED`), so every artifact built from real gh output carries
# that casing. These four fixtures are `batched.json` with only the `state`
# values changed — same candidates, same relations, same open/closed roles.
#
#   upper         → gh's real casing: OPEN / CLOSED
#   mixedcase     → a third casing: Open / Closed
#   badstate      → #10 carries an unknown word (MERGED) in any casing
#   badstate-array→ #10 carries a non-string (["open"])
# ---------------------------------------------------------------------------
cat > "$WORK/upper.json" <<'JSON'
{ "schema_version": 2,
  "proposal": { "title": "T", "background": "B", "changes": "C" },
  "verdict": "none", "target": null, "children": [], "related": [],
  "reason": "survey found nothing",
  "relations_mode": "batched", "relation_errors": [],
  "candidates": [
    { "number": 10, "title": "c10", "state": "OPEN", "labels": [], "body": "b10",
      "relation_status": "resolved", "parent_number": 99, "parent_is_meta": true, "has_sub_issues": false },
    { "number": 11, "title": "c11", "state": "CLOSED", "labels": [], "body": "b11",
      "relation_status": "resolved", "parent_number": null, "parent_is_meta": false, "has_sub_issues": false },
    { "number": 12, "title": "c12", "state": "OPEN", "labels": [], "body": "b12",
      "relation_status": "resolved", "parent_number": null, "parent_is_meta": false, "has_sub_issues": false },
    { "number": 13, "title": "c13", "state": "CLOSED", "labels": [], "body": "b13",
      "relation_status": "resolved", "parent_number": 88, "parent_is_meta": false, "has_sub_issues": false }
  ] }
JSON

cat > "$WORK/mixedcase.json" <<'JSON'
{ "schema_version": 2,
  "proposal": { "title": "T", "background": "B", "changes": "C" },
  "verdict": "none", "target": null, "children": [], "related": [],
  "reason": "survey found nothing",
  "relations_mode": "batched", "relation_errors": [],
  "candidates": [
    { "number": 10, "title": "c10", "state": "Open", "labels": [], "body": "b10",
      "relation_status": "resolved", "parent_number": 99, "parent_is_meta": true, "has_sub_issues": false },
    { "number": 11, "title": "c11", "state": "Closed", "labels": [], "body": "b11",
      "relation_status": "resolved", "parent_number": null, "parent_is_meta": false, "has_sub_issues": false },
    { "number": 12, "title": "c12", "state": "Open", "labels": [], "body": "b12",
      "relation_status": "resolved", "parent_number": null, "parent_is_meta": false, "has_sub_issues": false },
    { "number": 13, "title": "c13", "state": "Closed", "labels": [], "body": "b13",
      "relation_status": "resolved", "parent_number": 88, "parent_is_meta": false, "has_sub_issues": false }
  ] }
JSON

cat > "$WORK/badstate.json" <<'JSON'
{ "schema_version": 2,
  "proposal": { "title": "T", "background": "B", "changes": "C" },
  "verdict": "none", "target": null, "children": [], "related": [],
  "reason": "survey found nothing",
  "relations_mode": "batched", "relation_errors": [],
  "candidates": [
    { "number": 10, "title": "c10", "state": "MERGED", "labels": [], "body": "b10",
      "relation_status": "resolved", "parent_number": 99, "parent_is_meta": true, "has_sub_issues": false },
    { "number": 11, "title": "c11", "state": "closed", "labels": [], "body": "b11",
      "relation_status": "resolved", "parent_number": null, "parent_is_meta": false, "has_sub_issues": false },
    { "number": 12, "title": "c12", "state": "open", "labels": [], "body": "b12",
      "relation_status": "resolved", "parent_number": null, "parent_is_meta": false, "has_sub_issues": false },
    { "number": 13, "title": "c13", "state": "closed", "labels": [], "body": "b13",
      "relation_status": "resolved", "parent_number": 88, "parent_is_meta": false, "has_sub_issues": false }
  ] }
JSON

cat > "$WORK/badstate-array.json" <<'JSON'
{ "schema_version": 2,
  "proposal": { "title": "T", "background": "B", "changes": "C" },
  "verdict": "none", "target": null, "children": [], "related": [],
  "reason": "survey found nothing",
  "relations_mode": "batched", "relation_errors": [],
  "candidates": [
    { "number": 10, "title": "c10", "state": ["open"], "labels": [], "body": "b10",
      "relation_status": "resolved", "parent_number": 99, "parent_is_meta": true, "has_sub_issues": false },
    { "number": 11, "title": "c11", "state": "closed", "labels": [], "body": "b11",
      "relation_status": "resolved", "parent_number": null, "parent_is_meta": false, "has_sub_issues": false },
    { "number": 12, "title": "c12", "state": "open", "labels": [], "body": "b12",
      "relation_status": "resolved", "parent_number": null, "parent_is_meta": false, "has_sub_issues": false },
    { "number": 13, "title": "c13", "state": "closed", "labels": [], "body": "b13",
      "relation_status": "resolved", "parent_number": 88, "parent_is_meta": false, "has_sub_issues": false }
  ] }
JSON

VALIDATOR_PRESENT=no; [ -f "$VALIDATOR" ] && VALIDATOR_PRESENT=yes

# run_validate <artifact-key> <raw-review-text> → "valid" | "invalid" | "<missing>"
run_validate() {
    local key="$1" raw="$2" out
    if [ "$VALIDATOR_PRESENT" != "yes" ]; then printf '<missing>'; return; fi
    printf '%b' "$raw" > "$WORK/raw.txt"
    out=$("$RWT" 15 node "$(node_path "$VALIDATOR")" \
            --artifact "$(node_path "$WORK/$key.json")" \
            --review-raw "$(node_path "$WORK/raw.txt")" 2>/dev/null | head -n 1)
    printf '%s' "${out//[[:space:]]/}"
}

echo "=== last-json-object.js module presence ==="
if [ -f "$LASTJSON" ]; then pass "L0: bin/lib/last-json-object.js exists"
else fail "L0: bin/lib/last-json-object.js exists" "RED-EXPECTED: not yet extracted from bin/request-off-clearance"; fi

echo ""
echo "=== A: verdict-specific number allowlist (S13 step 4) ==="

# Long reason used by the 501-char case (built here so the table stays readable).
LONG_REASON=$(node -e "process.stdout.write('x'.repeat(501))" 2>/dev/null || printf 'x%.0s' $(seq 1 501))

while IFS='|' read -r name artifact review want; do
    [[ -z "${name// /}" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name//[[:space:]]/}"
    artifact="${artifact//[[:space:]]/}"
    want="${want//[[:space:]]/}"
    got=$(run_validate "$artifact" "$review")
    if [ "$got" = "<missing>" ]; then
        fail "$name" "RED-EXPECTED: validate-review-verdict.js not yet created (want=$want)"
    else
        assert_eq "$name" "$want" "$got"
    fi
done <<'TABLE'
# --- the three mandatory cases from S14 ---
A1-subof-target-is-parent      | batched | {"verdict":"sub-of","target":99,"children":[],"related":[],"reason":"parent is meta","worth_filing":true}     | valid
A2-subof-target-unknown        | batched | {"verdict":"sub-of","target":777,"children":[],"related":[],"reason":"nope","worth_filing":true}             | invalid
A3-subof-unavailable-outside   | unavail | {"verdict":"sub-of","target":99,"children":[],"related":[],"reason":"no relations","worth_filing":true}      | invalid
# --- baseline valid forms (CPR-ORTH counterparts: the validator must not over-reject) ---
A4-subof-target-in-cand        | batched | {"verdict":"sub-of","target":10,"children":[],"related":[],"reason":"same area","worth_filing":true}         | valid
A5-reopen-valid                | batched | {"verdict":"reopen","target":11,"children":[],"related":[],"reason":"same root cause","worth_filing":true}   | valid
# A6 names the two ORPHANS (#11, #12). Naming #10 here would be a re-parent, not an
# aggregation — see B17. IC-C3's ">= 2 resolved parentless candidates" is a
# precondition of the verdict, so the positive case has to satisfy it genuinely.
A6-make-parent-valid           | batched | {"verdict":"make-parent","target":null,"children":[11,12],"related":[],"reason":"group","worth_filing":true} | valid
A7-sibling-valid               | batched | {"verdict":"sibling","target":null,"children":[],"related":[10],"reason":"adjacent","worth_filing":true}     | valid
A8-none-valid                  | batched | {"verdict":"none","target":null,"children":[],"related":[],"reason":"nothing matches","worth_filing":true}   | valid
A9-subof-unavailable-in-cand   | unavail | {"verdict":"sub-of","target":10,"children":[],"related":[],"reason":"same area","worth_filing":true}         | valid
# IC-C1 admits an OPEN candidate: state is a tie-break input only, never an eligibility
# test, so "the duplicate is still open" is a dispatch-time no-op and not a malformed
# verdict. A5 is the closed counterpart; both must be accepted (CPR-ORTH).
A10-reopen-open-candidate      | batched | {"verdict":"reopen","target":10,"children":[],"related":[],"reason":"same defect","worth_filing":true}       | valid
# A candidate that already has a (non-meta) parent is still a legal sub-of TARGET —
# what B19 rejects is naming that parent itself.
A11-subof-target-is-parented-cand | batched | {"verdict":"sub-of","target":13,"children":[],"related":[],"reason":"same area","worth_filing":true}      | valid
# --- state casing (#1862): `gh issue view --json state` answers OPEN/CLOSED ---
# The artifact is validated BEFORE any per-verdict logic, so an uppercase `state`
# rejects the whole artifact — every verdict, including `none`, folds to invalid.
# A14/A16 are therefore the load-bearing cases: they prove the defect sits in the
# artifact gate, not in the reopen branch.
A12-reopen-uppercase-closed-target | upper | {"verdict":"reopen","target":11,"children":[],"related":[],"reason":"same root cause","worth_filing":true} | valid
A13-reopen-uppercase-open-target   | upper | {"verdict":"reopen","target":10,"children":[],"related":[],"reason":"same defect","worth_filing":true}    | valid
A14-none-uppercase-artifact        | upper | {"verdict":"none","target":null,"children":[],"related":[],"reason":"nothing matches","worth_filing":true} | valid
# A15/A16 use a THIRD casing ("Open"/"Closed") deliberately. They pin the SHAPE of the
# fix, not just its symptom: expanding the literal allowlist (ISSUE_STATES + "OPEN",
# "CLOSED") would turn A12-A14 green while leaving any other casing broken — a
# special-case patch, not a general one (CPR-UNV). Only normalizing the casing
# (`.toLowerCase()` behind a `typeof c.state === "string"` guard) satisfies all five.
A15-reopen-mixedcase-closed-target | mixedcase | {"verdict":"reopen","target":11,"children":[],"related":[],"reason":"same root cause","worth_filing":true} | valid
A16-none-mixedcase-artifact        | mixedcase | {"verdict":"none","target":null,"children":[],"related":[],"reason":"nothing matches","worth_filing":true} | valid
# --- malformed verdicts ---
B1-unknown-verdict             | batched | {"verdict":"escalate","target":null,"children":[],"related":[],"reason":"r","worth_filing":true}             | invalid
B2-reopen-target-null          | batched | {"verdict":"reopen","target":null,"children":[],"related":[],"reason":"r","worth_filing":true}               | invalid
B3-reopen-target-outside       | batched | {"verdict":"reopen","target":99,"children":[],"related":[],"reason":"r","worth_filing":true}                 | invalid
B4-make-parent-target-not-null | batched | {"verdict":"make-parent","target":10,"children":[10,11],"related":[],"reason":"r","worth_filing":true}       | invalid
B5-children-outside-cand       | batched | {"verdict":"make-parent","target":null,"children":[10,777],"related":[],"reason":"r","worth_filing":true}    | invalid
B6-children-empty              | batched | {"verdict":"make-parent","target":null,"children":[],"related":[],"reason":"r","worth_filing":true}          | invalid
B7-children-duplicated         | batched | {"verdict":"make-parent","target":null,"children":[10,10],"related":[],"reason":"r","worth_filing":true}     | invalid
B8-sibling-related-empty       | batched | {"verdict":"sibling","target":null,"children":[],"related":[],"reason":"r","worth_filing":true}              | invalid
B9-sibling-related-duplicated  | batched | {"verdict":"sibling","target":null,"children":[],"related":[10,10],"reason":"r","worth_filing":true}         | invalid
B10-sibling-target-not-null    | batched | {"verdict":"sibling","target":10,"children":[],"related":[10],"reason":"r","worth_filing":true}              | invalid
B11-reopen-children-nonempty   | batched | {"verdict":"reopen","target":11,"children":[10],"related":[],"reason":"r","worth_filing":true}               | invalid
B12-none-related-nonempty      | batched | {"verdict":"none","target":null,"children":[],"related":[10],"reason":"r","worth_filing":true}               | invalid
B13-reason-empty               | batched | {"verdict":"none","target":null,"children":[],"related":[],"reason":"","worth_filing":true}                  | invalid
B14-reason-missing             | batched | {"verdict":"none","target":null,"children":[],"related":[],"worth_filing":true}                              | invalid
# --- cascade PRECONDITIONS, not just shape (issue-verdict-cascade IC-C2 / IC-C3) ---
# A well-shaped verdict whose precondition is unmet is still a verdict the caller must
# not act on: each of these would silently perform a destructive or unsanctioned move.
# B17: #10 already sits under #99. Aggregating it under a NEW parent is a re-parent,
#      which IC-C3 never sanctions — and #11 being a legitimate orphan must not launder it.
B17-make-parent-parented-child | batched | {"verdict":"make-parent","target":null,"children":[11,10],"related":[],"reason":"r","worth_filing":true}    | invalid
# B18: one orphan is not a class. B6 pins the empty case; this pins the singleton, which
#      is the boundary a "children must be non-empty" reading would wrongly admit.
B18-make-parent-single-child   | batched | {"verdict":"make-parent","target":null,"children":[11],"related":[],"reason":"r","worth_filing":true}       | invalid
# B19: #88 is a real parent of candidate #13, but parent_is_meta is false — only a meta
#      parent is something a new issue may be filed under, so it never enters PARENTS.
B19-subof-non-meta-parent      | batched | {"verdict":"sub-of","target":88,"children":[],"related":[],"reason":"r","worth_filing":true}                | invalid
# B20: both unavail candidates are `unresolved`, so their "no parent" is an UNKNOWN, not
#      an observed absence. IC-C3 may not be evaluated at all against them.
B20-make-parent-unresolved     | unavail | {"verdict":"make-parent","target":null,"children":[10,20],"related":[],"reason":"r","worth_filing":true}    | invalid
# --- state casing GUARDS: what must stay rejected once casing is normalized ---
# B21: "MERGED" is not open or closed in ANY casing. Tolerating unknown words is the
#      over-correction a case-insensitive fix invites, so it is pinned explicitly.
B21-state-unknown-word         | badstate | {"verdict":"none","target":null,"children":[],"related":[],"reason":"r","worth_filing":true}               | invalid
# B22: a non-string `state`. This is the counter-case to a `String(c.state).toLowerCase()`
#      implementation, which would stringify ["open"] into "open" and admit it. The
#      validator coerces nothing elsewhere (see its header) — a wrong TYPE is a producer
#      defect, not a value to repair, so it must be rejected on type before casing.
B22-state-non-string-array     | badstate-array | {"verdict":"none","target":null,"children":[],"related":[],"reason":"r","worth_filing":true}         | invalid
# --- JSON extraction cardinality (bin/lib/last-json-object.js) ---
C1-zero-json-objects           | batched | I think the survey verdict is fine, no JSON here.                                        | invalid
C2-prose-then-one-json         | batched | Reasoning...\nHere is my answer:\n{"verdict":"none","target":null,"children":[],"related":[],"reason":"ok","worth_filing":true} | valid
C3-two-json-objects            | batched | {"verdict":"none","target":null,"children":[],"related":[],"reason":"a","worth_filing":true}\n{"verdict":"reopen","target":10,"children":[],"related":[],"reason":"b","worth_filing":true} | invalid
TABLE

# B15: reason over the 500-char limit (kept out of the table — the value is 501 chars).
got=$(run_validate batched "{\"verdict\":\"none\",\"target\":null,\"children\":[],\"related\":[],\"reason\":\"$LONG_REASON\",\"worth_filing\":true}")
if [ "$got" = "<missing>" ]; then
    fail "B15-reason-501-chars" "RED-EXPECTED: validate-review-verdict.js not yet created (want=invalid)"
else
    assert_eq "B15-reason-501-chars" "invalid" "$got"
fi
# B16: exactly 500 chars must remain valid (off-by-one boundary, CPR-ORTH counterpart).
BOUNDARY_REASON=$(node -e "process.stdout.write('x'.repeat(500))" 2>/dev/null || printf 'x%.0s' $(seq 1 500))
got=$(run_validate batched "{\"verdict\":\"none\",\"target\":null,\"children\":[],\"related\":[],\"reason\":\"$BOUNDARY_REASON\",\"worth_filing\":true}")
if [ "$got" = "<missing>" ]; then
    fail "B16-reason-500-chars-boundary" "RED-EXPECTED: validate-review-verdict.js not yet created (want=valid)"
else
    assert_eq "B16-reason-500-chars-boundary" "valid" "$got"
fi

echo ""
echo "=== D: format_note() sanitization (S13 痕跡と外向き保護) ==="

# run_note <survey> <review> <status> <reason> → note text (single line) or "<missing>"
run_note() {
    if [ "$VALIDATOR_PRESENT" != "yes" ]; then printf '<missing>'; return; fi
    "$RWT" 15 node "$(node_path "$VALIDATOR")" --format-note \
        --survey-verdict "$1" --review-verdict "$2" --status "$3" --reason "$4" 2>/dev/null
}

NOTE_RAW=$(printf 'line one\nline two\ttabbed <!-- injected --> tail')
NOTE=$(run_note none reopen replaced "$NOTE_RAW")
if [ "$NOTE" = "<missing>" ]; then
    fail "D1-fixed-template"        "RED-EXPECTED: validate-review-verdict.js not yet created"
    fail "D2-no-newline"            "RED-EXPECTED: validate-review-verdict.js not yet created"
    fail "D3-comment-markers-stripped" "RED-EXPECTED: validate-review-verdict.js not yet created"
else
    if printf '%s' "$NOTE" | grep -qF 'survey verdict none -> review verdict reopen (replaced)'; then
        pass "D1-fixed-template"
    else
        fail "D1-fixed-template" "note does not carry the fixed template (got: $NOTE)"
    fi
    if [ "$(printf '%s' "$NOTE" | wc -l | tr -d ' ')" = "0" ]; then
        pass "D2-no-newline"
    else
        fail "D2-no-newline" "note spans multiple lines (got: $NOTE)"
    fi
    if printf '%s' "$NOTE" | grep -qF -- '<!--' || printf '%s' "$NOTE" | grep -qF -- '-->'; then
        fail "D3-comment-markers-stripped" "note still contains HTML comment markers (got: $NOTE)"
    else
        pass "D3-comment-markers-stripped"
    fi
fi

# D4: reason longer than 120 chars is truncated in the note.
LONG_NOTE_REASON=$(node -e "process.stdout.write('y'.repeat(300))" 2>/dev/null || printf 'y%.0s' $(seq 1 300))
NOTE2=$(run_note reopen none replaced "$LONG_NOTE_REASON")
if [ "$NOTE2" = "<missing>" ]; then
    fail "D4-reason-truncated-120" "RED-EXPECTED: validate-review-verdict.js not yet created"
else
    YCOUNT=$(printf '%s' "$NOTE2" | tr -cd 'y' | wc -c | tr -d ' ')
    if [ "$YCOUNT" -le 120 ] && [ "$YCOUNT" -gt 0 ]; then
        pass "D4-reason-truncated-120 (y-count=$YCOUNT)"
    else
        fail "D4-reason-truncated-120" "reason not truncated to <=120 chars (y-count=$YCOUNT)"
    fi
fi

# D5: a single stripping pass can SPELL a marker that was not in the input.
# `<<!--!--` contains `<!--` at offset 1; deleting it rejoins `<` + `!--` into a fresh
# `<!--`. `---->>` does the same for `-->`. So one pass over the PoC below hands back
# exactly `PoC --> and <!-- end` — the markers the pass was asked to remove. Only a
# fixed-point loop is safe, and D3's plain `<!-- injected -->` cannot tell the two apart.
POC_REASON='PoC ---->> and <<!--!-- end'
NOTE3=$(run_note none reopen replaced "$POC_REASON")
if [ "$NOTE3" = "<missing>" ]; then
    fail "D5-comment-markers-stripped-to-fixed-point" "RED-EXPECTED: validate-review-verdict.js not yet created"
else
    if printf '%s' "$NOTE3" | grep -qF -- '<!--' || printf '%s' "$NOTE3" | grep -qF -- '-->'; then
        fail "D5-comment-markers-stripped-to-fixed-point" \
            "a single stripping pass re-spelled a marker (got: $NOTE3)"
    else
        pass "D5-comment-markers-stripped-to-fixed-point"
    fi
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
