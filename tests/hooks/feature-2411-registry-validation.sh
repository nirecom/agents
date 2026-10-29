#!/usr/bin/env bash
# tests/hooks/feature-2411-registry-validation.sh
# Tests: hooks/lib/test-language-registry/validate.js, hooks/lib/test-language-registry.json
# Tags: TL2, hooks, test-language-registry, validation, table-driven, scope:issue-specific, pwsh-not-required
# #2411 registry fields: codeLanguage.{sourcePatterns,shebangInterpreters}, newFileNameShape,
# notationDoc, diagnostics.markerWrapHint, and the caseMarkerReader + helperLibrary pair.
# Every fixture table is the real table plus those fields, mutated in a temp root that holds
# the files the table names; validate(table, root) is called directly, the real file is only read.
set -uo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

if ! command -v node >/dev/null 2>&1; then
  echo "SKIP: node not available"
  exit 77
fi

TMPBASE="$(make_tmp)"
readonly TMPBASE
trap 'rm -rf "$TMPBASE"' EXIT
harness_isolate "$TMPBASE/iso"
cd "$TMPBASE" || exit 1

FX_ROOT="$TMPBASE/root"
mkdir -p "$FX_ROOT"
DRIVER_M="$(np "$TMPBASE/driver.js")"
VALIDATE_M="$(np "$SCRIPT_CHECKOUT_ROOT/hooks/lib/test-language-registry/validate.js")"
REAL_M="$(np "$SCRIPT_CHECKOUT_ROOT/hooks/lib/test-language-registry.json")"
REAL_ROOT_M="$(np "$SCRIPT_CHECKOUT_ROOT")"
BASE_M="$(np "$TMPBASE/base.json")"
ROOT_M="$(np "$FX_ROOT")"

cat >"$TMPBASE/driver.js" <<'JS'
"use strict";
const fs = require("fs");
const path = require("path");
const [mode, validatePath, tablePath, root, extra] = process.argv.slice(2);
const { validate } = require(validatePath);
const isObj = (v) => v !== null && typeof v === "object" && !Array.isArray(v);
const isStr = (v) => typeof v === "string";
const clone = (v) => JSON.parse(JSON.stringify(v));
const table = JSON.parse(fs.readFileSync(tablePath, "utf8"));
const supported = table.entries.filter((e) => e.status === "supported");
const out = [];

// A rejection is validate's own error; anything else thrown is a crash, not a verdict.
function verdict(t, r) {
  try {
    validate(t, r);
    return { v: "accept", msg: "" };
  } catch (e) {
    const msg = String(e && e.message).replace(/\s+/g, " ");
    return { v: msg.startsWith("test-language-registry: ") ? "reject" : "crash", msg };
  }
}

// Number of fields that differ; a string array counts as one field.
function diffs(a, b) {
  const objs = (x) => Array.isArray(x) && x.every(isObj);
  if (isObj(a) && isObj(b)) {
    return [...new Set([...Object.keys(a), ...Object.keys(b)])].reduce((n, k) => n + diffs(a[k], b[k]), 0);
  }
  if (objs(a) && objs(b) && a.length === b.length) return a.reduce((n, x, i) => n + diffs(x, b[i]), 0);
  return JSON.stringify(a) === JSON.stringify(b) ? 0 : 1;
}

if (mode === "setup") {
  table.entries.forEach((e, i) => {
    if (e.status !== "supported") return;
    e.codeLanguage = { sourcePatterns: [`*.fx${i}`], shebangInterpreters: [`fx${i}`] };
    e.newFileNameShape = `fx-<name>.fx${i}`;
    e.notationDoc = `fx/notation-${e.id}.md`;
    e.diagnostics = Object.assign({}, e.diagnostics, { markerWrapHint: `wrap every ${e.id} case` });
    e.caseMarkerReader = e.caseMarkerReader || { file: `fx/reader-${e.id}.sh`, function: "fx_reader" };
    e.helperLibrary = e.helperLibrary || { path: `fx/helper-${e.id}.txt`, sourceRegex: "fx-helper" };
    e.envClearLine = e.envClearLine || { file: `fx/env-clear-${e.id}.sh`, function: "fx_env_clear" };
  });
  for (const e of table.entries) {
    const named = [e.launch && e.launch.wrapper, e.helperLibrary && e.helperLibrary.path, e.notationDoc];
    for (const k of ["caseMarkerReader", "caseEmbedRules", "tableDrivenDetector", "envClearLine"]) named.push(e[k] && e[k].file);
    for (const rel of named.filter(isStr)) {
      fs.mkdirSync(path.dirname(path.join(root, rel)), { recursive: true });
      fs.writeFileSync(path.join(root, rel), "");
    }
  }
  fs.writeFileSync(extra, JSON.stringify(table, null, 2));
  out.push(`supported=${supported.length}`);
} else if (mode === "real") {
  const r = verdict(clone(table), root);
  out.push(`verdict=${r.v}${r.msg ? ` msg=${r.msg}` : ""}`);
} else if (mode === "facts") {
  const has = (rel) => isStr(rel) && rel !== "" && fs.existsSync(path.join(root, rel));
  const strs = (v, min) => (Array.isArray(v) && v.length >= min && v.every((s) => isStr(s) && s !== "") ? "ok" : "bad");
  out.push(`supported\t${supported.map((e) => e.id).join(",")}`);
  for (const e of supported) {
    const c = isObj(e.codeLanguage) ? e.codeLanguage : {};
    const d = isObj(e.diagnostics) ? e.diagnostics : {};
    const h = isObj(e.helperLibrary) ? e.helperLibrary : {};
    out.push(`pair\t${e.id}\treader=${isObj(e.caseMarkerReader) ? "yes" : "no"} helper=${isObj(e.helperLibrary) ? "yes" : "no"} helperFile=${has(h.path) ? "yes" : "no"}`);
    out.push(`fields\t${e.id}\tsourcePatterns=${strs(c.sourcePatterns, 1)} shebangInterpreters=${strs(c.shebangInterpreters, 0)}`
      + ` newFileNameShape=${isStr(e.newFileNameShape) && e.newFileNameShape !== "" && !e.newFileNameShape.includes(",") ? "ok" : "bad"}`
      + ` notationDoc=${has(e.notationDoc) ? "ok" : "bad"} markerWrapHint=${isStr(d.markerWrapHint) && d.markerWrapHint !== "" ? "ok" : "bad"}`);
  }
  for (const e of table.entries) {
    const c = e.envClearLine;
    out.push(`env\t${e.id}\t${c === null ? "null" : !isObj(c) ? "absent" : `${c.file}|${c.function}|exists=${has(c.file) ? "yes" : "no"}`}`);
  }
} else {
  // rows: name|entry-id|field[,field]|js — js edits t; e is the entry with that id.
  for (const line of fs.readFileSync(extra, "utf8").split("\n")) {
    const [name, id, field, ...js] = line.split("|");
    if (!name) continue;
    const t = clone(table);
    new Function("t", "e", js.join("|"))(t, t.entries.find((x) => x.id === id));
    const r = verdict(clone(t), root);
    const named = field.split(",").some((f) => f !== "" && r.msg.includes(f));
    out.push(mode === "accept" ? `${name}\tverdict=${r.v}${r.msg ? ` msg=${r.msg}` : ""}`
      : `${name}\tverdict=${r.v} diffs=${diffs(table, t)} names-field=${named ? "yes" : "no"}`);
  }
}
process.stdout.write(out.join("\n") + "\n");
JS

# run_rows <accept|reject> — "name|entry-id|field|js" rows on stdin, each one edit of the base
# fixture. reject wants validate's own error naming the field, from a fixture <n> fields away
# (second argument, default 1; a cross-entry pair edits two entries).
run_rows() {
  local mode="$1" want="verdict=accept" name rest out got
  [ "$mode" = accept ] || want="verdict=reject diffs=${2:-1} names-field=yes"
  cat >"$TMPBASE/rows.txt"
  out="$(node "$DRIVER_M" "$mode" "$VALIDATE_M" "$BASE_M" "$ROOT_M" "$(np "$TMPBASE/rows.txt")" 2>&1)"
  while IFS='|' read -r name rest; do
    [ -n "$name" ] || continue
    got="$(printf '%s\n' "$out" | awk -F'\t' -v n="$name" '$1 == n { print $2; exit }')"
    assert_eq "$name: ${got:-no result ($(printf '%s' "$out" | head -n 2 | tr '\n' ' '))}" "$name: $want"
  done <"$TMPBASE/rows.txt"
}

SETUP_OUT="$(node "$DRIVER_M" setup "$VALIDATE_M" "$REAL_M" "$ROOT_M" "$BASE_M" 2>&1)"

# ---- PIN: green before and after the change ----

case_begin "pin-real-registry-validates" "hooks/lib/test-language-registry.json"
got="$(node "$DRIVER_M" real "$VALIDATE_M" "$REAL_M" "$REAL_ROOT_M" 2>&1)"
assert_eq "real registry: $got" "real registry: verdict=accept"
case_end

case_begin "pin-well-formed-new-fields-accept" "hooks/lib/test-language-registry/validate.js"
case "$SETUP_OUT" in
  supported=0 | "") fail "fixture base built" "got [$SETUP_OUT]" ;;
  supported=*) pass "fixture base built ($SETUP_OUT)" ;;
  *) fail "fixture base built" "got [$SETUP_OUT]" ;;
esac
run_rows accept <<'ROWS'
base-all-new-fields||x|
source-patterns-two-strings|bash|x|e.codeLanguage.sourcePatterns = ["*.fxa", "*.fxb"];
shebang-interpreters-two-strings|bash|x|e.codeLanguage.shebangInterpreters = ["fxa", "fxb"];
new-file-name-shape-other-string|pytest|x|e.newFileNameShape = "test_<name>.fx";
notation-doc-other-existing-file|pester|x|e.notationDoc = t.entries.find((o) => o.id === "bash").notationDoc;
marker-wrap-hint-other-string|bash|x|e.diagnostics.markerWrapHint = "wrap each case, then rerun";
helper-path-other-existing-file|bash|x|e.helperLibrary.path = e.notationDoc;
source-patterns-distinct-between-entries|pester|x|e.codeLanguage.sourcePatterns = ["*.fxp1", "*.fxp2"];
reader-and-helper-both-present|pester|x|e.caseMarkerReader = Object.assign({}, e.caseMarkerReader, { file: "fx/reader-pester.sh", function: "fx_other" });
reader-and-helper-both-absent|js|x|e.caseMarkerReader = null; e.helperLibrary = null;
ROWS
case_end

case_begin "pin-existing-rejections-still-reject" "hooks/lib/test-language-registry/validate.js"
run_rows reject <<'ROWS'
control-helper-path-with-tab|bash|helperLibrary.path|e.helperLibrary.path = "fx/a\tb.sh";
control-helper-not-object|bash|helperLibrary|e.helperLibrary = "fx/helper.sh";
control-diagnostics-not-object|bash|diagnostics|e.diagnostics = "x";
control-wrapper-missing-file|pester|launch.wrapper|e.launch.wrapper = "fx/no-such-wrapper.ps1";
ROWS
case_end

# ---- FUTURE: red until validate.js gains the check ----

case_begin "future-new-field-wrong-type-rejects" "hooks/lib/test-language-registry/validate.js"
run_rows reject <<'ROWS'
code-language-not-object|bash|codeLanguage|e.codeLanguage = "sh";
source-patterns-string|bash|codeLanguage.sourcePatterns|e.codeLanguage.sourcePatterns = "*.fx0";
source-patterns-number-item|bash|codeLanguage.sourcePatterns|e.codeLanguage.sourcePatterns = [7];
shebang-interpreters-string|bash|codeLanguage.shebangInterpreters|e.codeLanguage.shebangInterpreters = "fx0";
shebang-interpreters-number-item|bash|codeLanguage.shebangInterpreters|e.codeLanguage.shebangInterpreters = [7];
new-file-name-shape-number|pytest|newFileNameShape|e.newFileNameShape = 7;
new-file-name-shape-array|pytest|newFileNameShape|e.newFileNameShape = ["fx-<name>.fx"];
notation-doc-number|pester|notationDoc|e.notationDoc = 7;
notation-doc-object|pester|notationDoc|e.notationDoc = { path: "fx/notation-pester.md" };
marker-wrap-hint-number|bash|diagnostics.markerWrapHint|e.diagnostics.markerWrapHint = 7;
marker-wrap-hint-object|js|diagnostics.markerWrapHint|e.diagnostics.markerWrapHint = { text: "wrap" };
ROWS
case_end

case_begin "future-new-field-tab-newline-comma-rejects" "hooks/lib/test-language-registry/validate.js"
run_rows reject <<'ROWS'
source-patterns-item-tab|bash|codeLanguage.sourcePatterns|e.codeLanguage.sourcePatterns = ["*.f\tx"];
source-patterns-item-newline|bash|codeLanguage.sourcePatterns|e.codeLanguage.sourcePatterns = ["*.f\nx"];
shebang-interpreters-item-tab|bash|codeLanguage.shebangInterpreters|e.codeLanguage.shebangInterpreters = ["f\tx"];
shebang-interpreters-item-newline|bash|codeLanguage.shebangInterpreters|e.codeLanguage.shebangInterpreters = ["f\nx"];
new-file-name-shape-tab|pytest|newFileNameShape|e.newFileNameShape = "fx-<name>\t.fx";
new-file-name-shape-newline|pytest|newFileNameShape|e.newFileNameShape = "fx-<name>\n.fx";
new-file-name-shape-comma|pytest|newFileNameShape|e.newFileNameShape = "fx-<name>.fx,fx-<name>.fy";
notation-doc-tab|pester|notationDoc|e.notationDoc = "fx/notation\t-pester.md";
notation-doc-newline|pester|notationDoc|e.notationDoc = "fx/notation\n-pester.md";
marker-wrap-hint-tab|bash|diagnostics.markerWrapHint|e.diagnostics.markerWrapHint = "wrap\tevery case";
marker-wrap-hint-newline|js|diagnostics.markerWrapHint|e.diagnostics.markerWrapHint = "wrap\nevery case";
ROWS
case_end

case_begin "future-named-file-missing-rejects" "hooks/lib/test-language-registry/validate.js"
run_rows reject <<'ROWS'
notation-doc-missing-file|pester|notationDoc|e.notationDoc = "fx/no-such-notation.md";
helper-library-path-missing-file|bash|helperLibrary.path|e.helperLibrary.path = "fx/no-such-helper.sh";
helper-library-path-missing-file-new-entry|pytest|helperLibrary.path|e.helperLibrary.path = "fx/no-such-helper.py";
ROWS
case_end

# shellcheck source=feature-2411-registry-validation/source-patterns-overlap.sh
source "$SCRIPT_CHECKOUT_ROOT/tests/hooks/feature-2411-registry-validation/source-patterns-overlap.sh"

case_begin "future-reader-without-helper-or-reverse-rejects" "hooks/lib/test-language-registry/validate.js"
run_rows reject <<'ROWS'
reader-without-helper|pester|caseMarkerReader,helperLibrary|e.helperLibrary = null;
helper-without-reader|pytest|caseMarkerReader,helperLibrary|e.caseMarkerReader = null;
helper-without-reader-first-entry|bash|caseMarkerReader,helperLibrary|e.caseMarkerReader = null;
ROWS
case_end

FACTS="$(node "$DRIVER_M" facts "$VALIDATE_M" "$REAL_M" "$REAL_ROOT_M" 2>&1)"
# fact_of <kind> <id> — that entry's fact line from the real table.
fact_of() { printf '%s\n' "$FACTS" | awk -F'\t' -v k="$1" -v i="$2" '$1 == k && $2 == i { print $3; exit }'; }

case_begin "future-real-registry-three-languages-carry-reader-and-helper" "hooks/lib/test-language-registry.json"
for id in pester pytest js; do
  assert_eq "$id: $(fact_of pair "$id")" "$id: reader=yes helper=yes helperFile=yes"
done
case_end

case_begin "future-real-registry-supported-entries-carry-new-fields" "hooks/lib/test-language-registry.json"
SUPPORTED_IDS="$(printf '%s\n' "$FACTS" | awk -F'\t' '$1 == "supported" { print $2; exit }')"
if [ -z "$SUPPORTED_IDS" ]; then
  fail "real registry lists supported entries" "facts=[$(printf '%s' "$FACTS" | head -n 2 | tr '\n' ' ')]"
fi
for id in ${SUPPORTED_IDS//,/ }; do
  assert_eq "$id: $(fact_of fields "$id")" "$id: sourcePatterns=ok shebangInterpreters=ok newFileNameShape=ok notationDoc=ok markerWrapHint=ok"
done
case_end

# ---- envClearLine: the tombstone guard's per-language clear-line part ----

case_begin "pin-env-clear-line-well-formed-accepts" "hooks/lib/test-language-registry/validate.js"
run_rows accept <<'ROWS'
env-clear-line-recognized-only-null|test-naming-convention|x|e.envClearLine = null;
env-clear-line-recognized-only-absent|test-naming-convention|x|delete e.envClearLine;
env-clear-line-other-existing-file|bash|x|e.envClearLine.file = t.entries.find((o) => o.id === "js").envClearLine.file;
env-clear-line-other-function-name|js|x|e.envClearLine.function = "fx_other_clear_2";
ROWS
case_end

case_begin "future-env-clear-line-required-on-supported-rejects" "hooks/lib/test-language-registry/validate.js"
run_rows reject <<'ROWS'
env-clear-line-missing-first-entry|bash|envClearLine|delete e.envClearLine;
env-clear-line-missing-last-supported|js|envClearLine|delete e.envClearLine;
env-clear-line-null-on-supported|pester|envClearLine|e.envClearLine = null;
env-clear-line-file-missing|pytest|envClearLine|e.envClearLine.file = "fx/no-such-env-clear.sh";
ROWS
case_end

case_begin "future-env-clear-line-shape-rejects" "hooks/lib/test-language-registry/validate.js"
run_rows reject <<'ROWS'
env-clear-line-function-hyphen|bash|envClearLine|e.envClearLine.function = "bad-name";
env-clear-line-function-empty|pester|envClearLine|e.envClearLine.function = "";
env-clear-line-file-absolute|pytest|envClearLine|e.envClearLine.file = "/abs/env-clear.sh";
env-clear-line-not-object|js|envClearLine|e.envClearLine = "bin/lib/test-language-parts/js.sh";
ROWS
case_end

# Every #2411 field is required on a supported entry: neither absent nor null is accepted.
case_begin "future-new-field-absent-or-null-on-supported-rejects" "hooks/lib/test-language-registry/validate.js"
run_rows reject <<'ROWS'
code-language-absent|bash|codeLanguage|delete e.codeLanguage;
code-language-null|bash|codeLanguage|e.codeLanguage = null;
new-file-name-shape-absent|pytest|newFileNameShape|delete e.newFileNameShape;
new-file-name-shape-null|pytest|newFileNameShape|e.newFileNameShape = null;
notation-doc-absent|pester|notationDoc|delete e.notationDoc;
notation-doc-null|pester|notationDoc|e.notationDoc = null;
marker-wrap-hint-absent|js|diagnostics.markerWrapHint|delete e.diagnostics.markerWrapHint;
marker-wrap-hint-null|js|diagnostics.markerWrapHint|e.diagnostics.markerWrapHint = null;
env-clear-line-null-first-entry|bash|envClearLine|e.envClearLine = null;
ROWS
case_end

# A named file must sit under the root without "..", even when the path resolves back inside it.
case_begin "future-named-file-traversal-rejects" "hooks/lib/test-language-registry/validate.js"
run_rows reject <<'ROWS'
notation-doc-dot-dot|pester|notationDoc|e.notationDoc = "fx/../" + e.notationDoc;
helper-library-path-dot-dot|bash|helperLibrary.path|e.helperLibrary.path = "tests/../" + e.helperLibrary.path;
env-clear-line-file-dot-dot|js|envClearLine|e.envClearLine.file = "fx/../" + e.envClearLine.file;
ROWS
case_end

case_begin "future-real-registry-env-clear-line-per-entry" "hooks/lib/test-language-registry.json"
for id in bash pester pytest js; do
  assert_eq "$id: $(fact_of env "$id")" "$id: hooks/lib/test-gates/parts/env-clear/$id.js|envClearLine|exists=yes"
done
assert_eq "test-naming-convention: $(fact_of env test-naming-convention)" "test-naming-convention: null"
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
