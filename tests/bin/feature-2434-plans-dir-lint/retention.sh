#!/usr/bin/env bash
# Tests: hooks/lib/plans-artifact-registry.js, bin/check-plans-artifacts
# Tags: scope:common, TL1, TL2, registry, retention, sweep-plans, plans-dir, plans-dir-lint, table-driven, pwsh-not-required
# Part file of tests/bin/feature-2434-plans-dir-lint.sh (sourced; uses its T, LINT,
# REG_JS, TABLE_REL, edit_table, check and trim_f). Retention class per registry kind (plan / user-requested
# / non-plan; unknown is a classification result only): coverage, the fixed
# assignment, retentionClassOf and the lint red path.
# TL3 gap: none — the registry and the lint are pure node, exercised here for real.

RDRIVER="$T/retention-driver.js"
cat > "$RDRIVER" <<'JS'
// retention-driver.js <op> <args...> — one registry call, printed as one line.
const [op, ...args] = process.argv.slice(2);
let reg;
try { reg = require(process.env.REG_N); } catch (e) { console.log("MISSING-REGISTRY"); process.exit(0); }
const all = () => [...(reg.CONTROL_KINDS || []), ...(reg.ARTIFACT_KINDS || [])];
try {
  switch (op) {
    case "classes":
      console.log(Array.isArray(reg.RETENTION_CLASSES) ? [...reg.RETENTION_CLASSES].join(",") : "MISSING-FN");
      break;
    case "coverage": {
      if (typeof reg.retentionCoverageErrors !== "function") { console.log("MISSING-FN"); break; }
      const errs = reg.retentionCoverageErrors();
      console.log(Array.isArray(errs) ? `n=${errs.length}` : "not-array");
      break;
    }
    case "every-entry-classed": {
      const cls = new Set(reg.RETENTION_CLASSES || []);
      const bad = all().filter((e) => !cls.has(e.retention)).map((e) => e.kind);
      console.log(cls.size === 0 ? "MISSING-FN" : (bad.join(",") || "all"));
      break;
    }
    case "coverage-injected": {
      if (typeof reg.retentionCoverageErrors !== "function") { console.log("MISSING-FN"); break; }
      const table = {
        controlKinds: [{ kind: "ctl-ok", re: /^a\.txt$/, retention: "non-plan" }, { kind: "ctl-missing", re: /^b\.txt$/ }],
        artifactKinds: [{ kind: "art-bad", re: /^c\.md$/, retention: "record" }],
      };
      console.log([...reg.retentionCoverageErrors(table)].sort().join(";") || "none");
      break;
    }
    case "kinds-with":
      console.log(all().filter((e) => e.retention === args[0]).map((e) => e.kind).sort().join(",") || "none");
      break;
    case "class":
      console.log(typeof reg.retentionClassOf === "function" ? String(reg.retentionClassOf(args[0], args[1])) : "MISSING-FN");
      break;
    case "parse": {
      const r = reg.parsePlansEntry(args[0]);
      console.log(r ? `${r.verdict}:${r.kind || "-"}` : "null");
      break;
    }
    case "artifact-path":
      console.log(require("path").basename(reg.getPlansArtifactPath(args[0], args[1], { topic: args[2], ext: args[3], plansDir: process.env.WORKFLOW_PLANS_DIR })));
      break;
    default:
      console.log("bad-op");
  }
} catch (e) {
  console.log("THREW:" + (e && e.message ? e.message.split("\n")[0] : e));
}
JS

rreg() { node "$(np "$RDRIVER")" "$@" 2>/dev/null | tr -d '\r'; }
RT_SID="0f1b93d2-f399-4d09-8c5a-ad600b98f49c"

case_begin "RT1-retention-coverage-clean" "hooks/lib/plans-artifact-registry.js"
check "RT1 RETENTION_CLASSES is exactly plan,user-requested,non-plan" "plan,user-requested,non-plan" "$(rreg classes)"
check "RT1 retentionCoverageErrors() over the real tables is empty" "n=0" "$(rreg coverage)"
check "RT1 every CONTROL/ARTIFACT entry carries a class from RETENTION_CLASSES" "all" "$(rreg every-entry-classed)"
case_end

case_begin "RT1b-retention-coverage-injected" "hooks/lib/plans-artifact-registry.js"
check "RT1b an injected table reports the classless and the invalid kind, not the valid one" \
  "art-bad: record;ctl-missing: undefined" "$(rreg coverage-injected)"
case_end

case_begin "RT2-retention-assignment-fixed" "hooks/lib/plans-artifact-registry.js"
check "RT2 the plan class is exactly {plan-artifact}" "plan-artifact" "$(rreg kinds-with plan)"
check "RT2 the user-requested class is exactly {user-requested}" "user-requested" "$(rreg kinds-with user-requested)"
case_end

case_begin "RT3-retention-class-of" "hooks/lib/plans-artifact-registry.js"
while IFS='|' read -r name want; do
  [ -z "$name" ] && continue
  case "$name" in \#*) continue ;; esac
  name="$(trim_f "$name")"; want="$(trim_f "$want")"
  [ "$name" = "<empty>" ] && name=""
  name="${name//__SID__/$RT_SID}"
  check "RT3 retentionClassOf($(printf '%q' "$name")) is $want" "$want" "$(rreg class "$name" "$RT_SID")"
done <<'TABLE'
__SID__-detail.md                                   | plan
__SID__-context.md                                  | plan
__SID__-user-requested-project-progress.md          | user-requested
__SID__-user-requested-2544-pre-2561-carryover.md   | user-requested
__SID__-survey-code.md                              | non-plan
__SID__-concerns-log.md                             | non-plan
__SID__-note-topic.md                               | non-plan
__SID__-handoff.md                                  | non-plan
# control outranks the artifact reading of the trailing context.md
__SID__-codex-context.md                            | non-plan
__SID__-sweep-plans-approved-sessions.txt           | non-plan
# unknown: unregistered, ambiguous, sid mismatch, outside the grammar, empty, sid-less
__SID__-history-staging.md                          | unknown
__SID__-note-intent.md                              | unknown
__SID__-b1-note-x.md                                | unknown
__SID__-user-requested-.md                          | unknown
__SID__-user-requested-Topic.md                     | unknown
<empty>                                             | unknown
-intent.md                                          | unknown
TABLE
case_end

case_begin "RT4-user-requested-kind" "hooks/lib/plans-artifact-registry.js"
check "RT4 parsePlansEntry reads <sid>-user-requested-<topic>.md as the user-requested artifact" \
  "artifact:user-requested" "$(rreg parse "$RT_SID-user-requested-project-progress.md")"
check "RT4 getPlansArtifactPath builds <sid>-user-requested-<topic>.md" \
  "$RT_SID-user-requested-x.md" "$(rreg artifact-path "$RT_SID" user-requested x)"
case_end

# RT4b rows: <ext> | <class of <sid>-user-requested-x.<ext>> | <path builder: accept / reject>
case_begin "RT4b-user-requested-extensions" "hooks/lib/plans-artifact-registry.js"
while IFS='|' read -r ext want_class want_path; do
  [ -z "$ext" ] && continue
  case "$ext" in \#*) continue ;; esac
  ext="$(trim_f "$ext")"; want_class="$(trim_f "$want_class")"; want_path="$(trim_f "$want_path")"
  base="$RT_SID-user-requested-x.$ext"
  check "RT4b [.$ext] retentionClassOf($base) is $want_class" "$want_class" "$(rreg class "$base" "$RT_SID")"
  got="$(rreg artifact-path "$RT_SID" user-requested x "$ext")"
  if [ "$want_path" = "accept" ]; then
    check "RT4b [.$ext] getPlansArtifactPath builds $base" "$base" "$got"
  else
    check "RT4b [.$ext] getPlansArtifactPath rejects the extension (throws)" "THREW" "${got%%:*}"
  fi
done <<'TABLE'
md     | user-requested | accept
txt    | user-requested | accept
json   | user-requested | accept
tsv    | user-requested | accept
# unsupported: outside the kind's (md|txt|json|tsv) alternation, incl. case and near-miss
log    | unknown        | reject
jsonl  | unknown        | reject
yaml   | unknown        | reject
MD     | unknown        | reject
TABLE
case_end

case_begin "RT5-lint-retention-red-path" "bin/check-plans-artifacts"
# The lint's --source run is the commit-time gate: a kind whose class is invalid
# must stop it, and the unmodified copy must stay clean (sanctioned counterpart).
run_lint_tree() {
  local tree="$1"
  L_RC=0
  L_OUT="$(cd "$tree" && run_with_timeout 60 node "$(np "$tree/bin/check-plans-artifacts")" --source "$(np "$tree")" 2>&1)" || L_RC=$?
}
make_lint_tree() {
  local tree="$1"
  mkdir -p "$tree/bin" "$tree/hooks" "$tree/skills" "$tree/agents" "$tree/rules" "$tree/docs"
  cp "$LINT" "$tree/bin/check-plans-artifacts"
  cp -r "$SCRIPT_CHECKOUT_ROOT/hooks/lib" "$tree/hooks/lib"
  cp -r "$SCRIPT_CHECKOUT_ROOT/hooks/workflow-state" "$tree/hooks/workflow-state"
}
CLEAN="$T/lint-clean"
make_lint_tree "$CLEAN"
run_lint_tree "$CLEAN"
check "RT5 the unmodified registry copy passes --source (exit 0)" "0" "$L_RC"

BAD="$T/lint-bad"
make_lint_tree "$BAD"
if ! edit_table "$BAD" set-retention plan-artifact bogus 2>/dev/null; then
  fail "RT5 fixture: the copied tree carries the data file with a plan-artifact entry" "rewrite did not apply ($BAD/$TABLE_REL missing or without that kind)"
else
  run_lint_tree "$BAD"
  check "RT5 an invalid retention class fails --source (exit 1)" "1" "$L_RC"
  check "RT5 the lint names the kind with the invalid class" "yes" \
    "$(printf '%s\n' "$L_OUT" | grep -qF 'retention class missing or invalid: plan-artifact' && printf yes || printf no)"
fi
case_end
true
