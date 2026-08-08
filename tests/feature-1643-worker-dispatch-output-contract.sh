#!/usr/bin/env bash
# tests/feature-1643-worker-dispatch-output-contract.sh
# Tests: bin/worker-dispatch/emit.js, bin/worker-dispatch.js, bin/worker-dispatch/workers/test-runner.js, bin/worker-dispatch/workers/worktree-copy.js, bin/worker-dispatch/workers/worktree-backup.js, bin/worker-dispatch/workers/doc-append.js, bin/worker-dispatch/workers/issue-reconcile.js, bin/worker-dispatch/workers/session-close-gate.js
# Tags: worker-dispatch, emit, output-contract, renderer, yaml, status-triple, stub-cli, TL2, scope:issue-specific
#
# Issue #1643 — the plain-script dispatcher replaces six LLM workers. Calling
# skills parse the workers' stdout, so the rendered output must stay BYTE-
# IDENTICAL to the `## Output contract` sections of the agents/*.md files that
# this issue deletes. The literals below were extracted from those files before
# deletion and are the only surviving copy — do not "tidy" them.
#
# Quoting differs per worker and is part of the contract:
#   worktree-copy / issue-reconcile / session-close-gate : UNQUOTED values
#   worktree-backup / doc-append                         : QUOTED values
#   test-runner                                          : fenced YAML block
#
# TL3 gap (what this TL2 test does NOT catch):
#   - Real `gh` / `uv run doc-append.py` / `docker` output shapes: the domain CLIs
#     are stubbed here. The real `gh issue list` flag contract is covered by
#     tests/TL3-worker-dispatch-gh-contract.sh (RUN_TL3-gated).
#   - Whether the calling SKILL.md parsers actually accept the bytes — only a real
#     skill run exercises that.
# Closest-to-action mitigation: bin/check-verification-gate.sh category
# skill-orchestration fires at WORKFLOW_USER_VERIFIED preflight.

set -u

if command -v timeout >/dev/null 2>&1 && [ -z "${_WD1643_OC_INNER:-}" ]; then
    _WD1643_OC_INNER=1 timeout 420 bash "$0" "$@"
    exit $?
fi

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
nodepath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi; }
DISPATCH_JS="$AGENTS_DIR/bin/worker-dispatch.js"

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
# removed. Each now belongs to the worker module that replaced it:
#   bin/worker-dispatch/workers/worktree-copy.js   (was worktree-copy-worker)
#   bin/worker-dispatch/workers/worktree-backup.js (was worktree-backup-worker)
#   bin/worker-dispatch/workers/doc-append.js      (was doc-append-worker)
#   bin/worker-dispatch/workers/issue-reconcile.js (was issue-reconcile-worker)
#   bin/worker-dispatch/workers/session-close-gate.js (was session-close-worker)
#   bin/worker-dispatch/workers/test-runner.js     (was test-runner)
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
//   status: pass | fail | timeout | runner-error
//   exit_code: <int>
//   duration_seconds: <int>
//   summary: <=300-char human summary
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
if (!["pass", "fail", "timeout", "runner-error"].includes(status)) bad(`status '${status}'`);
if (!/^exit_code:\s*-?\d+$/m.test(raw)) bad("exit_code not an int");
if (!/^duration_seconds:\s*\d+$/m.test(raw)) bad("duration_seconds not an int");
const summary = (raw.match(/^summary:\s*(.*)$/m) || ["", ""])[1];
if (summary.length > 300) bad(`summary ${summary.length} chars > 300`);
const ft = raw.slice(raw.indexOf("failing_tests:")).split("log_tail:")[0];
if (status === "pass" && !/^failing_tests:\s*\[\]\s*$/m.test(ft)) bad("status pass requires 'failing_tests: []'");
const ftItems = (ft.match(/^\s+- /gm) || []).length;
if (ftItems > 10) bad(`failing_tests ${ftItems} > 10`);
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
  if (!/^RUN_CONTRACT: PASS=\d+ FAIL=\d+ SKIP=\d+ EXECUTED=\d+$/.test(lines[0] || "")) {
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
cat > "$MAIN_RAW/tests/run-all.sh" <<'RASTUB'
#!/usr/bin/env bash
echo "Results: PASS=1  FAIL=0  SKIP=0"
echo "RUN_CONTRACT: PASS=1 FAIL=0 SKIP=0 EXECUTED=1"
exit 0
RASTUB
chmod +x "$MAIN_RAW/tests/run-all.sh"

write_payload() {
    printf '%s' "$2" > "$PLANS_RAW/$1.json"
    nodepath "$PLANS_RAW/$1.json"
}

dispatch() {
    local worker="$1" pfile="$2"
    run_with_timeout 90 env "PATH=$STUB:$PATH" "WORKFLOW_PLANS_DIR=$PLANS" \
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
}

# ===========================================================================
# Group 2 — failure path: status failed, artifact_path is the null form
# ===========================================================================
group_failure() {
    local name worker json p out st art
    # Domain CLI absent/failing: PATH is emptied of the stubs.
    while IFS='|' read -r name worker json; do
        [ -z "${name// /}" ] && continue
        name="$(echo "$name" | xargs)"; worker="$(echo "$worker" | xargs)"
        impl_missing "failure/$name" "$DISPATCH_JS" "bin/worker-dispatch.js" && continue
        p="$(write_payload "bad-$name" "$json")"
        out="$TMPD/fail-$name.txt"
        run_with_timeout 90 env "WORKFLOW_PLANS_DIR=$PLANS" \
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
