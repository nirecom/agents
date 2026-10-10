#!/usr/bin/env bash
# tests/bin/feature-2561-worker-script-direct-launch.sh
# Tests: hooks/lib/worker-dispatch-registry.js, bin/doc-append.py, bin/compose-doc-append-entry, skills/issue-close-stage/scripts/run-stage-chain.sh, skills/issue-close-finalize/scripts/run-initial.sh, skills/issue-close-finalize/scripts/run-loop-step.js, skills/issue-close-finalize/scripts/run-finalize-terminal.sh
# Tags: worker-dispatch, registry, direct-launch, root-names, coverage-table, scope:issue-specific, TL2
# Four workers are never run through the dispatcher by the child-roots test, so each script
# they declare must have a test that launches it directly (where the root decoy applies).
# TL3 gap (what this test does NOT catch):
# - whether the named test exercises the script's happy path, or only a rejection path
# - a script the worker starts without declaring it in the registry

set -uo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RWT="$SCRIPT_CHECKOUT_ROOT/bin/run-with-timeout.sh"
# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

command -v node >/dev/null 2>&1 || { echo "SKIP: node not available"; exit 77; }

TMP_ROOT="$(np "$(make_tmp)")"
readonly TMP_ROOT
trap 'rm -rf "$TMP_ROOT"' EXIT
harness_isolate "$TMP_ROOT/iso"
unset CLAUDE_CODE_SESSION_ID

readonly REGISTRY="$(np "$SCRIPT_CHECKOUT_ROOT")/hooks/lib/worker-dispatch-registry.js"
readonly STAGE_ONE_WORKERS="doc-append,issue-reconcile,issue-close-stage,issue-close-finalize"
readonly CHECKOUT_ANCHOR="script-checkout-root"
readonly FINALIZE_DIR="skills/issue-close-finalize/scripts"
readonly FINALIZE_TEST="tests/skills/feature-1673-finalize-script-contract.sh"

readonly DECOY_LAUNCHER="dl_launch decoy"

# <script declared by a stage-one-only worker>|<test that launches it without the dispatcher>
# and, where given, |<launcher words that must stand on the same line as the launch>
TABLE=(
  "bin/doc-append.py|tests/bin/feature-1672-doc-append-backdate.sh"
  "bin/compose-doc-append-entry|tests/bin/feature-436-compose-doc-append.sh"
  "skills/issue-close-stage/scripts/run-stage-chain.sh|tests/bin/feature-1673-issue-close-stage-behavior.sh"
  "$FINALIZE_DIR/run-loop-step.js|$FINALIZE_TEST|$DECOY_LAUNCHER"
  "$FINALIZE_DIR/run-initial.sh|$FINALIZE_TEST|$DECOY_LAUNCHER"
  "$FINALIZE_DIR/run-finalize-terminal.sh|$FINALIZE_TEST|$DECOY_LAUNCHER"
)
readonly TABLE_FILE="$TMP_ROOT/table.txt"
printf '%s\n' "${TABLE[@]}" >"$TABLE_FILE"

# compare.js <registry> <workers csv> <table file> <anchor>
#   prints "equal", or one line per difference: undeclared:<rel> | untabled:<rel> |
#   no-worker:<name> | anchor:<rel>=<anchor>
cat >"$TMP_ROOT/compare.js" <<'COMPARE_JS'
"use strict";
const fs = require("fs");
const [registryPath, workersCsv, tablePath, anchor] = process.argv.slice(2);
const registry = require(registryPath);
const table = new Set(fs.readFileSync(tablePath, "utf8").split(/\r?\n/).filter(Boolean).map((l) => l.split("|")[0]));
const declared = new Map();
const out = [];
for (const name of workersCsv.split(",")) {
  const entry = registry.workers && registry.workers[name];
  if (!entry) {
    out.push(`no-worker:${name}`);
    continue;
  }
  const scripts = (entry.binaries && entry.binaries.scripts) || {};
  for (const key of Object.keys(scripts)) declared.set(scripts[key].rel, scripts[key].anchor);
}
for (const rel of table) if (!declared.has(rel)) out.push(`undeclared:${rel}`);
for (const [rel, a] of declared) {
  if (!table.has(rel)) out.push(`untabled:${rel}`);
  else if (a !== anchor) out.push(`anchor:${rel}=${a}`);
}
process.stdout.write(out.length === 0 ? "equal\n" : `${out.sort().join("\n")}\n`);
COMPARE_JS

# evidence.js <test file> <script rel> [launcher words]
#   no-path   the file never names the script's repo-relative path
#   no-launch it names the path, but no line hands the script to an interpreter
#   launch    an interpreter word is followed by the script (a variable holding it, or the path)
#   launch-elsewhere  launcher words were asked for, and no launching line carries them before the script
cat >"$TMP_ROOT/evidence.js" <<'EVIDENCE_JS'
"use strict";
const fs = require("fs");
const path = require("path");
const [file, rel, launcher] = process.argv.slice(2);
const esc = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
const text = fs.readFileSync(file, "utf8");
if (!text.includes(rel)) {
  process.stdout.write("no-path\n");
  process.exit(0);
}
const code = text.split(/\r?\n/).filter((l) => !/^\s*#/.test(l));
const base = esc(path.basename(rel));
const assign = new RegExp(`^\\s*(?:readonly\\s+|local\\s+)?([A-Za-z_][A-Za-z0-9_]*)=["']?[^\\s"']*/${base}["']?\\s*$`);
const names = code.map((l) => assign.exec(l)).filter(Boolean).map((m) => m[1]);
const interp = "(?:^|[\\s;(|&])(?:bash|sh|node|python[0-9.]*)\\s+";
const tests = names.map((n) => new RegExp(`${interp}"?\\$\\{?${n}\\}?"?(?:[\\s;)]|$)`));
tests.push(new RegExp(`${interp}"?[^\\s"']*${esc(rel)}"?(?:[\\s;)]|$)`));
// Index of the launch on each launching line; with launcher words, they must come before it.
const at = code.map((l) => tests.map((t) => t.exec(l)).filter(Boolean).map((m) => m.index)).filter((a) => a.length > 0);
const lines = code.filter((l) => tests.some((t) => t.test(l)));
const under = lines.filter((l, i) => !launcher || (l.indexOf(launcher) !== -1 && l.indexOf(launcher) < Math.max(...at[i])));
process.stdout.write(lines.length === 0 ? "no-launch\n" : under.length === 0 ? "launch-elsewhere\n" : "launch\n");
EVIDENCE_JS

expect_eq() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1" "want=$3 got=$2"; fi; }
compare() { bash "$RWT" 60 node "$TMP_ROOT/compare.js" "$1" "$STAGE_ONE_WORKERS" "$2" "$CHECKOUT_ANCHOR" 2>&1 | tr '\n' ' '; }
evidence() { bash "$RWT" 60 node "$TMP_ROOT/evidence.js" "$1" "$2" "${3:-}" 2>&1; }

# row_case <script rel>: every table row for that script names a real direct-launch test.
row_case() {
  local rel="$1" row test_rel launcher seen=0
  if [[ -f "$SCRIPT_CHECKOUT_ROOT/$rel" ]]; then pass "$rel: the script exists"
  else fail "$rel: the script exists" "missing: $rel"; fi
  for row in "${TABLE[@]}"; do
    [[ "${row%%|*}" == "$rel" ]] || continue
    seen=$((seen + 1))
    IFS='|' read -r _ test_rel launcher <<<"$row"
    case "$test_rel" in
      tests/*.sh) pass "$rel: $test_rel is a test path" ;;
      *) fail "$rel: $test_rel is a test path" "not under tests/" ;;
    esac
    if [[ ! -f "$SCRIPT_CHECKOUT_ROOT/$test_rel" ]]; then
      fail "$rel: $test_rel exists" "missing test file"
      continue
    fi
    pass "$rel: $test_rel exists"
    expect_eq "$rel: $test_rel launches the script directly${launcher:+ under '$launcher'}" \
      "$(evidence "$SCRIPT_CHECKOUT_ROOT/$test_rel" "$rel" "$launcher")" "launch"
    if grep -q -- "worker-dispatch\.js" "$SCRIPT_CHECKOUT_ROOT/$test_rel" && ! grep -q -- "$(basename "$rel")" "$SCRIPT_CHECKOUT_ROOT/$test_rel"; then
      fail "$rel: $test_rel is not dispatcher-only" "the file reaches the script only through the dispatcher"
    fi
  done
  expect_eq "$rel: exactly one table row" "$seen" "1"
}

registry_case() {
  expect_eq "the table equals the scripts the four workers declare, all checkout-anchored" "$(compare "$REGISTRY" "$TABLE_FILE")" "equal "
  expect_eq "the table has six rows" "${#TABLE[@]}" "6"
  expect_eq "issue-reconcile declares no script" \
    "$(node -p 'Object.keys(require(process.argv[1]).workers["issue-reconcile"].binaries.scripts || {}).length' "$REGISTRY" 2>&1)" "0"
}

# fake_registry <file> <js object literal of workers>
fake_registry() { printf '"use strict";\nmodule.exports = { workers: %s };\n' "$2" >"$1"; }

compare_verdicts_case() {
  local reg="$TMP_ROOT/fake-registry.js" one="$TMP_ROOT/one-row.txt" none
  none='"issue-reconcile":{binaries:{scripts:{}}},"issue-close-stage":{binaries:{scripts:{}}},"issue-close-finalize":{binaries:{scripts:{}}}'
  printf 'bin/a.sh|tests/bin/a.sh\n' >"$one"
  fake_registry "$reg" "{\"doc-append\":{binaries:{scripts:{a:{anchor:\"$CHECKOUT_ANCHOR\",rel:\"bin/a.sh\"}}}},$none}"
  expect_eq "compare: same set" "$(compare "$reg" "$one")" "equal "
  fake_registry "$reg" "{\"doc-append\":{binaries:{scripts:{a:{anchor:\"$CHECKOUT_ANCHOR\",rel:\"bin/a.sh\"},b:{anchor:\"$CHECKOUT_ANCHOR\",rel:\"bin/b.sh\"}}}},$none}"
  expect_eq "compare: a new declaration is reported" "$(compare "$reg" "$one")" "untabled:bin/b.sh "
  fake_registry "$reg" "{\"doc-append\":{binaries:{scripts:{}}},$none}"
  expect_eq "compare: a dropped declaration is reported" "$(compare "$reg" "$one")" "undeclared:bin/a.sh "
  fake_registry "$reg" "{\"doc-append\":{binaries:{scripts:{a:{anchor:\"family-worktree\",rel:\"bin/a.sh\"}}}},$none}"
  expect_eq "compare: another anchor is reported" "$(compare "$reg" "$one")" "anchor:bin/a.sh=family-worktree "
  fake_registry "$reg" "{\"doc-append\":{binaries:{scripts:{a:{anchor:\"$CHECKOUT_ANCHOR\",rel:\"bin/a.sh\"}}}}}"
  case "$(compare "$reg" "$one")" in
    *"no-worker:issue-reconcile"*) pass "compare: a missing worker is reported" ;;
    *) fail "compare: a missing worker is reported" "$(compare "$reg" "$one")" ;;
  esac
}

evidence_verdicts_case() {
  local d="$TMP_ROOT/ev dir & \$x" rel="skills/demo/scripts/run-demo.sh"
  mkdir -p "$d"
  printf '%s\n' '# only a comment about skills/demo/scripts/run-demo.sh' 'bash "$OTHER"' >"$d/comment.sh"
  printf '%s\n' "# Tests: $rel" 'DEMO="$ROOT/skills/demo/scripts/run-demo.sh"' '[ -f "$DEMO" ] || exit 1' >"$d/assigned.sh"
  printf '%s\n' "# Tests: $rel" 'DEMO="$ROOT/skills/demo/scripts/run-demo.sh"' 'grep -q x "$DEMO"' 'bash "$DEMOLITION"' >"$d/lookalike.sh"
  printf '%s\n' 'echo nothing here' >"$d/absent.sh"
  printf '%s\n' "# Tests: $rel" 'readonly DEMO="$DIR/run-demo.sh"' 'run_with_timeout 30 bash "$DEMO" 1 2' >"$d/var.sh"
  printf '%s\n' "# Tests: $rel" 'DEMO="$ROOT/skills/demo/scripts/run-demo.sh"' '    uv run python3 "${DEMO}" "$@"' >"$d/brace.sh"
  printf '%s\n' 'out="$(node "$ROOT/skills/demo/scripts/run-demo.sh" --x)"' >"$d/literal.sh"
  expect_eq "evidence: comment only" "$(evidence "$d/comment.sh" "$rel")" "no-launch"
  expect_eq "evidence: assigned, only existence-checked" "$(evidence "$d/assigned.sh" "$rel")" "no-launch"
  expect_eq "evidence: a longer variable name is not a launch" "$(evidence "$d/lookalike.sh" "$rel")" "no-launch"
  expect_eq "evidence: path absent" "$(evidence "$d/absent.sh" "$rel")" "no-path"
  expect_eq "evidence: launched through a variable" "$(evidence "$d/var.sh" "$rel")" "launch"
  expect_eq "evidence: launched through a braced variable" "$(evidence "$d/brace.sh" "$rel")" "launch"
  expect_eq "evidence: launched by literal path" "$(evidence "$d/literal.sh" "$rel")" "launch"
  printf '%s\n' "# Tests: $rel" 'DEMO="$DIR/run-demo.sh"' 'dl_launch decoy "$T" env "A=1" node "$DEMO" x' >"$d/decoyed.sh"
  printf '%s\n' "# Tests: $rel" 'DEMO="$DIR/run-demo.sh"' 'dl_launch decoy "$T" bash "$OTHER"' 'dl_launch bare "$T" bash "$DEMO"' >"$d/split.sh"
  printf '%s\n' "# Tests: $rel" 'DEMO="$DIR/run-demo.sh"' 'bash "$DEMO" && dl_launch decoy "$T" true' >"$d/after.sh"
  expect_eq "evidence: launcher words on the launching line" "$(evidence "$d/decoyed.sh" "$rel" "$DECOY_LAUNCHER")" "launch"
  expect_eq "evidence: launcher words on another line only" "$(evidence "$d/split.sh" "$rel" "$DECOY_LAUNCHER")" "launch-elsewhere"
  expect_eq "evidence: launcher words after the launch" "$(evidence "$d/after.sh" "$rel" "$DECOY_LAUNCHER")" "launch-elsewhere"
  expect_eq "evidence: a plain launch does not satisfy launcher words" "$(evidence "$d/var.sh" "$rel" "$DECOY_LAUNCHER")" "launch-elsewhere"
  expect_eq "evidence: no launch at all stays no-launch with launcher words" "$(evidence "$d/assigned.sh" "$rel" "$DECOY_LAUNCHER")" "no-launch"
}

case_begin "table-equals-registry-declarations" "hooks/lib/worker-dispatch-registry.js"
registry_case
case_end

case_begin "registry-compare-reports-every-difference" "hooks/lib/worker-dispatch-registry.js"
compare_verdicts_case
case_end

case_begin "launch-evidence-classifier-both-verdicts" "hooks/lib/worker-dispatch-registry.js"
evidence_verdicts_case
case_end

case_begin "doc-append-py-has-direct-launch-test" "bin/doc-append.py"
row_case "bin/doc-append.py"
case_end

case_begin "compose-entry-has-direct-launch-test" "bin/compose-doc-append-entry"
row_case "bin/compose-doc-append-entry"
case_end

case_begin "stage-chain-has-direct-launch-test" "skills/issue-close-stage/scripts/run-stage-chain.sh"
row_case "skills/issue-close-stage/scripts/run-stage-chain.sh"
case_end

case_begin "finalize-initial-has-direct-launch-test" "skills/issue-close-finalize/scripts/run-initial.sh"
row_case "$FINALIZE_DIR/run-initial.sh"
case_end

case_begin "finalize-loop-step-has-direct-launch-test" "skills/issue-close-finalize/scripts/run-loop-step.js"
row_case "$FINALIZE_DIR/run-loop-step.js"
case_end

case_begin "finalize-terminal-has-direct-launch-test" "skills/issue-close-finalize/scripts/run-finalize-terminal.sh"
row_case "$FINALIZE_DIR/run-finalize-terminal.sh"
case_end

echo ""
echo "Total: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
