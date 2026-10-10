#!/usr/bin/env bash
# Tests: bin/check-root-names.sh, bin/check-root-names/classification.json
# Tags: root-names, whole-tree-scan, classification, gate, static-check, bin, scope:issue-specific, TL2
# #2561: the real gate over the real checkout — every check reports nothing, and
# the classification table has the shape the checks rely on.
# TL3 gap (what this test does NOT catch):
# - the CI job that runs the same scan on a fresh clone.
set -euo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RWT="$SCRIPT_CHECKOUT_ROOT/bin/run-with-timeout.sh"
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
T="$(np "$(make_tmp)")"
readonly T
harness_isolate "$T/iso"
trap 'rm -rf "$T"' EXIT
REAL_GATE="$SCRIPT_CHECKOUT_ROOT/bin/check-root-names.sh"
RETIRED_LIST="$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-2561-root-names-residue.sh"
. "$(dirname "$0")/feature-2561-root-names/common.sh"

REAL_TABLE="$SCRIPT_CHECKOUT_ROOT/bin/check-root-names/classification.json"
DOTFILES_CHECKOUT="$(dirname "$SCRIPT_CHECKOUT_ROOT")/dotfiles"
SCAN_TIMEOUT=300

# real_gate <args...> — the real gate, from the checkout; sets GATE_OUT / GATE_RC.
real_gate() {
  GATE_RC=0
  GATE_OUT="$(cd "$SCRIPT_CHECKOUT_ROOT" && run_with_timeout "$SCAN_TIMEOUT" bash "$REAL_GATE" "$@" 2>&1)" || GATE_RC=$?
}

gate_paths_status() {
  git -C "$SCRIPT_CHECKOUT_ROOT" status --porcelain -- bin/check-root-names.sh bin/check-root-names
}

c_whole_tree() {
  local before
  before="$(gate_paths_status)"
  real_gate
  expect "scan: every check over the agents checkout exits 0" rc_is 0
  expect "scan: the gate writes nothing beside itself" test "$(gate_paths_status)" = "$before"
}

c_every_file_classified() {
  real_gate --only table-match
  expect "scan: every tracked file falls under a rule and keeps to it" rc_is 0
  real_gate --only residue
  expect "scan: no retired spelling is left in content or paths" rc_is 0
}

# table_report — one "ok <text>" / "no <text>" line per property of the table.
table_report() {
  node - "$(np "$REAL_TABLE")" "$(np "$SCRIPT_CHECKOUT_ROOT")" "$N_SCR,$N_AMR,$N_TMR,$N_TCR" \
    "$C_PROP=property" "$C_KEY=payload-key" "${C_FN}=function" <<'JS'
const fs = require("fs");
const path = require("path");
const [file, root, nameList, ...carrierArgs] = process.argv.slice(2);
const names = nameList.split(",");
const say = (ok, text) => console.log(`${ok ? "ok" : "no"} ${text}`);
let table = null;
try {
  table = JSON.parse(fs.readFileSync(file, "utf8"));
} catch (err) {
  say(false, `the table is readable JSON (${err.code || err.message})`);
}
if (table) {
  const rules = Array.isArray(table.rules) ? table.rules : null;
  const exceptions = Array.isArray(table.exceptions) ? table.exceptions : null;
  say(rules !== null && rules.length > 0, "rules is a non-empty array");
  say(exceptions !== null, "exceptions is an array");
  const isText = (v) => typeof v === "string" && v.trim().length > 0;
  const all = (list, test) => list !== null && list.every(test);
  say(all(rules, (r) => r.repo === "agents" || r.repo === "dotfiles"), "every rule names its repo");
  say(all(rules, (r) => isText(r.glob)), "every rule has a glob");
  say(all(rules, (r) => Array.isArray(r.allow) && r.allow.every((n) => names.includes(n))),
    "every rule allows only the four names");
  say(all(rules, (r) => typeof r.sourced === "boolean"), "every rule says whether it is sourced");
  say(all(rules, (r) => isText(r.reason)), "every rule gives a reason");
  say(all(exceptions, (e) => isText(e.reason)), "every exception gives a reason");
  for (const repo of ["agents", "dotfiles"]) {
    say(rules !== null && rules.some((r) => r.repo === repo), `the table has rules for ${repo}`);
  }
  for (const arg of carrierArgs) {
    const [carrier, kind] = arg.split("=");
    const bare = carrier.replace(/\(\)$/, "");
    const hit = (exceptions || []).find((e) => typeof e.carrier === "string" && e.carrier.replace(/\(\)$/, "") === bare);
    say(Boolean(hit), `the ${kind} carrier is listed`);
    if (!hit) continue;
    say(hit.kind === kind, `the ${kind} carrier has its kind`);
    say(isText(hit.source) && fs.existsSync(path.join(root, hit.source)), `the ${kind} carrier source exists`);
    say(Array.isArray(hit.files) && hit.files.includes(hit.source), `the ${kind} carrier files include its source`);
    say(Array.isArray(hit.files) && hit.files.every((f) => fs.existsSync(path.join(root, f))),
      `every ${kind} carrier file exists`);
  }
  const carriers = (exceptions || []).filter((e) => "carrier" in e);
  say(carriers.length === carrierArgs.length, "exactly the three carriers are listed");
  const named = (exceptions || []).filter((e) => "file" in e);
  const mine = (e) => (e.repo || "agents") === "agents";
  const few = (list) => (list.length ? ` (${list.slice(0, 5).join(", ")})` : "");
  const gone = named.filter((e) => mine(e) && !fs.existsSync(path.join(root, String(e.file)))).map((e) => e.file);
  say(gone.length === 0, `every file named by an agents exception exists${few(gone)}`);
  const known = ["set-agents-root", "own-script-root-form", "agents-root-subpath", "leave-decoy"];
  const odd = named.filter((e) => !Array.isArray(e.forms) || e.forms.some((f) => !known.includes(f))).map((e) => e.file);
  say(odd.length === 0, `every exception frees only known forms${few(odd)}`);
  const listed = require("child_process")
    .execFileSync("git", ["-C", root, "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
      { encoding: "utf8", maxBuffer: 1 << 28 })
    .split("\0").filter(Boolean);
  say(listed.length > 100, "the checkout lists its files");
  const toRe = (glob) => new RegExp("^" + glob.split(/(\*\*\/|\*\*|\*|\?)/).map((part) =>
    ({ "**/": "(?:.*/)?", "**": ".*", "*": "[^/]*", "?": "[^/]" }[part] ||
      part.replace(/[.+^${}()|[\]\\]/g, "\\$&"))).join("") + "$");
  const idle = (rules || []).filter((r) => r.repo === "agents" && isText(r.glob) &&
    !listed.some((f) => toRe(r.glob).test(f))).map((r) => r.glob);
  say(idle.length === 0, `every agents rule matches a file of the checkout${few(idle)}`);
}
JS
}

# A seeded tree under the real table: the scan reads files and reports what it finds.
c_seeded_control() {
  local tree="$T/control"
  fx "$tree/bin/control.sh" "echo \"$V_AMR\""
  fx "$tree/docs/fine.md" "the root is $N_AMR"
  real_gate --root "$tree"
  expect "control: a seeded violation under the real table exits 1" rc_is 1
  expect "control: the seeded line is reported by its check" \
    reports "bin/control.sh" table-match 1 "$N_AMR is not allowed by the rule of this file"
  expect "control: the file within its rule is not" clean_for "docs/fine.md"
  rm -f "$tree/bin/control.sh"
  real_gate --root "$tree"
  expect "control: the same tree without the violation exits 0" rc_is 0
}

# The default run (no root: the tracked files of the gate's own checkout) under a
# one-entry list kept in the temp dir; its word is certain to be in a tracked file.
c_tracked_control() {
  local list="$T/control-list.txt" word="harness_git_init" known="tests/lib/harness.sh"
  fx "$list" '# retired-names:begin' "# name $word" '# retired-names:end'
  expect "tracked: the control file is tracked and carries the word" \
    git -C "$SCRIPT_CHECKOUT_ROOT" grep -q -w --cached -e "$word" -- "$known"
  real_gate --only residue --retired-names-from "$list"
  expect "tracked: a word of a tracked file exits 1 on the default run" rc_is 1
  expect "tracked: the tracked file is reported by its repo-relative path" \
    reports "$known" residue "" "retired name \"$word\""
}

c_table_shape() {
  local report line seen=0
  report="$(table_report 2>&1)" || report+=$'\n'"no the table check ran to its end"
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    seen=$((seen + 1))
    expect "table: ${line#?? }" test "${line%% *}" = ok
  done <<<"$report"
  expect "table: the report is not empty" test "$seen" -gt 1
}

c_dotfiles_tree() {
  if [[ ! -f "$REAL_GATE" ]]; then
    fail "dotfiles: the gate exists" "missing $REAL_GATE"
    return 0
  fi
  if [[ ! -d "$DOTFILES_CHECKOUT/.git" && ! -f "$DOTFILES_CHECKOUT/.git" ]]; then
    skip "dotfiles: no sibling checkout at $DOTFILES_CHECKOUT"
    return 0
  fi
  real_gate --repo dotfiles --root "$DOTFILES_CHECKOUT"
  expect "dotfiles: every check over the sibling checkout exits 0" rc_is 0
}

case_begin "agents-checkout-has-no-violation" "bin/check-root-names.sh"
c_whole_tree
case_end

case_begin "every-tracked-file-is-classified-and-clean" "bin/check-root-names/classification.json"
c_every_file_classified
case_end

case_begin "classification-table-has-the-expected-shape" "bin/check-root-names/classification.json"
c_table_shape
case_end

case_begin "seeded-violation-is-reported-under-the-real-table" "bin/check-root-names.sh"
c_seeded_control
case_end

case_begin "tracked-file-is-reported-on-the-default-run" "bin/check-root-names/main.js"
c_tracked_control
case_end

case_begin "dotfiles-checkout-has-no-violation" "bin/check-root-names/classification.json"
c_dotfiles_tree
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[[ "$FAIL" -eq 0 ]]
