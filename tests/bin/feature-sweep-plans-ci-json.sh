#!/usr/bin/env bash
# tests/bin/feature-sweep-plans-ci-json.sh
# Tests: bin/sweep-plans.sh, bin/sweep-plans/summary.sh
# Tags: scope:common, TL2, sweep, plans, workflow-plans, ci-mode, json, encoder, node-less, maintenance, bin, pwsh-not-required
# The --ci-mode JSON line is encoded by bash alone: with node absent from PATH the run
# still prints exactly one JSON line (classifier_failed=1, nothing deleted), the no-dir
# path does too, and every string (errors, approval tokens / reasons, gate_id) escapes
# \ " and U+0000-U+001F so it round-trips through JSON.parse. node on PATH is the
# positive control: same key set. The test's own node only parses the captured output.
# TL3 gap: none — the real script runs under a PATH stub dir that omits node.

set -uo pipefail
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

command -v node >/dev/null 2>&1 || { echo "SKIP: node not available (needed to parse the output)"; exit 77; }

readonly T_ROOT="$(make_tmp)"
trap 'chmod -R u+rwX "$T_ROOT" 2>/dev/null; rm -rf "$T_ROOT"' EXIT
harness_isolate "$T_ROOT/wf"
unset CLAUDE_CODE_SESSION_ID 2>/dev/null || true
export CLAUDE_TRANSCRIPT_BASE_DIR="$T_ROOT/transcripts"
mkdir -p "$CLAUDE_TRANSCRIPT_BASE_DIR"

SWEEP="$SCRIPT_CHECKOUT_ROOT/bin/sweep-plans.sh"
SUMMARY="$SCRIPT_CHECKOUT_ROOT/bin/sweep-plans/summary.sh"
U="a1b2c3d4-e5f6-4890-abcd-ef1234567890"
BASH_ABS="$(command -v bash)"
NODE_ABS="$(command -v node)"
OUTF="$T_ROOT/stdout.txt"
ERRF="$T_ROOT/stderr.txt"
SEQ=0

# ─── PATH stub dirs: wrappers exec the real tool by absolute path ───────────
STUB_TOOLS=(bash cat cygpath date dirname env find grep head ls mkdir paste rm sed sort stat touch tr uname)
# build_stub_dir <dir> <tool...> — one wrapper per tool found on the real PATH.
build_stub_dir() {
  local d="$1" t real; shift
  mkdir -p "$d"
  for t in "$@"; do
    real="$(command -v "$t" 2>/dev/null)" || continue
    [[ "$real" == /* ]] || continue
    printf '#!%s\nexec %q "$@"\n' "$BASH_ABS" "$real" > "$d/$t"
    chmod +x "$d/$t"
  done
}
STUB_NONODE="$T_ROOT/stub-no-node"
STUB_NODE="$T_ROOT/stub-with-node"
build_stub_dir "$STUB_NONODE" "${STUB_TOOLS[@]}"
build_stub_dir "$STUB_NODE" "${STUB_TOOLS[@]}" node

# ─── Output inspection (the test's own node) ────────────────────────────────
JCHECK_JS="$T_ROOT/jcheck.js"
cat > "$JCHECK_JS" <<'JS'
const fs = require("fs");
const [op, file, ...rest] = process.argv.slice(2);
const out = (s) => process.stdout.write(s);
const raw = fs.readFileSync(file, "utf8");
const lines = raw.split("\n");
if (op === "shape") {
  if (raw.length === 0) return out("empty stdout");
  if (lines[lines.length - 1] !== "") return out("no trailing newline");
  if (lines.length !== 2) return out((lines.length - 1) + " lines");
  let o;
  try { o = JSON.parse(lines[0]); } catch (e) { return out("not JSON: " + e.message); }
  return out(o !== null && typeof o === "object" && !Array.isArray(o) ? "ok" : "not a JSON object");
}
if (op === "noctl") return out(/[\u0000-\u001f]/.test(lines[0]) ? "raw control char in the JSON line" : "ok");
if (op === "contains-hex") {
  const needle = Buffer.from(rest[0], "hex").toString("utf8").toLowerCase();
  return out(lines[0].toLowerCase().includes(needle) ? "ok" : "missing " + JSON.stringify(needle));
}
let o;
try { o = JSON.parse(lines[0]); } catch (e) { return out("<bad-json>"); }
const get = (p) => {
  let v = o;
  for (const k of p.split(".")) {
    if (v === null || typeof v !== "object" || !(k in v)) return undefined;
    v = v[k];
  }
  return v;
};
if (op === "get") { const v = get(rest[0]); return out(v === undefined ? "<missing>" : JSON.stringify(v)); }
if (op === "eqfile") {
  const v = get(rest[0]); const want = fs.readFileSync(rest[1], "utf8");
  return out(v === want ? "ok" : "want=" + JSON.stringify(want) + " got=" + JSON.stringify(v));
}
if (op === "keys") return out(Object.keys(o).sort().join(","));
if (op === "numbers") {
  const bad = rest.filter((k) => typeof o[k] !== "number");
  return out(bad.length ? "not numbers: " + bad.join(",") : "ok");
}
out("<unknown op>");
JS
jc() { node "$(np "$JCHECK_JS")" "$1" "$(np "$2")" "${@:3}" 2>&1; }
check() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1" "want=$(printf '%q' "$2") got=$(printf '%q' "$3")"; fi; }
expect_present() { if [[ -e "$2" ]]; then pass "$1"; else fail "$1" "removed: ${2##*/}"; fi; }
expect_gone() { if [[ -e "$2" ]]; then fail "$1" "still present: ${2##*/}"; else pass "$1"; fi; }

# The counter key list comes from summary.sh itself (SSOT), plus the four non-counter keys.
mapfile -t COUNTERS < <(bash -c 'source "$1"; printf "%s\n" "${SUMMARY_COUNTERS[@]}"' _ "$SUMMARY" | tr -d '\r')
EXPECTED_KEYS="$(printf '%s\n' "${COUNTERS[@]}" approval_candidates approval_skipped errors gate_id | LC_ALL=C sort | paste -sd, -)"

# expect_json_shape <label> — stdout is one JSON object line with every key, counters numeric.
expect_json_shape() {
  check "$1 stdout is exactly one JSON object line" "ok" "$(jc shape "$OUTF")"
  check "$1 key set is SUMMARY_COUNTERS + errors/approval_candidates/approval_skipped/gate_id" \
    "$EXPECTED_KEYS" "$(jc keys "$OUTF")"
  check "$1 every SUMMARY_COUNTERS key is a JSON number" "ok" "$(jc numbers "$OUTF" "${COUNTERS[@]}")"
}

backdate() { touch -d "60 days ago" "$1" 2>/dev/null || touch -t 202401010000 "$1" 2>/dev/null || true; }
FIX_FILES=("$U-intent.md" "$U-user-requested-progress.md" "$U-note-scratch.md" "$U-survey-code.md"
  "$U-outline-codex-round-1-raw.md" "$U-x-history-staging.md" "$U-note-intent.md")
FIX_NON_PLAN=("$U-note-scratch.md" "$U-survey-code.md" "$U-outline-codex-round-1-raw.md")
mk_fixture() {
  local n
  SEQ=$((SEQ + 1)); D="$T_ROOT/plans-$1-$SEQ"
  mkdir -p "$D"
  for n in "${FIX_FILES[@]}"; do printf 'x\n' > "$D/$n"; backdate "$D/$n"; done
}

# run_stubbed <stub dir> <plans dir> <args...> — sets RC; stdout -> OUTF, stderr -> ERRF.
run_stubbed() {
  local stub="$1" pd="$2"; shift 2
  RC=0
  WORKFLOW_PLANS_DIR="$pd" SWEEP_AGE_DAYS=30 run_with_timeout 120 \
    env PATH="$stub" "$BASH_ABS" "$SWEEP" "$@" >"$OUTF" 2>"$ERRF" || RC=$?
}

case_begin "C0-stub-path-precondition" "bin/sweep-plans.sh"
P_RC=0; env PATH="$STUB_NONODE" "$BASH_ABS" -c 'command -v node' >/dev/null 2>&1 || P_RC=$?
if [[ "$P_RC" -ne 0 ]]; then pass "C0 node is unreachable under the no-node stub PATH"; else fail "C0 node is unreachable under the no-node stub PATH" "node resolved"; fi
P_RC=0; env PATH="$STUB_NODE" "$BASH_ABS" -c 'command -v node' >/dev/null 2>&1 || P_RC=$?
check "C0 node is reachable under the with-node stub PATH" "0" "$P_RC"
for t in find stat date sort paste rm; do
  if [[ -x "$STUB_NONODE/$t" ]]; then pass "C0 the stub dir carries $t"; else fail "C0 the stub dir carries $t" "missing"; fi
done
case_end

case_begin "C1-node-less-ci-mode-run" "bin/sweep-plans.sh"
mk_fixture c1
run_stubbed "$STUB_NONODE" "$D" --ci-mode
check "C1 node-less --ci-mode run exits 0" "0" "$RC"
expect_json_shape "C1"
check "C1 classifier_failed=1 (the classifier needs node)" "1" "$(jc get "$OUTF" classifier_failed)"
check "C1 scanned=7" "7" "$(jc get "$OUTF" scanned)"
check "C1 files_removed=0" "0" "$(jc get "$OUTF" files_removed)"
check "C1 errors is an empty array" "[]" "$(jc get "$OUTF" errors)"
check "C1 approval_candidates is an empty array" "[]" "$(jc get "$OUTF" approval_candidates)"
check "C1 approval_skipped is an empty array" "[]" "$(jc get "$OUTF" approval_skipped)"
check "C1 gate_id is null" "null" "$(jc get "$OUTF" gate_id)"
for n in "${FIX_FILES[@]}"; do expect_present "C1 every file is unknown and kept: $n" "$D/$n"; done
if grep -q 'retention classifier unavailable (node not found)' "$ERRF"; then
  pass "C1 stderr names the missing node"
else
  fail "C1 stderr names the missing node" "stderr=$(head -c 300 "$ERRF")"
fi
case_end

case_begin "C2-node-less-no-dir" "bin/sweep-plans.sh"
run_stubbed "$STUB_NONODE" "$T_ROOT/does-not-exist" --ci-mode
check "C2 node-less no-dir run exits 0" "0" "$RC"
expect_json_shape "C2"
for c in "${COUNTERS[@]}"; do check "C2 $c=0" "0" "$(jc get "$OUTF" "$c")"; done
check "C2 errors is an empty array" "[]" "$(jc get "$OUTF" errors)"
check "C2 approval_candidates is an empty array" "[]" "$(jc get "$OUTF" approval_candidates)"
check "C2 approval_skipped is an empty array" "[]" "$(jc get "$OUTF" approval_skipped)"
check "C2 gate_id is null" "null" "$(jc get "$OUTF" gate_id)"
case_end

# ─── _summary_json driven directly, node off PATH ──────────────────────────
# driver.sh <summary.sh> <error|cand|skip|gate> <value file>
DRIVER="$T_ROOT/driver.sh"
cat > "$DRIVER" <<'SH'
set -euo pipefail
source "$1"
CI_MODE=1
sweep_plans_counters_init
APPROVAL_CANDIDATES=(); APPROVAL_SKIPPED=(); gate_id=""
scanned=12
v=""
IFS= read -r -d '' v < "$3" || true
case "$2" in
  error) errors=("$v") ;;
  cand) APPROVAL_CANDIDATES=("$v") ;;
  skip) APPROVAL_SKIPPED=("$v") ;;
  gate) gate_id="$v" ;;
esac
_summary_json
SH
# drive <mode> <value> — writes the value to VALF and runs the driver; sets RC.
VALF="$T_ROOT/value.bin"
drive() {
  printf '%s' "$2" > "$VALF"
  RC=0
  run_with_timeout 30 env PATH="$STUB_NONODE" "$BASH_ABS" "$DRIVER" "$SUMMARY" "$1" "$VALF" \
    >"$OUTF" 2>"$ERRF" || RC=$?
}

# C3 rows: parallel arrays <name> / <value> / <hex of the exact escape the line must contain, or ->.
C3_NAMES=(); C3_VALUES=(); C3_ESC=()
c3_row() { C3_NAMES+=("$1"); C3_VALUES+=("$2"); C3_ESC+=("$3"); }
c3_row plain "rm-failed:/tmp/plans/x.md" -
c3_row double-quote 'say "hi"' 5c22
c3_row backslash 'C:\Users\x' 5c5c
c3_row tab $'a\tb' 615c7462
c3_row newline $'line1\nline2' 315c6e6c
c3_row carriage-return $'a\rb' 615c7262
c3_row trailing-newline $'end\n' 645c6e
c3_row control-0x01 $'a\x01b' 615c7530303031
c3_row control-0x1f $'a\x1fb' 615c7530303166
c3_row mixed $'a"b\\c\td' 615c22625c5c635c7464
c3_row unicode-non-ascii $'\xe6\x97\xa5\xe6\x9c\xac\xe8\xaa\x9e-\xe3\x83\x95\xe3\x82\xa1\xe3\x82\xa4\xe3\x83\xab.md' -
c3_row path-with-spaces "rm-failed:/tmp/a dir/x y.md" -

case_begin "C3-string-escape-round-trip" "bin/sweep-plans/summary.sh"
for i in "${!C3_NAMES[@]}"; do
  name="${C3_NAMES[$i]}"
  drive error "${C3_VALUES[$i]}"
  check "C3 [$name] node-less _summary_json exits 0" "0" "$RC"
  check "C3 [$name] stdout is exactly one JSON object line" "ok" "$(jc shape "$OUTF")"
  check "C3 [$name] no raw control char in the line" "ok" "$(jc noctl "$OUTF")"
  check "C3 [$name] errors[0] round-trips unchanged" "ok" "$(jc eqfile "$OUTF" errors.0 "$(np "$VALF")")"
  check "C3 [$name] errors has exactly one entry" "1" "$(jc get "$OUTF" errors.length)"
  if [[ "${C3_ESC[$i]}" != "-" ]]; then
    check "C3 [$name] the line carries the spec escape" "ok" "$(jc contains-hex "$OUTF" "${C3_ESC[$i]}")"
  fi
done
case_end

case_begin "C3b-approval-arrays-and-gate-id" "bin/sweep-plans/summary.sh"
drive cand "$U"$'\t1\t2\t1700000000'
check "C3b [candidate] exits 0" "0" "$RC"
check "C3b [candidate] stdout is exactly one JSON object line" "ok" "$(jc shape "$OUTF")"
check "C3b [candidate] token is the session string" "\"$U\"" "$(jc get "$OUTF" approval_candidates.0.token)"
check "C3b [candidate] plan_files is the number 1" "1" "$(jc get "$OUTF" approval_candidates.0.plan_files)"
check "C3b [candidate] user_requested_files is the number 2" "2" "$(jc get "$OUTF" approval_candidates.0.user_requested_files)"
check "C3b [candidate] newest is the number 1700000000" "1700000000" "$(jc get "$OUTF" approval_candidates.0.newest)"
check "C3b [candidate] exactly one candidate" "1" "$(jc get "$OUTF" approval_candidates.length)"
check "C3b [candidate] scanned=12 is a number" "12" "$(jc get "$OUTF" scanned)"
check "C3b [candidate] empty gate_id encodes as null" "null" "$(jc get "$OUTF" gate_id)"
drive cand $'@empty\t0\t3\t1690000000'
check "C3b [@empty candidate] token is \"@empty\"" '"@empty"' "$(jc get "$OUTF" approval_candidates.0.token)"
check "C3b [@empty candidate] plan_files is the number 0" "0" "$(jc get "$OUTF" approval_candidates.0.plan_files)"
check "C3b [@empty candidate] user_requested_files is the number 3" "3" "$(jc get "$OUTF" approval_candidates.0.user_requested_files)"
drive skip "$U"$'\tchanged-since-gate'
check "C3b [skip] exits 0" "0" "$RC"
check "C3b [skip] stdout is exactly one JSON object line" "ok" "$(jc shape "$OUTF")"
check "C3b [skip] token is the session string" "\"$U\"" "$(jc get "$OUTF" approval_skipped.0.token)"
check "C3b [skip] reason is the string changed-since-gate" '"changed-since-gate"' "$(jc get "$OUTF" approval_skipped.0.reason)"
check "C3b [skip] exactly one skipped entry" "1" "$(jc get "$OUTF" approval_skipped.length)"
GID="0123456789abcdef0123456789abcdef"
drive gate "$GID"
check "C3b [gate] exits 0" "0" "$RC"
check "C3b [gate] stdout is exactly one JSON object line" "ok" "$(jc shape "$OUTF")"
check "C3b [gate] a non-empty gate_id encodes as a string" "\"$GID\"" "$(jc get "$OUTF" gate_id)"
check "C3b [gate] key set is unchanged" "$EXPECTED_KEYS" "$(jc keys "$OUTF")"
case_end

case_begin "C4-node-present-positive-control" "bin/sweep-plans.sh"
mk_fixture c4
run_stubbed "$STUB_NODE" "$D" --ci-mode
check "C4 --ci-mode run with node exits 0" "0" "$RC"
expect_json_shape "C4"
check "C4 classifier_failed=0" "0" "$(jc get "$OUTF" classifier_failed)"
check "C4 files_removed=3 (non-plan only)" "3" "$(jc get "$OUTF" files_removed)"
check "C4 gate_id is null" "null" "$(jc get "$OUTF" gate_id)"
check "C4 approval_candidates[0].token" "\"$U\"" "$(jc get "$OUTF" approval_candidates.0.token)"
for n in "${FIX_NON_PLAN[@]}"; do expect_gone "C4 non-plan $n is removed" "$D/$n"; done
expect_present "C4 the plan file is kept" "$D/$U-intent.md"
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
