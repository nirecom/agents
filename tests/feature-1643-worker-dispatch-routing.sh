#!/usr/bin/env bash
# tests/feature-1643-worker-dispatch-routing.sh
# Tests: bin/worker-dispatch.js, bin/worker-dispatch/registry.js
# Tags: worker-dispatch, routing, exit-code-contract, prototype-pollution, fail-closed, TL1, TL2, scope:issue-specific
#
# Issue #1643 — the dispatcher is the one door six workers are reached through.
# The per-worker suites prove each worker behaves; this file proves the DOOR
# behaves: that every registered name reaches a real module, that names which
# exist on every JavaScript object cannot masquerade as registered workers, and
# that a worker misbehaving becomes a rendered failure the caller can parse
# rather than a Node crash the caller cannot.
#
# The exit-code contract is the load-bearing part. Callers branch on it: exit 0
# means "read the contract on stdout", exit 2 means "the invocation was unusable
# and there is nothing to read". A worker that throws must NOT turn into exit 1
# with a stack trace, because a caller that only knows 0 and 2 would then treat
# a crash as an unknown-worker error.
#
# TL3 gap (what this TL1+TL2 test does NOT catch):
#   - The real skills invoking the dispatcher with an argv shape no test uses;
#     tests/feature-1643-worker-dispatch-callers.sh covers the caller side by
#     source scan, and tests/TL3-worker-dispatch-gh-contract.sh is the gated
#     real-environment tier.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED
# preflight via bin/check-verification-gate.sh category: skill-orchestration.

set -u

if command -v timeout >/dev/null 2>&1 && [ -z "${_WD1643_ROUTE_INNER:-}" ]; then
    _WD1643_ROUTE_INNER=1 timeout 420 bash "$0" "$@"
    exit $?
fi

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DISPATCH_JS="$AGENTS_DIR/bin/worker-dispatch.js"
REGISTRY_JS="$AGENTS_DIR/bin/worker-dispatch/registry.js"
DATA_JS="$AGENTS_DIR/hooks/lib/worker-dispatch-registry.js"
PRELOAD="$AGENTS_DIR/tests/feature-1643-worker-dispatch-lib/routing-stub.js"
nodepath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi; }

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; [ -n "${2:-}" ] && echo "    detail: $2"; FAIL=$((FAIL + 1)); }
assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then pass "$name"
    else fail "$name" "want=$(printf '%q' "$want") got=$(printf '%q' "$got")"; fi
}
assert_has() {
    local name="$1" needle="$2" hay="$3"
    case "$hay" in
        *"$needle"*) pass "$name" ;;
        *) fail "$name" "want substring '$needle' in '$hay'" ;;
    esac
}
assert_lacks() {
    local name="$1" needle="$2" hay="$3"
    case "$hay" in
        *"$needle"*) fail "$name" "unwanted substring '$needle' present" ;;
        *) pass "$name" ;;
    esac
}
run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

for f in "$DISPATCH_JS" "$REGISTRY_JS" "$DATA_JS" "$PRELOAD"; do
    if [ ! -f "$f" ]; then
        fail "0: fixture prerequisites missing" "$f"
        echo ""
        echo "Total: PASS=$PASS FAIL=$FAIL"
        exit 1
    fi
done

TMPD="$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/wd-route-$$")"
mkdir -p "$TMPD"
trap 'rm -rf "$TMPD"' EXIT

MAIN_RAW="$TMPD/mainrepo"
mkdir -p "$MAIN_RAW/tests"
git -C "$MAIN_RAW" init -q -b main
git -C "$MAIN_RAW" config user.email "test@example.com"
git -C "$MAIN_RAW" config user.name "Test"
git -C "$MAIN_RAW" config core.hooksPath /dev/null
echo init > "$MAIN_RAW/README.md"
printf '#!/usr/bin/env bash\nexit 0\n' > "$MAIN_RAW/tests/run-all.sh"
git -C "$MAIN_RAW" add -A >/dev/null 2>&1
git -C "$MAIN_RAW" commit -q --no-verify -m initial >/dev/null 2>&1

PLANS_RAW="$TMPD/plans"; mkdir -p "$PLANS_RAW"
OUTSIDE_RAW="$TMPD/outside"; mkdir -p "$OUTSIDE_RAW"
MAIN="$(nodepath "$MAIN_RAW")"
PLANS="$(nodepath "$PLANS_RAW")"

printf '{"cwd":"%s","timeout_seconds":30}' "$MAIN" > "$PLANS_RAW/ok.json"
cp "$PLANS_RAW/ok.json" "$OUTSIDE_RAW/ok.json"
# A second payload for a status-triple worker — the shape assertions below are
# about the unquoted three-line contract, which test-runner does not use.
printf '{"session_id":"sess-route","plans_dir":"%s","artifact_dir":"%s"}' "$PLANS" "$PLANS" \
    > "$PLANS_RAW/triple.json"

DOUT=""; DERR=""; DRC=0
# dispatch <worker> <main-root> <payload-path> — no preload; the real registry.
dispatch() {
    DRC=0
    DERR="$TMPD/stderr.txt"
    DOUT="$(run_with_timeout 60 env "WORKFLOW_PLANS_DIR=$PLANS" \
        node "$(nodepath "$DISPATCH_JS")" "$1" "$2" "$3" 2>"$DERR")" || DRC=$?
}
# dispatch_stub <mode> [worker] [payload-basename] — routes to the misbehaving
# worker staged by the preload. The worker choice selects the RENDERER, which is
# what the result-shape assertions are really about.
dispatch_stub() {
    local worker="${2:-test-runner}" pfile="${3:-ok.json}"
    DRC=0
    DERR="$TMPD/stderr.txt"
    DOUT="$(run_with_timeout 60 env "WORKFLOW_PLANS_DIR=$PLANS" \
        "WD_MODE=$1" "WD_REGISTRY_MODULE=$(nodepath "$REGISTRY_JS")" \
        node -r "$(nodepath "$PRELOAD")" "$(nodepath "$DISPATCH_JS")" \
        "$worker" "$MAIN" "$PLANS/$pfile" 2>"$DERR")" || DRC=$?
}
field_of() { printf '%s\n' "$DOUT" | sed -n "s/^$1: //p" | head -1; }

# ===========================================================================
# Group 1 (TL1) — every registered name reaches a loadable module
#
# Driven from the SSOT name list, so a seventh worker added to the registry
# without a module is a failure here rather than a runtime surprise.
# ===========================================================================
group_registry_routing() {
    local names count name got
    names="$(node -e '
process.stdout.write(require(process.argv[1]).WORKER_NAMES.join("\n"));
' "$(nodepath "$DATA_JS")")"
    count="$(printf '%s\n' "$names" | grep -c '.')"
    # Guard against a false green: an empty name list would pass the loop below
    # by never running it.
    if [ "$count" -ge 6 ]; then pass "routing/registry-lists-at-least-six-workers"
    else fail "routing/registry-lists-at-least-six-workers" "count=$count"; fi

    while IFS= read -r name; do
        [ -z "$name" ] && continue
        got="$(node -e '
const reg = require(process.argv[1]);
const mod = reg.loadModule(process.argv[2]);
process.stdout.write(mod === null ? "null" : typeof mod.run);
' "$(nodepath "$REGISTRY_JS")" "$name" 2>&1)" || got="<threw>"
        assert_eq "routing/$name/module-loads-with-a-run-function" "function" "$got"
    done <<EOF
$names
EOF

    # And no module may exist that the registry does not name — an unreachable
    # worker is either dead code or a name the guard has never vetted.
    got="$(node -e '
const fs = require("fs"), path = require("path");
const data = require(process.argv[1]);
const dir = path.join(path.dirname(process.argv[2]), "workers");
const files = fs.readdirSync(dir).filter((f) => f.endsWith(".js")).map((f) => f.slice(0, -3));
const orphans = files.filter((f) => !data.WORKER_NAMES.includes(f));
process.stdout.write(orphans.join(","));
' "$(nodepath "$DATA_JS")" "$(nodepath "$REGISTRY_JS")")"
    assert_eq "routing/no-unregistered-worker-modules" "" "$got"
}

# ===========================================================================
# Group 2 (TL2) — names every object already has must not route
#
# registry.get() uses an own-property lookup. If it ever regressed to a plain
# `data.workers[name]`, `__proto__` and `constructor` would both return truthy
# objects and the dispatcher would carry them past the enum wall.
# ===========================================================================
group_prototype_names() {
    local name
    for name in __proto__ constructor toString hasOwnProperty valueOf prototype; do
        dispatch "$name" "$MAIN" "$PLANS/ok.json"
        assert_eq "proto/$name/exit2" "2" "$DRC"
        assert_eq "proto/$name/nothing-rendered-on-stdout" "" "$DOUT"
        assert_has "proto/$name/stderr-says-unknown-worker" "unknown worker" "$(cat "$DERR")"
    done
}

# ===========================================================================
# Group 3 (TL2) — payload residency is enforced at the dispatcher boundary
#
# These are rendered failures, not exit 2: the worker name and main-root were
# usable, so there is a contract to report into. The rows dispatch `test-runner`,
# so the contract they report into is the test-runner-yaml one, whose status
# vocabulary is pass | fail | timeout | runner-error — the value has to be a
# member of that set, because skills/run-tests/SKILL.md RNT-9 branches on it.
# ===========================================================================
group_payload_residency() {
    local desc arg
    while IFS='|' read -r desc arg; do
        [ -z "${desc// }" ] && continue
        desc="${desc%"${desc##*[![:space:]]}"}"
        arg="${arg## }"; arg="${arg%% }"
        arg="${arg//OUTSIDE/$(nodepath "$OUTSIDE_RAW")}"
        arg="${arg//PLANS/$PLANS}"
        dispatch test-runner "$MAIN" "$arg"
        assert_eq "residency/$desc/exit0" "0" "$DRC"
        assert_eq "residency/$desc/status" "runner-error" "$(field_of status)"
        assert_has "residency/$desc/summary-blames-the-payload" "payload:" "$(field_of summary)"
    done <<'TABLE'
absolute-path-outside-plans | OUTSIDE/ok.json
traversal-escapes-plans     | PLANS/../outside/ok.json
bare-relative-path          | ok.json
dot-relative-path           | ./ok.json
missing-file-inside-plans   | PLANS/no-such-payload.json
TABLE

    # Control: the same payload INSIDE plans-dir is accepted, so the failures
    # above are about residency and not about the fixture being unusable.
    dispatch test-runner "$MAIN" "$PLANS/ok.json"
    assert_eq "residency/control-inside-plans/exit0" "0" "$DRC"
    assert_eq "residency/control-inside-plans/not-a-payload-failure" "" \
        "$(field_of summary | grep -o '^payload:' || true)"
}

# ===========================================================================
# Group 4 (TL2) — a misbehaving worker still produces a parseable contract
#
# Both rows route through `test-runner`, so the failure is spoken in the
# test-runner-yaml vocabulary (pass | fail | timeout | runner-error).
# ===========================================================================
group_worker_throws() {
    dispatch_stub throw-error
    assert_eq "throws/exit0-not-1" "0" "$DRC"
    assert_eq "throws/status" "runner-error" "$(field_of status)"
    assert_has "throws/summary-names-the-worker-error" "worker error: boom inside the worker" "$(field_of summary)"
    # A stack trace on stderr would leak absolute host paths into a transcript.
    assert_lacks "throws/no-stack-frames-on-stderr" "    at " "$(cat "$DERR")"
    assert_lacks "throws/no-node-crash-banner" "Node.js v" "$(cat "$DERR")"

    dispatch_stub throw-string
    assert_eq "throws-string/exit0" "0" "$DRC"
    assert_eq "throws-string/status" "runner-error" "$(field_of status)"
    assert_has "throws-string/summary-degrades-gracefully" "worker error:" "$(field_of summary)"
}

group_bad_result_shape() {
    dispatch_stub return-empty session-close-gate triple.json
    assert_eq "shape/empty/exit0" "0" "$DRC"
    assert_eq "shape/empty/status-defaults-to-failed" "failed" "$(field_of status)"
    assert_eq "shape/empty/summary-has-a-placeholder" "no summary" "$(field_of summary)"
    assert_eq "shape/empty/artifact-has-a-placeholder" "(none)" "$(field_of artifact_path)"

    dispatch_stub return-noisy session-close-gate triple.json
    assert_eq "shape/noisy/exit0" "0" "$DRC"
    # Double quotes are illegal in an unquoted contract slot, and a summary that
    # spanned two lines would forge a second contract field.
    assert_lacks "shape/noisy/no-double-quotes-in-status" '"' "$(field_of status)"
    assert_eq "shape/noisy/summary-stays-on-one-line" "line one line two" "$(field_of summary)"
    assert_eq "shape/noisy/rendered-line-count" "3" "$(printf '%s\n' "$DOUT" | grep -c '.')"
}

# ===========================================================================
# Group 6 (TL2) — a worker that RETURNS a degenerate value is reported honestly
#
# `emit.render()` coerces a non-object result into a failure render before the
# renderers dereference `result.status`. Without that, a worker returning null or
# undefined was an uncaught TypeError: exit 1, nothing parseable on stdout, and a
# stack trace on stderr carrying absolute host paths straight into a transcript.
# A bare string was worse in a quieter way — it rendered with a DEFAULTED status
# and looked like an ordinary failure, hiding the fact that the worker never
# produced a result at all.
#
# So three things are pinned per row: exit 0, the rejection status of the row's
# own renderer, and a summary that names the degenerate shape. Plus the negative
# the fix was really about — stderr carries no stack frames and no absolute host
# path. Both renderers are driven, because the coercion has to speak whichever
# vocabulary the caller is parsing.
# ===========================================================================
group_degenerate_result() {
    local mode worker pfile want_status shape err
    while IFS='|' read -r mode worker pfile want_status shape; do
        [ -z "${mode// }" ] && continue
        mode="$(echo "$mode" | xargs)"; worker="$(echo "$worker" | xargs)"
        pfile="$(echo "$pfile" | xargs)"; want_status="$(echo "$want_status" | xargs)"
        shape="$(echo "$shape" | xargs)"

        dispatch_stub "$mode" "$worker" "$pfile"
        err="$(cat "$DERR")"

        assert_eq "degenerate/$mode/$worker/exit0" "0" "$DRC"
        assert_eq "degenerate/$mode/$worker/status" "$want_status" "$(field_of status)"
        assert_has "degenerate/$mode/$worker/summary-names-the-shape" \
            "worker returned no usable result ($shape)" "$(field_of summary)"
        # The whole point of the coercion: no crash escaping to stderr.
        assert_lacks "degenerate/$mode/$worker/no-stack-frames-on-stderr" "    at " "$err"
        assert_lacks "degenerate/$mode/$worker/no-node-crash-banner" "Node.js v" "$err"
        # A stack frame would carry the fixture path AND the dispatcher's own
        # install path; neither belongs in a transcript.
        assert_lacks "degenerate/$mode/$worker/no-fixture-path-on-stderr" "$TMPD" "$err"
        assert_lacks "degenerate/$mode/$worker/no-install-path-on-stderr" "$AGENTS_DIR" "$err"

        if [ "$worker" = "test-runner" ]; then
            assert_eq "degenerate/$mode/$worker/exit-code-field" "-1" "$(field_of exit_code)"
            assert_eq "degenerate/$mode/$worker/failing-tests-empty" "[]" "$(field_of failing_tests)"
        else
            assert_eq "degenerate/$mode/$worker/artifact-null-form" "(none)" "$(field_of artifact_path)"
        fi
    done <<'TABLE'
return-null      | test-runner        | ok.json     | runner-error | null
return-undefined | test-runner        | ok.json     | runner-error | undefined
return-string    | test-runner        | ok.json     | runner-error | string
return-null      | session-close-gate | triple.json | failed       | null
return-undefined | session-close-gate | triple.json | failed       | undefined
return-string    | session-close-gate | triple.json | failed       | string
TABLE
}

group_registry_routing
group_prototype_names
group_payload_residency
group_worker_throws
group_bad_result_shape
group_degenerate_result

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $((FAIL > 0 ? 1 : 0))
