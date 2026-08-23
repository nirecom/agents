#!/bin/bash
# tests/fix-2098-issue-template-no-prefill.sh
# Tests: .github/ISSUE_TEMPLATE/incident.yml, .github/ISSUE_TEMPLATE/task.yml
# Tags: github, issues, templates, tests, scope:common, layer:TL1
#
# A `value:` prefill on a `required: true` textarea satisfies GitHub's
# non-empty check by itself, so the field can be submitted untouched (#2098).
# Structural awk walk, not a YAML validator: the default interpreter has no
# PyYAML and `uv run --with pyyaml` needs a first-run network resolve, which
# an always-run TL1 test must not depend on. K1-K13 below feed the scanner
# synthetic fragments, catching its false negatives and false positives alike.

set -u

PASS=0
FAIL=0

# TL3 gap (what this test does NOT catch):
# - GitHub's hosted form actually rendering an empty title/body once the
#   `title:`/`value:` prefills are gone.
# - GitHub actually rejecting an untouched required field on submit.
# Closest-to-action mitigation: bin/check-verification-gate.sh has no risk
# category for .github/ISSUE_TEMPLATE/*.yml (its categories are pwsh-required,
# hook-registration, skill-orchestration, installer, merge-base-suspect), so no
# auto-prompt fires for this file set; the gap is closed only by the manual
# post-merge render check on github.com recorded in the plan's S10 step.

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE_DIR="$AGENTS_DIR/.github/ISSUE_TEMPLATE"

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

TMPDIRS=()
cleanup() {
    for d in "${TMPDIRS[@]:-}"; do [ -n "${d:-}" ] && rm -rf "$d"; done
}
trap cleanup EXIT

# Emits one line per `body:` item that carries an id:
#   <id>|<has_value>|<has_placeholder>|<has_required>|<type>|<placeholder_nonempty>|<label>
# Absolute indentation is ignored and a space before the colon (`value :`) is
# tolerated: YAML treats those as the same key, and a scanner pinned to one
# literal spelling reports "no prefill" on a prefill GitHub still honours.
# RELATIVE depth is enforced: `value:`/`placeholder:`/`label:` count only under
# attributes: and `required:` only under validations:, each at that section's
# own key depth (secind/keyind), so keys outside the section or nested one
# level deeper — which GitHub Issue Forms ignores — are ignored here too, as
# are block-scalar bodies (`| ...`). K1-K13 pin all of it.
scan_template() {
    awk '
        function flush() {
            if (started && id != "") print id "|" hv "|" hp "|" hr "|" ty "|" hpne "|" lbl
        }
        { match($0, /^[ \t]*/); ind = RLENGTH }
        inblk {
            if ($0 ~ /^[ \t]*$/) next
            if (ind > blkind) { if (blkkind == "placeholder") hpne = 1; next }
            inblk = 0
        }
        sec != "" && $0 !~ /^[ \t]*$/ {
            if (ind <= secind) { sec = ""; keyind = -1 }
            else if (keyind < 0) { keyind = ind }
        }
        /^[ \t]*-[ \t]*type[ \t]*:/ {
            flush(); started = 1; id = ""; hv = 0; hp = 0; hr = 0; hpne = 0; lbl = ""; sec = "";
            ty = $0; sub(/^[ \t]*-[ \t]*type[ \t]*:[ \t]*/, "", ty); sub(/[ \t]+$/, "", ty); next
        }
        /^[ \t]+id[ \t]*:/ {
            id = $0; sub(/^[ \t]+id[ \t]*:[ \t]*/, "", id); sub(/[ \t]+$/, "", id); next
        }
        /^[ \t]+attributes[ \t]*:[ \t]*$/ { sec = "attributes"; secind = ind; keyind = -1; next }
        /^[ \t]+validations[ \t]*:[ \t]*$/ { sec = "validations"; secind = ind; keyind = -1; next }
        sec == "attributes" && ind == keyind && /^[ \t]+label[ \t]*:/ {
            lbl = $0; sub(/^[ \t]+label[ \t]*:[ \t]*/, "", lbl); sub(/[ \t]+$/, "", lbl);
            gsub(/^["'"'"']|["'"'"']$/, "", lbl); next
        }
        sec == "attributes" && ind == keyind && /^[ \t]+value[ \t]*:/ {
            hv = 1; v = $0; sub(/^[ \t]+value[ \t]*:[ \t]*/, "", v);
            if (v ~ /^[|>]/) { inblk = 1; blkind = ind; blkkind = "value" } next
        }
        sec == "attributes" && ind == keyind && /^[ \t]+placeholder[ \t]*:/ {
            hp = 1; v = $0; sub(/^[ \t]+placeholder[ \t]*:[ \t]*/, "", v); sub(/[ \t]+$/, "", v);
            if (v ~ /^[|>]/) { inblk = 1; blkind = ind; blkkind = "placeholder" }
            else { gsub(/^["'"'"']|["'"'"']$/, "", v); if (v != "") hpne = 1 }
            next
        }
        sec == "validations" && ind == keyind && /^[ \t]+required[ \t]*:[ \t]*true[ \t]*$/ { hr = 1; next }
        END { flush() }
    ' "$1"
}

# Emits the block-scalar body of the FIRST body: item's attributes.value, and
# only when that item is the opening `type: markdown` one. T6/T12 assert against
# this instead of the whole file, so guidance text sitting in an unrelated
# placeholder cannot satisfy them. Same indentation tolerance as scan_template.
first_markdown_value() {
    awk '
        /^[ \t]*-[ \t]*type[ \t]*:/ {
            n++; if (n > 1) exit;
            ismd = ($0 ~ /type[ \t]*:[ \t]*markdown[ \t]*$/); next
        }
        ismd && /^[ \t]+attributes[ \t]*:[ \t]*$/ { inattr = 1; next }
        inattr && /^[ \t]+value[ \t]*:[ \t]*[|>]/ {
            match($0, /^[ \t]*/); blkind = RLENGTH; inval = 1; next
        }
        inval {
            if ($0 ~ /^[ \t]*$/) { print ""; next }
            match($0, /^[ \t]*/); if (RLENGTH <= blkind) exit
            print
        }
    ' "$1"
}

# Expected-value table: only the four fields #2098 owns. The shared invariants
# (no value:, required: true, non-empty placeholder) need no per-field column,
# but `label:` does: bin/github-issues/lib/extract-field.sh greps the literals
# `background|changes|cause|fix`, and the only thing that puts those words into
# a submitted issue body is this `label:` value. Renaming a label silently turns
# every future report into a `(no <Field> recorded)` marker, so the label token
# is pinned per row. task.yml's `subtasks` is deliberately absent (triage: NA).
FIELD_TABLE='incident.yml|cause|Cause
incident.yml|fix|Fix
task.yml|background|Background
task.yml|changes|Changes'

# Top-level `labels:` drives the category branch: issue-to-history.sh greps the
# labels string for `type:incident` and falls back to FEATURE otherwise, so a
# renamed template label reroutes incidents into the FEATURE arm.
TYPE_LABEL_TABLE='incident.yml|type:incident
task.yml|type:task'

# ---------------------------------------------------------------------------
# T1-T4, T8-T10: per registered field
# ---------------------------------------------------------------------------
while IFS='|' read -r tfile tid tlabel; do
    [ -z "$tfile" ] && continue
    path="$TEMPLATE_DIR/$tfile"
    if [ ! -f "$path" ]; then
        fail "T4 $tfile/$tid: template file not found at $path"
        continue
    fi
    row="$(scan_template "$path" | awk -F'|' -v id="$tid" '$1 == id { print; exit }')"
    if [ -z "$row" ]; then
        fail "T4 $tfile/$tid: field id not found in scan output (renamed or removed?)"
        continue
    fi
    pass "T4 $tfile/$tid: field is present in the template"
    has_value="$(printf '%s' "$row" | cut -d'|' -f2)"
    has_placeholder="$(printf '%s' "$row" | cut -d'|' -f3)"
    has_required="$(printf '%s' "$row" | cut -d'|' -f4)"
    item_type="$(printf '%s' "$row" | cut -d'|' -f5)"
    placeholder_nonempty="$(printf '%s' "$row" | cut -d'|' -f6)"
    field_label="$(printf '%s' "$row" | cut -d'|' -f7)"

    if [ "$has_value" = "0" ]; then
        pass "T1 $tfile/$tid: no value: prefill"
    else
        fail "T1 $tfile/$tid: value: prefill present — required: true is defeated (#2098)"
    fi

    if [ "$has_required" = "1" ]; then
        pass "T2 $tfile/$tid: required: true retained"
    else
        fail "T2 $tfile/$tid: required: true missing — prefill must be removed, not the requirement"
    fi

    if [ "$has_placeholder" = "1" ]; then
        pass "T3 $tfile/$tid: placeholder: retained"
    else
        fail "T3 $tfile/$tid: placeholder: missing — input guidance lost"
    fi

    # T8: the field must still be a free-text textarea. Swapping it for an
    # `input` or a `dropdown` would also make the prefill disappear from the
    # scan, so T1 alone would pass on a field that no longer accepts prose.
    if [ "$item_type" = "textarea" ]; then
        pass "T8 $tfile/$tid: still a textarea"
    else
        fail "T8 $tfile/$tid: expected type textarea, got '$item_type'"
    fi

    # T9: presence alone is not guidance — an empty `placeholder: |` block
    # renders as a blank hint, which is what removing the prefill was supposed
    # to avoid regressing into.
    if [ "$placeholder_nonempty" = "1" ]; then
        pass "T9 $tfile/$tid: placeholder: carries non-empty guidance text"
    else
        fail "T9 $tfile/$tid: placeholder: is present but empty — guidance lost"
    fi

    # T10: template-to-parser contract (see FIELD_TABLE comment).
    if [ "$field_label" = "$tlabel" ]; then
        pass "T10 $tfile/$tid: label: is exactly '$tlabel' (extract_field's grep token)"
    else
        fail "T10 $tfile/$tid: expected label: '$tlabel', got '$field_label' — extract_field would stop matching"
    fi
done <<TABLE
$FIELD_TABLE
TABLE

# ---------------------------------------------------------------------------
# T5/T6/T12: per registered template file
# ---------------------------------------------------------------------------
for tfile in incident.yml task.yml; do
    path="$TEMPLATE_DIR/$tfile"
    if [ ! -f "$path" ]; then
        fail "T5/T6 $tfile: template file not found at $path"
        continue
    fi
    if grep -qE '^title[ \t]*:' "$path"; then
        fail "T5 $tfile: top-level title: prefill present — it is submitted verbatim (#2094)"
    else
        pass "T5 $tfile: no top-level title: prefill"
    fi
    md_value="$(first_markdown_value "$path")"
    if printf '%s\n' "$md_value" | grep -qF '**Title**:'; then
        pass "T6 $tfile: title-writing guidance kept in the opening markdown value:"
    else
        fail "T6 $tfile: '**Title**:' missing from the opening markdown item's value: block"
    fi
    # T12: the token alone is not guidance. Threshold rationale: the guidance
    # the plan (S4/S5) moves here reads "**Title**: one short line naming the
    # symptom — e.g. ..." — 8+ words follow the token on that line. Four is the
    # floor below which the remainder cannot be an instruction (bare token plus
    # a fragment), so it fails only on a genuinely gutted block.
    title_line="$(printf '%s\n' "$md_value" | grep -F '**Title**:' | head -1)"
    title_rest="${title_line#*\*\*Title\*\*:}"
    title_words="$(printf '%s\n' "$title_rest" | wc -w | tr -d '[:space:]')"
    if [ "${title_words:-0}" -ge 4 ]; then
        pass "T12 $tfile: '**Title**:' is followed by an actual instruction ($title_words words)"
    else
        fail "T12 $tfile: '**Title**:' carries only ${title_words:-0} words of instruction"
    fi
done

# ---------------------------------------------------------------------------
# T11: top-level type label per template file
# ---------------------------------------------------------------------------
while IFS='|' read -r tfile want_label; do
    [ -z "$tfile" ] && continue
    path="$TEMPLATE_DIR/$tfile"
    if [ ! -f "$path" ]; then
        fail "T11 $tfile: template file not found at $path"
        continue
    fi
    if grep -qE "^labels[ \t]*:.*\"$want_label\"" "$path"; then
        pass "T11 $tfile: top-level labels: carries '$want_label' (category branch input)"
    else
        fail "T11 $tfile: '$want_label' missing from top-level labels: — category branch would misroute"
    fi
done <<TABLE
$TYPE_LABEL_TABLE
TABLE

# ---------------------------------------------------------------------------
# T7: whole-scan invariant — for EVERY item (registered or not), required: true
# and a value: prefill must never coexist. Registration is not required; only
# the #2098 defect combination fails.
# ---------------------------------------------------------------------------
t7_violations=""
for tfile in incident.yml task.yml; do
    path="$TEMPLATE_DIR/$tfile"
    [ -f "$path" ] || continue
    while IFS='|' read -r sid shv shp shr sty; do
        : "$sty"
        [ -z "$sid" ] && continue
        if [ "$shr" = "1" ] && [ "$shv" = "1" ]; then
            t7_violations="$t7_violations $tfile/$sid"
        fi
    done < <(scan_template "$path")
done
if [ -z "$t7_violations" ]; then
    pass "T7: no item combines required: true with a value: prefill"
else
    fail "T7: required+value prefill found on:$t7_violations"
fi

# ---------------------------------------------------------------------------
# K1-K6: scanner kill verification (Mutation Probe spirit, parser-regex-tests.md)
# The guard above is only as good as scan_template. Feed it synthetic fragments
# whose answer is known and assert both detection and non-detection, so a
# scanner that silently stops seeing prefills cannot make T1/T7 pass by default.
# ---------------------------------------------------------------------------
KILL_TMP="$(mktemp -d)"
TMPDIRS+=("$KILL_TMP")

cat > "$KILL_TMP/canonical.yml" <<'EOF'
body:
  - type: textarea
    id: probe
    attributes:
      label: Probe
      placeholder: |
        Probe: ...
      value: "Probe: "
    validations:
      required: true
EOF

# Space before the colon — same YAML key, and the shape the old literal-spelling
# scanner missed entirely.
cat > "$KILL_TMP/spaced.yml" <<'EOF'
body:
  - type: textarea
    id: probe
    attributes:
      label : Probe
      placeholder : |
        Probe: ...
      value : "Probe: "
    validations:
      required : true
EOF

# Deeper (but still valid) indentation.
cat > "$KILL_TMP/deep.yml" <<'EOF'
body:
    - type: textarea
      id: probe
      attributes:
        label: Probe
        placeholder: |
          Probe: ...
        value: "Probe: "
      validations:
        required: true
EOF

# The post-#2098 shape: placeholder only, no value:.
cat > "$KILL_TMP/fixed.yml" <<'EOF'
body:
  - type: textarea
    id: probe
    attributes:
      label: Probe
      placeholder: |
        Probe: ...
    validations:
      required: true
EOF

# Placeholder key present but its block scalar is empty (T9's target shape).
cat > "$KILL_TMP/emptyph.yml" <<'EOF'
body:
  - type: textarea
    id: probe
    attributes:
      label: Probe
      placeholder: |
    validations:
      required: true
EOF

# Non-detection: `value:` appears as prose INSIDE a block scalar, not as a key.
cat > "$KILL_TMP/decoy.yml" <<'EOF'
body:
  - type: textarea
    id: probe
    attributes:
      label: Probe
      placeholder: |
        value: "Probe: "
    validations:
      required: true
EOF

# K7: keys at the ITEM level, outside attributes:/validations:. GitHub Issue
# Forms ignores them, so the scanner must too — otherwise T1/T7 would report a
# prefill that no rendered form carries (false positive).
cat > "$KILL_TMP/misplaced.yml" <<'EOF'
body:
  - type: textarea
    id: probe
    attributes:
      label: Probe
      placeholder: Probe text
    value: "Probe: "
    validations:
      required: true
EOF

# K8: keys nested ONE LEVEL DEEPER than the section's key depth (under an
# unrelated sub-map). Also ignored by GitHub, so neither value: nor required:
# may register.
cat > "$KILL_TMP/nested.yml" <<'EOF'
body:
  - type: textarea
    id: probe
    attributes:
      label: Probe
      placeholder: Probe text
      extra:
        value: "Probe: "
    validations:
      extra:
        required: true
EOF

# K9/K10: duplicate keys within one item. YAML's own last-wins rule is NOT
# assumed — the guard is fail-closed: any value: at all counts as a prefill,
# and any required: true at all counts as required, so a duplicate cannot
# smuggle the #2098 combination past T7.
cat > "$KILL_TMP/dupvalue.yml" <<'EOF'
body:
  - type: textarea
    id: probe
    attributes:
      label: Probe
      placeholder: Probe text
      value: ""
      value: "Probe: "
    validations:
      required: true
EOF

cat > "$KILL_TMP/duprequired.yml" <<'EOF'
body:
  - type: textarea
    id: probe
    attributes:
      label: Probe
      placeholder: Probe text
    validations:
      required: false
      required: true
EOF

# K11-K13: only the bare YAML boolean `true` counts as required. `"true"` is a
# string, and `True`/`yes` are YAML 1.1 spellings GitHub's schema does not
# accept — a form written that way is not actually required. Reading them as
# required would make T2 green on a template GitHub rejects, so the guard
# refuses them and T2 fails loudly instead.
bool_yml() {
    cat > "$KILL_TMP/$1" <<EOF
body:
  - type: textarea
    id: probe
    attributes:
      label: Probe
      placeholder: Probe text
    validations:
      required: $2
EOF
}
bool_yml quoted.yml '"true"'
bool_yml titlecase.yml 'True'
bool_yml yesform.yml 'yes'

while IFS='|' read -r kname kfile khv khp khr khpne; do
    kname="${kname// /}"
    [ -z "$kname" ] && continue
    case "$kname" in \#*) continue ;; esac
    kfile="${kfile// /}"; khv="${khv// /}"; khp="${khp// /}"
    khr="${khr// /}"; khpne="${khpne// /}"
    krow="$(scan_template "$KILL_TMP/$kfile" | awk -F'|' '$1 == "probe" { print; exit }')"
    kgot="$(printf '%s' "$krow" | cut -d'|' -f2),$(printf '%s' "$krow" | cut -d'|' -f3),$(printf '%s' "$krow" | cut -d'|' -f4),$(printf '%s' "$krow" | cut -d'|' -f6)"
    kwant="$khv,$khp,$khr,$khpne"
    if [ "$kgot" = "$kwant" ]; then
        pass "$kname ($kfile): scanner reports value/placeholder/required/ph-nonempty = $kwant"
    else
        fail "$kname ($kfile): want $kwant, got $kgot (row='$krow')"
    fi
done <<'TABLE'
K1 | canonical.yml | 1 | 1 | 1 | 1
K2 | spaced.yml    | 1 | 1 | 1 | 1
K3 | deep.yml      | 1 | 1 | 1 | 1
K4 | fixed.yml     | 0 | 1 | 1 | 1
K5 | emptyph.yml   | 0 | 1 | 1 | 0
K6 | decoy.yml     | 0 | 1 | 1 | 1
K7 | misplaced.yml   | 0 | 1 | 1 | 1
K8 | nested.yml      | 0 | 1 | 0 | 1
K9 | dupvalue.yml    | 1 | 1 | 1 | 1
K10 | duprequired.yml | 0 | 1 | 1 | 1
K11 | quoted.yml      | 0 | 1 | 0 | 1
K12 | titlecase.yml   | 0 | 1 | 0 | 1
K13 | yesform.yml     | 0 | 1 | 0 | 1
TABLE

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
