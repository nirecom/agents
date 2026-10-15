#!/usr/bin/env bash
# Tests: bin/check-plans-artifacts, hooks/lib/plans-artifact-registry.js
# Tags: scope:issue-specific, TL2, plans-dir-lint, feature-2434, plans-dir, registry, table-driven, pwsh-not-required
# Part file of tests/bin/feature-2434-plans-dir-lint.sh (sourced; uses its T, TABLE_REL,
# FALLBACK_WORD, make_tree, table_tree, edit_table, run_source, run_source_gate, np, check and trim_f).
# #2638: a --source run judges with the table of the tree it scans — replaced, never
# merged with the checker's own; a present but broken table stops the run (exit 2).
# TL3 gap: the lint firing from the real pre-commit hook of a linked worktree.

has() { if printf '%s\n' "$1" | grep -qF -- "$2"; then printf yes; else printf no; fi; }
has_word() { if printf '%s\n' "$1" | grep -qi -- "$2"; then printf yes; else printf no; fi; }

CONTROL_REF='cat "$PLANS_DIR/$SID-detail-plan-terminal.txt"'

case_begin "judged-table-replaces-not-merges" "bin/check-plans-artifacts"
FX="$T/jt-replace"
if table_tree "jt-replace: fixture tree with the data file" "$FX"; then
  printf '%s\n' 'cat "$PLANS_DIR/$SID-detail.md"' > "$FX/bin/m.sh"
  run_source_gate "$FX"
  check "jt-replace: control — detail.md is an artifact under the copied table (exit 0)" "0" "$L_RC"
  if edit_table "$FX" remove-kind plan-artifact 2>/dev/null; then
    run_source_gate "$FX"
    check "jt-replace: a kind the judged table dropped is not refilled from the checker's (exit 1)" "1" "$L_RC"
    check "jt-replace: the finding names the file that still uses the dropped name" "yes" "$(has "$L_OUT" "bin/m.sh")"
  else
    fail "jt-replace: fixture edit" "remove-kind did not apply"
  fi
fi
case_end

# break_table <tree> <shape> — turn <tree>'s table into one broken shape; non-zero when it did not apply.
break_table() {
  local f="$1/$TABLE_REL"
  case "$2" in
    intact) return 0 ;;
    invalid-json) printf '%s\n' '{ "formatTokens": [' > "$f" ;;
    top-level-array) printf '%s\n' '[]' > "$f" ;;
    no-control-kinds) edit_table "$1" delete-key controlKinds ;;
    entry-without-source) edit_table "$1" drop-source survey ;;
    invalid-regex-source) edit_table "$1" set-source survey '(' ;;
    undefined-placeholder) edit_table "$1" set-source survey '%NOPE%\.md' ;;
    format-token-with-symbol) edit_table "$1" add-format-token 'bad|token' ;;
    path-is-a-directory) rm -f "$f" && mkdir "$f" ;;
    *) return 1 ;;
  esac
}

# Rows: <shape> | <expected exit>. "intact" is the control: the same tree passes untouched.
case_begin "judged-table-broken-stops-the-run" "bin/check-plans-artifacts"
while IFS='|' read -r SHAPE WANT_RC; do
  [ -z "$SHAPE" ] && continue
  case "$SHAPE" in \#*) continue ;; esac
  SHAPE="$(trim_f "$SHAPE")"; WANT_RC="$(trim_f "$WANT_RC")"
  FX="$T/jt-broken-$SHAPE"
  table_tree "jt-broken/$SHAPE: fixture tree with the data file" "$FX" || continue
  if ! break_table "$FX" "$SHAPE" 2>/dev/null; then
    fail "jt-broken/$SHAPE: fixture edit" "the shape did not apply"
    continue
  fi
  run_source_gate "$FX"
  check "jt-broken/$SHAPE: exit $WANT_RC" "$WANT_RC" "$L_RC"
  [ "$WANT_RC" = "2" ] || continue
  check "jt-broken/$SHAPE: a broken table never falls back to the checker's own" \
    "no" "$(has_word "$L_ERR$L_OUT" "$FALLBACK_WORD")"
done <<'TABLE'
intact                   | 0
invalid-json             | 2
top-level-array          | 2
no-control-kinds         | 2
entry-without-source     | 2
invalid-regex-source     | 2
undefined-placeholder    | 2
format-token-with-symbol | 2
path-is-a-directory      | 2
TABLE
case_end

case_begin "judged-table-exception-from-judged-side" "bin/check-plans-artifacts"
FX="$T/jt-exc-used"
if table_tree "jt-exception: fixture tree with the data file" "$FX"; then
  printf '%s\n' "$CONTROL_REF" > "$FX/bin/probe.sh"
  run_source_gate "$FX"
  check "jt-exception: control — the control-name reference fails without an exception (exit 1)" "1" "$L_RC"
  if edit_table "$FX" add-exception bin/probe.sh 'detail-plan-terminal\.txt' "fixture: probe reads the terminal file" 2>/dev/null; then
    run_source_gate "$FX"
    check "jt-exception: an exception listed in the judged table excuses the reference (exit 0)" "0" "$L_RC"
  else
    fail "jt-exception: fixture edit" "add-exception did not apply"
  fi
fi
case_end

case_begin "judged-table-unused-exception" "bin/check-plans-artifacts"
FX="$T/jt-exc-unused"
if table_tree "jt-unused-exception: fixture tree with the data file" "$FX"; then
  printf '%s\n' 'echo ok' > "$FX/bin/probe.sh"
  if edit_table "$FX" add-exception bin/probe.sh 'detail-plan-terminal\.txt' "fixture: nothing matches this" 2>/dev/null; then
    run_source_gate "$FX"
    check "jt-unused-exception: an exception whose scanned file no longer matches fails (exit 1)" "1" "$L_RC"
    check "jt-unused-exception: the finding says unused exception" "yes" "$(has "$L_OUT" "unused exception")"
    check "jt-unused-exception: the finding names the exception's file" "yes" "$(has "$L_OUT" "bin/probe.sh")"
  else
    fail "jt-unused-exception: fixture edit" "add-exception did not apply"
  fi
fi
case_end

case_begin "judged-table-exception-empty-reason" "bin/check-plans-artifacts"
FX="$T/jt-exc-reason"
if table_tree "jt-empty-reason: fixture tree with the data file" "$FX"; then
  printf '%s\n' "$CONTROL_REF" > "$FX/bin/probe.sh"
  if edit_table "$FX" add-exception bin/probe.sh 'detail-plan-terminal\.txt' "" 2>/dev/null; then
    run_source_gate "$FX"
    check "jt-empty-reason: an exception without a reason fails (exit 1, not a broken table)" "1" "$L_RC"
    check "jt-empty-reason: the finding says empty reason" "yes" "$(has "$L_OUT" "empty reason")"
  else
    fail "jt-empty-reason: fixture edit" "add-exception did not apply"
  fi
fi
case_end

case_begin "judged-table-invalid-retention" "bin/check-plans-artifacts"
FX="$T/jt-retention"
if table_tree "jt-retention: fixture tree with the data file" "$FX"; then
  if edit_table "$FX" set-retention survey bogus 2>/dev/null; then
    run_source_gate "$FX"
    check "jt-retention: an invalid retention class in the judged table fails (exit 1, not a broken table)" "1" "$L_RC"
    check "jt-retention: the finding names the kind" "yes" "$(has "$L_OUT" "retention class missing or invalid: survey")"
  else
    fail "jt-retention: fixture edit" "set-retention did not apply"
  fi
fi
case_end

# The judged tree is data: its own registry modules sit next to the table and must never be loaded.
case_begin "judged-tree-code-is-never-executed" "bin/check-plans-artifacts"
FX="$T/jt-noexec"
JT_MARKER="$T/jt-noexec-loaded.marker"
if table_tree "jt-noexec: fixture tree with the data file" "$FX"; then
  printf '%s\n' 'cat "$PLANS_DIR/$SID-detail.md"' > "$FX/bin/m.sh"
  for JT_MOD in plans-artifact-registry.js plans-artifact-table.js; do
    printf '%s\n' "require(\"fs\").appendFileSync(\"$(np "$JT_MARKER")\", \"$JT_MOD\\n\");" \
      "module.exports = {};" > "$FX/hooks/lib/$JT_MOD"
  done
  run_source "$FX"
  check "jt-noexec: --source <tree> gives the tree's normal verdict (exit 0)" "0" "$L_RC"
  check "jt-noexec: --source <tree> loads neither module of the judged tree" "absent" "$([ -e "$JT_MARKER" ] && tr '\n' ' ' < "$JT_MARKER" || printf absent)"
  rm -f "$JT_MARKER"
  run_source_gate "$FX"
  check "jt-noexec: the cwd form gives the same verdict (exit 0)" "0" "$L_RC"
  check "jt-noexec: the cwd form loads neither module of the judged tree" "absent" "$([ -e "$JT_MARKER" ] && tr '\n' ' ' < "$JT_MARKER" || printf absent)"
fi
case_end

cat > "$T/loader-vs-registry.js" <<'JS'
// loader-vs-registry.js <checkout root> <data file rel path> — prints "equal", or what differs
// between the loader's reading of the checkout's data file and the registry's exported tables.
"use strict";
const path = require("path");
const [root, wantRel] = process.argv.slice(2);
let loader;
try { loader = require(path.join(root, "hooks", "lib", "plans-artifact-table.js")); } catch (e) {
  console.log("MISSING-LOADER"); process.exit(0);
}
const reg = require(path.join(root, "hooks", "lib", "plans-artifact-registry.js"));
const diffs = [];
const rel = Object.values(loader).find((v) => typeof v === "string" && v.replace(/\\/g, "/") === wantRel);
if (!rel) diffs.push(`no exported string equals ${wantRel}`);
let table = null;
for (const fn of Object.values(loader).filter((v) => typeof v === "function")) {
  try {
    const t = fn(path.join(root, wantRel));
    if (t && Array.isArray(t.controlKinds) && Array.isArray(t.artifactKinds)) { table = t; break; }
  } catch (e) { /* not the loading function */ }
}
if (!table) { console.log("NO-LOADING-FUNCTION"); process.exit(0); }
const kinds = (label, got, want) => {
  if (!Array.isArray(want) || want.length === 0) { diffs.push(`${label}: registry side empty`); return; }
  if (got.length !== want.length) diffs.push(`${label}: count ${got.length} != ${want.length}`);
  want.forEach((w, i) => {
    const g = got[i] || {};
    const same = g.kind === w.kind && g.re instanceof RegExp && g.re.source === w.re.source && g.retention === w.retention;
    if (!same) diffs.push(`${label}[${i}] ${w.kind}`);
  });
};
kinds("controlKinds", table.controlKinds, reg.CONTROL_KINDS);
kinds("artifactKinds", table.artifactKinds, reg.ARTIFACT_KINDS);
const tokens = (x) => [...(x || [])].join(",");
if (tokens(table.formatTokens) === "" || tokens(table.formatTokens) !== tokens(reg.FORMAT_TOKENS)) diffs.push("formatTokens");
const wantExc = reg.SOURCE_LINT_EXCEPTIONS || [];
const gotExc = table.sourceLintExceptions || [];
if (wantExc.length === 0) diffs.push("sourceLintExceptions: registry side empty");
if (gotExc.length !== wantExc.length) diffs.push(`sourceLintExceptions: count ${gotExc.length} != ${wantExc.length}`);
wantExc.forEach((w, i) => {
  const g = gotExc[i] || {};
  const same = g.file === w.file && g.pattern instanceof RegExp && g.pattern.source === w.pattern.source && g.reason === w.reason;
  if (!same) diffs.push(`sourceLintExceptions[${i}] ${w.file}`);
});
console.log(diffs.length === 0 ? "equal" : diffs.join("; "));
JS

case_begin "loader-reading-equals-registry-exports" "hooks/lib/plans-artifact-registry.js"
LVR_OUT="$(run_with_timeout 30 node "$(np "$T/loader-vs-registry.js")" "$(np "$SCRIPT_CHECKOUT_ROOT")" "$TABLE_REL" 2>&1 | tr -d '\r')"
check "loader-vs-registry: the loader's reading of the data file equals CONTROL_KINDS / ARTIFACT_KINDS / FORMAT_TOKENS / SOURCE_LINT_EXCEPTIONS" \
  "equal" "$LVR_OUT"
case_end
true
