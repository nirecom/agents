# Group: js orphan removal on an ES module (package.json "type": "module")
# Tests: bin/lib/test-retire-predicate.sh, bin/lib/test-retire-predicate/orphan-removal.sh
# Tags: TL2, bin, case-markers, js, esm, scope:issue-specific
# Sourced by tests/bin/feature-2502-retire-per-case.sh (fresh, retire, survivors_kept come from there).
# node's module-syntax detection is switched off for every node run here, so the nearest
# package.json alone decides whether `import`/`export` parse: the rewrite checked in a temp dir
# that package.json does not reach would be refused.

ESM_REL=tests/bin/feature-9999-esm.js
ESM_NODE_OPTIONS=--no-experimental-detect-module

# esm_fixture <name> <with-package-json:1|0> — prints a fresh checkout holding the committed
# ES-module sample (live case alpha, orphan case gone, a top-level export) and, when asked,
# tests/bin/package.json with "type": "module".
esm_fixture() {
  local co
  co="$(fresh "$1")"
  cat >"$co/$ESM_REL" <<'JS'
// Tests: bin/a.sh, bin/gone.sh
// Tags: TL2, scope:issue-specific
import test from "node:test";
import assert from "node:assert";
import { caseBegin, caseEnd } from "../lib/harness.js";

export const helper = () => 1;

caseBegin("alpha", "bin/a.sh");
test("alpha", () => {
  assert.strictEqual(helper(), 1);
});
caseEnd();

caseBegin("gone", "bin/gone.sh");
test("gone", () => {
  assert.ok(true);
});
caseEnd();
JS
  if [[ "$2" == 1 ]]; then printf '{"type":"module"}\n' >"$co/tests/bin/package.json"; fi
  git -C "$co" add -A >/dev/null
  git -C "$co" commit -q -m esm-sample
  printf '%s' "$co"
}

esm_parses() {
  NODE_OPTIONS="$ESM_NODE_OPTIONS" node --check "$(np "$1")" >/dev/null 2>&1
}

case_begin "js-esm-partial-orphan-removed" "bin/lib/test-retire-predicate/orphan-removal.sh"
CO="$(esm_fixture esm-ok 1)"
cp "$CO/$ESM_REL" "$TMPBASE/esm-orig.js"
OUT="$(NODE_OPTIONS="$ESM_NODE_OPTIONS" retire "$CO" "$ESM_REL" -)"
has_line "esm: verdict is partial-orphan in case mode" "$OUT" "VERDICT=partial-orphan MODE=case ORPHANS=1"
has_line "esm: removal rc 0" "$OUT" "RC=0"
has_line "esm: removal names gone" "$OUT" "gone"
if esm_parses "$CO/$ESM_REL"; then pass "esm: node --check accepts the rewrite as an ES module"; else fail "esm: node --check accepts the rewrite as an ES module" "$(head -c 300 "$TMPBASE/retire.err")"; fi
assert_eq "esm alpha: $(grep -c '^caseBegin("alpha"' "$CO/$ESM_REL"), gone: $(grep -cE 'caseBegin\("gone"|^test\("gone"' "$CO/$ESM_REL"), export: $(grep -c '^export const helper = ' "$CO/$ESM_REL"), imports: $(grep -c '^import ' "$CO/$ESM_REL")" \
  "esm alpha: 1, gone: 0, export: 1, imports: 3"
survivors_kept esm "$TMPBASE/esm-orig.js" "$CO/$ESM_REL"
assert_eq "esm staged: $(git -C "$CO" diff --cached --name-only)" "esm staged: $ESM_REL"
case_end

# Control: without the package.json the same rewrite does not parse as a module, so the
# syntax-check refuses it — the passing case above is decided by the package.json beside the file.
case_begin "js-esm-without-package-json-refused" "bin/lib/test-retire-predicate/orphan-removal.sh"
CO="$(esm_fixture esm-nopkg 0)"
OUT="$(NODE_OPTIONS="$ESM_NODE_OPTIONS" retire "$CO" "$ESM_REL" -)"
has_line "esm without package.json: the verdict still asks for case removal" "$OUT" "VERDICT=partial-orphan MODE=case ORPHANS=1"
has_line "esm without package.json: the syntax-check refuses the rewrite" "$OUT" "RC=1"
if grep -q 'syntax-check' "$TMPBASE/retire.err"; then pass "esm without package.json: the WARNING names the syntax-check"; else fail "esm without package.json: the WARNING names the syntax-check" "$(head -c 300 "$TMPBASE/retire.err")"; fi
if git -C "$CO" diff --quiet -- "$ESM_REL"; then pass "esm without package.json: the file is unchanged"; else fail "esm without package.json: the file is unchanged" "rewritten"; fi
assert_eq "esm without package.json staged: [$(git -C "$CO" diff --cached --name-only)]" "esm without package.json staged: []"
case_end

case_begin "js-esm-changed-after-verdict-not-cut" "bin/lib/test-retire-predicate/orphan-removal.sh"
CO="$(esm_fixture esm-edit 1)"
OUT="$(NODE_OPTIONS="$ESM_NODE_OPTIONS" retire "$CO" "$ESM_REL" - '$a // edited')"
has_line "esm edited after the verdict: the removal refuses the changed file" "$OUT" "RC=1"
assert_eq "esm edited after the verdict: gone left $(grep -c '^caseBegin("gone"' "$CO/$ESM_REL"), last line [$(tail -n 1 "$CO/$ESM_REL")], staged [$(git -C "$CO" diff --cached --name-only)]" \
  "esm edited after the verdict: gone left 1, last line [// edited], staged []"
case_end

unset ESM_REL ESM_NODE_OPTIONS
