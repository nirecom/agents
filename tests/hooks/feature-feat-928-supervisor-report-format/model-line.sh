#!/bin/bash
# tests/hooks/feature-feat-928-supervisor-report-format/model-line.sh
# Tests: hooks/lib/supervisor-report-format.js
# Tags: hook, supervisor, model-routing, unit, scope:issue-specific
# #2100 SF-M1..SF-M3 (Step 6 H1-H4, H6-H8): the line right after each supervisor
# spawn instruction is formatAgentModelLine(<role>). RED until Step 6 lands.
# Runnable standalone: bash tests/hooks/feature-feat-928-supervisor-report-format/model-line.sh

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck source=../../lib/harness.sh
. "$AGENTS_DIR/tests/lib/harness.sh"
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
        run_with_timeout 10 env -u REVIEWER_MODEL -u ALERT_MODEL -u PRODUCER_HIGH_MODEL -u PRODUCER_LOW_MODEL \
            -u CLAUDE_CODE_SUBAGENT_MODEL -u CLAUDE_PROJECT_DIR \
             -u CLAUDE_CODE_SESSION_ID \
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
ml_render haiku 'ALERT_MODEL=haiku\nREVIEWER_MODEL=haiku\n'
ml_render alert_only 'ALERT_MODEL=haiku\n'
ml_render reviewer_only 'REVIEWER_MODEL=haiku\n'
ml_render invalid 'ALERT_MODEL=gpt-mlleak\nREVIEWER_MODEL=claude-mlleak-5\n'

# --- SF-M1: fixture alias reaches the line after every spawn instruction -----
case_begin "sf-m1-spawn-model-line" "hooks/lib/supervisor-report-format.js"
ml_check "SF-M1 H1 cumSev (no findings) -> ALERT_MODEL" haiku H1 "$RE_H12" haiku
ml_check "SF-M1 H2 cumSev (findings) -> ALERT_MODEL" haiku H2 "$RE_H12" haiku
ml_check "SF-M1 H3 L2-armed -> ALERT_MODEL" haiku H3 "$RE_H34" haiku
ml_check "SF-M1 H4 worktree-off proposal -> ALERT_MODEL" haiku H4 "$RE_H34" haiku
ml_check "SF-M1 H6 pre-merge block -> REVIEWER_MODEL" haiku H6 "$RE_H6" haiku
ml_check "SF-M1 H7 L3 stage boundary -> REVIEWER_MODEL" haiku H7 "$RE_H78" haiku
ml_check "SF-M1 H8 L3 severity threshold -> REVIEWER_MODEL" haiku H8 "$RE_H78" haiku
case_end

# --- SF-M1 role-swap: only the matching role's key moves the line ------------
case_begin "sf-m1-role-swap-isolation" "hooks/lib/supervisor-report-format.js"
ml_check "SF-M1 swap H1 ignores REVIEWER_MODEL" reviewer_only H1 "$RE_H12" sonnet
ml_check "SF-M1 swap H3 ignores REVIEWER_MODEL" reviewer_only H3 "$RE_H34" sonnet
ml_check "SF-M1 swap H4 ignores REVIEWER_MODEL" reviewer_only H4 "$RE_H34" sonnet
ml_check "SF-M1 swap H6 ignores ALERT_MODEL" alert_only H6 "$RE_H6" opus
ml_check "SF-M1 swap H7 ignores ALERT_MODEL" alert_only H7 "$RE_H78" opus
ml_check "SF-M1 swap H8 ignores ALERT_MODEL" alert_only H8 "$RE_H78" opus
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
case_end

# --- SF-M2: disallowed values fall back to the role default, value withheld ---
case_begin "sf-m2-invalid-model-fallback" "hooks/lib/supervisor-report-format.js"
ml_check "SF-M2 H2 invalid ALERT_MODEL -> sonnet" invalid H2 "$RE_H12" sonnet
ml_check "SF-M2 H3 invalid ALERT_MODEL -> sonnet" invalid H3 "$RE_H34" sonnet
ml_check "SF-M2 H6 invalid REVIEWER_MODEL -> opus" invalid H6 "$RE_H6" opus
ml_check "SF-M2 H7 invalid REVIEWER_MODEL -> opus" invalid H7 "$RE_H78" opus
leak="$(grep -l -e 'mlleak' "$ML_WORK"/out/invalid/*.txt "$ML_WORK/out/invalid.err" 2>/dev/null)"
if [ -f "$ML_WORK/out/invalid/H1.txt" ] && [ -z "$leak" ]; then
    pass "SF-M2 invalid values never echoed into any formatter output"
else
    fail "SF-M2 invalid value leaked or no output (${leak:-no output})"
fi
case_end

# --- SF-M3 negative control: no spawn instruction -> no model line ------------
case_begin "sf-m3-no-spawn-line-no-model" "hooks/lib/supervisor-report-format.js"
fb="$ML_WORK/out/haiku/FB.txt"
if [ -f "$fb" ] && grep -q 'freshness backstop denied the merge' "$fb" && ! grep -q 'Subagent model:' "$fb"; then
    pass "SF-M3 formatFreshnessBackstopReason carries no Subagent model: line"
else
    fail "SF-M3 formatFreshnessBackstopReason output unexpected: $(head -c 300 "$fb" 2>/dev/null)"
fi
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
