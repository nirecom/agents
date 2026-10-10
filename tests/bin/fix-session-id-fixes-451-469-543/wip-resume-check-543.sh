# wip-resume-check-543.sh — #543 SID-resolution tests ported to the driver.
# F1: driver wip-check phase passes the CLAUDE_CODE_SESSION_ID-resolved --session-id
# through to wip-state.sh check. (E1, the retired env-file source, was removed in #1091.)
# Sourced by fix-session-id-fixes-451-469-543.sh; inherits globals and helpers.

# Helper: build a minimal driver fixture under a temp dir.
# Sets B543_PLANS, B543_FAKE_SCRIPT_CHECKOUT_ROOT, B543_MOCKBIN, B543_RESP, B543_WIPD, B543_TMP.
setup_drv_mock() {
    B543_TMP="$(mktemp -d 2>/dev/null || mktemp -d -t wipfix543drv)"
    B543_PLANS="$B543_TMP/plans"
    B543_FAKE_SCRIPT_CHECKOUT_ROOT="$B543_TMP/fake-script-checkout-root"
    B543_MOCKBIN="$B543_TMP/bin"
    B543_RESP="$B543_TMP/resp"
    B543_WIPD="$B543_TMP/wip"
    B543_WIP_LOG="$B543_TMP/wip-state-args.log"
    mkdir -p "$B543_PLANS" "$B543_MOCKBIN" "$B543_RESP" "$B543_WIPD" \
        "$B543_FAKE_SCRIPT_CHECKOUT_ROOT/bin/github-issues" "$B543_FAKE_SCRIPT_CHECKOUT_ROOT/hooks/lib" \
        "$B543_FAKE_SCRIPT_CHECKOUT_ROOT/skills/workflow-init/scripts"

    cat > "$B543_MOCKBIN/gh" <<GHEOF
#!/bin/bash
RESP="$B543_RESP"
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
    if [ -f "\$RESP/issue-view-\$N.json" ]; then cat "\$RESP/issue-view-\$N.json"; exit 0; fi
    exit 1
fi
if [ "\$cmd" = "repo" ] && [ "\$sub" = "view" ]; then echo "mockorg/mockrepo"; exit 0; fi
if [ "\$cmd" = "api" ]; then echo "[]"; exit 0; fi
exit 0
GHEOF
    chmod +x "$B543_MOCKBIN/gh"

    # Issue fixture for #42
    printf '{"number":42,"title":"Issue 42","body":"Body","labels":[{"name":"intent:clarified","name":"type:task"}],"state":"OPEN","createdAt":"2026-01-01T00:00:00Z"}\n' \
        > "$B543_RESP/issue-view-42.json"

    cat > "$B543_FAKE_SCRIPT_CHECKOUT_ROOT/bin/github-issues/wip-state.sh" <<WIPEOF
#!/bin/bash
printf '%s\n' "\$*" >> '$B543_WIP_LOG'
CMD="\$1"; shift
case "\$CMD" in
    check) echo "same" ;;
    set)   exit 0 ;;
    *)     exit 0 ;;
esac
WIPEOF
    chmod +x "$B543_FAKE_SCRIPT_CHECKOUT_ROOT/bin/github-issues/wip-state.sh"

    cat > "$B543_FAKE_SCRIPT_CHECKOUT_ROOT/skills/workflow-init/scripts/filter-init-candidates.sh" <<'FEOF'
#!/bin/bash
while [ $# -gt 0 ]; do
    case "$1" in --repo-map) shift 2 ;; -*) shift ;; *) echo "#${1#\#}"; shift ;; esac
done
exit 0
FEOF
    chmod +x "$B543_FAKE_SCRIPT_CHECKOUT_ROOT/skills/workflow-init/scripts/filter-init-candidates.sh"
    # The driver finds its siblings from its own path: launch it from a copy
    # that holds the stubs above (the copy never overwrites an existing file).
    script_checkout_fixture_copy "$B543_FAKE_SCRIPT_CHECKOUT_ROOT" bin hooks skills

    : > "$B543_WIP_LOG"
}

teardown_drv_mock() {
    if [ -n "${B543_TMP:-}" ] && [ -d "$B543_TMP" ]; then
        rm -rf "$B543_TMP" 2>/dev/null || true
    fi
    B543_TMP=""
}

# === F1: driver wip-check phase passes --session-id through to wip-state.sh check ===
if [ ! -f "$DRIVER" ]; then
    fail "F1: $DRIVER missing"
else
    setup_drv_mock

    ORIG_PATH_F1="$PATH"
    export PATH="$B543_MOCKBIN:$PATH"
    run_with_timeout 30 bash -c "
        export CLAUDE_CODE_SESSION_ID='testSID'
        export WORKFLOW_PLANS_DIR='$B543_PLANS'
        node '$B543_FAKE_SCRIPT_CHECKOUT_ROOT/bin/workflow/workflow-init-driver' '#42'
    " >/dev/null 2>&1
    RC=$?
    export PATH="$ORIG_PATH_F1"
    if grep -q -- "--session-id testSID" "$B543_WIP_LOG" 2>/dev/null; then
        pass "F1: driver wip-check phase passes --session-id testSID to wip-state.sh check"
    else
        fail "F1: rc=$RC log=$(cat "$B543_WIP_LOG" 2>/dev/null)"
    fi
    teardown_drv_mock
fi
