#!/bin/bash
# Tests: skills/workflow-init/SKILL.md, bin/workflow/lib/workflow-init/phases/meta-classify.js, bin/workflow/lib/workflow-init/phases/route-decision.js, tests/feature-issue-create-skill/section-dispatch-bulk.sh
# Tags: workflow-init, meta-routing, scope:issue-specific
#
# Issue #1181 — workflow-init WI-8 sub-issue guard for Path META. The guard
# replaced the retired list-open-sub-issues.sh and, since #2087, lives in the
# driver's meta-classify phase: open sub-issues emit ACTION=ask_user
# ASK_ID=meta_select.
#
# TL3 gap (NOT caught here): real gh sub_issues API calls, AskUserQuestion UI and
# live interaction — mitigated at WORKFLOW_USER_VERIFIED preflight (bin/check-verification-gate.sh, category skill-orchestration).

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW_INIT_SKILL="$AGENTS_DIR/skills/workflow-init/SKILL.md"
ROUTE_DECISION_JS="$AGENTS_DIR/bin/workflow/lib/workflow-init/phases/route-decision.js"
META_CLASSIFY_JS="$AGENTS_DIR/bin/workflow/lib/workflow-init/phases/meta-classify.js"
DRIVER="$AGENTS_DIR/bin/workflow/workflow-init-driver"
SECTION_BULK="$AGENTS_DIR/tests/feature-issue-create-skill/section-dispatch-bulk.sh"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm '"$secs"'; exec @ARGV' -- "$@"; fi
}

# ===========================================================================
# T1: route-decision.js exists (replaced list-open-sub-issues.sh)
# ===========================================================================
if [ -f "$ROUTE_DECISION_JS" ]; then
    pass "T1: driver route-decision.js exists (sub-issue guard absorbed from list-open-sub-issues.sh)"
else
    fail "T1: driver route-decision.js missing at $ROUTE_DECISION_JS"
fi

# ===========================================================================
# T2: driver meta-classify.js contains sub_issues API reference (#2087 moved it
# out of route-decision.js)
# ===========================================================================
if [ ! -f "$META_CLASSIFY_JS" ]; then
    fail "T2: meta-classify.js missing at $META_CLASSIFY_JS"
elif grep -q "sub_issues" "$META_CLASSIFY_JS"; then
    pass "T2: meta-classify.js references sub_issues API (WI-8 open sub-issue guard)"
else
    fail "T2: meta-classify.js missing sub_issues API reference"
fi

# ===========================================================================
# T3: SKILL.md contains sub-issue selection re-fetch (meta_select resume path)
# ===========================================================================
if grep -qiE "(meta_select|re.fetch|re-fetch|re.invok)" "$WORKFLOW_INIT_SKILL"; then
    pass "T3: SKILL.md contains sub-issue meta_select / re-fetch reference"
else
    fail "T3: SKILL.md missing meta_select or re-fetch reference"
fi

# ===========================================================================
# T4: SKILL.md or meta-classify.js contains owner/repo resolution.
# #1899 replaced the `gh repo view --json nameWithOwner` lookup (which can name
# `upstream` on a fork) with an origin-remote resolver, so `nameWithOwner` is no
# longer the marker — accept either spelling, but require that some owner/repo
# resolution is still present. #2087 moved the resolver to meta-classify.js.
# ===========================================================================
if grep -qE "(nameWithOwner|OWNER_REPO|owner_repo|ownerRepo|resolveOwnerRepoFromOrigin|parseOriginOwnerRepo)" "$META_CLASSIFY_JS" 2>/dev/null || \
   grep -qE "(nameWithOwner|OWNER_REPO)" "$WORKFLOW_INIT_SKILL"; then
    pass "T4: owner/repo resolution present in meta-classify.js or SKILL.md"
else
    fail "T4: owner/repo resolution missing from both meta-classify.js and SKILL.md"
fi

# ===========================================================================
# T5: SKILL.md contains ISSUES[@] full loop reference
# ===========================================================================
if grep -qE 'ISSUES\[(@|\*|[0-9]+)\]' "$WORKFLOW_INIT_SKILL"; then
    pass "T5: SKILL.md contains ISSUES[@] full loop reference"
else
    fail "T5: SKILL.md missing ISSUES[@] loop reference"
fi

# ===========================================================================
# T6: meta-classify.js routes NO_OPEN to Path META (all sub-issues closed/absent).
# #2087 moved the no-open-sub-issues → META decision out of route-decision.js
# into the meta-classify phase, which is now the owner; route-decision.js is
# still accepted as the fallback owner (same OR-across-two-files shape as T4).
# ===========================================================================
if [ ! -f "$META_CLASSIFY_JS" ]; then
    fail "T6: meta-classify.js missing"
elif grep -qiE "(META|meta_decision|path.*META)" "$META_CLASSIFY_JS"; then
    pass "T6: meta-classify.js routes to Path META when no open sub-issues"
elif [ -f "$ROUTE_DECISION_JS" ] && grep -qiE "(META|meta_decision|path.*META)" "$ROUTE_DECISION_JS"; then
    pass "T6: route-decision.js routes to Path META when no open sub-issues (pre-#2087 owner)"
else
    fail "T6: META path routing missing from both meta-classify.js and route-decision.js"
fi

# ===========================================================================
# T7: SKILL.md or meta-classify.js handles ERROR / ask_user for WI-8 meta guard
# ===========================================================================
if grep -qiE "(ask_user|AskUserQuestion|meta_select)" "$WORKFLOW_INIT_SKILL" || \
   grep -qiE "(ask_user|meta_select)" "$META_CLASSIFY_JS" 2>/dev/null; then
    pass "T7: meta guard ask_user / meta_select handling present"
else
    fail "T7: missing ask_user / meta_select handling in SKILL.md or meta-classify.js"
fi

# ===========================================================================
# T8: meta_select ask_id present in driver (replaces WORKFLOW_ABORTED_META_SUBISSUE_SELECTION)
# ===========================================================================
if [ ! -f "$META_CLASSIFY_JS" ]; then
    fail "T8: meta-classify.js missing at $META_CLASSIFY_JS"
elif grep -q "meta_select" "$META_CLASSIFY_JS"; then
    pass "T8: meta-classify.js contains meta_select ask_id (replaces WORKFLOW_ABORTED_META_SUBISSUE_SELECTION)"
else
    fail "T8: meta-classify.js missing meta_select ask_id"
fi

# ===========================================================================
# T9-T11: driver route-decision mock tests (open / empty / closed-only sub-issues)
# ===========================================================================
if [ ! -f "$DRIVER" ]; then
    skip "T9-T11: driver missing, skipping mock tests"
    FAIL=$((FAIL + 3))
else
    to_native() {
        if command -v cygpath >/dev/null 2>&1; then cygpath -u "$1"; else printf '%s' "$1"; fi
    }
    ROOT1181="$(to_native "$(mktemp -d)")"
    trap 'rm -rf "$ROOT1181"' EXIT
    ORIG_PATH1181="$PATH"
    _CN1181=0
    TIMEOUT_WRAP="$AGENTS_DIR/bin/run-with-timeout.sh"

    setup_t() {
        local sid="$1"
        _CN1181=$((_CN1181 + 1))
        T_CASE="$ROOT1181/c-$_CN1181"
        T_PLANS="$T_CASE/plans"
        T_CFG="$T_CASE/cfg"
        T_MOCKBIN="$T_CASE/bin"
        T_RESP="$T_CASE/resp"
        T_WIPD="$T_CASE/wip"
        mkdir -p "$T_PLANS" "$T_MOCKBIN" "$T_RESP" "$T_WIPD" \
            "$T_CFG/bin/github-issues" "$T_CFG/hooks/lib" \
            "$T_CFG/skills/workflow-init/scripts"
        # #1899: repo identity resolves from origin (not `gh repo view`), so
        # CWD must be a git repo with a github.com origin matching the gh
        # mock's myorg/myrepo. core.hooksPath disabled per fixture-isolation.md.
        git -C "$T_CASE" init -q >/dev/null 2>&1
        git -C "$T_CASE" config core.hooksPath /dev/null >/dev/null 2>&1
        git -C "$T_CASE" remote add origin "https://github.com/myorg/myrepo.git" >/dev/null 2>&1
        cat > "$T_MOCKBIN/gh" <<GHEOF
#!/bin/bash
echo "\$*" >> "$T_CASE/gh.log"
T_RESP="$T_RESP"
cmd="\${1:-}"; sub="\${2:-}"
if [ "\$cmd" = "issue" ] && [ "\$sub" = "view" ]; then
    shift 2; N=""
    while [ \$# -gt 0 ]; do
        case "\$1" in
            --repo|--json|--jq) if [ \$# -ge 2 ]; then shift 2; else shift; fi ;;
            -*) shift ;;
            *) [ -z "\$N" ] && N="\$1"; shift ;;
        esac
    done
    N="\${N#\#}"
    if [ -f "\$T_RESP/issue-view-\$N.json" ]; then cat "\$T_RESP/issue-view-\$N.json"; exit 0; fi
    exit 1
fi
if [ "\$cmd" = "repo" ] && [ "\$sub" = "view" ]; then echo "myorg/myrepo"; exit 0; fi
if [ "\$cmd" = "api" ]; then
    if echo "\${2:-}" | grep -q "sub_issues"; then
        if [ -f "\$T_RESP/sub-issues.json" ]; then cat "\$T_RESP/sub-issues.json"; else echo "[]"; fi
    else echo "{}"; fi
    exit 0
fi
echo "unhandled: \$*" >&2; exit 1
GHEOF
        chmod +x "$T_MOCKBIN/gh"
        cat > "$T_CFG/bin/github-issues/wip-state.sh" <<WIPEOF
#!/bin/bash
V=""; N=""
while [ \$# -gt 0 ]; do
    case "\$1" in
        --session-id|--repo) shift 2 ;;
        -*) shift ;;
        *) [ -z "\$V" ] && V="\$1" || N="\$1"; shift ;;
    esac
done
N="\${N#\#}"
case "\$V" in
    check) if [ -f "$T_WIPD/s-\$N" ]; then cat "$T_WIPD/s-\$N"; else echo "same"; fi; exit 0 ;;
    set)   echo "same" > "$T_WIPD/s-\$N"; exit 0 ;;
    *)     exit 0 ;;
esac
WIPEOF
        chmod +x "$T_CFG/bin/github-issues/wip-state.sh"
        printf '#!/bin/bash\necho "${CLAUDE_SESSION_ID:-mock}"\n' > "$T_CFG/bin/resolve-session-id"
        cp "$AGENTS_DIR/bin/parse-issue-tokens" "$T_CFG/bin/parse-issue-tokens"
        cp "$AGENTS_DIR/hooks/lib/parse-closes-issues.js" "$T_CFG/hooks/lib/parse-closes-issues.js"
        cat > "$T_CFG/skills/workflow-init/scripts/filter-init-candidates.sh" <<'FEOF'
#!/bin/bash
while [ $# -gt 0 ]; do
    case "$1" in --repo-map) shift 2 ;; -*) shift ;; *) echo "#${1#\#}"; shift ;; esac
done
exit 0
FEOF
        chmod +x "$T_CFG/bin/resolve-session-id" "$T_CFG/bin/parse-issue-tokens" \
            "$T_CFG/skills/workflow-init/scripts/filter-init-candidates.sh"
        export WORKFLOW_PLANS_DIR="$T_PLANS" AGENTS_CONFIG_DIR="$T_CFG" CLAUDE_SESSION_ID="$sid"
        unset NON_GITHUB CLAUDE_ENV_FILE 2>/dev/null || true
        export PATH="$T_MOCKBIN:$ORIG_PATH1181"
    }

    teardown_t() {
        export PATH="$ORIG_PATH1181"
        unset WORKFLOW_PLANS_DIR AGENTS_CONFIG_DIR CLAUDE_SESSION_ID 2>/dev/null || true
    }

    mock_issue() {
        local n="$1" state="$2" labels_csv="${3:-}" labels="" l
        local IFS=','
        for l in $labels_csv; do labels="$labels{\"name\":\"$l\"},"; done
        labels="[${labels%,}]"
        printf '{"number":%s,"title":"Issue %s","body":"B","labels":%s,"state":"%s","createdAt":"2026-01-01T00:00:00Z"}\n' \
            "$n" "$n" "$labels" "$state" > "$T_RESP/issue-view-$n.json"
    }

    run_t() {
        T_OUT="$(cd "$T_CASE" && "$TIMEOUT_WRAP" 30 node "$DRIVER" "$@" 2>/dev/null)"
        T_RC=$?; return 0
    }

    get_t() {
        local val
        val="$(printf '%s\n' "$T_OUT" | grep -m1 "^${1}=")" || { printf ''; return; }
        val="${val#"${1}"=}"; val="${val%$'\r'}"
        case "$val" in \'*\') val="${val#\'}"; val="${val%\'}" ;; esac
        printf '%s' "$val"
    }

    # T9: meta issue with open sub-issue → ask_user meta_select
    setup_t t9-1181
    mock_issue 99 OPEN "meta"
    printf '[{"number":42,"title":"Open child","state":"open"}]\n' > "$T_RESP/sub-issues.json"
    run_t '#99'
    ACT="$(get_t ACTION)"; AID="$(get_t ASK_ID)"
    if [ "$ACT" = "ask_user" ] && [ "$AID" = "meta_select" ]; then
        pass "T9: meta issue with open sub-issue → ask_user meta_select"
    else
        fail "T9: expected ask_user meta_select; got ACT=$ACT AID=$AID out=$T_OUT"
    fi
    teardown_t

    # T10: meta issue with empty sub-issues → PATH_DECISION=META
    setup_t t10-1181
    mock_issue 99 OPEN "meta"
    printf '[]\n' > "$T_RESP/sub-issues.json"
    run_t '#99'
    ACT="$(get_t ACTION)"; PD="$(get_t PATH_DECISION)"
    if [ "$ACT" = "done" ] && [ "$PD" = "META" ]; then
        pass "T10: meta issue with no sub-issues → PATH_DECISION=META"
    else
        fail "T10: expected done PATH_DECISION=META; got ACT=$ACT PD=$PD"
    fi
    teardown_t

    # T11: meta issue with closed-only sub-issue → PATH_DECISION=META
    setup_t t11-1181
    mock_issue 99 OPEN "meta"
    printf '[{"number":55,"title":"Closed child","state":"closed"}]\n' > "$T_RESP/sub-issues.json"
    run_t '#99'
    ACT="$(get_t ACTION)"; PD="$(get_t PATH_DECISION)"
    if [ "$ACT" = "done" ] && [ "$PD" = "META" ]; then
        pass "T11: meta issue with closed-only sub-issue → PATH_DECISION=META"
    else
        fail "T11: expected done PATH_DECISION=META; got ACT=$ACT PD=$PD"
    fi
    teardown_t

fi  # end driver-present block

# ===========================================================================
# T12: section-dispatch-bulk.sh WF-META-DOC2 assertion updated for meta-classify.js
# (#2087 moved the guard out of route-decision.js into the meta-classify phase,
# so the owning file the sibling test names must have moved with it)
# ===========================================================================
if [ ! -f "$SECTION_BULK" ]; then
    fail "T12: section-dispatch-bulk.sh missing"
elif grep -q "WF-META-DOC2" "$SECTION_BULK" && grep -q "meta-classify.js" "$SECTION_BULK"; then
    pass "T12: section-dispatch-bulk.sh WF-META-DOC2 references meta-classify.js (updated assertion)"
elif grep -q "WF-META-DOC2" "$SECTION_BULK"; then
    pass "T12: section-dispatch-bulk.sh contains WF-META-DOC2 assertion (sub-issue guard present)"
else
    fail "T12: section-dispatch-bulk.sh missing WF-META-DOC2 assertion"
fi

# ===========================================================================
# Summary
# ===========================================================================
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
