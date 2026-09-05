# shellcheck shell=bash
# Tests: tests/bin-check-on-demand-rules/fixtures.sh
# Tags: rules-injection, on-demand-rules, fixtures, git-discipline, real-git, error-propagation, false-green, TL2, scope:common
#
# D8 pins the SPELLINGS that would let a fixture failure pass unnoticed; the F block runs
# the failure. Two shapes are separated (CPR-SC): a git op that FAILS (F1-F5 — does every
# caller of fx_ensure_git act on the status?) and a git op that half-succeeded (F6-F7 —
# does the `-d …/.git` idempotency check, which tests existence and not completeness,
# hand the next call a directory that is not a repository?).

echo ""
echo "=== F1-F3: fx_ensure_git / fx_stage / git_commit_all propagate a git failure ==="
cat > "$SCEN_DIR/f-propagate.sh" <<'EOF'
set -uo pipefail
. "$FX_HARNESS"

STUB="$BASE/stub"; mkdir -p "$STUB"
printf '#!/usr/bin/env bash\nexit 3\n' > "$STUB/git"
chmod +x "$STUB/git"
PATH="$STUB:$PATH"
hash -r
probe=0; git --version >/dev/null 2>&1 || probe=$?
echo "stub_rc=$probe"

rc=0; fx_ensure_git "$BASE/a1" || rc=$?
echo "ensure_rc=$rc"
rc=0; fx_stage "$BASE/a2" . || rc=$?
echo "stage_rc=$rc"
rc=0; git_commit_all "$BASE/a3" || rc=$?
echo "commit_all_rc=$rc"
EOF
f_prop="$(fx_scenario f-propagate)"
f_stub="$(fx_get "$f_prop" stub_rc)"
prop_gone="$(fx_missing "$f_prop" stub_rc ensure_rc stage_rc commit_all_rc || true)"
if [[ -n "$prop_gone" ]]; then
    fail "F1-F3: the scenario never reported '$prop_gone' — it died before the failure injection was measured, so none of F1-F3 is a finding about fixtures.sh: $(brief "$f_prop")"
elif [[ "$f_stub" != "3" ]]; then
    fail "F1-F3: the failing-git stub never took effect (a direct git exited '${f_stub:-<none>}', want 3) — nothing below would be exercising a failure at all: $(brief "$f_prop")"
else
    f1="$(fx_get "$f_prop" ensure_rc)"
    if [[ "$f1" != "0" ]]; then
        pass "F1: fx_ensure_git returns nonzero ($f1) when the underlying git fails"
    else
        fail "F1: fx_ensure_git returned 0 while git was failing — every caller then believes it has a repo, and the --staged cases grade an empty diff (R6 false green)"
    fi
    f2="$(fx_get "$f_prop" stage_rc)"
    if [[ "$f2" != "0" ]]; then
        pass "F2: fx_stage returns nonzero ($f2) when the repo could not be built"
    else
        fail "F2: fx_stage returned 0 although fx_ensure_git could not build the repo — the case that staged through it stages nothing and still goes green"
    fi
    f3="$(fx_get "$f_prop" commit_all_rc)"
    if [[ "$f3" != "0" ]]; then
        pass "F3: git_commit_all returns nonzero ($f3) when the repo could not be built"
    else
        fail "F3: git_commit_all returned 0 with no repository built — the committed baseline the --staged cases contrast against never existed"
    fi
fi

echo ""
echo "=== F4/F5: no checker verdict is graded after a failed repo setup ==="
# The checker is replaced by a canary stub, so the case can see WHETHER it ran and on WHICH
# argv — a `--staged` invocation with no paths at all is the empty-file-list grading D8e
# only pins as text.
cat > "$SCEN_DIR/f-checker-invocation.sh" <<'EOF'
set -uo pipefail
. "$FX_HARNESS"

d="$BASE/n1"
fx_base "$d"

CAN="$BASE/checker-invoked"
ARGV="$BASE/checker-argv"
CHECKER="$BASE/checker-stub.sh"
{ printf '#!/usr/bin/env bash\n'
  printf 'touch "%s"\n' "$CAN"
  printf 'printf "%%s\\n" "$*" >> "%s"\n' "$ARGV"
  printf 'exit 0\n'; } > "$CHECKER"
chmod +x "$CHECKER"

STUB="$BASE/stub"; mkdir -p "$STUB"
printf '#!/usr/bin/env bash\nexit 3\n' > "$STUB/git"
chmod +x "$STUB/git"
PATH="$STUB:$PATH"
hash -r

rc=0; fx_ensure_git "$d" || rc=$?
echo "setup_rc=$rc"
echo "sentinel=${FX_SETUP_FAILED_RC:-unset}"
# Both channels: what the driver PRINTS (every case file reads the stdout value) and what
# it RETURNS (a caller writing `run_checker … || handle` reads the status instead).
ret=0; rc="$(run_checker "$d" staged)" || ret=$?
echo "run_checker_rc=$rc"
echo "run_checker_status=$ret"
if [ -f "$CAN" ]; then echo "invoked=yes"; else echo "invoked=no"; fi
echo "argv=$(cat "$ARGV" 2>/dev/null)"
rm -f "$CAN" "$ARGV"
ret=0; rc="$(run_checker_files "$d" rules/od.md)" || ret=$?
echo "run_checker_files_rc=$rc"
echo "run_checker_files_status=$ret"
if [ -f "$CAN" ]; then echo "files_invoked=yes"; else echo "files_invoked=no"; fi
EOF
f_inv="$(fx_scenario f-checker-invocation)"
f_setup="$(fx_get "$f_inv" setup_rc)"
# The sentinel is read back from the scenario rather than hard-coded here, so this file
# pins the CONTRACT (a value that is neither of the checker's own verdicts) and not a
# second copy of the number (CPR-SSOT).
f_sent="$(fx_get "$f_inv" sentinel)"
inv_gone="$(fx_missing "$f_inv" setup_rc sentinel run_checker_rc run_checker_status invoked run_checker_files_rc run_checker_files_status files_invoked || true)"
if [[ -n "$inv_gone" ]]; then
    fail "F4/F5: the scenario never reported '$inv_gone' — it died before either driver was called, so neither case below is a finding about fixtures.sh: $(brief "$f_inv")"
elif [[ "$f_setup" == "0" ]]; then
    fail "F4/F5: fx_ensure_git reported success under the failing-git stub, so neither case below is standing on a failed setup: $(brief "$f_inv")"
elif [[ ! "$f_sent" =~ ^[0-9]+$ ]] || [[ "$f_sent" == "0" ]] || [[ "$f_sent" == "1" ]]; then
    fail "F4/F5: fixtures.sh exposes no distinguishable setup-failure code (FX_SETUP_FAILED_RC='${f_sent:-<unset>}'). 0 and 1 are the CHECKER's own clean/violation verdicts, so a driver reporting either leaves a case unable to tell 'the repo was never built' from a real verdict"
else
    f4_rc="$(fx_get "$f_inv" run_checker_rc)"
    f4_st="$(fx_get "$f_inv" run_checker_status)"
    f4_inv="$(fx_get "$f_inv" invoked)"
    f4_argv="$(fx_get "$f_inv" argv)"
    if [[ "$f4_rc" == "$f_sent" ]] && [[ "$f4_st" == "$f_sent" ]] && [[ "$f4_inv" == "no" ]]; then
        pass "F4: run_checker reports the failed repo setup as FX_SETUP_FAILED_RC ($f_sent) on both its stdout and its exit status, and never invokes the checker"
    else
        fail "F4: fx_ensure_git failed inside run_checker, but the driver printed '$f4_rc' / returned '$f4_st' (want '$f_sent' on both) after invoking the checker (invoked=$f4_inv) as 'checker ${f4_argv:-<no argv recorded>}' — a bare nonzero is not enough: printing the checker's own 1 makes a never-built repo read as an ordinary violation, and a --staged run with no paths grades an empty staged list as clean"
    fi
    f5_rc="$(fx_get "$f_inv" run_checker_files_rc)"
    f5_st="$(fx_get "$f_inv" run_checker_files_status)"
    f5_inv="$(fx_get "$f_inv" files_invoked)"
    if [[ "$f5_rc" == "$f_sent" ]] && [[ "$f5_st" == "$f_sent" ]] && [[ "$f5_inv" == "no" ]]; then
        pass "F5: run_checker_files reports the failed repo setup as FX_SETUP_FAILED_RC ($f_sent) on both channels instead of grading the explicit list against a missing repo"
    else
        fail "F5: run_checker_files printed '$f5_rc' / returned '$f5_st' (want '$f_sent' on both, checker invoked=$f5_inv) — CPR-ORTH sibling of F4: the same silent-proceed lives in both drivers, so a case whose expectation depends on the repo existing cannot tell setup failure from a clean verdict"
    fi
fi

echo ""
echo "=== F6/F7: a half-built repo is never accepted as a finished one ==="
# F6 forces `git config` to fail exactly once, so `git init` has already created
# $FX_GIT_TEMPLATE/.git when _fx_git_template gives up. The next call's `-d …/.git` test
# then sees a directory and returns 0 — and the clone inherits whatever core.hooksPath the
# HOST has, which is the very leak rules/test/fixture-isolation.md forbids.
cat > "$SCEN_DIR/f-partial-template.sh" <<'EOF'
set -uo pipefail
. "$FX_HARNESS"

STUB="$BASE/stub"; mkdir -p "$STUB"
FLAG="$BASE/config-already-failed"
REAL_GIT="$(command -v git)"
{ printf '#!/usr/bin/env bash\n'
  printf 'for a in "$@"; do\n'
  printf '  if [ "$a" = "config" ] && [ ! -f "%s" ]; then : > "%s"; exit 9; fi\n' "$FLAG" "$FLAG"
  printf 'done\n'
  printf 'exec "%s" "$@"\n' "$REAL_GIT"; } > "$STUB/git"
chmod +x "$STUB/git"
PATH="$STUB:$PATH"
hash -r

rc=0; fx_ensure_git "$BASE/p1" || rc=$?
echo "first_rc=$rc"
if [ -d "$FX_GIT_TEMPLATE/.git" ]; then echo "tpl_left_behind=yes"; else echo "tpl_left_behind=no"; fi
rc=0; fx_ensure_git "$BASE/p2" || rc=$?
echo "second_rc=$rc"
echo "p2_hooks=$(git -C "$BASE/p2" config --get core.hooksPath 2>/dev/null)"
EOF
f_tpl="$(fx_scenario f-partial-template)"
f6_first="$(fx_get "$f_tpl" first_rc)"
f6_second="$(fx_get "$f_tpl" second_rc)"
f6_hooks="$(fx_get "$f_tpl" p2_hooks)"
tpl_gone="$(fx_missing "$f_tpl" first_rc tpl_left_behind second_rc p2_hooks || true)"
if [[ -n "$tpl_gone" ]]; then
    fail "F6: the scenario never reported '$tpl_gone' — it died before the half-built template could be retried: $(brief "$f_tpl")"
elif [[ "$f6_first" == "0" ]]; then
    fail "F6: the first fx_ensure_git returned 0 although git config was forced to fail — the injection did not land, so the partial-template state was never created: $(brief "$f_tpl")"
elif [[ "$f6_second" != "0" ]] || is_null_device "$f6_hooks"; then
    pass "F6: a template abandoned after git init is repaired or rejected on the next call, never handed on as finished (second_rc=$f6_second, hooks=${f6_hooks:-<unset>})"
else
    fail "F6: after _fx_git_template failed mid-build, the next fx_ensure_git returned 0 and cloned the half-built template — the fixture's core.hooksPath reads '${f6_hooks:-<unset>}' instead of the null device (tpl_left_behind=$(fx_get "$f_tpl" tpl_left_behind)). The '-d \$FX_GIT_TEMPLATE/.git' idempotency test decides on existence alone, so a template missing every config line is indistinguishable from a finished one"
fi

cat > "$SCEN_DIR/f-partial-clone.sh" <<'EOF'
set -uo pipefail
. "$FX_HARNESS"

d="$BASE/q1"
mkdir -p "$d/.git"
rc=0; fx_ensure_git "$d" || rc=$?
echo "ensure_rc=$rc"
grc=0; git -C "$d" rev-parse --git-dir >/dev/null 2>&1 || grc=$?
echo "rev_parse_rc=$grc"
EOF
f_clone="$(fx_scenario f-partial-clone)"
f7_rc="$(fx_get "$f_clone" ensure_rc)"
f7_git="$(fx_get "$f_clone" rev_parse_rc)"
clone_gone="$(fx_missing "$f_clone" ensure_rc rev_parse_rc || true)"
if [[ -n "$clone_gone" ]]; then
    fail "F7: the scenario never reported '$clone_gone' — it died before the incomplete .git was handed to fx_ensure_git: $(brief "$f_clone")"
elif [[ "$f7_git" == "0" ]]; then
    pass "F7: fx_ensure_git turned an incomplete .git into a usable repository (ensure_rc=$f7_rc)"
elif [[ "$f7_rc" != "0" ]]; then
    pass "F7: fx_ensure_git refused an incomplete .git (ensure_rc=$f7_rc) instead of reporting a repo it did not build"
else
    fail "F7: fx_ensure_git returned 0 for a .git directory that git itself rejects (rev-parse exited $f7_git) — a cp -R interrupted partway leaves exactly this shape, and the '-d \$d/.git' test cannot tell it from a finished clone, so fx_stage and run_checker then work against a non-repository and their cases grade an empty staged list"
fi

echo ""
echo "=== F8: an UNMARKED .git is re-cloned, however usable it looks ==="
# F7's .git is empty, so a `git rev-parse` probe would also reject it — which means F7
# cannot tell a completion-marker contract from an incidental validity check. F8 isolates
# exactly that: a real, working, hooks-disabled clone whose marker alone is missing. That
# is what a cp -R killed after the objects but before the marker leaves, and the only
# reading under which it is safe is "unmarked means unfinished — discard and rebuild".
cat > "$SCEN_DIR/f-unmarked-clone.sh" <<'EOF'
set -uo pipefail
. "$FX_HARNESS"

d="$BASE/r1"
rc=0; fx_ensure_git "$d" || rc=$?
echo "seed_rc=$rc"
if [ -f "$d/$FX_CLONE_READY" ]; then echo "seed_marker=yes"; else echo "seed_marker=no"; fi
rm -f "$d/$FX_CLONE_READY"
if [ -f "$d/$FX_CLONE_READY" ]; then echo "marker_removed=no"; else echo "marker_removed=yes"; fi
# A witness that the SECOND call really rebuilt rather than short-circuited: a file no
# clone of the template can produce, which a rebuild necessarily discards.
: > "$d/.git/nsg-stale-witness"
rc=0; fx_ensure_git "$d" || rc=$?
echo "reensure_rc=$rc"
if [ -f "$d/$FX_CLONE_READY" ]; then echo "marker_back=yes"; else echo "marker_back=no"; fi
if [ -f "$d/.git/nsg-stale-witness" ]; then echo "stale_kept=yes"; else echo "stale_kept=no"; fi
grc=0; git -C "$d" rev-parse --git-dir >/dev/null 2>&1 || grc=$?
echo "rev_parse_rc=$grc"
echo "hooks=$(git -C "$d" config --get core.hooksPath 2>/dev/null)"
EOF
f_unm="$(fx_scenario f-unmarked-clone)"
unm_gone="$(fx_missing "$f_unm" seed_rc seed_marker marker_removed reensure_rc marker_back stale_kept rev_parse_rc hooks || true)"
f8_seed="$(fx_get "$f_unm" seed_marker)"
f8_rc="$(fx_get "$f_unm" reensure_rc)"
f8_back="$(fx_get "$f_unm" marker_back)"
f8_stale="$(fx_get "$f_unm" stale_kept)"
f8_git="$(fx_get "$f_unm" rev_parse_rc)"
f8_hooks="$(fx_get "$f_unm" hooks)"
if [[ -n "$unm_gone" ]]; then
    fail "F8: the scenario never reported '$unm_gone' — it died before the marker could be removed and the clone retried: $(brief "$f_unm")"
elif [[ "$f8_seed" != "yes" ]]; then
    fail "F8: the seed fx_ensure_git (rc=$(fx_get "$f_unm" seed_rc)) left no completion marker at \$d/$FX_CLONE_READY, so 'finished' is recorded nowhere and the retry below cannot be about the marker at all: $(brief "$f_unm")"
elif [[ "$f8_rc" == "0" && "$f8_back" == "yes" && "$f8_stale" == "no" && "$f8_git" == "0" ]] && is_null_device "$f8_hooks"; then
    pass "F8: an unmarked .git is discarded and re-cloned — the marker is restored, the stale content is gone, and the rebuilt repo still has hooks disabled ($f8_hooks)"
elif [[ "$f8_rc" != "0" ]]; then
    pass "F8: fx_ensure_git refused an unmarked .git (rc=$f8_rc) instead of reporting a repo whose build never finished"
else
    fail "F8: fx_ensure_git returned 0 on a .git carrying no completion marker (marker_back=$f8_back, stale content kept=$f8_stale, rev-parse=$f8_git, hooks='${f8_hooks:-<unset>}') — it short-circuited on the DIRECTORY, so the one shape the marker exists to catch, a cp -R killed before its last step, is handed to fx_stage and run_checker as a finished repository"
fi
