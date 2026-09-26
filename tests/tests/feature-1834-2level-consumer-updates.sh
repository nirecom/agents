#!/usr/bin/env bash
# tests/tests/feature-1834-2level-consumer-updates.sh
# Tests: tests/run-all.sh, bin/select-tests.sh, bin/audit-tests.sh, bin/audit-tests-common.sh
# Tags: scope:issue-specific
# TL2 (#1834): post-migration enumeration of tests/<category>/<name>.sh across
# hooks/bin/skills/agents/install/tests. Whole file SKIPs (77) until the
# migration lands (tests/hooks/ present); PASSes once consumers are updated.
# TL3 gap: live run-tests/pre-commit corpus enumeration is covered by the
# day-to-day run-all invocation, not here.

set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$AGENTS_DIR/tests/lib/harness.sh"

# --- Skip guard: post-migration state not present yet ----------------------
if [[ ! -d "$AGENTS_DIR/tests/hooks" ]]; then
  echo "SKIP: 2-level tests/ migration not yet applied (tests/hooks/ absent)"
  exit 77
fi

RUN_ALL="$AGENTS_DIR/tests/run-all.sh"
SELECT_TESTS="$AGENTS_DIR/bin/select-tests.sh"
AUDIT_TESTS="$AGENTS_DIR/bin/audit-tests.sh"
AUDIT_TESTS_COMMON="$AGENTS_DIR/bin/audit-tests-common.sh"

TMP_ROOT="$(make_tmp)"
trap 'rm -rf "$TMP_ROOT"' EXIT

CATEGORIES=(hooks bin skills agents install tests)

# write_min <path> — a minimal, runnable test-shaped file.
# Single-redirect body: no `} >file` brace-group idiom, so the static case
# parser's depth tracker never miscounts these helpers (kept balanced so the
# marker pairs below sit at depth 0).
write_min() {
  mkdir -p "$(dirname "$1")"
  printf '#!/usr/bin/env bash\necho ok\n' > "$1"
}

# write_notests <path> <scope-value> — a test-shaped file WITHOUT a `# Tests:`
# header (Tags-only), so audit scanners surface a NO_TESTS_HEADER diagnostic
# naming its path. Single-redirect body (see write_min).
write_notests() {
  mkdir -p "$(dirname "$1")"
  printf '#!/usr/bin/env bash\n# Tags: scope:%s\necho hi\n' "$2" > "$1"
}

case_begin "run-all-enum" "tests/run-all.sh"
# =====================================================================
# 1a/1b/1c — run-all.sh --all enumeration (fixture TESTS_DIR)
# =====================================================================
FIX_TESTS="$TMP_ROOT/fixture-tests"
mkdir -p "$FIX_TESTS"
for cat in "${CATEGORIES[@]}"; do
  write_min "$FIX_TESTS/$cat/case-$cat.sh"
done
# Non-category dirs that must NOT be enumerated as tests.
write_min "$FIX_TESTS/lib/helper-lib.sh"
write_min "$FIX_TESTS/fixtures/some-fixture.sh"
write_min "$FIX_TESTS/__pycache__/cached.sh"
# Top-level file that must NOT be enumerated (run-all.sh itself lives here).
write_min "$FIX_TESTS/toplevel-orphan.sh"
# _archive dir must NOT be enumerated as tests (archived files are retired).
write_min "$FIX_TESTS/_archive/archived.sh"

PLAN="$(TESTS_DIR="$FIX_TESTS" RUN_ALL_PROGRESS=off bash "$RUN_ALL" --print-plan --all 2>/dev/null || true)"

plan_has() { printf '%s\n' "$PLAN" | grep -q -- "$1"; }

# 1a: every category subdir file is enumerated.
missing_cat=""
for cat in "${CATEGORIES[@]}"; do
  plan_has "/$cat/case-$cat.sh" || missing_cat="$missing_cat $cat"
done
if [[ -z "$missing_cat" ]]; then
  pass "1a run-all --all enumerates all six category subdirs"
else
  fail "1a run-all --all enumerates all six category subdirs" "missing:$missing_cat plan=[$PLAN]"
fi

# 1b: non-category dirs (lib/fixtures/__pycache__/_archive) and top-level files excluded.
leaked=""
plan_has "/lib/helper-lib.sh" && leaked="$leaked lib"
plan_has "/fixtures/some-fixture.sh" && leaked="$leaked fixtures"
plan_has "/__pycache__/cached.sh" && leaked="$leaked __pycache__"
plan_has "/toplevel-orphan.sh" && leaked="$leaked toplevel"
plan_has "/_archive/archived.sh" && leaked="$leaked _archive"
if [[ -z "$leaked" ]]; then
  pass "1b run-all --all excludes lib/fixtures/__pycache__/_archive and top-level files"
else
  fail "1b run-all --all excludes non-category dirs" "leaked:$leaked plan=[$PLAN]"
fi

# 1c: run-all.sh does not enumerate itself (real repo, real script).
REAL_PLAN="$(cd "$AGENTS_DIR" && RUN_ALL_PROGRESS=off bash "$RUN_ALL" --print-plan --all 2>/dev/null || true)"
if printf '%s\n' "$REAL_PLAN" | grep -E '^plan' | grep -q -- '/run-all\.sh$'; then
  fail "1c run-all --all excludes tests/run-all.sh itself" "run-all.sh appears in the plan"
else
  pass "1c run-all --all excludes tests/run-all.sh itself"
fi

# 1a_noarg: run-all with no --all flag uses the same code path (WANT_ALL || $# -eq 0).
PLAN_NOARG="$(TESTS_DIR="$FIX_TESTS" RUN_ALL_PROGRESS=off bash "$RUN_ALL" --print-plan 2>/dev/null || true)"
missing_noarg=""
for cat in "${CATEGORIES[@]}"; do
  printf '%s\n' "$PLAN_NOARG" | grep -q -- "/$cat/case-$cat.sh" || missing_noarg="$missing_noarg $cat"
done
if [[ -z "$missing_noarg" ]]; then
  pass "1a_noarg run-all (no --all flag) enumerates all six category subdirs"
else
  fail "1a_noarg run-all (no --all flag) enumerates all six category subdirs" "missing:$missing_noarg plan=[$PLAN_NOARG]"
fi

# =====================================================================
# 1f — run-all.sh split-pair layout: a category top-level dispatcher is work,
#      but its sibling <name>/ sub-file is NOT (it is sourced by the dispatcher,
#      never enumerated as an independent test).
# =====================================================================
FIX_SPLIT="$TMP_ROOT/fixture-split"
mkdir -p "$FIX_SPLIT/hooks/my-dispatcher"
write_min "$FIX_SPLIT/hooks/my-dispatcher.sh"
write_min "$FIX_SPLIT/hooks/my-dispatcher/part.sh"

SPLIT_PLAN="$(TESTS_DIR="$FIX_SPLIT" RUN_ALL_PROGRESS=off bash "$RUN_ALL" --print-plan --all 2>/dev/null || true)"
split_has() { printf '%s\n' "$SPLIT_PLAN" | grep -q -- "$1"; }

if split_has '/hooks/my-dispatcher.sh' && ! split_has '/hooks/my-dispatcher/part.sh'; then
  pass "1f run-all --all enumerates the split dispatcher but not its <name>/ sub-file"
else
  fail "1f run-all --all split-pair: dispatcher in / sub-file out" "plan=[$SPLIT_PLAN]"
fi
case_end

case_begin "select-stem" "bin/select-tests.sh"
# =====================================================================
# 1d — select-tests.sh stem-match into tests/hooks/ subdir
# =====================================================================
ST_REPO="$TMP_ROOT/select-repo"
mkdir -p "$ST_REPO/bin"
git -C "$ST_REPO" init -q
git -C "$ST_REPO" config core.hooksPath /dev/null
git -C "$ST_REPO" config core.autocrlf false
git -C "$ST_REPO" config user.email "t@example.com"
git -C "$ST_REPO" config user.name "t"
# Copy the real (post-migration) selector so TESTS_DIR resolves inside the fixture.
cp "$SELECT_TESTS" "$ST_REPO/bin/select-tests.sh"
printf 'init\n' > "$ST_REPO/README.md"
git -C "$ST_REPO" add -A >/dev/null 2>&1
git -C "$ST_REPO" commit -q -m "initial" >/dev/null 2>&1
BASE_SHA="$(git -C "$ST_REPO" rev-parse HEAD)"
# Changed source file whose stem must match a test in the hooks/ subdir.
mkdir -p "$ST_REPO/hooks" "$ST_REPO/tests/hooks"
printf '// changed\n' > "$ST_REPO/hooks/some-widget.js"
write_min "$ST_REPO/tests/hooks/some-widget.sh"
git -C "$ST_REPO" add -A >/dev/null 2>&1
git -C "$ST_REPO" commit -q -m "change" >/dev/null 2>&1

ST_OUT="$(cd "$ST_REPO" && bash "$ST_REPO/bin/select-tests.sh" "$BASE_SHA" 2>/dev/null || true)"
if printf '%s\n' "$ST_OUT" | grep -q -- '/tests/hooks/some-widget.sh'; then
  pass "1d select-tests stem-match finds tests in tests/hooks/ subdir"
else
  fail "1d select-tests stem-match finds tests in tests/hooks/ subdir" "out=[$ST_OUT]"
fi

# =====================================================================
# 1g — select-tests.sh stem-match reaches a test in EVERY category subdir
#      (hooks/bin/skills/agents/install/tests), and does NOT descend into a
#      split dispatcher's <name>/ children.
# =====================================================================
ST6_REPO="$TMP_ROOT/select-repo-6cat"
mkdir -p "$ST6_REPO/bin"
git -C "$ST6_REPO" init -q
git -C "$ST6_REPO" config core.hooksPath /dev/null
git -C "$ST6_REPO" config core.autocrlf false
git -C "$ST6_REPO" config user.email "t@example.com"
git -C "$ST6_REPO" config user.name "t"
cp "$SELECT_TESTS" "$ST6_REPO/bin/select-tests.sh"
printf 'init\n' > "$ST6_REPO/README.md"
git -C "$ST6_REPO" add -A >/dev/null 2>&1
git -C "$ST6_REPO" commit -q -m "initial" >/dev/null 2>&1
ST6_BASE="$(git -C "$ST6_REPO" rev-parse HEAD)"

# Changed source files, one distinct >=3-char stem each (the shapes select-tests
# derives stems from: hooks/*.js, bin/*, skills/*/SKILL.md, agents/*.md).
mkdir -p "$ST6_REPO/hooks" "$ST6_REPO/skills/charlie-widget" "$ST6_REPO/agents"
printf '// c\n' > "$ST6_REPO/hooks/alpha-widget.js"          # stem alpha-widget
printf '// c\n' > "$ST6_REPO/bin/bravo-widget.sh"            # stem bravo-widget
printf '# c\n'  > "$ST6_REPO/skills/charlie-widget/SKILL.md" # stem charlie-widget
printf '# c\n'  > "$ST6_REPO/agents/delta-widget.md"         # stem delta-widget
printf '// c\n' > "$ST6_REPO/bin/echo-widget.sh"             # stem echo-widget
printf '// c\n' > "$ST6_REPO/bin/foxtrot-widget.sh"          # stem foxtrot-widget
printf '// c\n' > "$ST6_REPO/hooks/split-widget.js"          # stem split-widget

# One matching test per category dir; the stem match is on the test's basename,
# so which category holds it is irrelevant to the match — only that the search
# reaches every category subdir.
write_min "$ST6_REPO/tests/hooks/alpha-widget.sh"
write_min "$ST6_REPO/tests/bin/bravo-widget.sh"
write_min "$ST6_REPO/tests/skills/charlie-widget.sh"
write_min "$ST6_REPO/tests/agents/delta-widget.sh"
write_min "$ST6_REPO/tests/install/echo-widget.sh"
write_min "$ST6_REPO/tests/tests/foxtrot-widget.sh"
# Split pair: a dispatcher plus a <name>/ child whose basename ALSO carries the
# stem — the child must still be excluded (it is not a standalone test).
write_min "$ST6_REPO/tests/hooks/split-widget.sh"
write_min "$ST6_REPO/tests/hooks/split-widget/split-widget-part.sh"
# _archive test file with a matching stem: must NOT appear in stem-match output.
write_min "$ST6_REPO/tests/_archive/alpha-widget.sh"
# tests/lib/ file with a matching stem: lib/ is not a category; must NOT appear.
write_min "$ST6_REPO/tests/lib/harness.sh"
# Corresponding changed source so the stem "harness" would be eligible for match.
printf '// changed\n' > "$ST6_REPO/hooks/harness.js"

git -C "$ST6_REPO" add -A >/dev/null 2>&1
git -C "$ST6_REPO" commit -q -m "change" >/dev/null 2>&1
ST6_OUT="$(cd "$ST6_REPO" && bash "$ST6_REPO/bin/select-tests.sh" "$ST6_BASE" 2>/dev/null || true)"
st6_has() { printf '%s\n' "$ST6_OUT" | grep -q -- "$1"; }

missing6=""
st6_has '/tests/hooks/alpha-widget.sh'    || missing6="$missing6 hooks"
st6_has '/tests/bin/bravo-widget.sh'      || missing6="$missing6 bin"
st6_has '/tests/skills/charlie-widget.sh' || missing6="$missing6 skills"
st6_has '/tests/agents/delta-widget.sh'   || missing6="$missing6 agents"
st6_has '/tests/install/echo-widget.sh'   || missing6="$missing6 install"
st6_has '/tests/tests/foxtrot-widget.sh'  || missing6="$missing6 tests"
if [[ -z "$missing6" ]]; then
  pass "1g select-tests stem-match reaches a test in all six category dirs"
else
  fail "1g select-tests stem-match covers all six category dirs" "missing:$missing6 out=[$ST6_OUT]"
fi

if st6_has '/tests/hooks/split-widget.sh' && ! st6_has '/tests/hooks/split-widget/split-widget-part.sh'; then
  pass "1h select-tests returns the split dispatcher but not its <name>/ children"
else
  fail "1h select-tests excludes split-dir children from stem-match" "out=[$ST6_OUT]"
fi

if ! st6_has '/tests/_archive/alpha-widget.sh'; then
  pass "1h_arch select-tests excludes tests/_archive/ files from stem-match results"
else
  fail "1h_arch select-tests excludes tests/_archive/ files" "out=[$ST6_OUT]"
fi

if ! st6_has '/tests/lib/harness.sh'; then
  pass "1g_lib select-tests excludes tests/lib/ files from stem-match results"
else
  fail "1g_lib select-tests excludes tests/lib/ files (lib/ is not a category)" "out=[$ST6_OUT]"
fi
case_end

case_begin "tl3-discovery" "bin/select-tests.sh"
# =====================================================================
# 1k — select-tests.sh discovers TL3-*.sh files in category subdirs.
#      Pre-fix: find -maxdepth 1 blocks recursion; TL3 test in tests/hooks/
#      is silently skipped → case FAILS pre-fix.
#      Post-fix: find without -maxdepth 1 reaches tests/hooks/ → PASSES.
# =====================================================================
TL3_REPO="$TMP_ROOT/tl3-repo"
mkdir -p "$TL3_REPO/bin"
git -C "$TL3_REPO" init -q
git -C "$TL3_REPO" config core.hooksPath /dev/null
git -C "$TL3_REPO" config core.autocrlf false
git -C "$TL3_REPO" config user.email "t@example.com"
git -C "$TL3_REPO" config user.name "t"
# Stub: get-config-var returns exit 1 so RUN_TL3 = ON (not-off).
printf '#!/usr/bin/env bash\nexit 1\n' > "$TL3_REPO/bin/get-config-var"
chmod +x "$TL3_REPO/bin/get-config-var"
# is-docs-only absent: _tl3_wanted returns 0 (run TL3) for any non-empty diff.
cp "$SELECT_TESTS" "$TL3_REPO/bin/select-tests.sh"
printf 'init\n' > "$TL3_REPO/README.md"
git -C "$TL3_REPO" add -A >/dev/null 2>&1
git -C "$TL3_REPO" commit -q -m "initial" >/dev/null 2>&1
TL3_BASE="$(git -C "$TL3_REPO" rev-parse HEAD)"

printf '// changed\n' > "$TL3_REPO/hooks/some-widget.js"
write_min "$TL3_REPO/tests/hooks/TL3-hooktest.sh"
git -C "$TL3_REPO" add -A >/dev/null 2>&1
git -C "$TL3_REPO" commit -q -m "change" >/dev/null 2>&1

TL3_OUT="$(cd "$TL3_REPO" && bash "$TL3_REPO/bin/select-tests.sh" "$TL3_BASE" 2>/dev/null || true)"
if printf '%s\n' "$TL3_OUT" | grep -q -- '/tests/hooks/TL3-hooktest.sh'; then
  pass "1k select-tests discovers TL3-*.sh files in category subdirs (find maxdepth fix)"
else
  fail "1k select-tests discovers TL3-*.sh in category subdirs" "out=[$TL3_OUT]"
fi
case_end

case_begin "audit-scan" "bin/audit-tests.sh"
# =====================================================================
# 1e — audit-tests.sh scans feature-NNN-*.sh inside category subdirs
# =====================================================================
AT_REPO="$TMP_ROOT/audit-repo"
mkdir -p "$AT_REPO/tests/hooks" "$AT_REPO/bin"
git -C "$AT_REPO" init -q
git -C "$AT_REPO" config core.hooksPath /dev/null
git -C "$AT_REPO" config core.autocrlf false
git -C "$AT_REPO" config user.email "t@example.com"
git -C "$AT_REPO" config user.name "t"
# A feature-numbered file in a category subdir, deliberately missing # Tests:
# so a scanned file surfaces a NO_TESTS_HEADER diagnostic naming its path.
write_notests "$AT_REPO/tests/hooks/feature-9999-cat-subdir.sh" issue-specific
printf 'init\n' > "$AT_REPO/README.md"
git -C "$AT_REPO" add -A >/dev/null 2>&1
git -C "$AT_REPO" commit -q -m "fixture" >/dev/null 2>&1

AT_OUT="$(cd "$AT_REPO" && bash "$AUDIT_TESTS" --dry-run --offline 2>&1 || true)"
if printf '%s\n' "$AT_OUT" | grep -q -- 'feature-9999-cat-subdir.sh'; then
  pass "1e audit-tests scans feature-NNN files in category subdirs"
else
  fail "1e audit-tests scans feature-NNN files in category subdirs" "out=[$AT_OUT]"
fi

# =====================================================================
# 1i — audit-tests.sh scans feature-NNN files in ALL six category subdirs.
#      Each fixture file omits `# Tests:` so the scan surfaces a NO_TESTS_HEADER
#      diagnostic naming its path — proof the scanner reached it.
# =====================================================================
AT6_REPO="$TMP_ROOT/audit-repo-6cat"
mkdir -p "$AT6_REPO/bin"
git -C "$AT6_REPO" init -q
git -C "$AT6_REPO" config core.hooksPath /dev/null
git -C "$AT6_REPO" config core.autocrlf false
git -C "$AT6_REPO" config user.email "t@example.com"
git -C "$AT6_REPO" config user.name "t"
printf 'init\n' > "$AT6_REPO/README.md"
for cat in "${CATEGORIES[@]}"; do
  write_notests "$AT6_REPO/tests/$cat/feature-9001-$cat-scan.sh" issue-specific
done
# Common (non-feature) files in ALL six category subdirs for audit-tests-common.
for cat in "${CATEGORIES[@]}"; do
  write_notests "$AT6_REPO/tests/$cat/common-widget-$cat.sh" common
done
# _archive files: must NOT be scanned by either audit tool.
write_notests "$AT6_REPO/tests/_archive/feature-9001-arch.sh" issue-specific
write_notests "$AT6_REPO/tests/_archive/common-widget-arch.sh" common
git -C "$AT6_REPO" add -A >/dev/null 2>&1
git -C "$AT6_REPO" commit -q -m "fixture" >/dev/null 2>&1

AT6_OUT="$(cd "$AT6_REPO" && bash "$AUDIT_TESTS" --dry-run --offline 2>&1 || true)"
missing_at=""
for cat in "${CATEGORIES[@]}"; do
  printf '%s\n' "$AT6_OUT" | grep -q -- "feature-9001-$cat-scan.sh" || missing_at="$missing_at $cat"
done
if [[ -z "$missing_at" ]]; then
  pass "1i audit-tests scans feature-NNN files in all six category subdirs"
else
  fail "1i audit-tests scans feature-NNN files in all six category subdirs" "missing:$missing_at out=[$AT6_OUT]"
fi

if ! printf '%s\n' "$AT6_OUT" | grep -q -- 'feature-9001-arch.sh'; then
  pass "1i_arch audit-tests excludes tests/_archive/ files from scan"
else
  fail "1i_arch audit-tests excludes tests/_archive/ files" "out=[$AT6_OUT]"
fi

# 1i_scope: audit-tests.sh must NOT pick up common-widget files (scope exclusion).
leaked_common_at=""
for cat in "${CATEGORIES[@]}"; do
  printf '%s\n' "$AT6_OUT" | grep -q -- "common-widget-$cat.sh" && leaked_common_at="$leaked_common_at $cat"
done
if [[ -z "$leaked_common_at" ]]; then
  pass "1i_scope audit-tests ignores common-widget files (scope exclusion)"
else
  fail "1i_scope audit-tests must not pick up common-widget files" "leaked:$leaked_common_at out=[$AT6_OUT]"
fi

# =====================================================================
# 1l — audit-tests.sh --fix-headers scans feature-NNN files in category subdirs.
#      Pre-fix: for dispatcher in tests/feature-[0-9]*-*.sh (flat); subdir file
#      not reached → no output → FAILS. Post-fix: scans tests/<cat>/feature-*.
# =====================================================================
FH_REPO="$TMP_ROOT/fix-headers-repo"
mkdir -p "$FH_REPO/bin"
git -C "$FH_REPO" init -q
git -C "$FH_REPO" config core.hooksPath /dev/null
git -C "$FH_REPO" config core.autocrlf false
git -C "$FH_REPO" config user.email "t@example.com"
git -C "$FH_REPO" config user.name "t"
printf 'init\n' > "$FH_REPO/README.md"
for cat in "${CATEGORIES[@]}"; do
  mkdir -p "$FH_REPO/tests/$cat"
  printf '#!/usr/bin/env bash\n# Tests: bin/nonexistent-fh.sh\n# Tags: scope:issue-specific\necho hi\n' \
    > "$FH_REPO/tests/$cat/feature-9998-$cat.sh"
  printf '#!/usr/bin/env bash\n# Tests: bin/nonexistent-fh.sh\n# Tags: scope:common\necho hi\n' \
    > "$FH_REPO/tests/$cat/common-widget-fh-$cat.sh"
done
git -C "$FH_REPO" add -A >/dev/null 2>&1
git -C "$FH_REPO" commit -q -m "fixture" >/dev/null 2>&1

FH_OUT="$(cd "$FH_REPO" && bash "$AUDIT_TESTS" --fix-headers --dry-run --offline 2>&1 || true)"
missing_fh=""
for cat in "${CATEGORIES[@]}"; do
  printf '%s\n' "$FH_OUT" | grep -q -- "feature-9998-$cat.sh" || missing_fh="$missing_fh $cat"
done
if [[ -z "$missing_fh" ]]; then
  pass "1l audit-tests --fix-headers scans feature-NNN files in all six category subdirs"
else
  fail "1l audit-tests --fix-headers scans feature-NNN files in all six category subdirs" "missing:$missing_fh out=[$FH_OUT]"
fi

# 1l_scope: audit-tests.sh --fix-headers must NOT pick up common-widget files.
leaked_fh_scope=""
for cat in "${CATEGORIES[@]}"; do
  printf '%s\n' "$FH_OUT" | grep -q -- "common-widget-fh-$cat.sh" && leaked_fh_scope="$leaked_fh_scope $cat"
done
if [[ -z "$leaked_fh_scope" ]]; then
  pass "1l_scope audit-tests --fix-headers excludes common-widget files (scope exclusion)"
else
  fail "1l_scope audit-tests --fix-headers must not pick up common-widget files" "leaked:$leaked_fh_scope out=[$FH_OUT]"
fi
case_end

case_begin "audit-common-scan" "bin/audit-tests-common.sh"
# =====================================================================
# 1j — audit-tests-common.sh scans a common (non-feature) file in a category
#      subdir. Reuses the AT6_REPO fixture built above (the common file omits
#      `# Tests:`, so a reached scan surfaces a NO_TESTS_HEADER diagnostic).
# =====================================================================
ATC_OUT="$(cd "$AT6_REPO" && bash "$AUDIT_TESTS_COMMON" --dry-run --offline 2>&1 || true)"
missing_atc=""
for cat in "${CATEGORIES[@]}"; do
  printf '%s\n' "$ATC_OUT" | grep -q -- "common-widget-$cat.sh" || missing_atc="$missing_atc $cat"
done
if [[ -z "$missing_atc" ]]; then
  pass "1j audit-tests-common scans common files in all six category subdirs"
else
  fail "1j audit-tests-common scans common files in all six category subdirs" "missing:$missing_atc out=[$ATC_OUT]"
fi

if ! printf '%s\n' "$ATC_OUT" | grep -q -- 'common-widget-arch.sh'; then
  pass "1j_arch audit-tests-common excludes tests/_archive/ common files from scan"
else
  fail "1j_arch audit-tests-common excludes tests/_archive/ common files" "out=[$ATC_OUT]"
fi

# 1j_scope: audit-tests-common must NOT pick up feature-NNN files (scope exclusion).
leaked_ftr_atc=""
for cat in "${CATEGORIES[@]}"; do
  printf '%s\n' "$ATC_OUT" | grep -q -- "feature-9001-$cat-scan.sh" && leaked_ftr_atc="$leaked_ftr_atc $cat"
done
if [[ -z "$leaked_ftr_atc" ]]; then
  pass "1j_scope audit-tests-common ignores feature-NNN files (scope exclusion)"
else
  fail "1j_scope audit-tests-common must not pick up feature-NNN files" "leaked:$leaked_ftr_atc out=[$ATC_OUT]"
fi

# =====================================================================
# 1m — audit-tests-common.sh --fix-headers scans common files in category subdirs.
#      Pre-fix: for testfile in tests/*.sh (flat); subdir file not reached.
#      Post-fix: scans tests/<cat>/*.sh; file found + reported.
# =====================================================================
FHC_REPO="$TMP_ROOT/fix-headers-common-repo"
mkdir -p "$FHC_REPO/bin"
git -C "$FHC_REPO" init -q
git -C "$FHC_REPO" config core.hooksPath /dev/null
git -C "$FHC_REPO" config core.autocrlf false
git -C "$FHC_REPO" config user.email "t@example.com"
git -C "$FHC_REPO" config user.name "t"
printf 'init\n' > "$FHC_REPO/README.md"
for cat in "${CATEGORIES[@]}"; do
  mkdir -p "$FHC_REPO/tests/$cat"
  printf '#!/usr/bin/env bash\n# Tests: bin/nonexistent-fhc.sh\n# Tags: scope:common, TL2\necho hi\n' \
    > "$FHC_REPO/tests/$cat/common-widget-$cat.sh"
  printf '#!/usr/bin/env bash\n# Tests: bin/nonexistent-fhc.sh\n# Tags: scope:issue-specific\necho hi\n' \
    > "$FHC_REPO/tests/$cat/feature-9001-fhc-$cat.sh"
done
git -C "$FHC_REPO" add -A >/dev/null 2>&1
git -C "$FHC_REPO" commit -q -m "fixture" >/dev/null 2>&1

FHC_OUT="$(cd "$FHC_REPO" && bash "$AUDIT_TESTS_COMMON" --fix-headers --dry-run --offline 2>&1 || true)"
missing_fhc=""
for cat in "${CATEGORIES[@]}"; do
  printf '%s\n' "$FHC_OUT" | grep -q -- "common-widget-$cat.sh" || missing_fhc="$missing_fhc $cat"
done
if [[ -z "$missing_fhc" ]]; then
  pass "1m audit-tests-common --fix-headers scans common files in all six category subdirs"
else
  fail "1m audit-tests-common --fix-headers scans common files in all six category subdirs" "missing:$missing_fhc out=[$FHC_OUT]"
fi

# 1m_scope: audit-tests-common --fix-headers must NOT pick up feature-NNN files.
leaked_fhc_scope=""
for cat in "${CATEGORIES[@]}"; do
  printf '%s\n' "$FHC_OUT" | grep -q -- "feature-9001-fhc-$cat.sh" && leaked_fhc_scope="$leaked_fhc_scope $cat"
done
if [[ -z "$leaked_fhc_scope" ]]; then
  pass "1m_scope audit-tests-common --fix-headers excludes feature-NNN files (scope exclusion)"
else
  fail "1m_scope audit-tests-common --fix-headers must not pick up feature-NNN files" "leaked:$leaked_fhc_scope out=[$FHC_OUT]"
fi
case_end

# --- Summary ---------------------------------------------------------------
echo ""
echo "Results: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[[ "$FAIL" -eq 0 ]]
