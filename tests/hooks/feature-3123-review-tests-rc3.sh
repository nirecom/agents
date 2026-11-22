#!/usr/bin/env bash
# Tests: skills/review-tests/scripts/run-codex-review-loop.sh
# Tags: feature-3123, feature-2478, review-tests, warnings-accepted, codex-review-loop, cc-fallback, scope:issue-specific, TL2
#
# #3123 T8 / T10 (S5-a, S5-b): the review-tests rc 3 marker is accept evidence, not an exit 8
# guard. A rerun on the same input enters the loop; WARNINGS_ACCEPTED (real workflow-mark.js,
# no workflow OFF) restores complete after exit 3 with or without a fallback raw, and after a
# fallback round that ended exit 4 (append failure, malformed report), adding no round and no
# ledger row. A recorded fallback round replaces the rc 3 marker (rc 1 -> continuing, 0 -> none).
# TL3 gap: a real claude -p session running the test-reviewer agent and the PostToolUse hook.

set -uo pipefail
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
# shellcheck source=tests/bin/feature-2937-review-loop/fixture.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-2937-review-loop/fixture.sh"
# shellcheck source=tests/bin/feature-2478-fallback/helpers.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-2478-fallback/helpers.sh"
# Pin both dirs here too: a parent does not inherit the fixture's pin (rules/test/fixture-isolation.md).
# Same FX_TMP as the fixture, so the dirs do not move; the fixture's EXIT trap removes readonly FX_TMP.
harness_isolate "$FX_TMP"

# The review-scope fingerprint is taken from the staged diff: stage a test and its target.
mkdir -p "$REPO/hooks"
printf '#!/usr/bin/env bash\n# Tests: hooks/impl.js\n' > "$REPO/tests/rc3.sh"
printf 'impl\n' > "$REPO/hooks/impl.js"
git -C "$REPO" add tests/rc3.sh hooks/impl.js

# FX_APPEND_FAIL=1: the copied bin/review-rounds meets a directory at the record path on append.
mv "$ROOT/bin/review-rounds" "$ROOT/bin/review-rounds-real"
cat > "$ROOT/bin/review-rounds" <<'STUB'
#!/usr/bin/env node
"use strict";
const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");
const argv = process.argv.slice(2);
const opt = (k) => { const i = argv.indexOf(`--${k}`); return i < 0 ? "" : argv[i + 1]; };
const real = () => spawnSync(process.execPath, [path.join(__dirname, "review-rounds-real"), ...argv], { stdio: "inherit" }).status;
if (argv[0] !== "append" || process.env.FX_APPEND_FAIL !== "1") process.exit(real());
const rec = path.join(process.env.WORKFLOW_STATE_DIR, `${opt("session")}.control`, `${opt("format")}-review-rounds.jsonl`);
const aside = `${rec}.fx-aside`;
const had = fs.existsSync(rec);
if (had) fs.renameSync(rec, aside);
fs.mkdirSync(rec, { recursive: true });
const rc = real();
fs.rmSync(rec, { recursive: true, force: true });
if (had) fs.renameSync(aside, rec);
process.exit(rc);
STUB
# seed.js <state-file> <sid> — a state with review_tests in_progress.
cat > "$FX_TMP/seed.js" <<'JS'
const fs = require("fs");
const [file, sid] = process.argv.slice(2);
const steps = {};
for (const s of ["workflow_init", "clarify_intent", "research", "outline", "detail", "branching_complete", "write_tests", "write_code"]) steps[s] = { status: "complete" };
steps.review_tests = { status: "in_progress" };
for (const s of ["run_tests", "review_security", "docs", "review_docs", "user_verification", "cleanup", "pre_final_report_gate", "final_report"]) steps[s] = { status: "pending" };
fs.writeFileSync(file, JSON.stringify({ version: 1, session_id: sid, steps, closes_issues: [3123] }));
JS
# input.js <sid> <cwd> — the PostToolUse input of the WARNINGS_ACCEPTED sentinel.
cat > "$FX_TMP/input.js" <<'JS'
const [sid, cwd] = process.argv.slice(2);
const command = 'echo "<<WORKFLOW_REVIEW_TESTS_WARNINGS_ACCEPTED: user accepts remaining gaps>>"';
process.stdout.write(JSON.stringify({ session_id: sid, tool_name: "Bash", tool_input: { command }, cwd }));
JS

F=test-review
PA=(--prestaged-producer test-reviewer --prestaged-exec PERFORMED)
term() { printf '%s/test-review-terminal.txt' "$(ctl "$1")"; }
cont() { printf '%s/test-review-continuing.txt' "$(ctl "$1")"; }
line1() { if [ -f "$1" ]; then sed -n '1p' "$1" | tr -d '\r'; else printf 'absent'; fi; }
fp_now() {
    node -e 'process.stdout.write(require(process.argv[1]).computeReviewScopeFingerprint(process.argv[2]).fingerprint || "")' \
        "$(np "$SCRIPT_CHECKOUT_ROOT/hooks/workflow-gate/review-tests-evidence.js")" "$(np "$REPO")"
}
seed_rt() { seed_sid "$1"; node "$(np "$FX_TMP/seed.js")" "$(np "$WORKFLOW_STATE_DIR/$1.json")" "$1"; }
rt_status() {
    node -e 'const s = require(process.argv[1]).readState(process.argv[2]); process.stdout.write(String(((s && s.steps && s.steps.review_tests) || {}).status))' \
        "$(np "$SCRIPT_CHECKOUT_ROOT/hooks/workflow-state")" "$1"
}
# accept <sid> — the real workflow-mark.js hook on WARNINGS_ACCEPTED (sets A_OUT).
accept() {
    local in
    ( cd "$REPO" || exit 1; CLAUDE_PROJECT_DIR="$(np "$REPO")" node "$SCRIPT_CHECKOUT_ROOT/bin/check-glossary-drift" \
        --session "$1" --step review_tests --record ) >/dev/null 2>&1
    in="$(node "$(np "$FX_TMP/input.js")" "$1" "$(np "$REPO")")"
    A_OUT="$( cd "$REPO" || exit 1; printf '%s' "$in" | env -u CLAUDE_PROJECT_DIR node "$SCRIPT_CHECKOUT_ROOT/hooks/workflow-mark.js" 2>&1 )"
}
# trace <sid> — ROUND_FILE | rows | ledger rows, as one comparable line.
trace() { printf '%s|%s|%s' "$(clf_read "$(round_file "$1" "$F")")" "$(rows "$1" "$F")" "$(ledger_rows "$1" "$F" | grep -c .)"; }
# exit3 <sid> — codex unusable: the wrapper ends exit 3 and leaves the rc 3 marker.
exit3() {
    seed_rt "$1"
    FX_RV=1 wrap review-tests "$1"
    assert_eq "$1 setup: the wrapper exits 3" "3" "$W_RC"
    assert_eq "$1 setup: the rc 3 marker is armed" "3" "$(line1 "$(term "$1")")"
}
# fresh_raw <sid> <line...> — the fallback reviewer's raw, newer than the rc 3 marker.
fresh_raw() {
    local sid="$1" r
    shift
    r="$(raw_of "$sid" "$F")"
    report "$r" "$@"
    touch -d "@$(( $(date +%s) + 2 ))" "$r"
}
accepted() {
    assert_eq "$1: review_tests restored to complete" "complete" "$(rt_status "$2")"
    assert_not_contains "$1: the sentinel is applied" "NOT APPLIED" "$A_OUT"
    assert_eq "$1: no round, no row, no ledger row from the acceptance" "$3" "$(trace "$2")"
}

echo "=== T8 D1: exit 3 with no fallback at all is accepted ==="
case_begin "exit3-without-fallback-is-accepted" "skills/review-tests/scripts/run-codex-review-loop.sh"
exit3 d1
before="$(trace d1)"
assert_eq "the marker pins the current scope" "$(fp_now)" "$(sed -n '2p' "$(term d1)" | tr -d '\r')"
accept d1
accepted "D1" d1 "$before"
case_end

echo "=== T8 D2: the rc 3 marker is not an exit 8 guard ==="
case_begin "rc3-marker-rerun-on-the-same-input-enters-the-loop" "skills/review-tests/scripts/run-codex-review-loop.sh"
exit3 d2
wrap review-tests d2
assert_eq "the rerun on the unchanged input reaches the reviewer (round 1, exit 1)" "1" "$W_RC"
assert_not_contains "no terminal-exit refusal" "terminal exit" "$W_ERR"
assert_eq "the reviewed round replaces the rc 3 marker" "absent" "$(line1 "$(term d2)")"
assert_eq "and leaves continuing evidence" "1" "$(line1 "$(cont d2)")"
case_end

case_begin "rc3-marker-outside-a-repository-skips-instead-of-exit-8" "skills/review-tests/scripts/run-codex-review-loop.sh"
exit3 d2o
mkdir -p "$FX_TMP/outside"
wrap review-tests d2o "$FX_TMP/outside"
assert_eq "outside a repository the rc 3 marker does not fail closed (exit 3, not 8)" "3" "$W_RC"
assert_eq "the marker is kept" "3" "$(line1 "$(term d2o)")"
case_end

case_begin "exit8-hint-names-the-accept-sentinel-only-for-guarding-terminals" "skills/review-tests/scripts/run-codex-review-loop.sh"
W="$SCRIPT_CHECKOUT_ROOT/skills/review-tests/scripts/run-codex-review-loop.sh"
pat="$(sed -n '/^exit8_hint()/,/^}/p' "$W" | grep -E "^[[:space:]]+[0-9|]+\)" | head -n 1 | tr -d ' ')"
assert_contains "exit8_hint still offers the sentinel for rc 2" "2" "$pat"
assert_not_contains "exit8_hint no longer lists rc 3 (it never reaches exit 8)" "3" "$pat"
seed_rt d2g
mkdir -p "$(ctl d2g)"
printf '2\n%s\n' "$(fp_now)" > "$(term d2g)"
wrap review-tests d2g
assert_eq "an rc 2 terminal on the same input still exits 8" "8" "$W_RC"
assert_contains "and names the accept sentinel" "WORKFLOW_REVIEW_TESTS_WARNINGS_ACCEPTED" "$W_ERR"
case_end

echo "=== T8 D3: a fallback round that ends exit 4 still leaves an acceptable rc 3 ==="
case_begin "fallback-round-with-failed-append-is-accepted" "skills/review-tests/scripts/run-codex-review-loop.sh"
exit3 d3a
before="$(trace d3a)"
fresh_raw d3a APPROVED
FX_RV=1 FX_APPEND_FAIL=1 wrapa review-tests d3a --prestaged-report "$(raw_of d3a "$F")" "${PA[@]}"
assert_eq "the fallback round reaches the append and fails (exit 4)" "4" "$W_RC"
assert_not_contains "it is not refused by the guard" "terminal exit" "$W_ERR"
assert_not_contains "it is not refused as unsupported" "not permitted" "$W_ERR"
assert_eq "the rc 3 marker survives the exit 4" "3" "$(line1 "$(term d3a)")"
assert_eq "the failed round is undone" "$before" "$(trace d3a)"
accept d3a
accepted "D3-a" d3a "$before"
assert_contains "accepted as the fallback that recorded no round" "exit 3, fallback ended without a recorded round" "$A_OUT"
case_end

case_begin "exit3-without-a-fallback-raw-is-accepted-as-unreviewed" "skills/review-tests/scripts/run-codex-review-loop.sh"
exit3 d3b
before="$(trace d3b)"
assert_eq "no fallback raw" "missing" "$(clf_file_state "$(raw_of d3b "$F")")"
accept d3b
accepted "D3-b" d3b "$before"
assert_contains "accepted as an unreviewed scope" "unreviewed scope accepted" "$A_OUT"
case_end

echo "=== T8 D4: a malformed fallback report (exit 4) is still accepted ==="
case_begin "malformed-fallback-report-is-accepted" "skills/review-tests/scripts/run-codex-review-loop.sh"
exit3 d4
before="$(trace d4)"
fresh_raw d4
FX_RV=1 wrapa review-tests d4 --prestaged-report "$(raw_of d4 "$F")" "${PA[@]}"
assert_eq "an empty verdict block halts (exit 4)" "4" "$W_RC"
assert_not_contains "not the guard's exit 8" "terminal exit" "$W_ERR"
assert_eq "the rc 3 marker survives" "3" "$(line1 "$(term d4)")"
accept d4
accepted "D4" d4 "$before"
case_end

echo "=== T10: a recorded fallback round replaces the rc 3 marker ==="
case_begin "recorded-fallback-round-replaces-the-rc3-marker" "skills/review-tests/scripts/run-codex-review-loop.sh"
exit3 t10c
fresh_raw t10c NEEDS_REVISION "C1. [HIGH] the marker outlives the round"
FX_RV=1 wrapa review-tests t10c --prestaged-report "$(raw_of t10c "$F")" "${PA[@]}"
assert_eq "rc 1: the fallback round continues" "1" "$W_RC"
assert_eq "rc 1: one row" "1" "$(rows t10c "$F")"
assert_eq "rc 1: the rc 3 marker is gone" "absent" "$(line1 "$(term t10c)")"
assert_eq "rc 1: continuing evidence is armed" "1" "$(line1 "$(cont t10c)")"
exit3 t10a
fresh_raw t10a APPROVED
FX_RV=1 wrapa review-tests t10a --prestaged-report "$(raw_of t10a "$F")" "${PA[@]}"
assert_eq "rc 0: the fallback round approves" "0" "$W_RC"
assert_eq "rc 0: the rc 3 marker is gone" "absent" "$(line1 "$(term t10a)")"
assert_eq "rc 0: no continuing evidence" "absent" "$(line1 "$(cont t10a)")"
case_end

finish
