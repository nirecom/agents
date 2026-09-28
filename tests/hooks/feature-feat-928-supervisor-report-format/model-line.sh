#!/bin/bash
# tests/hooks/feature-feat-928-supervisor-report-format/model-line.sh
# Tests: hooks/lib/supervisor-report-format.js
# Tags: hook, supervisor, model-routing, unit, scope:issue-specific
# #2100 SF-M1..SF-M3 (Step 6 H1-H4, H6-H8): the line right after each supervisor
# spawn instruction is formatAgentModelLine(<role>). RED until Step 6 lands.
# Runnable standalone: bash tests/hooks/feature-feat-928-supervisor-report-format/model-line.sh

# shellcheck source=_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

_to_node_path() {
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -m "$1"
    else
        printf '%s' "$1"
    fi
}

ML_WORK="$(mktemp -d)"
trap 'rm -rf "$ML_WORK"' EXIT
mkdir -p "$ML_WORK/cfg" "$ML_WORK/neutral" "$ML_WORK/wf" "$ML_WORK/plans"

# One node process per fixture .env renders every formatter into $ML_WORK/out/<tag>/<H>.txt.
ML_JS='
const fs = require("fs");
const path = require("path");
const f = require(process.env.ML_FORMATTER);
const dir = process.env.ML_OUTDIR;
const F1 = JSON.parse(process.env.ML_FINDINGS);
const sp = "/tmp/ml-supervisor.md", ap = "/tmp/ml-supervisor-audit.md", stp = "/tmp/ml-state.json";
const cases = {
  H1: () => f.formatCumSevErrorReason([], "sid-ml", "wsid-ml", sp, stp),
  H2: () => f.formatCumSevErrorReason(F1, "sid-ml", "wsid-ml", sp, stp),
  H3: () => f.formatL2ArmedReason("scheduled-review", "sid-ml", "wsid-ml", sp, stp),
  H4: () => f.formatWorktreeOffProposalReason("sid-ml", "wsid-ml", sp, stp),
  H6: () => f.formatPreMergeBlockReason("warning-flush", "sid-ml", "wsid-ml", ap, stp),
  H7: () => f.formatL3StageBoundaryReason("DETAIL", "CONTINUE", "sid-ml", stp),
  H8: () => f.formatL3SeverityThresholdReason("warning", "WARN", "sid-ml", stp),
  FB: () => f.formatFreshnessBackstopReason("freshness-backstop", "no TR5 run", "sid-ml", "wsid-ml", null),
};
for (const [k, fn] of Object.entries(cases)) {
  let out;
  try { out = String(fn()); } catch (e) { out = "THROW: " + e.message; }
  fs.writeFileSync(path.join(dir, k + ".txt"), out);
}
'

# ml_render <tag> <env-file-content> — render all formatters under that .env.
ml_render() {
    local tag="$1" content="$2"
    mkdir -p "$ML_WORK/out/$tag"
    printf '%b' "$content" > "$ML_WORK/cfg/.env"
    (
        cd "$ML_WORK/neutral" || exit 1
        run_with_timeout 10 env -u MODEL_REVIEWER -u MODEL_ALERT -u MODEL_PRODUCER_HIGH -u MODEL_PRODUCER_LOW \
            -u CLAUDE_CODE_SUBAGENT_MODEL -u CLAUDE_PROJECT_DIR \
            -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID -u CLAUDE_ENV_FILE \
            AGENTS_CONFIG_DIR="$(_to_node_path "$ML_WORK/cfg")" \
            CLAUDE_WORKFLOW_DIR="$ML_WORK/wf" WORKFLOW_PLANS_DIR="$ML_WORK/plans" \
            ML_FORMATTER="$FORMATTER_NODE" ML_OUTDIR="$(_to_node_path "$ML_WORK/out/$tag")" \
            ML_FINDINGS="$FINDINGS_ONE" \
            node -e "$ML_JS"
    ) 2>"$ML_WORK/out/$tag.err"
}

# ml_after <tag> <H> <spawn-ERE> — the line right after the first spawn line.
ml_after() {
    awk -v re="$3" 'hit { print; exit } $0 ~ re { hit = 1 }' "$ML_WORK/out/$1/$2.txt"
}

ml_count() {
    grep -c '^Subagent model:' "$ML_WORK/out/$1/$2.txt"
}

model_line() {
    printf 'Subagent model: pass model: "%s" to the Agent tool.' "$1"
}

# ml_check <label> <tag> <H> <spawn-ERE> <alias>
ml_check() {
    local label="$1" tag="$2" h="$3" re="$4" want got n
    want="$(model_line "$5")"
    if [ ! -f "$ML_WORK/out/$tag/$h.txt" ]; then
        fail "$label (no render output; stderr: $(head -c 300 "$ML_WORK/out/$tag.err"))"
        return
    fi
    if ! grep -qE "$re" "$ML_WORK/out/$tag/$h.txt"; then
        fail "$label (spawn line /$re/ missing from $h output)"
        return
    fi
    got="$(ml_after "$tag" "$h" "$re")"
    n="$(ml_count "$tag" "$h")"
    if [ "$got" = "$want" ] && [ "$n" = "1" ]; then
        pass "$label"
    else
        fail "$label (line after spawn: '$got'; want '$want'; Subagent model: lines=$n)"
    fi
}

RE_H12='^Recommended action: follow agents/supervisor[.]md '
RE_H34='^Action: invoke agents/supervisor[.]md '
RE_H6='^Action: Run agents/supervisor-audit[.]md as a subagent'
RE_H78='^Action: invoke agents/supervisor-audit[.]md as a subagent'

ml_render base ''
ml_render haiku 'MODEL_ALERT=haiku\nMODEL_REVIEWER=haiku\n'
ml_render alert_only 'MODEL_ALERT=haiku\n'
ml_render reviewer_only 'MODEL_REVIEWER=haiku\n'
ml_render invalid 'MODEL_ALERT=gpt-mlleak\nMODEL_REVIEWER=claude-mlleak-5\n'

# --- SF-M1: fixture alias reaches the line after every spawn instruction -----
ml_check "SF-M1 H1 cumSev (no findings) -> MODEL_ALERT" haiku H1 "$RE_H12" haiku
ml_check "SF-M1 H2 cumSev (findings) -> MODEL_ALERT" haiku H2 "$RE_H12" haiku
ml_check "SF-M1 H3 L2-armed -> MODEL_ALERT" haiku H3 "$RE_H34" haiku
ml_check "SF-M1 H4 worktree-off proposal -> MODEL_ALERT" haiku H4 "$RE_H34" haiku
ml_check "SF-M1 H6 pre-merge block -> MODEL_REVIEWER" haiku H6 "$RE_H6" haiku
ml_check "SF-M1 H7 L3 stage boundary -> MODEL_REVIEWER" haiku H7 "$RE_H78" haiku
ml_check "SF-M1 H8 L3 severity threshold -> MODEL_REVIEWER" haiku H8 "$RE_H78" haiku

# --- SF-M1 role-swap: only the matching role's key moves the line ------------
ml_check "SF-M1 swap H1 ignores MODEL_REVIEWER" reviewer_only H1 "$RE_H12" sonnet
ml_check "SF-M1 swap H3 ignores MODEL_REVIEWER" reviewer_only H3 "$RE_H34" sonnet
ml_check "SF-M1 swap H4 ignores MODEL_REVIEWER" reviewer_only H4 "$RE_H34" sonnet
ml_check "SF-M1 swap H6 ignores MODEL_ALERT" alert_only H6 "$RE_H6" opus
ml_check "SF-M1 swap H7 ignores MODEL_ALERT" alert_only H7 "$RE_H78" opus
ml_check "SF-M1 swap H8 ignores MODEL_ALERT" alert_only H8 "$RE_H78" opus
swap_diff=""
for h in H1 H2 H3 H4; do
    cmp -s "$ML_WORK/out/base/$h.txt" "$ML_WORK/out/reviewer_only/$h.txt" || swap_diff="$swap_diff $h"
done
for h in H6 H7 H8; do
    cmp -s "$ML_WORK/out/base/$h.txt" "$ML_WORK/out/alert_only/$h.txt" || swap_diff="$swap_diff $h"
done
if [ ! -f "$ML_WORK/out/base/H1.txt" ]; then
    fail "SF-M1 swap: no baseline render output"
elif [ -z "$swap_diff" ]; then
    pass "SF-M1 swap: other role's key leaves every output byte-identical to the no-.env baseline"
else
    fail "SF-M1 swap: output changed under the other role's key:$swap_diff"
fi

# --- SF-M2: disallowed values fall back to the role default, value withheld ---
ml_check "SF-M2 H2 invalid MODEL_ALERT -> sonnet" invalid H2 "$RE_H12" sonnet
ml_check "SF-M2 H3 invalid MODEL_ALERT -> sonnet" invalid H3 "$RE_H34" sonnet
ml_check "SF-M2 H6 invalid MODEL_REVIEWER -> opus" invalid H6 "$RE_H6" opus
ml_check "SF-M2 H7 invalid MODEL_REVIEWER -> opus" invalid H7 "$RE_H78" opus
leak="$(grep -l -e 'mlleak' "$ML_WORK"/out/invalid/*.txt "$ML_WORK/out/invalid.err" 2>/dev/null)"
if [ -f "$ML_WORK/out/invalid/H1.txt" ] && [ -z "$leak" ]; then
    pass "SF-M2 invalid values never echoed into any formatter output"
else
    fail "SF-M2 invalid value leaked or no output (${leak:-no output})"
fi

# --- SF-M3 negative control: no spawn instruction -> no model line ------------
fb="$ML_WORK/out/haiku/FB.txt"
if [ -f "$fb" ] && grep -q 'freshness backstop denied the merge' "$fb" && ! grep -q 'Subagent model:' "$fb"; then
    pass "SF-M3 formatFreshnessBackstopReason carries no Subagent model: line"
else
    fail "SF-M3 formatFreshnessBackstopReason output unexpected: $(head -c 300 "$fb" 2>/dev/null)"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
