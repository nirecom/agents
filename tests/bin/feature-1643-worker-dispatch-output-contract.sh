#!/usr/bin/env bash
# tests/bin/feature-1643-worker-dispatch-output-contract.sh
# Tests: bin/worker-dispatch/emit.js, bin/worker-dispatch.js, bin/worker-dispatch/workers/test-runner.js, bin/worker-dispatch/workers/worktree-copy.js, bin/worker-dispatch/workers/worktree-backup.js, bin/worker-dispatch/workers/doc-append.js, bin/worker-dispatch/workers/issue-reconcile.js, bin/worker-dispatch/workers/session-close-gate.js
# Tags: worker-dispatch, emit, output-contract, renderer, yaml, status-triple, stub-cli, TL2, scope:issue-specific
# TL3 gap (what this TL2 test does NOT catch):
#   - Real `gh` / `uv run doc-append.py` / `docker` output shapes (stubbed here; the
#     `gh issue list` flag contract is tests/bin/TL3-worker-dispatch-gh-contract.sh).
#   - Whether the calling SKILL.md parsers actually accept the bytes.
# Closest-to-action mitigation: bin/check-verification-gate.sh category
# skill-orchestration fires at WORKFLOW_USER_VERIFIED preflight.

set -u
# Issue #1643 — the plain-script dispatcher replaces six LLM workers. Calling skills
# parse their stdout, so output must stay BYTE-IDENTICAL to the `## Output contract`
# sections of the deleted agents/*.md files. The literals below are the only
# surviving copy — do not "tidy" them. Quoting is part of the contract:
#   worktree-copy / issue-reconcile / session-close-gate : UNQUOTED values
#   worktree-backup / doc-append                         : QUOTED values
#   test-runner                                          : fenced YAML block

if command -v timeout >/dev/null 2>&1 && [ -z "${_WD1643_OC_INNER:-}" ]; then
    _WD1643_OC_INNER=1 timeout 420 bash "$0" "$@"
    exit $?
fi

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
nodepath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi; }
DISPATCH_JS="$SCRIPT_CHECKOUT_ROOT/bin/worker-dispatch.js"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
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
impl_missing() {
    if [ -e "$2" ]; then return 1; fi
    fail "$1 — implementation missing: $3"; return 0
}

TMPD="$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/wd-oc-$$")"
mkdir -p "$TMPD"
trap 'rm -rf "$TMPD"' EXIT

# ---------------------------------------------------------------------------
# Frozen literals — transcribed verbatim, before deletion, from the
# `## Output contract` sections of the six agents/*.md subagents that #1643
# removed. Each now belongs to bin/worker-dispatch/workers/<worker>.js
# (worktree-copy, worktree-backup, doc-append, issue-reconcile,
# session-close-gate [was session-close-worker], test-runner).
# ---------------------------------------------------------------------------
SPECS="$TMPD/specs"; mkdir -p "$SPECS"

cat > "$SPECS/worktree-copy.spec" <<'EOF'
status: complete|partial|failed
summary: <N files copied; WORKTREE_NOTES.md written>
artifact_path: <absolute path to log file, or (none)>
EOF

cat > "$SPECS/worktree-backup.spec" <<'EOF'
status: dry_run_complete|copied|partial|skipped|failed
summary: "<N files / X MB to .worktree-backup/branch/; N docker bind-mounts>"
artifact_path: "<absolute manifest or dry-run txt path, or (none) on failure>"
EOF

cat > "$SPECS/doc-append.spec" <<'EOF'
status: appended|noop|failed
summary: "<one-line description <=80 chars>"
artifact_path: "<absolute log path or null>"
EOF

cat > "$SPECS/issue-reconcile.spec" <<'EOF'
status: complete|failed
summary: <N scanned; M to reconcile>
artifact_path: <absolute path to JSONL file, or (none) on failure>
EOF

cat > "$SPECS/session-close-gate.spec" <<'EOF'
status: complete|failed
summary: <gate_action=proceed|yield; SC-4 findings: N; SC-5 alert_phase: V>
artifact_path: <absolute path to gate JSON, or (none) on failure>
EOF

# ---------------------------------------------------------------------------
# Contract checker (prints OK, or MISMATCH:<reason>)
# ---------------------------------------------------------------------------
CHECK_JS="$TMPD/contract-check.js"
cat > "$CHECK_JS" <<'CHECKJS'
const fs = require("fs");
const spec = fs.readFileSync(process.argv[2], "utf8").replace(/\r\n/g, "\n").split("\n").filter(Boolean);
const actual = fs.readFileSync(process.argv[3], "utf8").replace(/\r\n/g, "\n").split("\n").filter((l) => l.trim() !== "");
const bad = (m) => { process.stdout.write("MISMATCH:" + m); process.exit(0); };
if (actual.length !== spec.length) bad(`line-count want=${spec.length} got=${actual.length}`);
for (let i = 0; i < spec.length; i++) {
  const sm = spec[i].match(/^([a-z_]+): (.*)$/);
  const am = actual[i].match(/^([a-z_]+): (.*)$/);
  if (!am) bad(`line${i + 1} not a 'key: value' line`);
  if (sm[1] !== am[1]) bad(`line${i + 1} key want=${sm[1]} got=${am[1]}`);
  const tmpl = sm[2], val = am[2];
  const quoted = tmpl.startsWith('"');
  if (quoted && !(val.startsWith('"') && val.endsWith('"') && val.length >= 2)) bad(`${sm[1]} must be quoted`);
  if (!quoted && val.startsWith('"')) bad(`${sm[1]} must NOT be quoted`);
  if (!tmpl.includes("<")) {
    const allowed = tmpl.split("|");
    if (!allowed.includes(val)) bad(`${sm[1]} value '${val}' not in ${allowed.join("|")}`);
  } else if (val === "") bad(`${sm[1]} empty`);
}
process.stdout.write("OK");
CHECKJS

YAML_CHECK_JS="$TMPD/yaml-check.js"
cat > "$YAML_CHECK_JS" <<'YCJS'
// The `## Output contract` (fenced YAML) of the deleted agents/test-runner.md,
// now owned by bin/worker-dispatch/workers/test-runner.js:
//   status: pass | fail | timeout | runner-error | unrunnable | skip (last two: #2501)
//   exit_code: <int>   duration_seconds: <int>   summary: <=300-char human summary
//   failing_tests:
//     - <up to 10 test names>
//   log_tail: |
//     <last <=40 lines>
// `failing_tests: []` MUST be present when `status: pass`.
const fs = require("fs");
const raw = fs.readFileSync(process.argv[2], "utf8").replace(/\r\n/g, "\n");
const bad = (m) => { process.stdout.write("MISMATCH:" + m); process.exit(0); };
const lines = raw.split("\n");
const top = lines.filter((l) => /^[a-z_]+:/.test(l)).map((l) => l.split(":")[0]);
const want = ["status", "exit_code", "duration_seconds", "summary", "failing_tests", "log_tail"];
if (top.join(",") !== want.join(",")) bad(`top-level keys want=${want.join(",")} got=${top.join(",")}`);
const status = (raw.match(/^status:\s*(\S+)/m) || [])[1];
if (!["pass", "fail", "timeout", "runner-error", "unrunnable", "skip"].includes(status)) bad(`status '${status}'`);
if (!/^exit_code:\s*-?\d+$/m.test(raw)) bad("exit_code not an int");
if (!/^duration_seconds:\s*\d+$/m.test(raw)) bad("duration_seconds not an int");
const summary = (raw.match(/^summary:\s*(.*)$/m) || ["", ""])[1];
if (summary.length > 300) bad(`summary ${summary.length} chars > 300`);
const ft = raw.slice(raw.indexOf("failing_tests:")).split("log_tail:")[0];
if (status === "pass" && !/^failing_tests:\s*\[\]\s*$/m.test(ft)) bad("status pass requires 'failing_tests: []'");
for (const l of ft.split("\n").slice(1)) if (l.trim() !== "" && !/^  - '.*'$/.test(l)) bad("failing_tests item not a quoted list entry");
if (!/^log_tail: \|\s*$/m.test(raw)) bad("log_tail must use the '|' block scalar");
const tail = raw.split(/^log_tail: \|\s*$/m)[1] || "";
const tailLines = tail.split("\n").filter((l) => l.trim() !== "");
if (tailLines.length > 40) bad(`log_tail ${tailLines.length} lines > 40`);
for (const l of tailLines) if (l !== "" && !/^\s\s+/.test(l)) bad("log_tail line not indented");
// #1378: when the suite emitted exactly ONE well-formed contract line, the
// renderer must surface it as the first top-level line, where the hook's parser
// reads it — and must not leave a second copy indented inside log_tail, because
// the parser's exactly-one rule reads two lines as ambiguous and demotes.
//
// The condition is "the fixture produced exactly one contract line", NOT
// `status: pass`: with zero or two contract lines, emitting none is the CORRECT
// behaviour, so keying on status would turn right answers into failures.
const CONTRACT_RE = /^[ \t]*RUN_CONTRACT: PASS=\d+ FAIL=\d+ SKIP=\d+ EXECUTED=\d+/gm;
const contractLines = raw.match(CONTRACT_RE) || [];
if (contractLines.length === 1) {
  // #2501: every stub here is a current run-all, and the renderer keeps the parsed shape (C3).
  if (!/^RUN_CONTRACT: PASS=\d+ FAIL=\d+ SKIP=\d+ EXECUTED=\d+ UNRUNNABLE=\d+ TIMEOUT=\d+$/.test(lines[0] || "")) {
    bad(`single contract line must be the first line, got '${lines[0]}'`);
  }
  if (/^[ \t]+RUN_CONTRACT:/m.test(tail)) bad("contract line must not remain inside log_tail");
}
process.stdout.write("OK");
YCJS

check_triple() { node "$CHECK_JS" "$(nodepath "$1")" "$(nodepath "$2")" 2>&1; }

# ---------------------------------------------------------------------------
# Fixtures: repo, PLANS_DIR, stub domain CLIs
# ---------------------------------------------------------------------------
MAIN_RAW="$TMPD/repo"; mkdir -p "$MAIN_RAW/docs" "$MAIN_RAW/tests"
git -C "$MAIN_RAW" init -q -b main
git -C "$MAIN_RAW" config user.email "test@example.com"
git -C "$MAIN_RAW" config user.name "Test"
git -C "$MAIN_RAW" config core.hooksPath /dev/null
echo x > "$MAIN_RAW/README.md"
git -C "$MAIN_RAW" add -A >/dev/null 2>&1
git -C "$MAIN_RAW" commit -q --no-verify -m init >/dev/null 2>&1
PLANS_RAW="$TMPD/plans"; mkdir -p "$PLANS_RAW"
WF_PIN="$(nodepath "$TMPD/wf")"; mkdir -p "$TMPD/wf"   # #2558: worker logs live under the workflow dir
MAIN="$(nodepath "$MAIN_RAW")"; PLANS="$(nodepath "$PLANS_RAW")"

STUB="$TMPD/stub"; mkdir -p "$STUB"
# `gh` stub — mirrors the real CLI by REJECTING unknown flags (notably --page),
# so a stub can never bless an interface the real gh does not have.
cat > "$STUB/gh" <<'GHSTUB'
#!/usr/bin/env bash
[ "$1" = "issue" ] && [ "$2" = "list" ] || { echo "unknown gh command" >&2; exit 1; }
shift 2
while [ $# -gt 0 ]; do
  case "$1" in
    --repo|--state|--limit|--json|-L|-s|-q) shift 2 ;;
    --) shift ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done
echo '[{"number":1,"title":"t","comments":[]}]'
GHSTUB
cat > "$STUB/uv" <<'UVSTUB'
#!/usr/bin/env bash
echo "appended"
UVSTUB
cat > "$STUB/docker" <<'DKSTUB'
#!/usr/bin/env bash
exit 0
DKSTUB
chmod +x "$STUB/gh" "$STUB/uv" "$STUB/docker"
# Failing domain CLIs for Group 2. Without them the call reaches the run's command guard: the
# worker env drops the test id, so run-all reports a hit charged to no test (#2669).
FAILSTUB="$TMPD/failstub"; mkdir -p "$FAILSTUB"
for _cli in gh uv docker; do
    printf '#!/usr/bin/env bash\necho "stub %s: failing on purpose" >&2\nexit 1\n' "$_cli" > "$FAILSTUB/$_cli"
    chmod +x "$FAILSTUB/$_cli"
done
# Windows: Node's shell-less spawn finds only gh.exe/gh.com, never the extensionless stub, and the
# worker env drops NODE_OPTIONS, so the cli-stub.sh preload cannot reach it either. A node copy
# named gh.exe exits 1 on `gh issue list ...` (node cannot load a module named `issue`): issue-
# reconcile reports failed in both groups instead of reaching the guard. The stubs exist first,
# so a link here never redirects a write to the node binary.
if [ "$(node -p process.platform)" = "win32" ]; then
    _node_bin="$(node -p 'process.execPath')"
    for _d in "$STUB" "$FAILSTUB"; do
        ln "$_node_bin" "$_d/gh.exe" 2>/dev/null || cp "$_node_bin" "$_d/gh.exe"
    done
fi

# `tests/run-all.sh` stub for the test-runner row.
#
# Stub inventory (#1378). Four test files carry a synthetic run-all.sh output:
# this one, feature-1643-worker-dispatch-canary-no-side-effect.sh:112,
# feature-1643-worker-dispatch-sentinel-stdout.sh:153 and
# feature-1643-worker-dispatch-test-runner-behavior.sh. Only THIS one verifies
# the emitted output contract, so only this one gains `RUN_CONTRACT:` — the
# sentinel-stdout stub deliberately emits hostile text and the canary stub exists
# to prove nothing was written, and giving either a contract line would make them
# assert something they are not about.
STUB_MODE="$MAIN_RAW/tests/stub-mode"
# $STUB_MODE selects the run: absent = one pass; `unrunnable` = a clean exit with one
# unlaunched file; `many-fail` = twelve failing files.
cat > "$MAIN_RAW/tests/run-all.sh" <<'RASTUB'
#!/usr/bin/env bash
mode="$(cat "$(dirname "$0")/stub-mode" 2>/dev/null)"
case "$mode" in
  unrunnable)
    echo "UNRUNNABLE: tests/x/a.Tests.ps1 (pwsh)"
    echo "Missing runtimes: pwsh"
    echo "Results: PASS=1  FAIL=0  SKIP=0"
    echo "RUN_CONTRACT: PASS=1 FAIL=0 SKIP=0 EXECUTED=1 UNRUNNABLE=1 TIMEOUT=0"
    exit 0 ;;
  many-fail)
    for i in 1 2 3 4 5 6 7 8 9 10 11 12; do echo "FAIL: tests/x/f$i.sh (exit 1)"; done
    echo "Results: PASS=0  FAIL=12  SKIP=0"
    echo "RUN_CONTRACT: PASS=0 FAIL=12 SKIP=0 EXECUTED=12 UNRUNNABLE=0 TIMEOUT=0"
    exit 1 ;;
esac
echo "Results: PASS=1  FAIL=0  SKIP=0"
echo "RUN_CONTRACT: PASS=1 FAIL=0 SKIP=0 EXECUTED=1 UNRUNNABLE=0 TIMEOUT=0"
exit 0
RASTUB
chmod +x "$MAIN_RAW/tests/run-all.sh"

write_payload() {
    printf '%s' "$2" > "$PLANS_RAW/$1.json"
    nodepath "$PLANS_RAW/$1.json"
}

dispatch() {
    local worker="$1" pfile="$2"
    run_with_timeout 90 env -u CLAUDE_CODE_SESSION_ID "PATH=$STUB:$PATH" "WORKFLOW_PLANS_DIR=$PLANS" "WORKFLOW_STATE_DIR=$WF_PIN" \
        node "$(nodepath "$DISPATCH_JS")" "$worker" "$MAIN" "$pfile" 2>/dev/null
}

# ===========================================================================
# Group 0 — false-green fence: the checker must reject deviations
# ===========================================================================
group_checker_selftest() {
    local f="$TMPD/fx.txt"
    printf 'status: complete\nsummary: 3 files copied; WORKTREE_NOTES.md written\nartifact_path: /tmp/a.log\n' > "$f"
    assert_eq "checker/accepts-good-unquoted" "OK" "$(check_triple "$SPECS/worktree-copy.spec" "$f")"

    printf 'status: copied\nsummary: "1 file / 2 MB"\nartifact_path: "/tmp/m.json"\n' > "$f"
    assert_eq "checker/accepts-good-quoted" "OK" "$(check_triple "$SPECS/worktree-backup.spec" "$f")"

    printf 'status: copied\nsummary: 1 file / 2 MB\nartifact_path: "/tmp/m.json"\n' > "$f"
    case "$(check_triple "$SPECS/worktree-backup.spec" "$f")" in
        MISMATCH:*) pass "checker/rejects-missing-quotes" ;;
        *) fail "checker/rejects-missing-quotes — accepted unquoted summary" ;;
    esac

    printf 'summary: x\nstatus: complete\nartifact_path: /tmp/a.log\n' > "$f"
    case "$(check_triple "$SPECS/worktree-copy.spec" "$f")" in
        MISMATCH:*) pass "checker/rejects-reordered-keys" ;;
        *) fail "checker/rejects-reordered-keys — accepted wrong key order" ;;
    esac

    printf 'status: done\nsummary: x\nartifact_path: /tmp/a.log\n' > "$f"
    case "$(check_triple "$SPECS/worktree-copy.spec" "$f")" in
        MISMATCH:*) pass "checker/rejects-unknown-status" ;;
        *) fail "checker/rejects-unknown-status — accepted status 'done'" ;;
    esac

    printf 'status: pass\nexit_code: 0\nduration_seconds: 1\nsummary: ok\nfailing_tests: []\nlog_tail: |\n  a\n' > "$f"
    assert_eq "checker/yaml-accepts-good" "OK" "$(node "$YAML_CHECK_JS" "$(nodepath "$f")" 2>&1)"
    printf 'status: pass\nexit_code: 0\nduration_seconds: 1\nsummary: ok\nlog_tail: |\n  a\n' > "$f"
    case "$(node "$YAML_CHECK_JS" "$(nodepath "$f")" 2>&1)" in
        MISMATCH:*) pass "checker/yaml-rejects-missing-failing-tests" ;;
        *) fail "checker/yaml-rejects-missing-failing-tests" ;;
    esac
    printf 'status: skipped\nexit_code: 0\nduration_seconds: 1\nsummary: ok\nfailing_tests: []\nlog_tail: |\n  a\n' > "$f"
    case "$(node "$YAML_CHECK_JS" "$(nodepath "$f")" 2>&1)" in
        MISMATCH:*) pass "checker/yaml-rejects-unknown-status" ;;
        *) fail "checker/yaml-rejects-unknown-status" ;;
    esac
    printf "status: fail\nexit_code: 1\nduration_seconds: 1\nsummary: ok\nfailing_tests:\n  - 'a.sh'\n  bare\nlog_tail: |\n  a\n" > "$f"
    case "$(node "$YAML_CHECK_JS" "$(nodepath "$f")" 2>&1)" in
        MISMATCH:*) pass "checker/yaml-rejects-malformed-failing-item" ;;
        *) fail "checker/yaml-rejects-malformed-failing-item" ;;
    esac
}

# ===========================================================================
# Group 1 — success path: rendered stdout matches the frozen contract
# ===========================================================================
group_success() {
    local name worker json p out
    while IFS='|' read -r name worker json; do
        [ -z "${name// /}" ] && continue
        name="$(echo "$name" | xargs)"; worker="$(echo "$worker" | xargs)"
        impl_missing "contract/$name" "$DISPATCH_JS" "bin/worker-dispatch.js" && continue
        json="${json//@MAIN@/$MAIN}"; json="${json//@PLANS@/$PLANS}"
        p="$(write_payload "ok-$name" "$json")"
        out="$TMPD/out-$name.txt"
        dispatch "$worker" "$p" > "$out"
        assert_eq "contract/$name" "OK" "$(check_triple "$SPECS/$worker.spec" "$out")"
    done <<'TABLE'
worktree-copy      | worktree-copy      | {"worktree_path":"@MAIN@","branch":"main","session_id":"s1"}
worktree-backup    | worktree-backup    | {"mode":"dry_run","worktree_path":"@MAIN@","branch":"main","session_id":"s1"}
doc-append         | doc-append         | {"mode":"history","category":"FEATURE","subject":"s","background":"b","changes":"c","commits":"abc","cwd":"@MAIN@","session_id":"s1"}
issue-reconcile    | issue-reconcile    | {"owner_repo":"example-owner/example-repo","limit":10,"session_id":"s1"}
session-close-gate | session-close-gate | {"session_id":"s1","plans_dir":"@PLANS@"}
TABLE
}

group_test_runner_yaml() {
    local p out
    impl_missing "contract/test-runner" "$DISPATCH_JS" "bin/worker-dispatch.js" && return
    p="$(write_payload "ok-test-runner" "{\"test_args\":[],\"cwd\":\"$MAIN\",\"timeout_seconds\":60}")"
    out="$TMPD/out-test-runner.txt"
    dispatch test-runner "$p" > "$out"
    assert_eq "contract/test-runner" "OK" "$(node "$YAML_CHECK_JS" "$(nodepath "$out")" 2>&1)"

    # #2501: a clean exit with an unlaunched file renders `unrunnable` and names the runtime.
    printf 'unrunnable' > "$STUB_MODE"
    out="$TMPD/out-test-runner-unrunnable.txt"
    dispatch test-runner "$p" > "$out"
    assert_eq "contract/test-runner-unrunnable" "OK" "$(node "$YAML_CHECK_JS" "$(nodepath "$out")" 2>&1)"
    assert_eq "contract/test-runner-unrunnable/contract-line" "RUN_CONTRACT: PASS=1 FAIL=0 SKIP=0 EXECUTED=1 UNRUNNABLE=1 TIMEOUT=0" "$(sed -n '1p' "$out" | tr -d '\r')"
    assert_eq "contract/test-runner-unrunnable/status" "unrunnable" "$(sed -n 's/^status: //p' "$out" | tr -d '\r')"
    assert_eq "contract/test-runner-unrunnable/failing-tests-empty" "failing_tests: []" "$(grep '^failing_tests:' "$out" | tr -d '\r')"
    case "$(sed -n 's/^summary: //p' "$out")" in
        *"Missing runtimes: pwsh"*) pass "contract/test-runner-unrunnable/summary-names-runtime" ;;
        *) fail "contract/test-runner-unrunnable/summary-names-runtime — got=$(sed -n 's/^summary: //p' "$out")" ;;
    esac

    # #2431: every failing path is listed; twelve is past the old cap of ten.
    printf 'many-fail' > "$STUB_MODE"
    out="$TMPD/out-test-runner-many-fail.txt"
    dispatch test-runner "$p" > "$out"
    assert_eq "contract/test-runner-many-fail" "OK" "$(node "$YAML_CHECK_JS" "$(nodepath "$out")" 2>&1)"
    assert_eq "contract/test-runner-many-fail/status" "fail" "$(sed -n 's/^status: //p' "$out" | tr -d '\r')"
    assert_eq "contract/test-runner-many-fail/all-twelve-listed" "12" "$(grep -c "^  - 'tests/x/f[0-9]*\.sh'" "$out")"
    assert_eq "contract/test-runner-many-fail/last-one-listed" "1" "$(grep -c "^  - 'tests/x/f12\.sh'" "$out")"
    rm -f "$STUB_MODE"
}

# ===========================================================================
# Group 2 — failure path: status failed, artifact_path is the null form
# ===========================================================================
group_failure() {
    local name worker json p out st art
    # Domain CLI failing: the failing stubs replace the ones Group 1 used.
    while IFS='|' read -r name worker json; do
        [ -z "${name// /}" ] && continue
        name="$(echo "$name" | xargs)"; worker="$(echo "$worker" | xargs)"
        impl_missing "failure/$name" "$DISPATCH_JS" "bin/worker-dispatch.js" && continue
        p="$(write_payload "bad-$name" "$json")"
        out="$TMPD/fail-$name.txt"
        run_with_timeout 90 env -u CLAUDE_CODE_SESSION_ID "PATH=$FAILSTUB:$PATH" "WORKFLOW_PLANS_DIR=$PLANS" "WORKFLOW_STATE_DIR=$WF_PIN" \
            node "$(nodepath "$DISPATCH_JS")" "$worker" "$MAIN" "$p" > "$out" 2>/dev/null
        st="$(sed -n '1s/^status: //p' "$out")"
        assert_eq "failure/$name/status" "failed" "$st"
        # Skipped-Because: the quoted workers may render "(none)" and doc-append
        # documents `null`; the frozen .md literals do not pin one form for the
        # failure case, so quotes are stripped before comparison rather than
        # asserting a form the contract never fixed.
        art="$(sed -n '3s/^artifact_path: //p' "$out" | tr -d '"')"
        case "$art" in
            "(none)"|null) pass "failure/$name/artifact-null-form" ;;
            *) fail "failure/$name/artifact-null-form — got=$(printf '%q' "$art")" ;;
        esac
        assert_eq "failure/$name/contract-shape" "OK" "$(check_triple "$SPECS/$worker.spec" "$out")"
    done <<'TABLE'
missing-field      | worktree-copy      | {"branch":"main"}
bad-type           | worktree-backup    | {"mode":123}
unknown-key        | doc-append         | {"mode":"history","evil":"x"}
cli-nonzero        | issue-reconcile    | {"owner_repo":"example-owner/example-repo","limit":10,"session_id":"s1"}
TABLE
    # The failure must come from the failing stub, not from an earlier fault (#2669): the stub exits 1 and names itself.
    local stub_rc=0 stub_err
    stub_err="$("$FAILSTUB/gh" issue list --repo o/r 2>&1 >/dev/null)" || stub_rc=$?
    assert_eq "failure/stub/exit-status" "1" "$stub_rc"
    case "$stub_err" in
        *"stub gh: failing on purpose"*) pass "failure/stub/marker" ;;
        *) fail "failure/stub/marker — got=$stub_err" ;;
    esac
}

# ===========================================================================
# Group 3 — the gh stub itself must reject the flag the old worker used
# ===========================================================================
group_gh_stub_fidelity() {
    local rc=0
    "$STUB/gh" issue list --repo o/r --state closed --limit 5 --json number >/dev/null 2>&1 || rc=$?
    assert_eq "gh-stub/accepts-real-flags" "0" "$rc"
    rc=0
    "$STUB/gh" issue list --repo o/r --page 2 >/dev/null 2>&1 || rc=$?
    if [ "$rc" -ne 0 ]; then pass "gh-stub/rejects-page-flag"
    else fail "gh-stub/rejects-page-flag — stub accepted --page (would bless a fake interface)"; fi
}

group_checker_selftest
group_gh_stub_fidelity
group_success
group_test_runner_yaml
group_failure

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $((FAIL > 0 ? 1 : 0))
