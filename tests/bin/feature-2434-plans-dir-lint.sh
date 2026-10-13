#!/usr/bin/env bash
# tests/bin/feature-2434-plans-dir-lint.sh
# Tests: bin/check-plans-artifacts, hooks/lib/plans-artifact-registry.js, .github/workflows/migration-blocks-audit.yml, hooks/lib/precommit-agents-repo-gates.sh
# Tags: scope:issue-specific, TL2, plans-dir-lint, feature-2434, plans-dir, control-dir, registry, classification, table-driven, pwsh-not-required, retention, sweep-plans
# Entry: setup + shared helpers; cases live in sourced part files under
# tests/bin/feature-2434-plans-dir-lint/ (lint, registry, consumers, retention).
# TL3 gap: real registry cross-module wiring; SOURCE_LINT_EXCEPTIONS has no injection
# seam (no env var / CLI flag in the plan), so "unused exception -> exit 1" is untested.
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
# shellcheck source=tests/bin/feature-2434-plans-dir-lint/registry.sh
. "$PART_DIR/registry.sh"
# shellcheck source=tests/bin/feature-2434-plans-dir-lint/consumers.sh
. "$PART_DIR/consumers.sh"
# shellcheck source=tests/bin/feature-2434-plans-dir-lint/retention.sh
. "$PART_DIR/retention.sh"

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[ "$FAIL" -eq 0 ]
