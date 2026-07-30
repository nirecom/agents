#!/usr/bin/env bash
# tests/feature-1643-worker-dispatch-reconcile-classify.sh
# Tests: bin/worker-dispatch/workers/issue-reconcile.js, bin/worker-dispatch.js, hooks/lib/worker-dispatch-registry.js
# Tags: worker-dispatch, issue-reconcile, classifier, table-driven, mutation-probe, sentinel, history-md, TL1, TL2, scope:issue-specific
#
# Issue #1643 — the issue-reconcile worker classifies every CLOSED issue as
# clean / history-only / needs-reconcile. Before this file the classifier had NO
# behavioural coverage: the sibling suites cover its capability surface, output
# shape and argv schema, but never what verdict it actually returns. The sharp
# bug this file exists to kill is substring matching on issue numbers: `#164`
# must not satisfy `#1643`'s history entry and vice versa — Group A is a mutation
# probe over that boundary, driving the exported predicate directly. Group B
# drives the whole dispatcher with a stub `gh` so the artifact contract
# (needs-reconcile rows ONLY) and the truncation summary are exercised for real.
#
# TL3 gap (what this TL1/TL2 test does NOT catch):
#   - The real `gh issue list --json number,title,comments` payload shape and its
#     flag contract; Group B stubs the external-process seam. On Windows a PATH
#     shim cannot shadow `gh` (spawnSync runs shell:false, so an extensionless
#     script or a .cmd is never resolved), so the stub is installed at
#     bin/worker-dispatch/spawn.js's `run` via a `node -r` preload — the whole
#     dispatcher, anchors, capability wall, fsguard and emit all stay real.
#     tests/TL3-worker-dispatch-gh-contract.sh (RUN_TL3-gated) fences the flag
#     contract against the real binary.
#   - A real docs/history.md whose entry headings drifted from the `#<N>:` form.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED
# preflight via bin/check-verification-gate.sh category: skill-orchestration.

set -u

if command -v timeout >/dev/null 2>&1 && [ -z "${_WD1643_RC_INNER:-}" ]; then
    _WD1643_RC_INNER=1 timeout 420 bash "$0" "$@"
    exit $?
fi

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
nodepath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi; }
WORKER_JS="$AGENTS_DIR/bin/worker-dispatch/workers/issue-reconcile.js"
DISPATCH_JS="$AGENTS_DIR/bin/worker-dispatch.js"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; [ -n "${2:-}" ] && echo "    detail: $2"; FAIL=$((FAIL + 1)); }
assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then pass "$name"
    else fail "$name" "want=$(printf '%q' "$want") got=$(printf '%q' "$got")"; fi
}
run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

if [ ! -f "$WORKER_JS" ] || [ ! -f "$DISPATCH_JS" ]; then
    fail "0: implementation missing" "worker=$WORKER_JS dispatcher=$DISPATCH_JS"
    echo ""
    echo "Total: PASS=$PASS FAIL=$FAIL"
    exit 1
fi

TMPD="$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/wd-rc-$$")"
mkdir -p "$TMPD"
trap 'rm -rf "$TMPD"' EXIT
WORKER_N="$(nodepath "$WORKER_JS")"

# Group A (TL1) — number-boundary mutation probe on hasHistoryEntry
HIST_JS="$TMPD/hist.js"
cat > "$HIST_JS" <<'HJS'
const w = require(process.argv[2]);
process.stdout.write(String(w.hasHistoryEntry(process.argv[3], Number(process.argv[4]))));
HJS

group_history_boundary() {
    local name corpus number want got
    while IFS='|' read -r name corpus number want; do
        [ -z "${name// /}" ] && continue
        case "$name" in \#*) continue ;; esac
        name="$(echo "$name" | xargs)"; number="$(echo "$number" | xargs)"
        want="$(echo "$want" | xargs)"
        got="$(run_with_timeout 30 node "$HIST_JS" "$WORKER_N" "$corpus" "$number" 2>&1)"
        assert_eq "hist/$name" "$want" "$got"
    done <<'TABLE'
exact-match          | - FEATURE #1643: dispatcher landed            | 1643 | true
near-miss-164-vs-1643| - FEATURE #1643: dispatcher landed            | 164  | false
near-miss-1643-vs-164| - FEATURE #164: older entry                   | 1643 | false
near-miss-16-vs-164  | - FEATURE #164: older entry                   | 16   | false
near-miss-164-vs-16  | - FEATURE #16: ancient entry                  | 164  | false
prose-mention-no-colon| resolved by #1643 in a later PR              | 1643 | false
prose-then-entry     | mentions #1643 then - FIX #1643: real entry   | 1643 | true
digit-prefixed-hit   | rev 9#1643: not an entry heading              | 1643 | false
empty-corpus         |                                              | 1643 | false
trailing-number-only | - FEATURE #1643                               | 1643 | false
TABLE
}

# Group A2 (TL1) — every verdict of classify(), plus sentinel near-misses
CLS_JS="$TMPD/classify.js"
cat > "$CLS_JS" <<'CJS'
const w = require(process.argv[2]);
const body = process.argv[3];
const issue = { number: 1643, title: "t", comments: body === "" ? [] : [{ body }] };
process.stdout.write(w.classify(issue, process.argv[4]));
CJS

group_classify_verdicts() {
    local name body corpus want got
    while IFS='|' read -r name body corpus want; do
        [ -z "${name// /}" ] && continue
        case "$name" in \#*) continue ;; esac
        name="$(echo "$name" | xargs)"; want="$(echo "$want" | xargs)"
        body="${body#"${body%%[![:space:]]*}"}"; body="${body%"${body##*[![:space:]]}"}"
        corpus="${corpus#"${corpus%%[![:space:]]*}"}"; corpus="${corpus%"${corpus##*[![:space:]]}"}"
        got="$(run_with_timeout 30 node "$CLS_JS" "$WORKER_N" "$body" "$corpus" 2>&1)"
        assert_eq "classify/$name" "$want" "$got"
    done <<'TABLE'
clean-sentinel        | <!-- issue-close-sentinel: appended -->      |                          | clean
clean-wins-over-history| <!-- issue-close-sentinel: appended -->     | - FIX #1643: entry       | clean
clean-leading-space    |   <!-- issue-close-sentinel: appended -->   |                          | clean
history-only           |                                            | - FIX #1643: entry       | history-only
needs-reconcile        |                                            |                          | needs-reconcile
needs-reconcile-near-miss-number|                                   | - FIX #164: entry        | needs-reconcile
sentinel-pending-not-clean | <!-- issue-close-sentinel: pending -->  |                          | needs-reconcile
sentinel-no-space-not-clean | <!--issue-close-sentinel: appended --> |                          | needs-reconcile
sentinel-not-at-start  | see this <!-- issue-close-sentinel: appended --> |                     | needs-reconcile
sentinel-plain-text    | issue-close-sentinel: appended              |                          | needs-reconcile
TABLE
}

# Group B (TL2) — the dispatcher end to end, with a stub `gh`
MAIN_RAW="$TMPD/repo"; mkdir -p "$MAIN_RAW/docs/history"
git -C "$MAIN_RAW" init -q -b main
git -C "$MAIN_RAW" config user.email test@example.com
git -C "$MAIN_RAW" config user.name test
git -C "$MAIN_RAW" config core.hooksPath /dev/null
echo x > "$MAIN_RAW/README.md"
git -C "$MAIN_RAW" add -A >/dev/null 2>&1
git -C "$MAIN_RAW" commit -q --no-verify -m init >/dev/null 2>&1
PLANS_RAW="$TMPD/plans"; mkdir -p "$PLANS_RAW"
MAIN="$(nodepath "$MAIN_RAW")"; PLANS="$(nodepath "$PLANS_RAW")"

PRELOAD="$AGENTS_DIR/tests/feature-1643-worker-dispatch-lib/spawn-stub.js"
CANNED="$TMPD/canned.json"
CALLLOG="$TMPD/gh-calls.jsonl"
if [ ! -f "$PRELOAD" ]; then
    fail "0: spawn stub missing" "$PRELOAD"
    echo ""
    echo "Total: PASS=$PASS FAIL=$FAIL"
    exit 1
fi

set_gh() {
    node -e 'require("fs").writeFileSync(process.argv[1], JSON.stringify([{stdout: process.argv[2], status: Number(process.argv[3]), stderr: "gh: canned failure"}]))' \
        "$(nodepath "$CANNED")" "$1" "${2:-0}"
}

DOUT=""; DRC=0
dispatch_reconcile() {
    DRC=0
    : > "$CALLLOG"
    DOUT="$(run_with_timeout 90 env \
        "WORKFLOW_PLANS_DIR=$PLANS" \
        "WD_SPAWN_MODULE=$(nodepath "$AGENTS_DIR/bin/worker-dispatch/spawn.js")" \
        "WD_CANNED=$(nodepath "$CANNED")" \
        "WD_CALL_LOG=$(nodepath "$CALLLOG")" \
        node -r "$(nodepath "$PRELOAD")" "$(nodepath "$DISPATCH_JS")" issue-reconcile "$MAIN" "$1" 2>/dev/null)" || DRC=$?
}
field_of() { printf '%s\n' "$DOUT" | sed -n "s/^$1: //p" | head -1; }
write_payload() { printf '%s' "$2" > "$PLANS_RAW/$1.json"; nodepath "$PLANS_RAW/$1.json"; }
# assert_summary <name> <glob> — the glob is intentionally unquoted inside [[ ]].
assert_summary() {
    local got; got="$(field_of summary)"
    if [[ "$got" == $2 ]]; then pass "$1"; else fail "$1" "summary='$got'"; fi
}
jsonl_count() { find "$PLANS_RAW" -name '*.jsonl' 2>/dev/null | wc -l | tr -d ' '; }

SENT='<!-- issue-close-sentinel: appended -->'
THREE_ISSUES="[{\"number\":11,\"title\":\"clean one\",\"comments\":[{\"body\":\"$SENT\"}]},{\"number\":12,\"title\":\"history one\",\"comments\":[]},{\"number\":13,\"title\":\"needs one\",\"comments\":[]}]"

group_artifact_only_needs_reconcile() {
    printf -- '- FEATURE #12: recorded in history\n' > "$MAIN_RAW/docs/history.md"
    set_gh "$THREE_ISSUES" 0
    local p
    p="$(write_payload rc-three "{\"owner_repo\":\"example-owner/example-repo\",\"history_md_path\":\"$MAIN/docs/history.md\",\"limit\":100,\"artifact_dir\":\"$PLANS\"}")"
    dispatch_reconcile "$p"
    assert_eq "artifact/exit0" "0" "$DRC"
    assert_eq "artifact/status" "complete" "$(field_of status)"

    local art rows
    art="$(field_of artifact_path)"
    if [ ! -f "$art" ]; then
        fail "artifact/jsonl-written" "artifact_path='$art' is not a file"
        return
    fi
    pass "artifact/jsonl-written"
    rows="$(grep -c '' "$art" | tr -d ' ')"
    assert_eq "artifact/one-row-only" "1" "$rows"
    if grep -q '"number":13' "$art"; then pass "artifact/row-is-needs-reconcile"
    else fail "artifact/row-is-needs-reconcile" "$(cat "$art")"; fi
    if grep -qE '"number":(11|12)' "$art"; then
        fail "artifact/omits-clean-and-history-only" "$(cat "$art")"
    else
        pass "artifact/omits-clean-and-history-only"
    fi
    assert_summary "artifact/summary-counts-all-verdicts" "*3 scanned*1 to reconcile*1 clean*1 history-only*"
}

# Fence: if the preload ever stopped taking effect the real `gh` would run and
# every Group B assertion below would be measuring the wrong process.
group_spawn_seam() {
    set_gh "$THREE_ISSUES" 0
    local p calls
    p="$(write_payload rc-seam "{\"owner_repo\":\"example-owner/example-repo\",\"limit\":7,\"artifact_dir\":\"$PLANS\"}")"
    dispatch_reconcile "$p"
    calls="$(grep -c '' "$CALLLOG" | tr -d ' ')"
    assert_eq "seam/exactly-one-child-process" "1" "$calls"
    assert_eq "seam/command-is-gh" "gh" "$(node -e 'process.stdout.write(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8").trim()).command)' "$(nodepath "$CALLLOG")")"
    assert_eq "seam/limit-reaches-gh-argv" "issue list --repo example-owner/example-repo --state closed --limit 7 --json number,title,comments" \
        "$(node -e 'process.stdout.write(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8").trim()).args.join(" "))' "$(nodepath "$CALLLOG")")"
}

group_limit_boundaries() {
    local p
    set_gh "$THREE_ISSUES" 0
    # limit at 1: gh is stubbed and still returns 3, so issues.length >= limit —
    # the summary MUST say the scan was truncated or the caller acts on a partial list.
    p="$(write_payload rc-limit1 "{\"owner_repo\":\"example-owner/example-repo\",\"limit\":1,\"artifact_dir\":\"$PLANS\"}")"
    dispatch_reconcile "$p"
    assert_summary "limit/1-reports-truncation" "*reached*incomplete*"

    # limit omitted → registry default (1000); 3 issues is far below it.
    p="$(write_payload rc-limitdef "{\"owner_repo\":\"example-owner/example-repo\",\"artifact_dir\":\"$PLANS\"}")"
    dispatch_reconcile "$p"
    assert_eq "limit/default-status" "complete" "$(field_of status)"
    case "$(field_of summary)" in
        *reached*) fail "limit/default-no-truncation-claim" "summary='$(field_of summary)'" ;;
        *) pass "limit/default-no-truncation-claim" ;;
    esac
}

group_history_sources() {
    local p base
    base="{\"owner_repo\":\"example-owner/example-repo\",\"limit\":100,\"artifact_dir\":\"$PLANS\""
    set_gh "[{\"number\":12,\"title\":\"t\",\"comments\":[]}]" 0

    # absent history.md → nothing satisfies the entry → needs-reconcile
    p="$(write_payload rc-hist-absent "$base,\"history_md_path\":\"$MAIN/docs/nope.md\"}")"
    dispatch_reconcile "$p"
    assert_summary "history/absent-file-counts-as-needs-reconcile" "*1 to reconcile*"

    # present but empty → same verdict, still no crash
    : > "$MAIN_RAW/docs/history-empty.md"
    p="$(write_payload rc-hist-empty "$base,\"history_md_path\":\"$MAIN/docs/history-empty.md\"}")"
    dispatch_reconcile "$p"
    assert_summary "history/empty-file-counts-as-needs-reconcile" "*1 to reconcile*"

    # directory form — the entry lives in a rotated year file
    printf -- '- FEATURE #12: rotated into a year file\n' > "$MAIN_RAW/docs/history/2026.md"
    p="$(write_payload rc-hist-dir "$base,\"history_dir_path\":\"$MAIN/docs/history\"}")"
    dispatch_reconcile "$p"
    assert_summary "history/dir-form-resolves-the-entry" "*0 to reconcile*1 history-only*"
}

group_gh_errors() {
    local name body rc p before after
    while IFS='|' read -r name body rc; do
        [ -z "${name// /}" ] && continue
        name="$(echo "$name" | xargs)"; rc="$(echo "$rc" | xargs)"
        body="${body#"${body%%[![:space:]]*}"}"; body="${body%"${body##*[![:space:]]}"}"
        set_gh "$body" "$rc"
        p="$(write_payload "rc-err-$name" "{\"owner_repo\":\"example-owner/example-repo\",\"limit\":100,\"artifact_dir\":\"$PLANS\"}")"
        before="$(jsonl_count)"
        dispatch_reconcile "$p"
        after="$(jsonl_count)"
        assert_eq "gherr/$name/status" "failed" "$(field_of status)"
        assert_eq "gherr/$name/exit0" "0" "$DRC"
        assert_eq "gherr/$name/artifact-null-form" "(none)" "$(field_of artifact_path)"
        assert_eq "gherr/$name/no-artifact-garbage" "$before" "$after"
    done <<'TABLE'
malformed-json | {not json at all               | 0
not-an-array   | {"number":1}                   | 0
nonzero-exit   | []                             | 4
TABLE

    # Empty array is NOT an error: a repo with no closed issues scans cleanly.
    set_gh "[]" 0
    p="$(write_payload rc-empty-array "{\"owner_repo\":\"example-owner/example-repo\",\"limit\":100,\"artifact_dir\":\"$PLANS\"}")"
    dispatch_reconcile "$p"
    assert_eq "gherr/empty-array/status" "complete" "$(field_of status)"
    assert_summary "gherr/empty-array/summary-zero" "0 scanned*0 to reconcile*"
}

for _g in group_history_boundary group_classify_verdicts group_spawn_seam group_artifact_only_needs_reconcile     group_limit_boundaries group_history_sources group_gh_errors; do
    "$_g"
done

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $((FAIL > 0 ? 1 : 0))
