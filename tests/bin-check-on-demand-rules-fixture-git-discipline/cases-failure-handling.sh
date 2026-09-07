# shellcheck shell=bash
# Tests: tests/bin-check-on-demand-rules/fixtures.sh
# Tags: rules-injection, on-demand-rules, fixtures, git-discipline, static-check, false-green, TL2, scope:common
# R6's silent false PASS: `cp -R` or `git add` fails under `>/dev/null 2>&1`, the repo is
# missing or empty, and the case still goes green on an empty `--staged` diff. D8 pins the
# spellings that permit it; D10 pins the early return the idempotency claim rests on; D11
# pins the quoting a fixture path with a space would otherwise break; D12 pins the
# hooks-disabled obligation `rules/test/fixture-isolation.md` places on every fixture repo.

echo ""
echo "=== D8: fx_ensure_git / fx_stage never swallow their own failure ==="
# SWALLOW_RE / CP_*_RE / TEMPLATE_CALL_RE / GIT_ADD_*_RE / STAGED_ENUM_RE / EARLY_GIT_TEST_RE
# and the C6 trio are defined once in scanners.sh; the D8t-D12v tables pin those same
# constants row by row.
fx_body fx_ensure_git > "$FX_BODY"
d8_cp="$(grep -cE -- "$CP_CALL_RE" "$FX_BODY" || true)"
d8_guarded="$(grep -E -- "$CP_GUARDED_RE" "$FX_BODY" | grep -cvE -- "$SWALLOW_RE" || true)"
if [[ "$d8_cp" == "0" ]]; then
    fail "D8a: no cp call in fx_ensure_git's body — the template clone is absent, so the first fixture never gets a repo and the --staged cases go green on an empty diff"
elif [[ "$d8_guarded" -lt "$d8_cp" ]]; then
    fail "D8a: $d8_cp cp call(s) in fx_ensure_git, only $d8_guarded under a handler that acts (want 'if ! cp …' or 'cp … || return 1'; '|| true' is not one) — an unchecked cp leaves the repo missing and says nothing"
else
    pass "D8a: every cp in fx_ensure_git sits under a failure handler that acts on the failure"
fi
if grep -qE -- "$TEMPLATE_CALL_RE" "$FX_BODY"; then
    pass "D8b: fx_ensure_git calls _fx_git_template, so the clone source exists on the first call"
else
    fail "D8b: fx_ensure_git never calls _fx_git_template (detail plan R21) — on the first call there is nothing to clone from"
fi
# D8d applies D8a's shape to `git add` (CPR-ORTH); D8e pins the staged-file enumeration.
# Both are TEXT discipline — the on-host positive confirmation is detail plan Step 4
# verification 3, the one-off manual test that disables fx_ensure_git and requires
# cases-staged.sh / cases-injection.sh to turn red. D8c's body count is the shared
# non-vacuity guard for D8c-D8e.
d8_swallow=""
d8_seen=0
for _fn in fx_ensure_git fx_stage run_checker; do
    fx_body "$_fn" > "$FX_BODY"
    [[ -s "$FX_BODY" ]] || continue
    d8_seen=$((d8_seen + 1))
    # run_checker feeds D8e only: its pre-existing `git add -A … || true` is outside this
    # contract, and folding it in would make D8c report an unrelated line.
    [[ "$_fn" == "run_checker" ]] && continue
    grep -qE -- "$SWALLOW_RE" "$FX_BODY" && d8_swallow="$d8_swallow $_fn"
done
if [[ "$d8_seen" -ne 3 ]]; then
    fail "D8c: only $d8_seen of fx_ensure_git/fx_stage/run_checker have a body in the dump, so D8c-D8e would scan nothing"
elif [[ -z "$d8_swallow" ]]; then
    pass "D8c: neither fx_ensure_git nor fx_stage ends a command with || true or || :"
else
    fail "D8c: failure swallowed by || true / || : in:$d8_swallow — the caller then cannot tell a built repo from a missing one"
fi
fx_body fx_stage > "$FX_BODY"
d8_add="$(grep -cE -- "$GIT_ADD_RE" "$FX_BODY" || true)"
d8_add_ok="$(grep -E -- "$GIT_ADD_GUARDED_RE" "$FX_BODY" | grep -cvE -- "$SWALLOW_RE" || true)"
if [[ "$d8_add" == "0" ]]; then
    fail "D8d: no git add in fx_stage's body — the entry point cases-staged.sh is redirected to stages nothing"
elif [[ "$d8_add_ok" -lt "$d8_add" ]]; then
    fail "D8d: $d8_add git add call(s) in fx_stage, only $d8_add_ok under a handler that acts (want 'if ! git … add …' or 'git … add … || return 1'; '|| true' is not one) — an unstaged file leaves --staged an empty diff and the case goes green on nothing"
else
    pass "D8d: every git add in fx_stage sits under a failure handler that acts on the failure"
fi
fx_body run_checker > "$FX_BODY"
d8_enum="$(grep -cE -- "$STAGED_ENUM_RE" "$FX_BODY" || true)"
d8_enum_sw="$(grep -E -- "$STAGED_ENUM_RE" "$FX_BODY" | grep -cE -- "$SWALLOW_RE" || true)"
if [[ "$d8_enum" == "0" ]]; then
    fail "D8e: run_checker's staged branch never enumerates staged files — every --staged case then grades an empty list"
elif [[ "$d8_enum_sw" != "0" ]]; then
    fail "D8e: the staged-file enumeration in run_checker carries || true / || : — an empty or failed enumeration reads as success and the case passes on zero files"
else
    pass "D8e: the staged-file enumeration in run_checker carries no empty-result swallow"
fi

echo ""
echo "=== D10/D11: fx_ensure_git idempotency and path quoting, statically ==="
# Text discipline again: Step 4 verification 2 measures `git init` == 1 on the real host,
# and this file never runs git. D10 pins the early return that measurement depends on.
fx_body fx_ensure_git > "$FX_BODY"
if [[ ! -s "$FX_BODY" ]]; then
    fail "D10: fx_ensure_git has no body in the dump — the idempotent entry point does not exist yet"
elif ! grep -qE -- "$EARLY_GIT_TEST_RE" "$FX_BODY" || ! grep -qE -- '(^|[^A-Za-z0-9_.-])return([[:space:]]|$)' "$FX_BODY"; then
    fail "D10: fx_ensure_git has no '-d …/.git' test paired with a return — without that early exit the second call re-clones, and cases-injection.sh pays it 25+ times over one INJ_DIR"
else
    pass "D10: fx_ensure_git short-circuits on an existing .git, so a repeat call costs no git"
fi
d11_bad=""
d11_seen=0
for _fn in fx_ensure_git fx_stage mk_tree; do
    fx_body "$_fn" > "$FX_BODY"
    [[ -s "$FX_BODY" ]] || continue
    d11_seen=$((d11_seen + 1))
    _u="$(strip_quoted < "$FX_BODY" | grep -nE -- "$UNQUOTED_EXP_RE" || true)"
    [[ -z "$_u" ]] || d11_bad="$d11_bad $_fn:$(printf '%s' "$_u" | tr '\n' ',')"
done
if [[ "$d11_seen" -ne 3 ]]; then
    fail "D11: only $d11_seen of fx_ensure_git/fx_stage/mk_tree have a body in the dump, so the quoting scan reads nothing"
elif [[ -z "$d11_bad" ]]; then
    pass "D11: every expansion in fx_ensure_git/fx_stage/mk_tree is quoted"
else
    fail "D11: unquoted expansion(s) —$d11_bad — a fixture path holding a space or a glob character splits there, and the repo is built somewhere other than where the case looks"
fi

echo ""
echo "=== D12: the cloned fixture repo keeps the developer's git hooks disabled ==="
# rules/test/fixture-isolation.md requires every fixture repo to disable core.hooksPath.
# One `git init` and N clones splits that obligation in three, and all three are text:
# whether a real pre-commit ever fires is Step 4 verification 3's on-host run.
fx_body _fx_git_template > "$FX_BODY"
if [[ ! -s "$FX_BODY" ]]; then
    fail "D12a: _fx_git_template has no body in the dump — the single repo every fixture is cloned from does not exist yet, so nothing disables git hooks anywhere in the suite"
elif ! grep -qE -- "$HOOKS_OFF_RE" "$FX_BODY"; then
    fail "D12a: _fx_git_template never sets core.hooksPath to /dev/null (rules/test/fixture-isolation.md) — the developer's real pre-commit/post-commit hooks then fire inside every cloned fixture"
else
    pass "D12a: _fx_git_template disables core.hooksPath on the one repo every fixture is cloned from"
fi
fx_body fx_ensure_git > "$FX_BODY"
if [[ ! -s "$FX_BODY" ]]; then
    fail "D12b: fx_ensure_git has no body in the dump, so the clone spelling cannot be read at all"
elif ! grep -qE -- "$CLONE_WHOLE_GIT_RE" "$FX_BODY"; then
    fail "D12b: fx_ensure_git's copy does not carry a whole .git to a whole .git — copying a subset (or handling config separately) leaves the template's core.hooksPath behind, and the fixture runs the host's hooks: $(brief "$(cat "$FX_BODY")")"
else
    pass "D12b: fx_ensure_git transports the entire .git, so the template's core.hooksPath travels into every clone"
fi
if [[ ! -s "$FX_BODY" ]]; then
    fail "D12c: fx_ensure_git has no body in the dump, so a re-init inside the clone path cannot be ruled out"
elif grep -qE -- "$REINIT_RE" "$FX_BODY"; then
    fail "D12c: fx_ensure_git re-runs git init/config on the clone — a rebuilt .git is no longer the template's .git, so the hooks-disabling setting is dropped without a word: $(brief "$(grep -E -- "$REINIT_RE" "$FX_BODY")")"
else
    pass "D12c: fx_ensure_git never re-inits or re-configures the clone, so the copied setting is the one in force"
fi
