#!/usr/bin/env bash
# tests/bin/feature-2434-plans-dir-lint.sh
# Tests: bin/check-plans-artifacts, hooks/lib/plans-artifact-registry.js, .github/workflows/migration-blocks-audit.yml, hooks/pre-commit
# Tags: scope:issue-specific, TL2, plans-dir-lint, feature-2434, plans-dir, control-dir, registry, classification, table-driven, pwsh-not-required, retention, sweep-plans
# Entry: setup + shared helpers; cases live in sourced part files under
# tests/bin/feature-2434-plans-dir-lint/ (lint, judged-table, registry, consumers, retention, commit-gate).
# TL3 gap: real registry cross-module wiring. TL gap: "a symlinked data file -> exit 2" is untested
# (symlink fixtures are unreliable on Windows); judged-table.sh's directory row guards that branch.
# Closest-to-action mitigation: hook-registration category in bin/check-verification-gate.sh

set -uo pipefail
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

command -v node >/dev/null 2>&1 || { echo "SKIP: node not available"; exit 77; }

readonly T="$(make_tmp)"
trap 'rm -rf "$T"' EXIT
harness_isolate "$T/wf"
unset CLAUDE_CODE_SESSION_ID 2>/dev/null || true
export CLAUDE_TRANSCRIPT_BASE_DIR="$T/transcripts"
mkdir -p "$CLAUDE_TRANSCRIPT_BASE_DIR"

LINT="$SCRIPT_CHECKOUT_ROOT/bin/check-plans-artifacts"
PART_DIR="$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-2434-plans-dir-lint"

make_tree() { mkdir -p "$1/bin" "$1/skills" "$1/hooks" "$1/agents" "$1/rules" "$1/docs"; }

run_source() {
  L_RC=0
  if [ ! -f "$LINT" ]; then L_OUT="implementation absent"; L_RC=127; return; fi
  L_OUT="$(run_with_timeout 30 node "$(np "$LINT")" --source "$(np "$1")" 2>&1)" || L_RC=$?
}

run_dir() {
  L_RC=0
  if [ ! -f "$LINT" ]; then L_OUT="implementation absent"; L_RC=127; return; fi
  L_OUT="$(run_with_timeout 30 node "$(np "$LINT")" --dir "$(np "$1")" 2>&1)" || L_RC=$?
}

# run_source_gate <tree> — the pre-commit form: cwd = the judged tree, no root argument.
# stdout lands in L_OUT, stderr (backslashes folded to /) in L_ERR.
run_source_gate() {
  L_RC=0; L_ERR=""
  if [ ! -f "$LINT" ]; then L_OUT="implementation absent"; L_RC=127; return; fi
  L_OUT="$(cd "$1" && run_with_timeout 30 node "$(np "$LINT")" --source 2>"$T/gate-stderr.txt")" || L_RC=$?
  L_ERR="$(tr '\\' '/' < "$T/gate-stderr.txt")"
}

# The judged tree's own table (#2638): the data file a --source run reads from <root>.
TABLE_REL="hooks/lib/plans-artifact-registry.json"
# The word the "no table in the judged tree" notice carries; a broken table must not print it.
FALLBACK_WORD="fallback"

# make_table_tree <dir> — make_tree plus a copy of the real data file. Returns 1 and says
# so while that file does not exist, so a dependent case fails instead of judging nothing.
make_table_tree() {
  make_tree "$1"
  mkdir -p "$1/hooks/lib"
  if ! cp "$SCRIPT_CHECKOUT_ROOT/$TABLE_REL" "$1/$TABLE_REL" 2>/dev/null; then
    echo "make_table_tree: data file missing in the checkout: $TABLE_REL" >&2
    return 1
  fi
}

# table_tree <label> <dir> — make_table_tree, recording a FAIL under <label> when it cannot.
table_tree() {
  make_table_tree "$2" && return 0
  fail "$1" "fixture: the checkout has no $TABLE_REL to copy"
  return 1
}

# edit_table <tree> <op> [args...] — one edit of <tree>'s table; non-zero when it did not apply.
edit_table() { node "$(np "$T/edit-table.js")" "$(np "$1/$TABLE_REL")" "${@:2}"; }

cat > "$T/edit-table.js" <<'EDITTABLE'
// edit-table.js <file> <op> [args...] — read the JSON table, apply one edit, write it back.
"use strict";
const fs = require("fs");
const [file, op, ...a] = process.argv.slice(2);
const table = JSON.parse(fs.readFileSync(file, "utf8"));
const entryOf = (kind) => {
  const e = [...(table.controlKinds || []), ...(table.artifactKinds || [])].find((x) => x.kind === kind);
  if (!e) throw new Error(`no such kind in the table: ${kind}`);
  return e;
};
const ops = {
  "add-kind": ([list, kind, source, retention]) => table[list].push({ kind, source, retention }),
  "remove-kind": ([kind]) => {
    entryOf(kind);
    for (const list of ["controlKinds", "artifactKinds"]) table[list] = table[list].filter((x) => x.kind !== kind);
  },
  "set-retention": ([kind, value]) => { entryOf(kind).retention = value; },
  "set-source": ([kind, value]) => { entryOf(kind).source = value; },
  "drop-source": ([kind]) => { delete entryOf(kind).source; },
  "delete-key": ([key]) => {
    if (!(key in table)) throw new Error(`no such key in the table: ${key}`);
    delete table[key];
  },
  "add-format-token": ([token]) => table.formatTokens.push(token),
  "add-exception": ([f, pattern, reason]) => table.sourceLintExceptions.push({ file: f, pattern, reason: reason || "" }),
};
if (!ops[op]) throw new Error(`unknown op: ${op}`);
ops[op](a);
fs.writeFileSync(file, `${JSON.stringify(table, null, 2)}\n`);
EDITTABLE

# Write helper JS once before cases to avoid multi-line strings inside case blocks
# (multi-line "..." with if/{ would confuse the case-marker depth counter)
cat > "$T/check-reg.js" << 'REGSCRIPT'
var reg = process.argv[2];
try {
  var r = require(reg);
  var excs = r.SOURCE_LINT_EXCEPTIONS || [];
  var bad = excs.filter(function(e) { return !e.reason; });
  if (bad.length > 0) {
    process.stderr.write("exceptions with empty reason: " + bad.length + "\n");
    process.exit(1);
  }
  process.exit(0);
} catch (e) {
  process.stderr.write("require failed: " + String(e.code || e.message) + "\n");
  process.exit(1);
}
REGSCRIPT

# ── registry driver (classification cases in registry.sh) ────────────────────
# Merged from tests/hooks/feature-2434-plans-artifact-registry.sh (RT-1a). Seam
# assumptions (the plan names functions, not return shapes): verdicts are
# control|artifact|unregistered|no-sid|ambiguous, as a string or .verdict;
# parsePlansEntry's optional 2nd arg is the injected {controlKinds, artifactKinds}
# table; *_KINDS entries are RegExps or objects holding one as .re/.regex/.pattern.
REG_JS="$SCRIPT_CHECKOUT_ROOT/hooks/lib/plans-artifact-registry.js"
REG_N="$(np "$REG_JS")"
PLANS_N="$(np "$WORKFLOW_PLANS_DIR")"
WF_N="$(np "$WORKFLOW_STATE_DIR")"
export REG_N PLANS_N WF_N

DRIVER="$T/driver.js"
cat > "$DRIVER" <<'JS'
// driver.js <op> <args...> — one registry call, printed as one line.
const [op, ...args] = process.argv.slice(2);
let reg;
try { reg = require(process.env.REG_N); } catch (e) { console.log("MISSING"); process.exit(0); }
const ctx = { plansDir: process.env.PLANS_N, workflowDir: process.env.WF_N };
const verdictOf = (r) => (r == null ? "null" : typeof r === "string" ? r : (r.verdict || "none"));
const reOf = (k) => (k instanceof RegExp ? k : k && (k.re || k.regex || k.pattern));
const matchesAny = (list, s) => Array.isArray(list) && list.some((k) => {
  const re = reOf(k);
  if (re instanceof RegExp) return re.test(s);
  if (typeof re === "string") return new RegExp(re).test(s);
  return typeof k === "string" && k === s;
});
try {
  switch (op) {
    case "classify": {
      const c = Object.assign({}, ctx);
      if (args[1]) c.sid = args[1];
      console.log(verdictOf(reg.classifyPlansEntry(args[0], c)));
      break;
    }
    case "parse": {
      const r = reg.parsePlansEntry(args[0]);
      if (!r) { console.log("null"); break; }
      if (r.verdict === "ambiguous") { console.log("ambiguous"); break; }
      console.log(`sid=${r.sid} kind=${r.kind ? "set" : "unset"}`);
      break;
    }
    case "parse-kind": {
      const r = reg.parsePlansEntry(args[0]);
      console.log(r == null ? "null" : r.verdict === "ambiguous" ? "ambiguous" : `${r.verdict}:${r.kind}:${r.sid}`);
      break;
    }
    case "parse-injected": {
      const table = { controlKinds: [/^x-y\.txt$/, /^y\.txt$/], artifactKinds: [] };
      const r = reg.parsePlansEntry(args[0], table);
      console.log(r && r.verdict === "ambiguous" ? "ambiguous" : "not-ambiguous");
      break;
    }
    case "format-tokens":
      console.log([...(reg.FORMAT_TOKENS || [])].sort().join(","));
      break;
    case "suffix-collisions": {
      const t = [...(reg.FORMAT_TOKENS || [])];
      const bad = [];
      for (const a of t) for (const b of t) if (a !== b && a.endsWith("-" + b)) bad.push(`${a}>${b}`);
      console.log(t.length === 0 ? "no-tokens" : (bad.join(",") || "none"));
      break;
    }
    case "migratable":
      console.log(matchesAny(reg.MIGRATABLE_KINDS, args[0]) ? "yes" : "no");
      break;
    case "migratable-subset": {
      const m = reg.MIGRATABLE_KINDS || [];
      const src = (k) => String(reOf(k));
      const ctl = new Set((reg.CONTROL_KINDS || []).map(src));
      console.log(m.length === 0 ? "empty" : (m.every((k) => ctl.has(src(k))) ? "subset" : "not-subset"));
      break;
    }
    case "legacy":
      console.log(reg.legacyBasename(args[0], args[1]));
      break;
    case "artifact-path-unknown": {
      try { reg.getPlansArtifactPath("s1", "no-such-kind", {}); console.log("returned"); }
      catch (e) { console.log("threw"); }
      break;
    }
    case "lint-exceptions": {
      const x = reg.SOURCE_LINT_EXCEPTIONS;
      console.log(Array.isArray(x) ? "array" : typeof x);
      break;
    }
    default:
      console.log("bad-op");
  }
} catch (e) {
  console.log("THREW:" + (e && e.message ? e.message.split("\n")[0] : e));
}
JS

reg() { node "$DRIVER" "$@" 2>/dev/null | tr -d '\r'; }

# check <label> <want> <got> — name-first, so a table row reads as its contract.
check() {
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "want=$(printf '%q' "$2") got=$(printf '%q' "$3")"; fi
}

trim_f() { printf '%s' "$1" | sed 's/^ *//; s/ *$//'; }

[ -f "$REG_JS" ] || fail "implementation missing: hooks/lib/plans-artifact-registry.js (every registry case fails for this reason)"

# The four sid shapes the workflow produces (C1): a UUID, the dated wsid that
# resolve-workflow-session-id.js returns, a derived bundle id, and a test sid.
SID_UUID="0199a2f1-cafe-4b0d-9c11-deadbeef0001"
SID_DATE="20260601-120000"
SID_DERIVED="0199a2f1-cafe-4b0d-9c11-deadbeef0001-b1"
SID_TEST="20260509-bundle-a"

# ── cases (part files; each uses the helpers above at source time) ───────────
# shellcheck source=tests/bin/feature-2434-plans-dir-lint/lint.sh
. "$PART_DIR/lint.sh"
# shellcheck source=tests/bin/feature-2434-plans-dir-lint/judged-table.sh
. "$PART_DIR/judged-table.sh"
# shellcheck source=tests/bin/feature-2434-plans-dir-lint/registry.sh
. "$PART_DIR/registry.sh"
# shellcheck source=tests/bin/feature-2434-plans-dir-lint/consumers.sh
. "$PART_DIR/consumers.sh"
# shellcheck source=tests/bin/feature-2434-plans-dir-lint/retention.sh
. "$PART_DIR/retention.sh"
# shellcheck source=tests/bin/feature-2434-plans-dir-lint/commit-gate.sh
. "$PART_DIR/commit-gate.sh"

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[ "$FAIL" -eq 0 ]
