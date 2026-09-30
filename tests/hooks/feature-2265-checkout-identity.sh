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
# wt2 loses its commondir file: with no `../..` nesting fallback (F1) it is no longer a checkout.
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
  CI_LABELS="{\"MAIN_GIT\":\"$(np "$T/main/.git")\",\"FOREIGN_GIT\":\"$(np "$T/foreign/.git")\",\"MAIN\":\"$(np "$T/main")\",\"WT\":\"$(np "$T/wt")\",\"WT2\":\"$(np "$T/wt2")\",\"NESTED\":\"$(np "$T/main/vendor/nested")\",\"FAKEWT\":\"$(np "$T/fakewt")\",\"FOREIGN\":\"$(np "$T/foreign")\",\"WTREL\":\"$(np "$T/wtrel")\",\"WT4\":\"$(np "$T/wt4")\"}" \
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
gitCommonDir | wt2     | - | null        | worktree without commondir -> null (no ../.. fallback)
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
checkoutRootOf | wt2           | main | null | worktree without commondir -> null (no ../.. fallback)
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

# F1 (#2265 review_security): a `.git` FILE is a linked worktree only when its gitdir exists
# directly under <common>/worktrees/ and that gitdir's `gitdir` back-reference names THIS
# `.git`; a `.git` DIRECTORY only when it is not a link to another checkout's `.git`.
# forged: gitdir names a nonexistent worktrees/<name> of main (one-line forgery).
# stolen: gitdir names wt's REAL registration, whose back-reference names wt, not stolen.
# outside: a hand-made gitdir outside <common>/worktrees/ with commondir + gitdir back-reference.
mkdir -p "$T/forged/sub" "$T/stolen/sub" "$T/outside/sub" "$T/outside-gd"
printf 'gitdir: %s\n' "$(np "$T/main/.git/worktrees/ghost-forged")" > "$T/forged/.git"
printf 'gitdir: %s\n' "$(np "$T/main/.git/worktrees/wt")" > "$T/stolen/.git"
printf '%s\n' "$(np "$T/main/.git")" > "$T/outside-gd/commondir"
printf '%s\n' "$(np "$T/outside/.git")" > "$T/outside-gd/gitdir"
printf 'gitdir: %s\n' "$(np "$T/outside-gd")" > "$T/outside/.git"
# junction: an unrelated dir whose `.git` is a directory link to main's real `.git`.
# mainlink: the whole main checkout reached through a link (control: must stay accepted).
mkdir -p "$T/junction/sub"
ci_link() {
  run_with_timeout 30 node -e 'require("fs").symlinkSync(process.argv[1], process.argv[2], "junction")' "$(np "$1")" "$(np "$2")" 2>/dev/null
}
CI_LINKS=yes
ci_link "$T/main/.git" "$T/junction/.git" || CI_LINKS=no
ci_link "$T/main" "$T/mainlink" || CI_LINKS=no

case_begin "f1-forged-gitdir-rejected" "hooks/lib/checkout-identity.js"
CI_ROWS=0
check "F1 vacuity: forged gitdir target really does not exist" "absent" \
  "$([[ -e "$T/main/.git/worktrees/ghost-forged" ]] && echo present || echo absent)"
check "F1 vacuity: stolen gitdir is wt's real registration" "yes" \
  "$([[ -f "$T/main/.git/worktrees/wt/gitdir" ]] && echo yes || echo no)"
ci_table <<'TABLE'
gitCommonDir   | forged      | -    | null | (a) .git file -> nonexistent main worktrees/<name> -> null
checkoutRootOf | forged/sub  | main | null | (a) forged worktree subdirectory -> null
gitCommonDir   | stolen      | -    | null | (b) .git file -> another worktree's registration -> null
checkoutRootOf | stolen/sub  | main | null | (b) stolen registration subdirectory -> null
gitCommonDir   | outside     | -    | null | (c) gitdir outside <common>/worktrees/ -> null
checkoutRootOf | outside/sub | main | null | (c) out-of-tree gitdir subdirectory -> null
TABLE
check "F1: all 6 forged-gitdir rows executed" "6" "$CI_ROWS"
case_end

case_begin "f1-linked-dot-git-directory-rejected" "hooks/lib/checkout-identity.js"
if [[ "$CI_LINKS" == yes ]]; then
  CI_ROWS=0
  ci_table <<'TABLE'
gitCommonDir   | junction     | -    | null     | (d) .git linked to main's .git -> null
checkoutRootOf | junction/sub | main | null     | (d) linked-.git subdirectory -> null
gitCommonDir   | mainlink     | -    | MAIN_GIT | control: whole checkout reached through a link -> main .git
checkoutRootOf | mainlink/sub | main | MAIN     | control: linked checkout subdirectory -> main root
TABLE
  check "F1: all 4 linked-.git rows executed" "4" "$CI_ROWS"
else
  skip "F1 (d): directory link creation failed on this host"
fi
case_end

# (e) controls: genuine checkouts built by `git init` / `git worktree add` keep resolving.
case_begin "f1-genuine-checkouts-still-accepted" "hooks/lib/checkout-identity.js"
CI_ROWS=0
ci_table <<'TABLE'
gitCommonDir   | main          | -    | MAIN_GIT | control: genuine main checkout -> main .git
gitCommonDir   | wt            | -    | MAIN_GIT | control: genuine linked worktree -> main .git
checkoutRootOf | main/sub/deep | main | MAIN     | control: genuine main subdirectory -> main root
checkoutRootOf | wt/sub        | wt   | WT       | control: genuine worktree anchored on itself -> worktree root
TABLE
check "F1: all 4 genuine-checkout rows executed" "4" "$CI_ROWS"
case_end

# decoy: a gitdir that mimics `worktrees/x` by NAME only, under a lookalike dir outside the real
# <common>/worktrees/, with a correct back-reference and commondir -> main .git.
mkdir -p "$T/decoy/sub" "$T/decoyco/worktrees/x"
printf 'gitdir: %s\n' "$(np "$T/decoyco/worktrees/x")" > "$T/decoy/.git"
printf '%s\n' "$(np "$T/decoy/.git")" > "$T/decoyco/worktrees/x/gitdir"
printf '%s\n' "$(np "$T/main/.git")" > "$T/decoyco/worktrees/x/commondir"
# wt3: a real registration whose `<gitdir>/gitdir` back-reference file was deleted.
git -C "$T/main" worktree add -q "$T/wt3" 2>/dev/null
mkdir -p "$T/wt3/sub"
rm -f "$T/main/.git/worktrees/wt3/gitdir"

case_begin "f1-decoy-and-missing-backref-rejected" "hooks/lib/checkout-identity.js"
check "F1 vacuity: decoy gitdir exists" "yes" "$([[ -d "$T/decoyco/worktrees/x" ]] && echo yes || echo no)"
check "F1 vacuity: decoy back-reference names decoy/.git" "$(np "$T/decoy/.git")" \
  "$(tr -d '\r\n' < "$T/decoyco/worktrees/x/gitdir")"
check "F1 vacuity: wt3 registration exists without its back-reference" "yes" \
  "$([[ -f "$T/main/.git/worktrees/wt3/commondir" && ! -e "$T/main/.git/worktrees/wt3/gitdir" ]] && echo yes || echo no)"
CI_ROWS=0
ci_table <<'TABLE'
gitCommonDir   | decoy      | -    | null | decoy worktrees/x outside <common>/worktrees/ -> null
checkoutRootOf | decoy/sub  | main | null | decoy worktrees/x subdirectory -> null
gitCommonDir   | wt3        | -    | null | registration with its gitdir back-reference deleted -> null
checkoutRootOf | wt3/sub    | main | null | back-reference-less registration subdirectory -> null
TABLE
check "F1: all 4 decoy/back-reference rows executed" "4" "$CI_ROWS"
case_end

# symfile: an unrelated dir whose `.git` FILE is a symlink to wt's genuine `.git` file. The
# back-reference names wt/.git, so this dir must not inherit wt's identity.
mkdir -p "$T/symfile/sub"
case_begin "f1-symlinked-dot-git-file-rejected" "hooks/lib/checkout-identity.js"
if run_with_timeout 30 node -e 'require("fs").symlinkSync(process.argv[1], process.argv[2], "file")' \
    "$(np "$T/wt/.git")" "$(np "$T/symfile/.git")" 2>/dev/null; then
  CI_ROWS=0
  ci_table <<'TABLE'
gitCommonDir   | symfile     | -    | null | .git file symlinked to wt's .git file -> null
checkoutRootOf | symfile/sub | main | null | symlinked-.git-file subdirectory -> null
TABLE
  check "F1: all 2 symlinked-.git-file rows executed" "2" "$CI_ROWS"
else
  skip "F1: file symlink creation failed on this host (symlinked .git file rows)"
fi
case_end

# wtrel: genuine worktree with RELATIVE gitdir / back-reference (git >= 2.48).
# wt4: genuine worktree whose `.git` file is rewritten to reach its registration through `..`.
# dotdot: a forged `..` spelling that lands on a nonexistent worktrees/<name>.
git -C "$T/main" worktree add -q "$T/wt4" 2>/dev/null
mkdir -p "$T/wt4/sub" "$T/dotdot/sub"
printf 'gitdir: %s\n' "$(np "$T/main/.git/worktrees")/../worktrees/wt4" > "$T/wt4/.git"
printf 'gitdir: %s\n' "$(np "$T/main/.git/worktrees")/wt/../ghost-dotdot" > "$T/dotdot/.git"

case_begin "f1-dotdot-gitdir-spellings" "hooks/lib/checkout-identity.js"
CI_ROWS=0
ci_table <<'TABLE'
gitCommonDir   | wt4        | -    | MAIN_GIT | control: genuine registration reached via .. -> main .git
checkoutRootOf | wt4/sub    | main | WT4      | control: genuine .. -spelled worktree subdirectory -> root
gitCommonDir   | dotdot     | -    | null     | forged .. spelling onto a nonexistent worktrees/<name> -> null
checkoutRootOf | dotdot/sub | main | null     | forged .. spelling subdirectory -> null
TABLE
check "F1: all 4 dotdot rows executed" "4" "$CI_ROWS"
case_end

case_begin "f1-relative-paths-worktree-accepted" "hooks/lib/checkout-identity.js"
if git -C "$T/main" worktree add -q --relative-paths "$T/wtrel" 2>/dev/null; then
  mkdir -p "$T/wtrel/sub"
  check "F1 vacuity: wtrel back-reference is relative" "relative" \
    "$(grep -Eq '^([A-Za-z]:|/)' "$T/main/.git/worktrees/wtrel/gitdir" && echo absolute || echo relative)"
  CI_ROWS=0
  ci_table <<'TABLE'
gitCommonDir   | wtrel     | -    | MAIN_GIT | control: --relative-paths worktree -> main .git
checkoutRootOf | wtrel/sub | main | WTREL    | control: --relative-paths worktree subdirectory -> root
TABLE
  check "F1: all 2 relative-paths rows executed" "2" "$CI_ROWS"
else
  skip "F1: git worktree add --relative-paths unsupported by this git"
fi
case_end

# Windows spellings of the same genuine checkouts: case-folded, lowercase drive, MSYS /c/...
case_begin "f1-win32-path-spellings-accepted" "hooks/lib/checkout-identity.js"
CI_WT="$(np "$T/wt")"; CI_MAIN="$(np "$T/main")"
if [[ "$CI_WT" =~ ^([A-Za-z]):(/.*)$ ]]; then
  CI_WT_MSYS="/${BASH_REMATCH[1],,}${BASH_REMATCH[2]}"
  [[ "$CI_MAIN" =~ ^([A-Za-z]):(/.*)$ ]]
  CI_MAIN_MSYS="/${BASH_REMATCH[1],,}${BASH_REMATCH[2]}"
  check "gitCommonDir: upper-cased worktree spelling -> main .git" "MAIN_GIT" "$(probe gitCommonDir "${CI_WT^^}")"
  check "gitCommonDir: lower-cased worktree spelling -> main .git" "MAIN_GIT" "$(probe gitCommonDir "${CI_WT,,}")"
  check "gitCommonDir: lowercase-drive worktree spelling -> main .git" "MAIN_GIT" "$(probe gitCommonDir "${CI_WT,}")"
  check "gitCommonDir: lower-cased main spelling -> main .git" "MAIN_GIT" "$(probe gitCommonDir "${CI_MAIN,,}")"
  check "checkoutRootOf: upper-cased worktree under lower-cased anchor -> worktree root" "WT" \
    "$(probe checkoutRootOf "${CI_WT^^}/SUB" "${CI_MAIN,,}")"
  check "checkoutRootOf: MSYS worktree spelling under MSYS anchor -> worktree root" "WT" \
    "$(probe checkoutRootOf "$CI_WT_MSYS/sub" "$CI_MAIN_MSYS")"
  check "checkoutRootOf: MSYS main subdirectory under native anchor -> main root" "MAIN" \
    "$(probe checkoutRootOf "$CI_MAIN_MSYS/sub/deep" "$CI_MAIN")"
else
  skip "F1: Windows drive-letter spellings not applicable on this host"
fi
case_end

# decoy2: a `..` spelling that climbs OUT of <common>/worktrees/ into a lookalike
# decoyco2/worktrees/x carrying a correct back-reference and commondir -> main .git.
mkdir -p "$T/decoy2/sub" "$T/decoyco2/worktrees/x"
printf 'gitdir: %s\n' "$(np "$T/main/.git/worktrees")/../../../decoyco2/worktrees/x" > "$T/decoy2/.git"
printf '%s\n' "$(np "$T/decoy2/.git")" > "$T/decoyco2/worktrees/x/gitdir"
printf '%s\n' "$(np "$T/main/.git")" > "$T/decoyco2/worktrees/x/commondir"
# wt5: a real registration whose commondir file exists but is empty.
git -C "$T/main" worktree add -q "$T/wt5" 2>/dev/null
mkdir -p "$T/wt5/sub"
: > "$T/main/.git/worktrees/wt5/commondir"

case_begin "f1-dotdot-escape-and-empty-commondir-rejected" "hooks/lib/checkout-identity.js"
check "F1 vacuity: decoyco2/worktrees/x exists" "yes" "$([[ -d "$T/decoyco2/worktrees/x" ]] && echo yes || echo no)"
check "F1 vacuity: decoyco2 back-reference names decoy2/.git" "$(np "$T/decoy2/.git")" \
  "$(tr -d '\r\n' < "$T/decoyco2/worktrees/x/gitdir")"
check "F1 vacuity: wt5 commondir exists and is empty" "yes" \
  "$([[ -f "$T/main/.git/worktrees/wt5/commondir" && ! -s "$T/main/.git/worktrees/wt5/commondir" ]] && echo yes || echo no)"
CI_ROWS=0
ci_table <<'TABLE'
gitCommonDir   | decoy2     | -    | null | .. escapes <common>/worktrees/ into a lookalike -> null
checkoutRootOf | decoy2/sub | main | null | .. escape subdirectory -> null
gitCommonDir   | wt5        | -    | null | registration with an empty commondir -> null
checkoutRootOf | wt5/sub    | main | null | empty-commondir registration subdirectory -> null
TABLE
check "F1: all 4 dotdot-escape/empty-commondir rows executed" "4" "$CI_ROWS"
case_end

# wtlink: the genuine worktree wt reached through a directory link on its PARENT path. Its
# `.git` is a regular file (not a link), so realpath(wtlink/.git) == wt/.git == the
# back-reference: accepted. Contrast f1-symlinked-dot-git-file-rejected, where `.git` ITSELF
# is the link inside an unrelated directory.
case_begin "f1-linked-parent-of-genuine-worktree-accepted" "hooks/lib/checkout-identity.js"
if ci_link "$T/wt" "$T/wtlink"; then
  check "F1 vacuity: wtlink/.git is a regular file, not a link" "yes" \
    "$([[ -f "$T/wtlink/.git" && ! -L "$T/wtlink/.git" ]] && echo yes || echo no)"
  CI_ROWS=0
  ci_table <<'TABLE'
gitCommonDir   | wtlink     | -    | MAIN_GIT | control: genuine worktree via linked parent -> main .git
checkoutRootOf | wtlink/sub | main | WT       | control: linked-parent worktree subdirectory -> worktree root
TABLE
  check "F1: all 2 linked-parent rows executed" "2" "$CI_ROWS"
else
  skip "F1: directory link creation failed on this host (linked-parent worktree rows)"
fi
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

# F1: a directory that only CLAIMS to be a worktree of E/main (forged `.git` file, or `.git`
# linked to E/main's real `.git`) must not make its own tests/run-all.sh a trusted emitter.
mkdir -p "$E/forged/tests" "$E/linked/tests"
printf 'gitdir: %s\n' "$(np "$E/main/.git/worktrees/ghost-forged")" > "$E/forged/.git"
printf '#!/usr/bin/env bash\n' > "$E/forged/tests/run-all.sh"
printf '#!/usr/bin/env bash\n' > "$E/linked/tests/run-all.sh"
EM_LINKED=yes
ci_link "$E/main/.git" "$E/linked/.git" || EM_LINKED=no

case_begin "f1-verify-emitter-identity-forged-checkouts" "hooks/workflow-run-tests/provenance-identity.js"
EM_ROWS=0
em_table <<'TABLE'
tests/run-all.sh           | forged | false | forged gitdir dir, relative spelling
abs:forged/tests/run-all.sh | forged | false | forged gitdir dir, absolute spelling
TABLE
check "verifyEmitterIdentity: all 2 forged rows executed" "2" "$EM_ROWS"
if [[ "$EM_LINKED" == yes ]]; then
  EM_ROWS=0
  em_table <<'TABLE'
tests/run-all.sh           | linked | false | .git linked to E/main's .git, relative spelling
abs:linked/tests/run-all.sh | linked | false | .git linked to E/main's .git, absolute spelling
TABLE
  check "verifyEmitterIdentity: all 2 linked rows executed" "2" "$EM_ROWS"
else
  skip "F1: directory link creation failed on this host (linked-.git emitter rows)"
fi
case_end

echo ""
echo "Total: $PASS passed, $FAIL failed, $SKIP skipped"
[[ "$FAIL" -gt 0 ]] && exit 1
exit 0
