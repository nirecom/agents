#!/usr/bin/env bash
# tests/bin/feature-2434-plans-dir-lint.sh
# Tests: bin/check-plans-artifacts, hooks/lib/plans-artifact-registry.js, .github/workflows/migration-blocks-audit.yml, hooks/lib/precommit-agents-repo-gates.sh
# Tags: scope:issue-specific, TL2, plans-dir-lint, feature-2434, plans-dir, control-dir, registry, classification, table-driven, pwsh-not-required
# TL3 gap (what this test does NOT catch):
# - Real registry cross-module wiring (bin/check-plans-artifacts importing registry)
# - Exception injection: SOURCE_LINT_EXCEPTIONS injection mechanism is AMBIGUOUS (no
#   env-var or CLI flag is defined in the plan); only direct node-require of the registry
#   is tested here. Cannot test "unused exception → exit 1" without an injection seam.
# Closest-to-action mitigation: hook-registration category in bin/check-verification-gate.sh

set -uo pipefail
AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$AGENTS_DIR/tests/lib/harness.sh"

command -v node >/dev/null 2>&1 || { echo "SKIP: node not available"; exit 77; }

T="$(make_tmp)"
trap 'rm -rf "$T"' EXIT
harness_isolate "$T/wf"
export CLAUDE_TRANSCRIPT_BASE_DIR="$T/transcripts"
mkdir -p "$CLAUDE_TRANSCRIPT_BASE_DIR"

LINT="$AGENTS_DIR/bin/check-plans-artifacts"

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

# ── registry driver (classification cases below) ─────────────────────────────
# Merged from tests/hooks/feature-2434-plans-artifact-registry.sh (RT-1a). Seam
# assumptions (the plan names functions, not return shapes): verdicts are
# control|artifact|unregistered|no-sid|ambiguous, as a string or .verdict;
# parsePlansEntry's optional 2nd arg is the injected {controlKinds, artifactKinds}
# table; *_KINDS entries are RegExps or objects holding one as .re/.regex/.pattern.
REG_JS="$AGENTS_DIR/hooks/lib/plans-artifact-registry.js"
REG_N="$(np "$REG_JS")"
PLANS_N="$(np "$WORKFLOW_PLANS_DIR")"
WF_N="$(np "$CLAUDE_WORKFLOW_DIR")"
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

# ── cases ────────────────────────────────────────────────────────────────────

case_begin "source-scan-matrix" "bin/check-plans-artifacts"
# C11: table-driven matrix over artifact/control/unregistered/token-spelling/malformed-path.
# Columns: label | content written to fixture file | expected exit code | file extension.
# The lint scans all files regardless of extension per plan Step 7-2 ("全ファイル").
while IFS='|' read -r LABEL CONTENT WANT_RC EXT; do
  FX="$T/scan-$LABEL"; make_tree "$FX"
  printf '%s\n' "$CONTENT" > "$FX/bin/m.$EXT"
  run_source "$FX"
  if [ "$L_RC" = "127" ]; then
    fail "source-scan/$LABEL" "implementation absent"
  elif [ "$L_RC" = "$WANT_RC" ]; then
    pass "source-scan/$LABEL"
  else
    fail "source-scan/$LABEL" "want exit $WANT_RC; got $L_RC"
  fi
done <<'MATRIX'
artifact-allowed|$PLANS_DIR/$SID-detail.md|0|sh
control-terminal|$PLANS_DIR/$SID-detail-plan-terminal.txt|1|sh
control-carrier-md|${PLANS_DIR}/${SESSION_ID}-test-review-concern-carrier.md|1|sh
unregistered-json|$PLANS_DIR/$SID-new-state.json|1|sh
dynamic-kind|$PLANS_DIR/$SID-$kind|1|sh
token-workflow-plans-alt|${WORKFLOW_PLANS_DIR:-$HOME/.workflow-plans}/$SID-detail-plan-terminal.txt|1|sh
token-plansdir-js|path.join(plansDir, sid + "-security-code-terminal.txt")|1|js
token-artifact-dir|$artifact_dir/$SID-test-review-terminal.txt|1|sh
token-log-dir|$LOG_DIR/$SID-detail-plan-round-number.txt|1|sh
token-placeholder-md|<PLANS_DIR>/<session-id>-detail-plan-terminal.txt|1|md
malformed-path-traversal|$PLANS_DIR/$SID-../../etc/passwd|1|sh
MATRIX
case_end

case_begin "static-registry-exceptions-have-reason" "hooks/lib/plans-artifact-registry.js"
REG="$(np "$AGENTS_DIR/hooks/lib/plans-artifact-registry.js")"
REG_RC=0
REG_OUT="$(run_with_timeout 15 node "$T/check-reg.js" "$REG" 2>&1)" || REG_RC=$?
if [ "$REG_RC" = "0" ]; then
  pass "static-registry-exceptions-have-reason"
else
  fail "static-registry-exceptions-have-reason" "exit $REG_RC: $REG_OUT"
fi
case_end

case_begin "dir-unregistered-warning" "bin/check-plans-artifacts"
FX="$T/fx-dir-unk"; mkdir -p "$FX"
UNK_NAME="ffffffff-0000-0000-0000-000000000000-unknown-custom.txt"
printf '%s\n' 'content' > "$FX/$UNK_NAME"
# Evidence that the prefix is a session (plan Step 7-1: unregistered needs it);
# an artifact never produces a diagnostic line of its own.
printf '%s\n' '# context' > "$FX/ffffffff-0000-0000-0000-000000000000-context.md"
run_dir "$FX"
if [ "$L_RC" = "0" ]; then
  pass "dir-unregistered-warning"
elif [ "$L_RC" = "127" ]; then
  fail "dir-unregistered-warning" "implementation absent"
else
  fail "dir-unregistered-warning" "want exit 0; got $L_RC: $L_OUT"
fi
# A lint that exits 0 without detecting anything must not pass: the warning names
# the file, its classification, and the count (plan Step 7-1 "件数を表示").
UNK_LINE="$(printf '%s\n' "$L_OUT" | grep -F "$UNK_NAME" | head -n 1)"
check "dir-unregistered-warning: the diagnostic names the unregistered file" \
  "yes" "$([ -n "$UNK_LINE" ] && printf yes || printf no)"
check "dir-unregistered-warning: the file's line classifies it as unregistered" \
  "yes" "$(printf '%s' "$UNK_LINE" | grep -qi 'unregistered' && printf yes || printf no)"
check "dir-unregistered-warning: the count of unregistered entries is 1" \
  "yes" "$(printf '%s\n' "$L_OUT" | grep -i 'unregistered' | grep -Eq '(^|[^0-9])1([^0-9]|$)' && printf yes || printf no)"
check "dir-unregistered-warning: the artifact is not reported" \
  "no" "$(printf '%s\n' "$L_OUT" | grep -qF -- '-context.md' && printf yes || printf no)"
case_end

case_begin "dir-control-error" "bin/check-plans-artifacts"
FX="$T/fx-dir-ctrl"; mkdir -p "$FX"
printf '%s\n' 'content' > "$FX/ffffffff-0000-0000-0000-000000000001-detail-plan-terminal.txt"
run_dir "$FX"
if [ "$L_RC" = "1" ]; then
  pass "dir-control-error"
elif [ "$L_RC" = "127" ]; then
  fail "dir-control-error" "implementation absent"
else
  fail "dir-control-error" "want exit 1; got $L_RC: $L_OUT"
fi
case_end

case_begin "repo-source-clean" "bin/check-plans-artifacts"
if [ ! -f "$LINT" ]; then
  fail "repo-source-clean" "implementation absent"
else
  R_RC=0
  R_OUT="$(cd "$AGENTS_DIR" && run_with_timeout 60 node "$(np "$LINT")" --source 2>&1)" || R_RC=$?
  if [ "$R_RC" = "0" ]; then
    pass "repo-source-clean"
  else
    fail "repo-source-clean" "want exit 0; got $R_RC: $R_OUT"
  fi
fi
case_end

case_begin "static-migration-blocks-audit-has-lint" ".github/workflows/migration-blocks-audit.yml"
YML="$AGENTS_DIR/.github/workflows/migration-blocks-audit.yml"
FOUND_CALL=0
grep -qF "check-plans-artifacts --source" "$YML" 2>/dev/null && FOUND_CALL=1
HAS_OR_TRUE=0
grep -F "check-plans-artifacts --source" "$YML" 2>/dev/null | grep -qF "|| true" && HAS_OR_TRUE=1
if [ "$FOUND_CALL" = "1" ] && [ "$HAS_OR_TRUE" = "0" ]; then
  pass "static-migration-blocks-audit-has-lint"
else
  fail "static-migration-blocks-audit-has-lint" "found_call=$FOUND_CALL has_or_true=$HAS_OR_TRUE"
fi
case_end

case_begin "static-precommit-gates-has-lint" "hooks/lib/precommit-agents-repo-gates.sh"
GATES="$AGENTS_DIR/hooks/lib/precommit-agents-repo-gates.sh"
GATES_OK=0
grep -qF "check-plans-artifacts --source" "$GATES" 2>/dev/null && GATES_OK=1
if [ "$GATES_OK" = "1" ]; then
  pass "static-precommit-gates-has-lint"
else
  fail "static-precommit-gates-has-lint" "check-plans-artifacts --source not in precommit-agents-repo-gates.sh"
fi
case_end

# ── registry classification cases (hooks/lib/plans-artifact-registry.js) ─────

case_begin "inventory-table-verdicts" "hooks/lib/plans-artifact-registry.js"
# Every inventory row, under a UUID sid. The verdict is the whole contract:
# control rows move, artifact rows stay, and nothing in the table is ambiguous.
while IFS='|' read -r name want; do
    [ -z "$name" ] && continue
    case "$name" in \#*) continue ;; esac
    name="$(trim_f "$name")"; want="$(trim_f "$want")"
    check "inventory: $name is $want" "$want" "$(reg classify "$SID_UUID-$name")"
done <<'TABLE'
# control — review loop state
detail-plan-round-number.txt                        | control
outline-plan-last-round.txt                         | control
test-review-terminal.txt                            | control
security-code-unresolved-concerns.json              | control
review-security-shared-concern-ledger.txt           | control
security-plan-concern-ledger-cycle3.txt             | control
detail-plan-concern-ledger-cap-snapshot.txt         | control
outline-plan-concern-carrier.md                     | control
security-code-round-2-delta-codex.txt               | control
# control — sole-writer CLIs
security-code-exit6-accepted.txt                    | control
review-plan-security-exit6-accepted.txt             | control
review-tests-exit6-accepted.txt                     | control
outline-risk-signal.txt                             | control
detail-risk-signal.txt                              | control
worker-commit-push.json                             | control
worker-x-1.json                                     | control
worker-commit-push.dispatched                       | control
# control — context, signals, close family, supervisor, init, clarify
codex-context.md                                    | control
codex-context.detail-plan.built                     | control
plan.jsonl                                          | control
changed-files.txt                                   | control
complexity-signals.txt                              | control
detail-signals.txt                                  | control
write-tests-signals.txt                             | control
write-code-signals.txt                              | control
finalize-state-1.json                               | control
finalize-binding-1.json                             | control
issue-close-outcome.json                            | control
session-close-gate.json                             | control
final-report-env.json                               | control
supervisor-state.json                               | control
wi-checkpoint.json                                  | control
handoff.md                                          | control
wt-cleanup-active                                   | control
workflow-init-aborted-pathA-multiN-label-failure.md | control
companion-precheck.json                             | control
intent-scan-block.txt                               | control
guard-attempt.tmp                                   | control
# artifacts — stay in PLANS_DIR
intent.md                                           | artifact
outline.md                                          | artifact
detail.md                                           | artifact
context.md                                          | artifact
survey-code.md                                      | artifact
survey-history.md                                   | artifact
issue-prefill.md                                    | artifact
test-review.md                                      | artifact
concerns-log.md                                     | artifact
codex-round-2-raw.md                                | artifact
complexity-judge-raw.txt                            | artifact
detail-judge-raw.txt                                | artifact
write-tests-judge-raw.txt                           | artifact
write-code-judge-raw.txt                            | artifact
worker-commit-push.draft.json                       | artifact
worker-x-1.draft.json                               | artifact
session-close-worker.log                            | artifact
issue-create-dispatch.txt                           | artifact
issue-create-survey.json                            | artifact
sweep-issues-survivors.tsv                          | artifact
sweep-issues-decisions.tsv                          | artifact
refactor-prompts-scan.json                          | artifact
note-topic.md                                       | artifact
note-topic.json                                     | artifact
TABLE
case_end

case_begin "sid-shapes-parse-alike" "hooks/lib/plans-artifact-registry.js"
# The kind is parsed from the remainder, never carved from the sid's shape, so
# a sid holding dashes of its own must still come back whole.
for SID in "$SID_UUID" "$SID_DATE" "$SID_DERIVED" "$SID_TEST"; do
    check "sid shape $SID: the round-number control file parses to its sid" \
        "sid=$SID kind=set" "$(reg parse "$SID-detail-plan-round-number.txt")"
    check "sid shape $SID: the detail artifact parses to its sid" \
        "sid=$SID kind=set" "$(reg parse "$SID-detail.md")"
    check "sid shape $SID: round-number classifies as control" \
        "control" "$(reg classify "$SID-detail-plan-round-number.txt")"
    check "sid shape $SID: detail.md classifies as artifact" \
        "artifact" "$(reg classify "$SID-detail.md")"
done
# The derived sid's files are its own: '<uuid>' cut leaves 'b1-...', which is
# no kind, so the only candidate is the full '<uuid>-b1'.
check "a derived sid's control file is not mistaken for its parent's" \
    "sid=$SID_DERIVED kind=set" "$(reg parse "$SID_DERIVED-test-review-round-number.txt")"
case_end

case_begin "unregistered-and-no-sid" "hooks/lib/plans-artifact-registry.js"
# A name matching no kind is a session's file when a session provably exists
# under that prefix (its context / intent in PLANS, or its state json in WF).
: > "$WORKFLOW_PLANS_DIR/$SID_UUID-context.md"
check "an unknown name under a sid with a context.md is unregistered" \
    "unregistered" "$(reg classify "$SID_UUID-foo.md")"
: > "$CLAUDE_WORKFLOW_DIR/$SID_DATE.json"
check "an unknown name under a sid with a workflow state json is unregistered" \
    "unregistered" "$(reg classify "$SID_DATE-scratch.txt")"
check "a worker stamp log with no session behind any prefix is no-sid" \
    "no-sid" "$(reg classify "2026-09-28T01-02-03-456Z-commit-push.log")"
# The fast path: the guard's current sid needs no stat at all.
check "an unknown name under the caller's own sid is unregistered without evidence" \
    "unregistered" "$(reg classify "20991231-235959-anything.bin" "20991231-235959")"
check "the same name with no ctx sid and no evidence is no-sid" \
    "no-sid" "$(reg classify "20991231-235959-anything.bin")"
case_end

case_begin "ambiguous-kind-table" "hooks/lib/plans-artifact-registry.js"
# With a test-only table in which 'x-y.txt' and 'y.txt' are both kinds,
# 'a-x-y.txt' splits two ways — ambiguous is reported, never a silent pick.
check "a name that parses under two sid prefixes is ambiguous" \
    "ambiguous" "$(reg parse-injected "a-x-y.txt")"
check "and a name with a single parse is not" \
    "not-ambiguous" "$(reg parse-injected "a-q-y.txt")"
case_end

case_begin "format-tokens-and-kind-sets" "hooks/lib/plans-artifact-registry.js"
check "FORMAT_TOKENS lists exactly the six review formats" \
    "detail-plan,outline-plan,review-security-shared,security-code,security-plan,test-review" \
    "$(reg format-tokens)"
check "no format token is a dash-suffix of another" "none" "$(reg suffix-collisions)"
check "MIGRATABLE_KINDS is a subset of CONTROL_KINDS" "subset" "$(reg migratable-subset)"
check "a switched control kind is migratable" "yes" "$(reg migratable "detail-plan-terminal.txt")"
check "the short-lived guard-attempt marker is not migratable" "no" "$(reg migratable "guard-attempt.tmp")"
check "legacyBasename is the pre-#2434 <sid>-<name> spelling" \
    "$SID_UUID-detail-plan-terminal.txt" "$(reg legacy "$SID_UUID" "detail-plan-terminal.txt")"
check "getPlansArtifactPath throws on an unregistered kind" "threw" "$(reg artifact-path-unknown)"
check "SOURCE_LINT_EXCEPTIONS is an array" "array" "$(reg lint-exceptions)"
case_end

case_begin "sid-grammar-single-source" "hooks/lib/plans-artifact-registry.js"
# C1: the sid grammar lives in state-io/core.js only. The registry imports it
# and holds no sid regex of its own.
SRC=""
[ -f "$REG_JS" ] && SRC="$(cat "$REG_JS")"
check "the registry names SESSION_ID_VALID_RE" "yes" \
    "$(printf '%s' "$SRC" | grep -q 'SESSION_ID_VALID_RE' && printf yes || printf no)"
check "and requires it from state-io/core" "yes" \
    "$(printf '%s' "$SRC" | grep -Eq "require\([^)]*state-io/core" && printf yes || printf no)"
check "and does not redefine the sid character class" "absent" \
    "$(printf '%s' "$SRC" | grep -Fq '[A-Za-z0-9_-]+$' && printf present || printf absent)"
case_end

# ── consumers surface an unregistered detection (C5) ─────────────────────────
# The static checks above prove each consumer names the lint; these run it. A
# throwaway agents repo holds the real lint, its libraries and one source file that
# spells an unregistered PLANS name. Each consumer must fail AND print the lint's
# diagnostic, so a swallowed stdout or a stray `|| true` cannot pass. The other
# pre-commit checkers are deliberately absent, so their gates only log a skip.
CONS="$T/consumer-repo"
CONS_BAD='new-state.json'
make_tree "$CONS"
[ -f "$LINT" ] && cp "$LINT" "$CONS/bin/check-plans-artifacts"
[ -d "$AGENTS_DIR/bin/lib" ] && cp -r "$AGENTS_DIR/bin/lib" "$CONS/bin/lib"
cp -r "$AGENTS_DIR/hooks/lib" "$CONS/hooks/lib"
[ -d "$AGENTS_DIR/hooks/workflow-state" ] && cp -r "$AGENTS_DIR/hooks/workflow-state" "$CONS/hooks/workflow-state"
printf '%s\n' '#!/usr/bin/env bash' "cat \"\$PLANS_DIR/\$SID-$CONS_BAD\"" > "$CONS/bin/consumer-probe.sh"
git -C "$CONS" init -q
git -C "$CONS" config core.hooksPath /dev/null
git -C "$CONS" config core.autocrlf false
git -C "$CONS" config user.email "test@example.com"
git -C "$CONS" config user.name "Test"
git -C "$CONS" add -A

case_begin "precommit-gate-surfaces-unregistered" "hooks/lib/precommit-agents-repo-gates.sh"
PC_RC=0
PC_OUT="$(cd "$CONS" && export _cfg_dir="$CONS" AGENTS_CONFIG_DIR="$CONS" && run_with_timeout 60 bash -c '. "$1"; _precommit_agents_repo_gates' _ "$AGENTS_DIR/hooks/lib/precommit-agents-repo-gates.sh" 2>&1)" || PC_RC=$?
check "pre-commit: an unregistered PLANS name in source blocks the commit (exit 1)" "1" "$PC_RC"
check "pre-commit: the blocked commit shows the lint's diagnostic naming the file" "yes" \
  "$(printf '%s\n' "$PC_OUT" | grep -qF "$CONS_BAD" && printf yes || printf no)"
check "pre-commit: the diagnostic names the offending source file" "yes" \
  "$(printf '%s\n' "$PC_OUT" | grep -qF 'consumer-probe.sh' && printf yes || printf no)"
case_end

case_begin "ci-audit-step-surfaces-unregistered" ".github/workflows/migration-blocks-audit.yml"
# Run the workflow's own run: line (not a copy of it) the way the job does: from
# the checkout root with AGENTS_CONFIG_DIR set to the workspace.
YML="$AGENTS_DIR/.github/workflows/migration-blocks-audit.yml"
CI_CMD="$(grep -E '^[[:space:]]*run:[[:space:]]*[^|>].*check-plans-artifacts' "$YML" 2>/dev/null | head -n 1 | sed -E 's/^[[:space:]]*run:[[:space:]]*//')"
if [ -z "$CI_CMD" ]; then
  fail "ci-audit: migration-blocks-audit.yml has a one-line run: step calling check-plans-artifacts" "implementation missing"
else
  CI_RC=0
  CI_OUT="$(cd "$CONS" && export AGENTS_CONFIG_DIR="$CONS" && run_with_timeout 60 bash -c "$CI_CMD" 2>&1)" || CI_RC=$?
  check "ci-audit: the lint step fails on an unregistered PLANS name" "1" "$CI_RC"
  check "ci-audit: the job log shows the diagnostic naming the file" "yes" \
    "$(printf '%s\n' "$CI_OUT" | grep -qF "$CONS_BAD" && printf yes || printf no)"
fi
check "ci-audit: no step is allowed to fail silently (continue-on-error)" "no" \
  "$(grep -Eq 'continue-on-error:[[:space:]]*true' "$YML" 2>/dev/null && printf yes || printf no)"
case_end

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[ "$FAIL" -eq 0 ]
