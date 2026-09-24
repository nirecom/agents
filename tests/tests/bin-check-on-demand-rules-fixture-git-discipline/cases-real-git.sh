# shellcheck shell=bash
# Tests: tests/bin-check-on-demand-rules/fixtures.sh
# Tags: rules-injection, on-demand-rules, fixtures, git-discipline, real-git, hooks-isolation, spawn-count, TL2, scope:common
#
# The E block closes this suite's own "reads text, never runs git" gap for the two claims
# that text cannot settle: that the clone really carries the hooks-disabling setting
# (rules/test/fixture-isolation.md), and that the template is built ONCE however many
# fixtures ask for a repo (#2111). Direct `git` is deliberate here and out of D1's reach:
# D1 polices tests/bin-check-on-demand-rules/, whose case files must route through
# fixtures.sh; this directory is the observer, and observing needs the primitive.

echo ""
echo "=== E1/E2: the cloned fixture repo really has git hooks disabled ==="
cat > "$SCEN_DIR/e-hooks-real.sh" <<'EOF'
set -uo pipefail
. "$FX_HARNESS"

d="$BASE/tpl-clone"
rc=0; fx_ensure_git "$d" || rc=$?
echo "ensure_rc=$rc"
echo "hooks_path=$(git -C "$d" config --get core.hooksPath 2>/dev/null)"

CAN="$BASE/pre-commit-fired"
mkdir -p "$d/.git/hooks"
printf '#!/usr/bin/env bash\ntouch "%s"\nexit 1\n' "$CAN" > "$d/.git/hooks/pre-commit"
chmod +x "$d/.git/hooks/pre-commit"
printf 'x\n' > "$d/a.txt"
git -C "$d" add a.txt >/dev/null 2>&1
crc=0; git -C "$d" commit -q -m fixture >/dev/null 2>&1 || crc=$?
echo "commit_rc=$crc"
if [ -f "$CAN" ]; then echo "hook_fired=yes"; else echo "hook_fired=no"; fi

# Non-vacuity control: the same planted hook in a sibling clone whose core.hooksPath is
# pointed back at .git/hooks. If THIS one does not fire either, the hook was never
# runnable and "hook_fired=no" above proves nothing about the template's setting.
c="$BASE/hooks-on"
fx_ensure_git "$c" || true
CAN2="$BASE/control-fired"
mkdir -p "$c/.git/hooks"
printf '#!/usr/bin/env bash\ntouch "%s"\nexit 1\n' "$CAN2" > "$c/.git/hooks/pre-commit"
chmod +x "$c/.git/hooks/pre-commit"
git -C "$c" config core.hooksPath "$c/.git/hooks" >/dev/null 2>&1
printf 'x\n' > "$c/a.txt"
git -C "$c" add a.txt >/dev/null 2>&1
crc2=0; git -C "$c" commit -q -m control >/dev/null 2>&1 || crc2=$?
echo "control_commit_rc=$crc2"
if [ -f "$CAN2" ]; then echo "control_hook_fired=yes"; else echo "control_hook_fired=no"; fi
EOF
e_real="$(fx_scenario e-hooks-real)"
e1_rc="$(fx_get "$e_real" ensure_rc)"
e1_path="$(fx_get "$e_real" hooks_path)"
if e_gone="$(fx_missing "$e_real" ensure_rc hooks_path commit_rc hook_fired control_hook_fired)"; then
    fail "E1/E2: the scenario never reported '$e_gone' — it died before it could measure anything, so neither case below is a finding about fixtures.sh: $(brief "$e_real")"
elif [[ "$e1_rc" != "0" ]]; then
    fail "E1: fx_ensure_git exited $e1_rc building a fixture repo, so the hooks setting could not be read at all — $(brief "$e_real")"
elif is_null_device "$e1_path"; then
    pass "E1: the fixture repo's own config resolves core.hooksPath to the null device ($e1_path)"
else
    fail "E1: git config --get core.hooksPath in an fx_ensure_git repo returned '${e1_path:-<unset>}', not the platform null device — the setting rules/test/fixture-isolation.md requires did not survive the template clone, so the developer's real hooks are live inside every fixture"
fi
e2_ctl="$(fx_get "$e_real" control_hook_fired)"
e2_fired="$(fx_get "$e_real" hook_fired)"
e2_crc="$(fx_get "$e_real" commit_rc)"
if [[ -n "$e_gone" ]]; then
    fail "E2: the scenario never reported '$e_gone', so the planted-hook probe never ran to completion: $(brief "$e_real")"
elif [[ "$e2_ctl" != "yes" ]]; then
    fail "E2: the control commit did not fire its planted pre-commit either (control_commit_rc=$(fx_get "$e_real" control_commit_rc)) — the probe cannot tell a disabled hook from an unrunnable one, so E2 would pass vacuously"
elif [[ "$e2_fired" == "no" ]] && [[ "$e2_crc" == "0" ]]; then
    pass "E2: a pre-commit planted inside an fx_ensure_git repo never runs, and the commit succeeds"
else
    fail "E2: the planted pre-commit fired=$e2_fired and the commit exited $e2_crc inside an fx_ensure_git repo — a real hook executes in fixture repos, which is the slowdown and the block rules/test/fixture-isolation.md exists to prevent"
fi

echo ""
echo "=== E3/E4: the ephemeral -c form is NOT the persistent guarantee ==="
# The regression this guards: someone repairs a hook-firing fixture by bolting
# `-c core.hooksPath=…` onto the one command that broke, leaving every other command run
# against that same repo exposed. The control repo below carries a hostile hooks dir of
# its own, so the case never depends on whether the host developer has hooks installed.
cat > "$SCEN_DIR/e-hooks-ephemeral.sh" <<'EOF'
set -uo pipefail
. "$FX_HARNESS"

d="$BASE/eph"
HOOKDIR="$BASE/host-hooks"
CAN="$BASE/host-hook-fired"
mkdir -p "$d" "$HOOKDIR" "$BASE/.empty-tpl"
printf '#!/usr/bin/env bash\ntouch "%s"\nexit 1\n' "$CAN" > "$HOOKDIR/pre-commit"
chmod +x "$HOOKDIR/pre-commit"
git -C "$d" init -q --template="$BASE/.empty-tpl"
git -C "$d" config core.hooksPath "$HOOKDIR"
git -C "$d" config user.email "test@example.com"
git -C "$d" config user.name "Test"
printf 'x\n' > "$d/a.txt"
git -C "$d" add a.txt >/dev/null 2>&1
erc=0; git -c core.hooksPath=/dev/null -C "$d" commit -q -m eph >/dev/null 2>&1 || erc=$?
echo "eph_commit_rc=$erc"
if [ -f "$CAN" ]; then echo "eph_hook_fired=yes"; else echo "eph_hook_fired=no"; fi
echo "eph_persisted=$(git -C "$d" config --get core.hooksPath 2>/dev/null)"
printf 'y\n' >> "$d/a.txt"
git -C "$d" add a.txt >/dev/null 2>&1
prc=0; git -C "$d" commit -q -m plain >/dev/null 2>&1 || prc=$?
echo "plain_commit_rc=$prc"
if [ -f "$CAN" ]; then echo "plain_hook_fired=yes"; else echo "plain_hook_fired=no"; fi
EOF
e_eph="$(fx_scenario e-hooks-ephemeral)"
e3_eph_fired="$(fx_get "$e_eph" eph_hook_fired)"
e3_persist="$(fx_get "$e_eph" eph_persisted)"
eph_gone="$(fx_missing "$e_eph" eph_commit_rc eph_hook_fired eph_persisted plain_commit_rc plain_hook_fired || true)"
if [[ -n "$eph_gone" ]]; then
    fail "E3: the scenario never reported '$eph_gone' — it died before the ephemeral override was exercised: $(brief "$e_eph")"
elif [[ "$e3_eph_fired" != "no" ]]; then
    fail "E3: the ephemeral 'git -c core.hooksPath=… commit' still fired the hook, so the scenario never demonstrated the override at all — $(brief "$e_eph")"
elif is_null_device "$e3_persist"; then
    fail "E3: after an ephemeral 'git -c core.hooksPath=…' command the repo's own config reads '$e3_persist' — the ephemeral form is indistinguishable from the persistent setting, so E1 would go green on a repo that is only protected one command at a time"
else
    pass "E3: an ephemeral 'git -c core.hooksPath=…' override suppresses that one command's hooks and leaves the repo's own config untouched, so it cannot satisfy E1"
fi
e4_fired="$(fx_get "$e_eph" plain_hook_fired)"
e4_rc="$(fx_get "$e_eph" plain_commit_rc)"
if [[ -n "$eph_gone" ]]; then
    fail "E4: the scenario never reported '$eph_gone', so the follow-up command was never observed: $(brief "$e_eph")"
elif [[ "$e4_fired" == "yes" ]] && [[ "$e4_rc" != "0" ]]; then
    pass "E4: the very next command run without -c fires the hook and fails, so the ephemeral form protects nothing but itself"
else
    fail "E4: the plain follow-up command reported hook_fired=$e4_fired rc=$e4_rc on a repo whose config still names a hostile hooks dir — the probe cannot show the residual exposure, so E3 has no teeth: $(brief "$e_eph")"
fi

echo ""
echo "=== E5/E6/E7: one template build, one clone per fixture, zero git for mk_tree ==="
# The permanent form of detail plan Step 4 verification 2 (docs/architecture/claude-code/
# test-runner-parallelism.md §9): a PATH-prepended `git`/`cp` shim logs every invocation
# and execs the real binary, so the counts are of real spawns, not of source text.
cat > "$SCEN_DIR/e-spawn-count.sh" <<'EOF'
set -uo pipefail
. "$FX_HARNESS"

SHIM="$BASE/shim"; mkdir -p "$SHIM"
REAL_GIT="$(command -v git)"
REAL_CP="$(command -v cp)"
GIT_LOG="$BASE/git-calls.log"
CP_LOG="$BASE/cp-calls.log"
: > "$GIT_LOG"
: > "$CP_LOG"
{ printf '#!/usr/bin/env bash\n'
  printf 'printf "%%s\\n" "$*" >> "%s"\n' "$GIT_LOG"
  printf 'exec "%s" "$@"\n' "$REAL_GIT"; } > "$SHIM/git"
{ printf '#!/usr/bin/env bash\n'
  printf 'printf "%%s\\n" "$*" >> "%s"\n' "$CP_LOG"
  printf 'exec "%s" "$@"\n' "$REAL_CP"; } > "$SHIM/cp"
chmod +x "$SHIM/git" "$SHIM/cp"
PATH="$SHIM:$PATH"
hash -r

mk_tree "$BASE/t1"
mk_tree "$BASE/t2"
echo "git_after_mk_tree=$(grep -c . "$GIT_LOG" || true)"

fx_ensure_git "$BASE/g1"
fx_ensure_git "$BASE/g2"
echo "git_total=$(grep -c . "$GIT_LOG" || true)"
echo "init_n=$(grep -cE '(^| )init( |$)' "$GIT_LOG" || true)"
echo "config_n=$(grep -cE '(^| )config( |$)' "$GIT_LOG" || true)"
echo "cp_total=$(grep -c . "$CP_LOG" || true)"

# The repeat half of the same claim: cases-injection.sh calls fx_ensure_git 25+ times over
# ONE fixture dir, so the second and later calls on an already-built tree must cost nothing.
mk_tree "$BASE/t1"
fx_ensure_git "$BASE/g1"
fx_ensure_git "$BASE/g2"
echo "git_after_repeat=$(grep -c . "$GIT_LOG" || true)"
echo "cp_after_repeat=$(grep -c . "$CP_LOG" || true)"

# A THIRD, never-seen fixture: the template must be reused, not rebuilt, however many
# fixtures arrive later in a run.
fx_ensure_git "$BASE/g3"
echo "init_after_third=$(grep -cE '(^| )init( |$)' "$GIT_LOG" || true)"
echo "config_after_third=$(grep -cE '(^| )config( |$)' "$GIT_LOG" || true)"
echo "cp_after_third=$(grep -c . "$CP_LOG" || true)"
EOF
e_cnt="$(fx_scenario e-spawn-count)"
e5_mk="$(fx_get "$e_cnt" git_after_mk_tree)"
e6_total="$(fx_get "$e_cnt" git_total)"
e6_init="$(fx_get "$e_cnt" init_n)"
e6_config="$(fx_get "$e_cnt" config_n)"
e7_cp="$(fx_get "$e_cnt" cp_total)"
e8_git="$(fx_get "$e_cnt" git_after_repeat)"
e8_cp="$(fx_get "$e_cnt" cp_after_repeat)"
e9_init="$(fx_get "$e_cnt" init_after_third)"
e9_config="$(fx_get "$e_cnt" config_after_third)"
e9_cp="$(fx_get "$e_cnt" cp_after_third)"
cnt_gone="$(fx_missing "$e_cnt" git_after_mk_tree git_total init_n config_n cp_total git_after_repeat cp_after_repeat init_after_third config_after_third cp_after_third || true)"
if [[ -n "$cnt_gone" ]]; then
    fail "E5-E7: the scenario never reported '$cnt_gone' — it died before the counts were taken: $(brief "$e_cnt")"
elif [[ "$e6_total" == "0" ]]; then
    fail "E5-E7: the git shim logged nothing across two fx_ensure_git calls — the shim never reached PATH, so every count below would read zero for the wrong reason: $(brief "$e_cnt")"
else
    if [[ "$e5_mk" == "0" ]]; then
        pass "E5: two mk_tree calls spawn git zero times — the default fixture builder is git-free"
    else
        fail "E5: mk_tree spawned git $e5_mk time(s) — the plain-tree builder is paying for a repo the --all cases never look at (#2111)"
    fi
    if [[ "$e6_init" == "1" ]] && [[ "$e6_config" == "3" ]]; then
        pass "E6: two fixture repos cost exactly one git init and one 3-call config sequence — the template is built once"
    else
        fail "E6: two fx_ensure_git calls spawned git init x$e6_init and git config x$e6_config, want 1 and 3 — per-fixture initialization is back, which is the #2111 cost the template was introduced to remove"
    fi
    if [[ "$e7_cp" == "2" ]]; then
        pass "E7: the clone step ran once per fixture dir (cp x2), so the single template really is being reused"
    else
        fail "E7: cp ran $e7_cp time(s) for two fixture dirs, want 2 — 0 means no fixture got a repo at all and the --staged cases would grade an empty diff; more means the clone is repeating itself"
    fi
    # E8 — the repeat call. E5-E7 measure the FIRST build of each thing; the cost
    # cases-injection.sh actually pays is the 25+ later calls on a tree that is already
    # built, and an idempotency check that re-clones is invisible to every count above.
    if [[ "$e8_git" == "$e6_total" ]] && [[ "$e8_cp" == "$e7_cp" ]]; then
        pass "E8: repeating mk_tree and both fx_ensure_git calls on already-built trees spawns no further git ($e8_git) and no further cp ($e8_cp)"
    else
        fail "E8: a repeat pass over the same trees moved the counts from git=$e6_total cp=$e7_cp to git=$e8_git cp=$e8_cp — the idempotent entry point is rebuilding what it already has, which is the per-call cost #2111 removed and which cases-injection.sh pays 25+ times over one INJ_DIR"
    fi
    # E9 — the template's lifetime. E6 pins one init for two fixtures; a template rebuilt
    # once per N fixtures would satisfy that and still scale linearly.
    if [[ "$e9_init" == "1" ]] && [[ "$e9_config" == "3" ]] && [[ "$e9_cp" == "3" ]]; then
        pass "E9: a third, unseen fixture costs one more clone (cp x3) and still no second template build (init x1, config x3)"
    else
        fail "E9: after a third fx_ensure_git the counts read init x$e9_init config x$e9_config cp x$e9_cp, want 1/3/3 — an init or config above 1/3 means the template is rebuilt per fixture after all; a cp other than 3 means the third fixture was not cloned exactly once"
    fi
fi
