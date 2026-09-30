#!/usr/bin/env bash
# tests/hooks/feature-2265-checkout-identity.sh
# Tests: hooks/lib/checkout-identity.js, hooks/workflow-run-tests/provenance-identity.js
# Tags: hook, lib, checkout-identity, worktree, git-common-dir, provenance, scope:issue-specific, pwsh-not-required, TL2

set -uo pipefail

# #2265: gitCommonDir moves from provenance-identity.js into hooks/lib/checkout-identity.js so
# the bash-guard allow resolver can recognise linked worktrees of the agents checkout; this
# suite pins the shared module and that provenance-identity now consumes it.

# TL3 gap (what this test does NOT catch):
# - Git layouts this fixture does not build (bare repos, submodules, GIT_DIR overrides).
# - Real symlinked or junctioned checkouts on a developer machine.
# Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: hook-registration.

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$AGENTS_DIR/tests/lib/harness.sh"

CI_MODULE="$AGENTS_DIR/hooks/lib/checkout-identity.js"
PROV="$AGENTS_DIR/hooks/workflow-run-tests/provenance-identity.js"

T="$(make_tmp)"
trap 'rm -rf "$T"' EXIT
harness_isolate "$T/state"
cd "$T" || exit 1

commit_one() {
  git -C "$1" config core.autocrlf false
  printf 'x\n' > "$1/f.txt"
  git -C "$1" add -A
  git -C "$1" -c user.email=fixture@example.com -c user.name=fixture commit -qm fixture
}

harness_git_init "$T/main"; commit_one "$T/main"
git -C "$T/main" worktree add -q "$T/wt" 2>/dev/null
git -C "$T/main" worktree add -q "$T/wt2" 2>/dev/null
# wt2 loses its commondir file: identity must come from the worktrees/<name> nesting fallback.
rm -f "$T/main/.git/worktrees/wt2/commondir"
harness_git_init "$T/foreign"; commit_one "$T/foreign"
git -C "$T/foreign" worktree add -q "$T/fakewt" 2>/dev/null
harness_git_init "$T/main/vendor/nested"
mkdir -p "$T/main/sub/deep" "$T/wt/sub" "$T/foreign/x" "$T/plain/x" "$T/main/vendor/nested/sub" \
  "$T/fakewt/sub" "$T/broken" "$T/dangling"
printf 'this is not a gitdir line\n' > "$T/broken/.git"
printf 'gitdir: %s\n' "$(np "$T/nowhere/.git/worktrees/ghost")" > "$T/dangling/.git"

# probe <fn> <arg...> -> a label (MAIN_GIT, FOREIGN_GIT, MAIN, WT, ...), "null", OTHER:<path>,
# or <MISSING:...> when the module or export is absent.
cat > "$T/probe.js" <<'JS'
const fs = require("fs");
const [mod, fn, ...args] = process.argv.slice(2);
let m;
try { m = require(mod); } catch (e) { process.stdout.write("<MISSING:module>"); process.exit(0); }
if (typeof m[fn] !== "function") { process.stdout.write(`<MISSING:${fn}>`); process.exit(0); }
const canon = (p) => { let r = p; try { r = fs.realpathSync(p); } catch (e) {} r = r.split("\\").join("/").replace(/\/+$/, "");
  return process.platform === "win32" ? r.toLowerCase() : r; };
let out;
try { out = m[fn](...args); } catch (e) { process.stdout.write(`<THREW:${e.message}>`); process.exit(0); }
if (out === null) { process.stdout.write("null"); process.exit(0); }
const labels = JSON.parse(process.env.CI_LABELS);
const hit = Object.keys(labels).find((k) => canon(labels[k]) === canon(String(out)));
process.stdout.write(hit || `OTHER:${out}`);
JS
probe() {
  CI_LABELS="{\"MAIN_GIT\":\"$(np "$T/main/.git")\",\"FOREIGN_GIT\":\"$(np "$T/foreign/.git")\",\"MAIN\":\"$(np "$T/main")\",\"WT\":\"$(np "$T/wt")\",\"WT2\":\"$(np "$T/wt2")\",\"NESTED\":\"$(np "$T/main/vendor/nested")\",\"FAKEWT\":\"$(np "$T/fakewt")\",\"FOREIGN\":\"$(np "$T/foreign")\"}" \
    run_with_timeout 30 node "$(np "$T/probe.js")" "$(np "$CI_MODULE")" "$@"
}

check() {
  if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1" "want=[$2] got=[$3]"; fi
}

# ci_table: stdin rows `fn | dir | anchor | want | description`, dir/anchor relative to $T,
# `-` = no anchor argument. Each row counts toward CI_ROWS so an empty table cannot pass.
CI_ROWS=0
ci_table() {
  local fn dir anchor want desc got
  while IFS='|' read -r fn dir anchor want desc; do
    fn="${fn//[[:space:]]/}"; dir="${dir//[[:space:]]/}"; anchor="${anchor//[[:space:]]/}"; want="${want//[[:space:]]/}"
    [[ -z "$fn" || "$fn" == \#* ]] && continue
    CI_ROWS=$((CI_ROWS + 1))
    if [[ "$anchor" == "-" ]]; then got="$(probe "$fn" "$(np "$T/$dir")")"
    else got="$(probe "$fn" "$(np "$T/$dir")" "$(np "$T/$anchor")")"; fi
    check "$fn:${desc}" "$want" "$got"
  done
}

case_begin "git-common-dir-main-and-worktrees" "hooks/lib/checkout-identity.js"
ci_table <<'TABLE'
gitCommonDir | main    | - | MAIN_GIT    | main checkout (.git directory) -> its .git
gitCommonDir | wt      | - | MAIN_GIT    | linked worktree (.git file -> commondir) -> main .git
gitCommonDir | wt2     | - | MAIN_GIT    | worktree without commondir -> worktrees/<name> fallback
gitCommonDir | foreign | - | FOREIGN_GIT | foreign repo -> its own .git
gitCommonDir | fakewt  | - | FOREIGN_GIT | worktree of the foreign repo -> foreign .git
TABLE
case_end

case_begin "git-common-dir-non-checkouts" "hooks/lib/checkout-identity.js"
ci_table <<'TABLE'
gitCommonDir | plain    | - | null | plain directory -> null
gitCommonDir | broken   | - | null | .git file without a gitdir line -> null
gitCommonDir | dangling | - | null | .git file pointing at a missing gitdir -> null
TABLE
case_end

case_begin "checkout-root-of-same-repository" "hooks/lib/checkout-identity.js"
ci_table <<'TABLE'
checkoutRootOf | main/sub/deep | main | MAIN | main subdirectory -> main root
checkoutRootOf | wt/sub        | main | WT   | linked worktree subdirectory -> worktree root
checkoutRootOf | wt            | main | WT   | linked worktree root itself -> worktree root
checkoutRootOf | wt2           | main | WT2  | worktree without commondir -> worktree root
TABLE
case_end

case_begin "checkout-root-of-foreign-and-plain" "hooks/lib/checkout-identity.js"
ci_table <<'TABLE'
checkoutRootOf | foreign/x              | main  | null | foreign repo -> null
checkoutRootOf | fakewt/sub             | main  | null | worktree of a foreign repo -> null
checkoutRootOf | plain/x                | main  | null | plain directory -> null
checkoutRootOf | main/vendor/nested/sub | main  | null | nested foreign repo inside main stops at its own .git -> null
checkoutRootOf | main/sub               | plain | null | anchor that is not a checkout -> null
TABLE
check "checkout-identity: all 17 table rows executed" "17" "$CI_ROWS"
case_end

# prov_has <regex> -> yes / no, or missing when the file itself is gone (never a silent "no").
prov_has() {
  [[ -f "$PROV" ]] || { printf 'missing'; return; }
  if grep -Eq "$1" "$PROV"; then printf 'yes'; else printf 'no'; fi
}

case_begin "provenance-identity-consumes-shared-module" "hooks/workflow-run-tests/provenance-identity.js"
# One owner for repository identity: the provenance check reuses the shared module.
check "provenance-identity.js requires ../lib/checkout-identity" "yes" \
  "$(prov_has 'require\(["'"'"']\.\./lib/checkout-identity(\.js)?["'"'"']\)')"
check "provenance-identity.js no longer defines its own gitCommonDir" "no" "$(prov_has '^function gitCommonDir')"
check "verifyEmitterIdentity still accepts this checkout's tests/run-all.sh" "true" \
  "$(run_with_timeout 30 node -e 'const m = require(process.argv[1]); process.stdout.write(String(m.verifyEmitterIdentity("run-all", process.argv[2], process.argv[3])));' \
    "$(np "$PROV")" "$(np "$AGENTS_DIR/tests/run-all.sh")" "$(np "$AGENTS_DIR")")"
case_end

# verifyEmitterIdentity trusts the module's OWN repository, so the behavioural rows run a copy of
# the module (and all of hooks/lib it may require) committed into a temp repo E/main, then ask it
# about an emitter reached through E/wt (same repo) and E/fwt (a foreign repo's worktree).
E="$T/emit"
harness_git_init "$E/main"
mkdir -p "$E/main/hooks/workflow-run-tests" "$E/main/tests"
cp -r "$AGENTS_DIR/hooks/lib" "$E/main/hooks/lib"
cp "$PROV" "$E/main/hooks/workflow-run-tests/provenance-identity.js"
printf '#!/usr/bin/env bash\n' > "$E/main/tests/run-all.sh"
commit_one "$E/main"
git -C "$E/main" worktree add -q "$E/wt" 2>/dev/null
harness_git_init "$E/foreign"
mkdir -p "$E/foreign/tests"
printf '#!/usr/bin/env bash\n' > "$E/foreign/tests/run-all.sh"
commit_one "$E/foreign"
git -C "$E/foreign" worktree add -q "$E/fwt" 2>/dev/null
mkdir -p "$E/wt/tests/sub"

# em_table: stdin rows `claimed | cwd | want | description`; `abs:<p>` = absolute $E/<p>,
# anything else is passed verbatim; cwd is relative to $E.
EM_ROWS=0
em_table() {
  local claimed cwd want desc got
  while IFS='|' read -r claimed cwd want desc; do
    claimed="${claimed//[[:space:]]/}"; cwd="${cwd//[[:space:]]/}"; want="${want//[[:space:]]/}"
    [[ -z "$claimed" || "$claimed" == \#* ]] && continue
    EM_ROWS=$((EM_ROWS + 1))
    [[ "$claimed" == abs:* ]] && claimed="$(np "$E/${claimed#abs:}")"
    got="$(run_with_timeout 30 node -e 'const m = require(process.argv[1]); process.stdout.write(String(m.verifyEmitterIdentity("run-all", process.argv[2], process.argv[3])));' \
      "$(np "$E/main/hooks/workflow-run-tests/provenance-identity.js")" "$claimed" "$(np "$E/$cwd")" 2>&1)"
    check "verifyEmitterIdentity:${desc}" "$want" "$got"
  done
}

case_begin "verify-emitter-identity-worktrees" "hooks/workflow-run-tests/provenance-identity.js"
em_table <<'TABLE'
tests/run-all.sh          | main      | true  | control: the module's own main checkout
tests/run-all.sh          | wt        | true  | same-repo linked worktree, relative spelling
abs:wt/tests/run-all.sh   | wt/tests/sub | true | same-repo linked worktree, absolute spelling
tests/run-all.sh          | fwt       | false | foreign repo's worktree, relative spelling
abs:fwt/tests/run-all.sh  | fwt       | false | foreign repo's worktree, absolute spelling
abs:fwt/tests/run-all.sh  | wt        | false | foreign emitter claimed from a same-repo worktree
TABLE
check "verifyEmitterIdentity: all 6 table rows executed" "6" "$EM_ROWS"
case_end

echo ""
echo "Total: $PASS passed, $FAIL failed, $SKIP skipped"
[[ "$FAIL" -gt 0 ]] && exit 1
exit 0
