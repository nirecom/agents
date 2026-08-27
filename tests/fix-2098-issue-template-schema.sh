#!/bin/bash
# tests/fix-2098-issue-template-schema.sh
# Tests: .github/ISSUE_TEMPLATE/task.yml, .github/ISSUE_TEMPLATE/incident.yml
# Tags: github, issues, templates, issue-forms, yaml-schema, scope:issue-specific, layer:TL1
#
# Real YAML parse + GitHub Issue Forms schema validation, the counterpart to
# tests/fix-2098-issue-template-no-prefill.sh's awk-only scan: a `title:` or a
# required-textarea `value:` in any YAML-equivalent form (quoted key, flow
# mapping) is still a prefill GitHub honours, and only a parser sees it.
# Needs `uv run --with pyyaml`; unrunnable -> every case SKIPped, never silently passed.

set -u

PASS=0
FAIL=0
SKIP=0

# TL3 gap (not caught here): GitHub's hosted form actually rendering an empty
# title/body and rejecting an untouched required field on submit, and Issue
# Forms schema rules GitHub enforces that PyYAML cannot know. No preflight-ask
# category covers .github/ISSUE_TEMPLATE/*.yml; the gap closes only at the
# manual post-merge render check on github.com.

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE_DIR="$AGENTS_DIR/.github/ISSUE_TEMPLATE"
TASK_YML="$TEMPLATE_DIR/task.yml"
INCIDENT_YML="$TEMPLATE_DIR/incident.yml"

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

VALIDATOR="$TMP/issue_forms_schema.py"
cat >"$VALIDATOR" <<'PY_EOF'
"""GitHub Issue Forms schema check + mutant generator (test-only)."""
import sys
import yaml

FORM_TYPES = {"markdown", "textarea", "input", "dropdown", "checkboxes"}

def load(path):
    with open(path, encoding="utf-8") as fh:
        return yaml.safe_load(fh)

def is_required(item):
    v = item.get("validations")
    return isinstance(v, dict) and v.get("required") is True

def required_textareas(doc):
    out = []
    for item in (doc.get("body") or []):
        if isinstance(item, dict) and item.get("type") == "textarea" and is_required(item):
            out.append(item)
    return out

def check(doc):
    errs = []
    if not isinstance(doc, dict):
        return ["top level is not a mapping"]
    if "title" in doc.keys():
        errs.append("top-level `title` key present: it prefills the issue title")
    for key in ("name", "description"):
        val = doc.get(key)
        if not isinstance(val, str) or not val.strip():
            errs.append("`%s` must be a non-empty string, got %r" % (key, val))
    body = doc.get("body")
    if not isinstance(body, list) or not body:
        errs.append("`body` must be a non-empty list, got %r" % (body,))
        return errs
    for i, item in enumerate(body):
        at = "body[%d]" % i
        if not isinstance(item, dict):
            errs.append("%s: entry is not a mapping" % at)
            continue
        typ = item.get("type")
        if not isinstance(typ, str) or typ not in FORM_TYPES:
            errs.append("%s: type %r not in %s" % (at, typ, sorted(FORM_TYPES)))
            continue
        attrs = item.get("attributes")
        if not isinstance(attrs, dict):
            errs.append("%s: attributes must be a mapping, got %r" % (at, attrs))
            continue
        if typ == "markdown":
            continue
        iid = item.get("id")
        if not isinstance(iid, str) or not iid.strip():
            errs.append("%s: id must be a non-empty string, got %r" % (at, iid))
        label = attrs.get("label")
        if not isinstance(label, str) or not label.strip():
            errs.append("%s: attributes.label must be non-empty, got %r" % (at, label))
        if typ == "textarea" and is_required(item):
            if "value" in attrs.keys():
                errs.append("%s (%s): required textarea carries a `value:` prefill" % (at, iid))
            ph = attrs.get("placeholder")
            if not isinstance(ph, str) or not ph.strip():
                errs.append("%s (%s): required textarea placeholder must be "
                            "a non-empty string, got %r" % (at, iid, ph))
    return errs

def mutate(kind, doc):
    flow = False
    if kind == "title-flow":
        doc["title"] = "mutant title"
        flow = True
    elif kind == "flow-control":
        flow = True
    elif kind == "value-back":
        required_textareas(doc)[0]["attributes"]["value"] = "Background: ..."
    elif kind == "empty-placeholder":
        required_textareas(doc)[0]["attributes"]["placeholder"] = "   "
    else:
        raise SystemExit("unknown mutation kind: %s" % kind)
    return yaml.safe_dump(doc, default_flow_style=flow, sort_keys=False,
                          allow_unicode=True)

def main(argv):
    mode = argv[1]
    if mode == "--mutate":
        kind, src, dst = argv[2], argv[3], argv[4]
        text = mutate(kind, load(src))
        with open(dst, "w", encoding="utf-8") as fh:
            fh.write(text)
        return 0
    path = argv[2]
    try:
        doc = load(path)
    except yaml.YAMLError as exc:
        print("PARSE-ERROR: %s" % str(exc).replace("\n", " "))
        return 2
    if mode == "--check":
        errs = check(doc)
        for e in errs:
            print("ERR: %s" % e)
        if errs:
            return 1
        print("OK")
        return 0
    if mode == "--dump-required":
        for item in required_textareas(doc):
            attrs = item.get("attributes") or {}
            ph = attrs.get("placeholder")
            ph_ok = 1 if isinstance(ph, str) and ph.strip() else 0
            print("%s|%d|%d" % (item.get("id"),
                                1 if "value" in attrs.keys() else 0, ph_ok))
        return 0
    raise SystemExit("unknown mode: %s" % mode)

if __name__ == "__main__":
    sys.exit(main(sys.argv))
PY_EOF

validate() { run_with_timeout 60 uv run --quiet --with pyyaml python "$VALIDATOR" "$@"; }

# --- Parser availability (resolved once; every case below shares the verdict) ---
UV_OK=0
if command -v uv >/dev/null 2>&1 \
    && run_with_timeout 120 uv run --quiet --with pyyaml python -c 'import yaml' >/dev/null 2>&1; then
    UV_OK=1
    SKIP_REASON=""
else
    SKIP_REASON="uv run --with pyyaml unavailable (no uv on PATH, or the pyyaml resolve failed offline)"
fi

for f in "$TASK_YML" "$INCIDENT_YML"; do
    [ -f "$f" ] || { fail "precondition missing — $f"; }
done

TASK_CK_BEFORE="$(cksum <"$TASK_YML")"
INCIDENT_CK_BEFORE="$(cksum <"$INCIDENT_YML")"

# ---------------------------------------------------------------------------
# Y1 — both real templates parse and satisfy the Issue Forms shape rules.
while IFS='|' read -r name file; do
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name//[[:space:]]/}"; file="${file//[[:space:]]/}"
    if [ "$UV_OK" != "1" ]; then skip "Y1-$name — $SKIP_REASON"; continue; fi
    out="$(validate --check "$TEMPLATE_DIR/$file" 2>&1)"; rc=$?
    if [ "$rc" -eq 0 ]; then
        pass "Y1-$name $file parses and satisfies the Issue Forms schema"
    else
        fail "Y1-$name $file — rc=$rc, validator said: $out"
    fi
done <<'TABLE'
task     | task.yml
incident | incident.yml
TABLE

# ---------------------------------------------------------------------------
# Y2 — every required textarea, DERIVED from the parsed file (not hardcoded),
# carries no `value:` and a non-empty placeholder. The id set is pinned too, so
# a template that lost `required: true` yields zero rows and fails here.
while IFS='|' read -r name file want_ids; do
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name//[[:space:]]/}"; file="${file//[[:space:]]/}"
    want_ids="${want_ids//[[:space:]]/}"
    if [ "$UV_OK" != "1" ]; then skip "Y2-$name — $SKIP_REASON"; continue; fi

    # tr -d '\015': python's print() emits CRLF on Windows; a trailing CR
    # would otherwise ride along into the last field of every row.
    rows="$(validate --dump-required "$TEMPLATE_DIR/$file" 2>&1 | tr -d '\015')"
    got_ids="$(printf '%s\n' "$rows" | cut -d'|' -f1 | paste -sd, -)"
    assert_eq "Y2-$name-required-ids" "$want_ids" "$got_ids"

    while IFS='|' read -r rid rvalue rph; do
        [ -z "$rid" ] && continue
        assert_eq "Y2-$name-$rid-no-value-prefill" "0" "$rvalue"
        assert_eq "Y2-$name-$rid-placeholder-nonempty" "1" "$rph"
    done <<<"$rows"
done <<'TABLE'
task     | task.yml     | background,changes
incident | incident.yml | cause,fix
TABLE

# ---------------------------------------------------------------------------
# Y3 (Mutation probe) — the schema check must FAIL on each planted prefill, in
# every YAML-equivalent spelling. `flow-control` is the counter-probe: the same
# round-trip WITHOUT a planted key must still PASS.
MUT_DIR="$TMP/mutants"
mkdir -p "$MUT_DIR"

# Text-level mutants: spellings a YAML re-dump would normalise away.
if [ "$UV_OK" = "1" ]; then
    cp "$TASK_YML" "$MUT_DIR/title-plain.yml"
    printf 'title: mutant title\n' >>"$MUT_DIR/title-plain.yml"
    cp "$TASK_YML" "$MUT_DIR/title-quoted.yml"
    printf '"title": mutant title\n' >>"$MUT_DIR/title-quoted.yml"
    for kind in title-flow flow-control value-back empty-placeholder; do
        validate --mutate "$kind" "$TASK_YML" "$MUT_DIR/$kind.yml" >/dev/null 2>&1 \
            || fail "Y3-setup could not generate the $kind mutant"
    done
fi

while IFS='|' read -r name mutant want_rc; do
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name//[[:space:]]/}"; mutant="${mutant//[[:space:]]/}"
    want_rc="${want_rc//[[:space:]]/}"
    if [ "$UV_OK" != "1" ]; then skip "Y3-$name — $SKIP_REASON"; continue; fi
    out="$(validate --check "$MUT_DIR/$mutant" 2>&1)"; rc=$?
    if [ "$rc" = "$want_rc" ]; then
        pass "Y3-$name ($mutant) → rc=$rc as required"
    else
        fail "Y3-$name ($mutant) — want rc=$want_rc, got rc=$rc; validator said: $out"
    fi
done <<'TABLE'
title-plain       | title-plain.yml       | 1
title-quoted      | title-quoted.yml      | 1
title-flow        | title-flow.yml        | 1
value-back        | value-back.yml        | 1
empty-placeholder | empty-placeholder.yml | 1
flow-control      | flow-control.yml      | 0
TABLE

# The real templates must be byte-identical to what this run started with:
# every mutant lives under $TMP, nothing is written back to .github/.
assert_eq "Y3-untouched-task task.yml is byte-identical after the probes"     "$TASK_CK_BEFORE" "$(cksum <"$TASK_YML")"
assert_eq "Y3-untouched-incident incident.yml is byte-identical after the probes"     "$INCIDENT_CK_BEFORE" "$(cksum <"$INCIDENT_YML")"

# ---------------------------------------------------------------------------
# Y4 — malformed YAML must be reported as a parse error (rc=2), never accepted.
# A validator that swallowed the error would report every mutant above as OK.
BAD_DIR="$TMP/bad"
mkdir -p "$BAD_DIR"
printf 'name: "unclosed\ndescription: x\nbody: []\n' >"$BAD_DIR/unclosed-quote.yml"
printf 'name: x\nbody:\n  - type: markdown\n   attributes:\n      value: hi\n' \
    >"$BAD_DIR/bad-indent.yml"
printf 'name: x\nbody:\n\t- type: markdown\n' >"$BAD_DIR/tab-indent.yml"

while IFS='|' read -r name file; do
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name//[[:space:]]/}"; file="${file//[[:space:]]/}"
    if [ "$UV_OK" != "1" ]; then skip "Y4-$name — $SKIP_REASON"; continue; fi
    out="$(validate --check "$BAD_DIR/$file" 2>&1)"; rc=$?
    if [ "$rc" -eq 2 ] && printf '%s\n' "$out" | grep -q '^PARSE-ERROR:'; then
        pass "Y4-$name malformed YAML is reported as a parse error"
    else
        fail "Y4-$name — want rc=2 + PARSE-ERROR, got rc=$rc: $out"
    fi
done <<'TABLE'
unclosed-quote | unclosed-quote.yml
bad-indent     | bad-indent.yml
tab-indent     | tab-indent.yml
TABLE

# ---------------------------------------------------------------------------
# Parser-INDEPENDENT fallback group (Y5/Y6). Y1-Y4 all SKIP when uv or PyYAML
# is unavailable, which would let an offline machine report "0 failed" with
# zero real coverage. Everything below runs unconditionally on plain
# awk/sed/grep, re-asserting: no `title:` prefill, no `value:` on required.
FB=0
fb_pass() { fb_note; pass "$1"; }
fb_fail() { fb_note; fail "$1"; }
fb_note() { FB=$((FB + 1)); }

# Blanks block-scalar BODIES (keeping the key line and the line count) so the
# `**Title**:` inside the templates' own markdown guidance is not mistaken for a
# `title:` key. Every detector below reads this, never the raw file.
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

# Prints one finding per line; empty output == clean. Tolerated key spellings:
# bare, "double"-quoted, 'single'-quoted, a space before the colon, and flow
# mappings (`{a: 1, title: x}`) — a stand-in for the parser must tolerate all.
TITLE_ERE='^[ \t]*("title"|'"'"'title'"'"'|title)[ \t]*:'
TITLE_FLOW_ERE='[{,][ \t]*("title"|'"'"'title'"'"'|title)[ \t]*:'

fallback_scan() {
    local clean
    clean="$(strip_block_scalars "$1")"
    printf '%s\n' "$clean" | grep -nE "$TITLE_ERE" | sed 's/^/TITLE-KEY-BLOCK|/'
    printf '%s\n' "$clean" | grep -nE "$TITLE_FLOW_ERE" | sed 's/^/TITLE-KEY-FLOW|/'
    # `value:` on a required textarea. Items are boundary-scanned (brace depth
    # for flow form, leading `-` for block form); key order/position within an
    # item is irrelevant, and a key only counts after a structural delimiter.
    printf '%s\n' "$clean" | awk '
        function ctx_key(name) { return "(^|[\n{,-])[[:blank:]]*[\"\047]?" name "[\"\047]?[[:blank:]]*:" }
        function flush() {
            if (item !~ ctx_key("type") "[[:blank:]]*[\"\047]?textarea") return
            if (item !~ ctx_key("required") "[[:blank:]]*[\"\047]?true") return
            if (item !~ ctx_key("value")) return
            id = "item"
            if (match(item, ctx_key("id") "[[:blank:]]*[A-Za-z0-9_-]+")) {
                id = substr(item, RSTART, RLENGTH)
                sub(/^.*:[[:blank:]]*/, "", id)
            }
            print "VALUE-ON-REQUIRED|" id
        }
        {
            line = $0
            sub(/^[ \t]*#.*$/, "", line)
            stripped = line
            sub(/^[ \t]*/, "", stripped)
            if (depth == 0 && stripped ~ /^-[[:blank:]]/) { flush(); item = "" }
            n = length(line)
            for (i = 1; i <= n; i++) {
                c = substr(line, i, 1)
                if (c == "{" && depth == 0) { flush(); item = "" }
                item = item c
                if (c == "{") depth++
                else if (c == "}" && depth > 0) depth--
            }
            item = item "\n"
        }
        END { flush() }
    '
}

# --- Y5 — the real templates are clean under the fallback scanner ------------
while IFS='|' read -r name file; do
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name//[[:space:]]/}"; file="${file//[[:space:]]/}"
    findings="$(fallback_scan "$TEMPLATE_DIR/$file")"
    if [ -z "$findings" ]; then
        fb_pass "Y5-$name $file carries no title/value prefill (parser-independent scan)"
    else
        fb_fail "Y5-$name $file — fallback scanner found: $(printf '%s' "$findings" | tr '\n' ' ')"
    fi
done <<'TABLE'
task     | task.yml
incident | incident.yml
TABLE

# The scanner must not be blind: the guidance block's `**Title**:` line is
# prose, yet a real key must still register — proof Y5 isn't a scanner that never fires.
if strip_block_scalars "$TASK_YML" | grep -q 'Title'; then
    fb_fail "Y5-strip — the markdown guidance block survived strip_block_scalars; Y5 is not proving anything"
else
    fb_pass "Y5-strip the markdown guidance block is blanked before scanning"
fi

# --- Y6 — mutants generated with text tools, so they exist with or without uv.
# Each spelling must be caught by the fallback path and (when uv is available)
# by the parser path. `control-*` plants no forbidden key and must PASS on both,
# so a red mutant proves detection rather than brittleness.
FB_MUT="$TMP/fb-mutants"
mkdir -p "$FB_MUT"

make_title_mutant() {  # make_title_mutant <dst-name> <literal line>
    cp "$TASK_YML" "$FB_MUT/$1"
    printf '%s\n' "$2" >>"$FB_MUT/$1"
}
make_title_mutant title-plain.yml  'title: mutant title'
make_title_mutant title-dquote.yml '"title": mutant title'
make_title_mutant title-squote.yml "'title': mutant title"
make_title_mutant title-spaced.yml 'title : mutant title'
make_title_mutant control-block.yml '# harmless control comment, plants no key'

make_value_mutant() {  # make_value_mutant <dst-name> <literal attribute line>
    awk -v ins="$2" '
        { print }
        /^[ \t]+label[ \t]*:[ \t]*Background[ \t]*$/ && !done { print ins; done = 1 }
    ' "$TASK_YML" >"$FB_MUT/$1"
}
make_value_mutant value-plain.yml  '      value: "Background: seeded"'
make_value_mutant value-quoted.yml '      "value": "Background: seeded"'
make_value_mutant value-spaced.yml '      value : "Background: seeded"'

cat >"$FB_MUT/title-flow.yml" <<'FLOW_EOF'
{name: Task, description: d, title: mutant title, body: [{type: markdown, attributes: {value: hi}}]}
FLOW_EOF
cat >"$FB_MUT/value-flow.yml" <<'FLOW_EOF'
{name: Task, description: d, body: [{type: textarea, id: background, attributes: {label: Background, placeholder: 'Background: ...', value: 'Background: seeded'}, validations: {required: true}}]}
FLOW_EOF
cat >"$FB_MUT/control-flow.yml" <<'FLOW_EOF'
{name: Task, description: d, body: [{type: textarea, id: background, attributes: {label: Background, placeholder: 'Background: ...'}, validations: {required: true}}]}
FLOW_EOF

# Every mutant must differ from its source: a silently missed insertion would make Y6 vacuous.
for m in value-plain.yml value-quoted.yml value-spaced.yml; do
    if [ "$(cksum <"$FB_MUT/$m")" = "$TASK_CK_BEFORE" ]; then
        fb_fail "Y6-gen $m is byte-identical to task.yml — the insertion did not happen"
    else
        fb_pass "Y6-gen $m differs from task.yml"
    fi
done

# name | mutant file | want fallback findings? (1=yes) | want parser rc
while IFS='|' read -r name mutant want_fb want_rc; do
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name//[[:space:]]/}"; mutant="${mutant//[[:space:]]/}"
    want_fb="${want_fb//[[:space:]]/}"; want_rc="${want_rc//[[:space:]]/}"

    findings="$(fallback_scan "$FB_MUT/$mutant")"
    got_fb=0; [ -n "$findings" ] && got_fb=1
    if [ "$got_fb" = "$want_fb" ]; then
        fb_pass "Y6-fallback-$name ($mutant) → findings=$got_fb as required"
    else
        fb_fail "Y6-fallback-$name ($mutant) — want findings=$want_fb, got $got_fb: $(printf '%s' "$findings" | tr '\n' ' ')"
    fi

    if [ "$UV_OK" != "1" ]; then
        skip "Y6-parser-$name — $SKIP_REASON"
        continue
    fi
    out="$(validate --check "$FB_MUT/$mutant" 2>&1)"; rc=$?
    if [ "$rc" = "$want_rc" ]; then
        pass "Y6-parser-$name ($mutant) → rc=$rc as required"
    else
        fail "Y6-parser-$name ($mutant) — want rc=$want_rc, got rc=$rc; validator said: $out"
    fi
done <<'TABLE'
title-plain   | title-plain.yml   | 1 | 1
title-dquote  | title-dquote.yml  | 1 | 1
title-squote  | title-squote.yml  | 1 | 1
title-spaced  | title-spaced.yml  | 1 | 1
title-flow    | title-flow.yml    | 1 | 1
value-plain   | value-plain.yml   | 1 | 1
value-quoted  | value-quoted.yml  | 1 | 1
value-spaced  | value-spaced.yml  | 1 | 1
value-flow    | value-flow.yml    | 1 | 1
control-block | control-block.yml | 0 | 0
control-flow  | control-flow.yml  | 0 | 0
TABLE

assert_eq "Y6-untouched-task task.yml is byte-identical after the fallback probes" \
    "$TASK_CK_BEFORE" "$(cksum <"$TASK_YML")"
assert_eq "Y6-untouched-incident incident.yml is byte-identical after the fallback probes" \
    "$INCIDENT_CK_BEFORE" "$(cksum <"$INCIDENT_YML")"

# A fallback group with zero assertions is the silent-skip hole this section closes.
if [ "$FB" -gt 0 ]; then
    pass "Y6-fallback-ran the parser-independent group contributed $FB assertions"
else
    fail "Y6-fallback-ran — the parser-independent group made no assertions"
fi

echo ""
if [ "$UV_OK" = "1" ]; then
    echo "Parser path (uv run --with pyyaml): RAN"
else
    echo "Parser path (uv run --with pyyaml): SKIPPED — $SKIP_REASON"
fi
echo "Parser-independent fallback assertions: $FB"
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
