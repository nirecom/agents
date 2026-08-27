#!/bin/bash
# tests/fix-2098-fallback-scan-semantics.sh
# Tests: .github/ISSUE_TEMPLATE/task.yml, .github/ISSUE_TEMPLATE/incident.yml
# Tags: github, issues, templates, issue-forms, yaml-scan, parser, negative-control, scope:issue-specific, layer:TL1, dup-group-keep:size-hard-limit
#
# Semantics of the parser-INDEPENDENT scanners guarding #2098 offline, on three
# axes none of their own files covers: C2 key ORDER (the split assumes `type:`
# is the item's first key), C3 the `required: "true"` contract (this file is its
# SSOT — see the C3 group), C7 sanctioned input (key-like text in comments and
# quoted descriptions). Own file: the schema sibling is at the 500-line cap.

set -u

PASS=0
FAIL=0
SKIP=0

# TL3 gap (what this test does NOT catch):
# - GitHub's hosted renderer actually honouring a prefill on a reordered-key
#   item, and actually rejecting `required: "true"` at template-load time.
# - The sibling suites' surrounding wiring: only their scanner FUNCTIONS run here.
# Closest-to-action mitigation: bin/check-verification-gate.sh has no category
# for .github/ISSUE_TEMPLATE/*.yml, so no preflight ask fires; the residue closes
# at the manual post-merge render check on github.com.

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE_DIR="$AGENTS_DIR/.github/ISSUE_TEMPLATE"
TASK_YML="$TEMPLATE_DIR/task.yml"
SCHEMA_SIB="$AGENTS_DIR/tests/fix-2098-issue-template-schema.sh"
NOPREFILL_SIB="$AGENTS_DIR/tests/fix-2098-issue-template-no-prefill.sh"

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

MUT="$TMP/mutants"
mkdir -p "$MUT"

TASK_CK_BEFORE="$(cksum <"$TASK_YML" 2>/dev/null)"

# ---------------------------------------------------------------------------
# L (Lift) — bind the two live scanner functions, extracted from their own files
# at runtime (same machinery as the B group in fix-2098-template-scan-quoting.sh).
# A re-typed copy would stay green after the real scanner regressed. L0 guards
# the lift itself: a silently empty extraction would false-green every row.
# ---------------------------------------------------------------------------
lift_fn() {  # lift_fn <file> <function-name>
    awk -v fn="$2" '
        $0 ~ ("^" fn "\\(\\)[[:blank:]]*\\{") { f = 1 }
        f { print }
        f && /^\}[[:blank:]]*$/ { exit }
    ' "$1"
}

SCAN_OK=0
if [ ! -f "$SCHEMA_SIB" ]; then
    fail "L0-schema — $SCHEMA_SIB is missing; the C2/C3/C7 rows would prove nothing"
else
    SBS_SRC="$(lift_fn "$SCHEMA_SIB" strip_block_scalars)"
    FBS_SRC="$(lift_fn "$SCHEMA_SIB" fallback_scan)"
    if [ -z "$FBS_SRC" ] || ! printf '%s\n' "$FBS_SRC" | grep -q 'VALUE-ON-REQUIRED'; then
        fail "L0-schema — fallback_scan could not be lifted (or carries no VALUE-ON-REQUIRED emit)"
    elif [ -z "$SBS_SRC" ]; then
        fail "L0-schema — strip_block_scalars could not be lifted; fallback_scan cannot run"
    else
        eval "$(awk '/^TITLE(_FLOW)?_ERE=/ { print }' "$SCHEMA_SIB")"
        eval "$SBS_SRC"
        eval "${FBS_SRC/fallback_scan()/live_scan()}"
        SCAN_OK=1
        pass "L0-schema fallback_scan + strip_block_scalars are lifted and bound as live_scan"
    fi
fi

TPL_OK=0
if [ ! -f "$NOPREFILL_SIB" ]; then
    fail "L0-noprefill — $NOPREFILL_SIB is missing; the C3 under-approximation rows cannot run"
else
    ST_SRC="$(lift_fn "$NOPREFILL_SIB" scan_template)"
    if [ -z "$ST_SRC" ]; then
        fail "L0-noprefill — scan_template could not be lifted from $NOPREFILL_SIB"
    else
        eval "${ST_SRC/scan_template()/live_template_scan()}"
        TPL_OK=1
        pass "L0-noprefill scan_template is lifted and bound as live_template_scan"
    fi
fi

live_count() {  # live_count <file> — VALUE-ON-REQUIRED findings from the live scanner
    live_scan "$1" | grep -c 'VALUE-ON-REQUIRED' || true
}

# Liveness of the lift: a fixture whose answer is known independently of every
# axis under test. At 0, every "want 0" row below would pass vacuously.
cat >"$MUT/live-canonical.yml" <<'EOF'
name: Task
description: d
body:
  - type: textarea
    id: background
    attributes:
      label: Background
      placeholder: "Background of the task"
      value: "Background: seeded"
    validations:
      required: true
EOF
if [ "$SCAN_OK" = "1" ]; then
    assert_eq "L1-liveness the lifted scanner fires on a canonical required+value item" \
        "1" "$(live_count "$MUT/live-canonical.yml")"
else
    skip "L1-liveness — the schema sibling's scanner could not be lifted (see L0-schema)"
fi

# ---------------------------------------------------------------------------
# C2 (Key order) — YAML mappings are UNORDERED, so `{id: …, type: textarea, …}`
# is the identical document to `{type: textarea, id: …, …}`. The live scanner
# splits the flattened text on `[-{] *type:`, which matches only when `type` is
# the item's FIRST key; any other order hides the whole item, prefill included.
# Fix that closes the RED rows: split on the item delimiter (`- ` / `{` / `,`)
# and read `type` anywhere inside the item, never by position.
# ---------------------------------------------------------------------------
cat >"$MUT/order-id-first.yml" <<'EOF'
name: Task
description: d
body:
  - id: background
    type: textarea
    attributes:
      label: Background
      placeholder: "Background of the task"
      value: "Background: seeded"
    validations:
      required: true
EOF

cat >"$MUT/order-attrs-first.yml" <<'EOF'
name: Task
description: d
body:
  - attributes:
      label: Background
      placeholder: "Background of the task"
      value: "Background: seeded"
    validations:
      required: true
    id: background
    type: textarea
EOF

cat >"$MUT/order-validations-first.yml" <<'EOF'
name: Task
description: d
body:
  - validations:
      required: true
    id: background
    type: "textarea"
    attributes:
      label: Background
      placeholder: "Background of the task"
      value: "Background: seeded"
EOF

printf '%s\n' '{name: Task, description: d, body: [{id: background, type: textarea, attributes: {label: Background, placeholder: p, value: "Background: seeded"}, validations: {required: true}}]}' >"$MUT/order-flow-id-first.yml"
printf '%s\n' '{name: Task, description: d, body: [{attributes: {label: Background, placeholder: p, value: "Background: seeded"}, validations: {required: true}, type: textarea, id: background}]}' >"$MUT/order-flow-type-last.yml"

# Controls: the SAME reordered shapes with no `value:`. The fix must not turn
# "reordered" into "always a finding".
printf '%s\n' '{name: Task, description: d, body: [{id: background, type: textarea, attributes: {label: Background, placeholder: p}, validations: {required: true}}]}' >"$MUT/order-flow-clean.yml"
cat >"$MUT/order-id-first-clean.yml" <<'EOF'
name: Task
description: d
body:
  - id: background
    type: textarea
    attributes:
      label: Background
      placeholder: "Background of the task"
    validations:
      required: true
EOF

while IFS='|' read -r name file want; do
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name//[[:space:]]/}"; file="${file//[[:space:]]/}"; want="${want//[[:space:]]/}"
    if [ "$SCAN_OK" != "1" ]; then skip "C2-$name — scanner not lifted (see L0-schema)"; continue; fi
    assert_eq "C2-$name the live scanner reads the item regardless of key order" \
        "$want" "$(live_count "$MUT/$file")"
done <<'TABLE'
# --- RED until the item split stops assuming `type` comes first ---
id-first          | order-id-first.yml          | 1
attrs-first       | order-attrs-first.yml       | 1
validations-first | order-validations-first.yml | 1
flow-id-first     | order-flow-id-first.yml     | 1
flow-type-last    | order-flow-type-last.yml    | 1
# --- controls: no prefill present, so no finding in either order ---
flow-clean        | order-flow-clean.yml        | 0
id-first-clean    | order-id-first-clean.yml    | 0
TABLE

# ---------------------------------------------------------------------------
# C3 — SSOT for the `required: "true"` oracle. GitHub's Issue Forms schema types
# `validations.required` as a BOOLEAN; a quoted `"true"` is the STRING "true" in
# YAML 1.1 and 1.2 alike, so GitHub REJECTS such a template: the field is not
# "required" — the template does not load. Two sibling suites read this from
# opposite sides ON PURPOSE, and the three groups below pin each side.
# ---------------------------------------------------------------------------
cat >"$MUT/req-quoted-with-value.yml" <<'EOF'
name: Task
description: d
body:
  - type: textarea
    id: background
    attributes:
      label: Background
      placeholder: "Background of the task"
      value: "Background: seeded"
    validations:
      required: "true"
EOF
cat >"$MUT/req-bool-with-value.yml" <<'EOF'
name: Task
description: d
body:
  - type: textarea
    id: background
    attributes:
      label: Background
      placeholder: "Background of the task"
      value: "Background: seeded"
    validations:
      required: true
EOF
cat >"$MUT/req-quoted-clean.yml" <<'EOF'
name: Task
description: d
body:
  - type: textarea
    id: background
    attributes:
      label: Background
      placeholder: "Background of the task"
    validations:
      required: "true"
EOF

# C3-schema — a SCHEMA VALIDATOR must REJECT the quoted spelling: accepting it
# would bless a template GitHub refuses to load. uv-gated; SKIP is counted.
STRICT="$TMP/required_boolean.py"
cat >"$STRICT" <<'PY_EOF'
"""GitHub Issue Forms: validations.required must be a BOOLEAN (test-only)."""
import sys
import yaml

with open(sys.argv[1], encoding="utf-8") as fh:
    doc = yaml.safe_load(fh) or {}
errs = []
for i, item in enumerate((doc.get("body") or []) if isinstance(doc, dict) else []):
    if not isinstance(item, dict):
        continue
    val = item.get("validations")
    if not isinstance(val, dict) or "required" not in val.keys():
        continue
    req = val["required"]
    # Type, not truthiness: the string "true" is truthy in Python yet is exactly
    # the value GitHub rejects.
    if not isinstance(req, bool):
        errs.append("body[%d] (%s): validations.required is %r (%s), not a boolean"
                    % (i, item.get("id"), req, type(req).__name__))
for e in errs:
    print("ERR: %s" % e)
print("OK" if not errs else "REJECTED")
sys.exit(1 if errs else 0)
PY_EOF

UV_OK=0
SKIP_REASON=""
if command -v uv >/dev/null 2>&1 \
    && run_with_timeout 120 uv run --quiet --with pyyaml python -c 'import yaml' >/dev/null 2>&1; then
    UV_OK=1
else
    SKIP_REASON="uv run --with pyyaml unavailable (no uv on PATH, or the pyyaml resolve failed offline)"
fi

while IFS='|' read -r name file want_rc; do
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name//[[:space:]]/}"; file="${file//[[:space:]]/}"; want_rc="${want_rc//[[:space:]]/}"
    if [ "$UV_OK" != "1" ]; then skip "C3-schema-$name — $SKIP_REASON"; continue; fi
    out="$(run_with_timeout 60 uv run --quiet --with pyyaml python "$STRICT" "$MUT/$file" 2>&1)"; rc=$?
    if [ "$rc" = "$want_rc" ]; then
        pass "C3-schema-$name ($file) → rc=$rc as the boolean contract requires"
    else
        fail "C3-schema-$name ($file) — want rc=$want_rc, got rc=$rc: $(printf '%s' "$out" | tr '\n' ' ')"
    fi
done <<'TABLE'
# --- a quoted "true" is a STRING, so the validator must reject the template ---
quoted-with-value | req-quoted-with-value.yml | 1
quoted-clean      | req-quoted-clean.yml      | 1
# --- the boolean spelling is accepted: the check is not "always reject" ---
bool-with-value   | req-bool-with-value.yml   | 0
TABLE

if [ "$UV_OK" = "1" ]; then
    real_rc=0
    run_with_timeout 60 uv run --quiet --with pyyaml python "$STRICT" "$TASK_YML" >/dev/null 2>&1 || real_rc=$?
    assert_eq "C3-schema-real the shipped task.yml satisfies the boolean contract" "0" "$real_rc"
else
    skip "C3-schema-real — $SKIP_REASON"
fi

# C3-detector — a DETECTOR may OVER-approximate: the schema sibling's scanner
# treats `"true"` as required and REPORTS the prefill. Over-reporting an already
# invalid template costs one look; under-reporting ships the #2098 defect. This
# leniency is intentional and pinned here, not a disagreement with C3-schema.
while IFS='|' read -r name file want; do
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name//[[:space:]]/}"; file="${file//[[:space:]]/}"; want="${want//[[:space:]]/}"
    if [ "$SCAN_OK" != "1" ]; then skip "C3-detector-$name — scanner not lifted (see L0-schema)"; continue; fi
    assert_eq "C3-detector-$name over-approximating on quoted required is intentional" \
        "$want" "$(live_count "$MUT/$file")"
done <<'TABLE'
quoted-with-value | req-quoted-with-value.yml | 1
bool-with-value   | req-bool-with-value.yml   | 1
# --- no prefill at all ⇒ nothing to report, whatever `required` says ---
quoted-clean      | req-quoted-clean.yml      | 0
TABLE

# C3-loud — the no-prefill sibling UNDER-approximates (K11: `"true"` ⇒ required=0).
# That is safe only because the field then reads as NOT REQUIRED, which its own
# T2 assertion fails on, loudly. Pinned here: the under-approximation may never
# be silent. scan_template emits <id>|<has_value>|<has_placeholder>|<has_required>|…
tpl_field() {  # tpl_field <file> <1-based column>
    live_template_scan "$1" | awk -F'|' -v c="$2" '$1 == "background" { print $c; exit }'
}
if [ "$TPL_OK" != "1" ]; then
    skip "C3-loud-required — scan_template not lifted (see L0-noprefill)"
    skip "C3-loud-value — scan_template not lifted (see L0-noprefill)"
    skip "C3-loud-verdict — scan_template not lifted (see L0-noprefill)"
    skip "C3-loud-bool-control — scan_template not lifted (see L0-noprefill)"
else
    assert_eq "C3-loud-required quoted \"true\" does not register as required (K11's rule)" \
        "0" "$(tpl_field "$MUT/req-quoted-with-value.yml" 4)"
    assert_eq "C3-loud-value the prefill itself is still seen, so nothing is hidden" \
        "1" "$(tpl_field "$MUT/req-quoted-with-value.yml" 2)"
    # The composite verdict a registered field would get: T2 fails on has_required=0.
    hr="$(tpl_field "$MUT/req-quoted-with-value.yml" 4)"
    verdict="pass"; [ "$hr" = "1" ] || verdict="fail-required-missing"
    assert_eq "C3-loud-verdict the under-approximation surfaces as a loud T2 failure, never a silent pass" \
        "fail-required-missing" "$verdict"
    assert_eq "C3-loud-bool-control the boolean spelling does register as required" \
        "1" "$(tpl_field "$MUT/req-bool-with-value.yml" 4)"
fi

# ---------------------------------------------------------------------------
# C7 (Sanctioned input) — the live scanner flattens the document into one string,
# so anything that merely LOOKS like a key is a false-positive candidate. YAML
# comments and quoted description text are where an author naturally writes
# `required: true` / `value:` as PROSE; neither is a key, neither may fire.
# Fix that closes the RED rows: strip `#` comments (outside quotes) before
# flattening, and do not match a key that sits inside a quoted scalar.
# ---------------------------------------------------------------------------
cat >"$MUT/neg-comment-value.yml" <<'EOF'
name: Task
description: d
body:
  - type: textarea
    id: background
    attributes:
      label: Background
      # value: "Background: ..." was removed here on purpose (#2098) — do not re-add
      placeholder: "Background of the task"
    validations:
      required: true
EOF

cat >"$MUT/neg-comment-required.yml" <<'EOF'
name: Task
description: d
body:
  - type: textarea
    id: notes
    attributes:
      label: Notes
      placeholder: "Anything else"
      value: "seeded, and harmless on an optional field"
    validations:
      # required: true  — deliberately NOT set; a prefill is fine when optional
      required: false
EOF

cat >"$MUT/neg-description.yml" <<'EOF'
name: Task
description: "Keep required: true on both fields and never add a value: prefill"
body:
  - type: textarea
    id: background
    attributes:
      label: Background
      description: "This field is required: true, and carries no value: prefill"
      placeholder: "Background of the task"
    validations:
      required: true
EOF

printf '%s\n' "{name: Task, description: 'write a title: one short line', body: [{type: textarea, id: background, attributes: {label: Background, placeholder: p}, validations: {required: true}}]}" >"$MUT/neg-title-prose.yml"

neg_findings() {  # neg_findings <file> — ALL finding lines, title ones included
    live_scan "$1" | grep -c '|' || true
}

while IFS='|' read -r name file; do
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name//[[:space:]]/}"; file="${file//[[:space:]]/}"
    if [ "$SCAN_OK" != "1" ]; then skip "C7-$name — scanner not lifted (see L0-schema)"; continue; fi
    got="$(neg_findings "$MUT/$file")"
    if [ "$got" = "0" ]; then
        pass "C7-$name key-like PROSE in $file raises no finding"
    else
        fail "C7-$name — $file is clean, yet the scanner reported $got finding(s): $(live_scan "$MUT/$file" | tr '\n' ' ')"
    fi
done <<'TABLE'
# --- RED: `#` comment text is flattened in as if it were a key ---
comment-value    | neg-comment-value.yml
comment-required | neg-comment-required.yml
# --- RED: key-like text inside a QUOTED description scalar ---
description      | neg-description.yml
# --- control: title-like prose in a flow scalar (already handled) ---
title-prose      | neg-title-prose.yml
TABLE

# The negative controls only mean something while the same scanner still FIRES
# on the real thing — otherwise "0 findings" would prove nothing at all.
if [ "$SCAN_OK" = "1" ]; then
    assert_eq "C7-liveness the same scanner still reports a genuine prefill" \
        "1" "$(live_count "$MUT/live-canonical.yml")"
    findings="$(live_scan "$TASK_YML")"
    if [ -z "$findings" ]; then
        pass "C7-real the shipped task.yml raises no finding under the lifted scanner"
    else
        fail "C7-real — task.yml: $(printf '%s' "$findings" | tr '\n' ' ')"
    fi
else
    skip "C7-liveness — scanner not lifted (see L0-schema)"
    skip "C7-real — scanner not lifted (see L0-schema)"
fi

# I (Idempotency + read-only): scanning twice must agree, and no probe above may
# write under .github/.
if [ "$SCAN_OK" = "1" ]; then
    assert_eq "I1-deterministic re-scanning the same file yields the same findings" \
        "$(live_scan "$MUT/live-canonical.yml")" "$(live_scan "$MUT/live-canonical.yml")"
else
    skip "I1-deterministic — scanner not lifted (see L0-schema)"
fi
assert_eq "I2-untouched-task task.yml is byte-identical after the probes" \
    "$TASK_CK_BEFORE" "$(cksum <"$TASK_YML" 2>/dev/null)"

echo ""
if [ "$UV_OK" = "1" ]; then
    echo "Schema path (uv run --with pyyaml): RAN"
else
    echo "Schema path (uv run --with pyyaml): SKIPPED — $SKIP_REASON"
fi
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
