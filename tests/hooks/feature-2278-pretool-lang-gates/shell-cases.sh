#!/bin/bash
# tests/feature-2278-pretool-lang-gates/shell-cases.sh
# Tests: hooks/lib/pretool-lang-gate.js, hooks/lib/write-tools.js, hooks/lib/plan-artifact-lang.js
# Tags: lang, hook, pretooluse, TL2, scope:issue-specific
# Sourced by ../feature-2278-pretool-lang-gates.sh — helpers come from there.
# SHL-T1..T4,T6: hooks/lib/pretool-lang-gate.js; SHL-T5/T7: plan-artifact-lang.js
# resolvePlanArtifactPath / isPlanArtifactPath — all called directly via node -e.

echo ""
echo "=== SHL: hooks/lib/pretool-lang-gate.js + plan-artifact-lang.js unit ==="

# shl_eval <js-body> — runs the body with `m` (pretool lib), `w` (write-tools
# lib) and `pa` (plan-artifact-lang lib) in scope; prints stdout, and on failure
# the stderr tail so a missing module reads as such. Child stdin is /dev/null.
shl_eval() {
    local body="$1" out errf="$TEST_ROOT/shl-stderr.txt"
    out="$(run_with_timeout 15 node -e "
const m = require('$PRETOOL_LIB_NODE');
const w = require('$WRITE_TOOLS_LIB_NODE');
const pa = require('$PLAN_ARTIFACT_LIB_NODE');
$body
" 2>"$errf" </dev/null)"
    if [ $? -ne 0 ]; then
        printf 'ERROR: %s' "$(tail -c 300 "$errf" 2>/dev/null | tr '\n' ' ')"
    else
        printf '%s' "$out"
    fi
}

# Shared MultiEdit payload: top-level path A; edits[0] inherits it, edits[1]
# spells file_path, edits[2] spells path.
SHL_TI='{"file_path":"A","edits":[{"new_string":"x"},{"file_path":"B","new_string":"y"},{"path":"C","new_string":"z"}]}'

# SHL-T1: collectEditTargets — per-element path inheritance, both path spellings
_shl1_got="$(shl_eval "
const t = m.collectEditTargets('MultiEdit', $SHL_TI);
process.stdout.write(JSON.stringify(t.map((x) => [x.filePath, x.fragment, x.editIndex])));
")"
_shl1_exp='[["A","x",0],["B","y",1],["C","z",2]]'
if [ "$_shl1_got" = "$_shl1_exp" ]; then
    pass "SHL-T1: collectEditTargets inherits the top-level path and reads file_path / path per element"
else
    fail "SHL-T1: expected $_shl1_exp, got: $_shl1_got"
fi

# SHL-T2: targetPathsOf set == collectEditWritePaths set (notebook_path excluded)
_shl2_got="$(shl_eval "
const ti = $SHL_TI;
const a = Array.from(new Set(m.targetPathsOf(m.collectEditTargets('MultiEdit', ti)))).sort();
const b = Array.from(new Set(w.collectEditWritePaths(ti).filter((p) => p !== ti.notebook_path))).sort();
process.stdout.write(JSON.stringify(a) + '|' + JSON.stringify(b));
")"
_shl2_exp='["A","B","C"]|["A","B","C"]'
if [ "$_shl2_got" = "$_shl2_exp" ]; then
    pass "SHL-T2: targetPathsOf matches collectEditWritePaths (write-tool contract parity)"
else
    fail "SHL-T2: expected $_shl2_exp, got: $_shl2_got"
fi

# SHL-T3: per-tool fragment source — table-driven matrix
# (skills/_shared/test-design/parser-regex-tests.md). Columns:
#   name | tool | tool_input JSON | expected [filePath, fragment, editIndex][]
# The heredoc feeds only this loop; shl_eval's node child reads /dev/null.
_shl3_ok=1; _shl3_n=0; _shl3_report=""
while IFS='|' read -r _name _tool _ti _exp; do
    [[ -z "$_name" || "$_name" =~ ^[[:space:]]*# ]] && continue
    _name="${_name//[[:space:]]/}"; _tool="${_tool//[[:space:]]/}"
    _ti="${_ti//[[:space:]]/}"; _exp="${_exp//[[:space:]]/}"
    _shl3_n=$((_shl3_n + 1))
    _got="$(shl_eval "
const t = m.collectEditTargets('$_tool', $_ti);
process.stdout.write(JSON.stringify(t.map((x) => [x.filePath, x.fragment, x.editIndex])));
")"
    if [ "$_got" != "$_exp" ]; then
        _shl3_ok=0
        _shl3_report+="  $_name ($_tool): expected $_exp got $_got"$'\n'
    fi
done <<'TABLE'
# name                    | tool      | tool_input                                                                        | expected
write-content             | Write     | {"file_path":"A","content":"c"}                                                   | [["A","c",null]]
edit-new-string           | Edit      | {"file_path":"A","old_string":"o","new_string":"n"}                               | [["A","n",null]]
editfiles-content         | editFiles | {"file_path":"A","content":"c"}                                                   | [["A","c",null]]
editfiles-new-string      | editFiles | {"file_path":"A","old_string":"o","new_string":"n"}                               | [["A","n",null]]
multiedit-drop-fragless   | MultiEdit | {"file_path":"A","edits":[{"old_string":"o"},{"old_string":"o","new_string":"n"}]} | [["A","n",1]]
multiedit-no-path         | MultiEdit | {"edits":[{"old_string":"o","new_string":"n"}]}                                   | []
TABLE
if [ "$_shl3_ok" -eq 1 ] && [ "$_shl3_n" -eq 6 ]; then
    pass "SHL-T3: Write→content, Edit→new_string, editFiles→content, pathless/fragmentless edits dropped ($_shl3_n rows)"
else
    fail "SHL-T3: fragment-source mismatch ($_shl3_n rows):"$'\n'"$_shl3_report"
fi

# SHL-T4: applyEdits — replace_all, first-occurrence, mismatch → null
_shl4_got="$(shl_eval "
const r = [
  m.applyEdits('aXbXc', [{ old_string: 'X', new_string: 'Y', replace_all: true }]),
  m.applyEdits('aXbXc', [{ old_string: 'X', new_string: 'Y' }]),
  m.applyEdits('aXbXc', [{ old_string: 'Z', new_string: 'Y' }]),
  m.applyEdits('aXbXc', [{ old_string: 'X', new_string: 'Y' }, { old_string: 'Y', new_string: 'Q' }]),
];
process.stdout.write(JSON.stringify(r));
")"
_shl4_exp='["aYbYc","aYbXc",null,"aQbXc"]'
if [ "$_shl4_got" = "$_shl4_exp" ]; then
    pass "SHL-T4: applyEdits replace_all / first occurrence / old_string mismatch → null / sequential"
else
    fail "SHL-T4: expected $_shl4_exp, got: $_shl4_got"
fi

# SHL-T5 (C2): resolvePlanArtifactPath(sid, stage) — path-traversal hardening.
# Mutation probe: run bin/mutation-probe.sh hooks/lib/plan-artifact-lang.js after implementation
# Columns: name | sid | stage | expected ("null", or a path with PLANS = $PLANS_DIR).
# Artifact SID class = UUID or YYYYMMDD-HHMMSS (hooks/lib/is-plan-artifact.js); any other sid → null.
# Paths are compared after path.resolve so separator style does not matter.
_shl5_ok=1; _shl5_n=0; _shl5_report=""
while IFS='|' read -r _name _sid _stage _exp; do
    [[ -z "$_name" || "$_name" =~ ^[[:space:]]*# ]] && continue
    _name="${_name//[[:space:]]/}"; _sid="${_sid//[[:space:]]/}"
    _stage="${_stage//[[:space:]]/}"; _exp="${_exp//[[:space:]]/}"
    _exp="${_exp/PLANS/$PLANS_DIR}"
    _shl5_n=$((_shl5_n + 1))
    _got="$(shl_eval "
const p = require('path');
const r = pa.resolvePlanArtifactPath('$_sid', '$_stage');
const exp = '$_exp';
if (exp === 'null') process.stdout.write(r === null ? 'null' : 'GOT:' + String(r));
else process.stdout.write(typeof r === 'string' && p.resolve(r) === p.resolve(exp) ? 'match' : 'GOT:' + String(r));
")"
    _want='match'; [ "$_exp" = 'null' ] && _want='null'
    if [ "$_got" != "$_want" ]; then
        _shl5_ok=0
        _shl5_report+="  $_name sid='$_sid' stage='$_stage': expected $_exp got $_got"$'\n'
    fi
done <<'TABLE'
# name              | sid                                   | stage      | expected
sid-dotdot          | ../evil                               | detail     | null
sid-slash           | a/b                                   | detail     | null
sid-backslash       | a\\b                                  | detail     | null
sid-empty           |                                       | detail     | null
sid-nonartifact     | sid-t13-123                           | detail     | null
stage-traversal    | a1b2c3d4-e5f6-7890-abcd-ef1234567890  | ../../etc  | null
stage-unknown       | a1b2c3d4-e5f6-7890-abcd-ef1234567890  | draft      | null
uuid-intent         | a1b2c3d4-e5f6-7890-abcd-ef1234567890  | intent     | PLANS/a1b2c3d4-e5f6-7890-abcd-ef1234567890-intent.md
timestamp-detail    | 20260625-120000                       | detail     | PLANS/20260625-120000-detail.md
TABLE
if [ "$_shl5_ok" -eq 1 ] && [ "$_shl5_n" -eq 9 ]; then
    pass "SHL-T5: resolvePlanArtifactPath rejects traversal/separator/empty/non-artifact-class sid and unknown stage; resolves UUID + TIMESTAMP sids ($_shl5_n rows)"
else
    fail "SHL-T5: resolvePlanArtifactPath mismatch ($_shl5_n rows):"$'\n'"$_shl5_report"
fi

# SHL-T6 (C6): collectEditTargets returns [] on malformed shapes (never throws).
# Columns: name | tool | tool_input JSON literal (null allowed)
_shl6_ok=1; _shl6_n=0; _shl6_report=""
while IFS='|' read -r _name _tool _ti; do
    [[ -z "$_name" || "$_name" =~ ^[[:space:]]*# ]] && continue
    _name="${_name//[[:space:]]/}"; _tool="${_tool//[[:space:]]/}"; _ti="${_ti//[[:space:]]/}"
    _shl6_n=$((_shl6_n + 1))
    _got="$(shl_eval "
process.stdout.write(JSON.stringify(m.collectEditTargets('$_tool', $_ti)));
")"
    if [ "$_got" != "[]" ]; then
        _shl6_ok=0
        _shl6_report+="  $_name ($_tool $_ti): expected [] got $_got"$'\n'
    fi
done <<'TABLE'
# name               | tool      | tool_input
edits-empty          | MultiEdit | {"file_path":"A","edits":[]}
edits-notarray       | MultiEdit | {"file_path":"A","edits":"notarray"}
content-number       | Write     | {"file_path":"A","content":42}
newstring-object     | Edit      | {"file_path":"A","old_string":"o","new_string":{"x":1}}
elem-fragment-number | MultiEdit | {"file_path":"A","edits":[{"old_string":"o","new_string":7}]}
input-null           | Write     | null
TABLE
if [ "$_shl6_ok" -eq 1 ] && [ "$_shl6_n" -eq 6 ]; then
    pass "SHL-T6: collectEditTargets → [] on edits:[] / non-array edits / non-string fragments / null input ($_shl6_n rows)"
else
    fail "SHL-T6: collectEditTargets malformed-shape mismatch ($_shl6_n rows):"$'\n'"$_shl6_report"
fi

# SHL-T7 (C5): isPlanArtifactPath(filePath) — separator-aware containment.
# Columns: name | path (PLANS = $PLANS_DIR) | expected true/false
_shl7_ok=1; _shl7_n=0; _shl7_report=""
while IFS='|' read -r _name _path _exp; do
    [[ -z "$_name" || "$_name" =~ ^[[:space:]]*# ]] && continue
    _name="${_name//[[:space:]]/}"; _path="${_path//[[:space:]]/}"; _exp="${_exp//[[:space:]]/}"
    _path="${_path/PLANS/$PLANS_DIR}"
    _shl7_n=$((_shl7_n + 1))
    _got="$(shl_eval "process.stdout.write(String(pa.isPlanArtifactPath('$_path')));")"
    if [ "$_got" != "$_exp" ]; then
        _shl7_ok=0
        _shl7_report+="  $_name path='$_path': expected $_exp got $_got"$'\n'
    fi
done <<'TABLE'
# name            | path                                                  | expected
inside-uuid       | PLANS/a1b2c3d4-e5f6-7890-abcd-ef1234567890-intent.md  | true
inside-timestamp  | PLANS/20260625-120000-detail.md                       | true
sibling-prefix    | PLANS-other/a1b2c3d4-e5f6-7890-abcd-ef1234567890-intent.md | false
non-artifact-name | PLANS/a1b2c3d4-e5f6-7890-abcd-ef1234567890-draft.md   | false
dotdot-escape     | PLANS/../a1b2c3d4-e5f6-7890-abcd-ef1234567890-intent.md | false
TABLE
if [ "$_shl7_ok" -eq 1 ] && [ "$_shl7_n" -eq 5 ]; then
    pass "SHL-T7: isPlanArtifactPath true for artifact basenames inside the plans dir; prefix-sibling dir, non-artifact name, .. escape → false ($_shl7_n rows)"
else
    fail "SHL-T7: isPlanArtifactPath mismatch ($_shl7_n rows):"$'\n'"$_shl7_report"
fi
