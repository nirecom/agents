#!/bin/bash
# tests/feature-worktree-start-non-interactive/reuse-safety.sh
# Tests: skills/worktree-start/SKILL.md, skills/worktree-start/scripts/derive-worktree-name.sh
# Tags: worktree, start, reuse-safety, idempotency, guard, TL2, scope:issue-specific
# B22 — WS-2 reuse-safety negative cases against real git worktree fixtures.
# Part of the feature-worktree-start-non-interactive suite — see the dispatcher.
#
# Why this file exists: B12 (session-and-idempotency.sh) pins the POSITIVE half of
# WS-2 — an entry at the expected path is reused instead of re-added. The negative
# half is the dangerous one. WS-2 lines 21-26 say an existing entry is reusable ONLY
# when all three hold: its `branch` line equals refs/heads/<BRANCH_TYPE>/<TASK_NAME>,
# it carries neither `locked` nor `prunable`, and `git -C <path> status --porcelain`
# prints nothing; a non-zero exit from either git call is treated the same as a
# failing condition ("ownership cannot be verified"). In every failing case the skill
# must STOP: no `git worktree add`, and no delete / prune / reset / stash of the
# worktree that is already there — it may hold another session's in-flight work.
#
# WS-2 is orchestration prose the model executes, so — exactly as B12 does — the
# documented algorithm is reproduced here as bash helper functions and driven against
# real fixtures. What is under test is the algorithm's decision and its
# non-mutation, not a script that implements it (there is none).

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"
setup_fixture
# derive-gh.sh also shims PATH; this file owns its own use of the shared $STUBDIR.
ensure_stubdir

REAL_GIT="$(command -v git)"

# --- fixture repo -----------------------------------------------------------
# One repo hosts every case; each case gets its own <base> directory, so the same
# derived <task-name>/<repo-name> tail can be reused without the cases colliding.
RS_REPO_NAME="rs-repo"
RS_REPO="$FIXTURE/$RS_REPO_NAME"
mkdir -p "$RS_REPO"
git -C "$RS_REPO" init -q >/dev/null 2>&1
git -C "$RS_REPO" config core.hooksPath /dev/null
git -C "$RS_REPO" config user.email "fixture@example.com"
git -C "$RS_REPO" config user.name "Fixture"
git -C "$RS_REPO" commit -q --allow-empty -m "fixture base" >/dev/null 2>&1

# The name really is derived by the script under test, so the paths these cases
# guard are the paths production would compute — not hand-written lookalikes.
RS_INTENT="$FIXTURE/rs-intent.md"
write_intent "$RS_INTENT" 'Reuse safety probe for worktree start' ''
run_derive B22/derive --intent "$RS_INTENT" --repo-dir "$RS_REPO"
RS_TASK="$(task_name)"
RS_TYPE="$(branch_type)"
RS_REPO_OUT="$(repo_name)"

# ── The WS-2 reuse-safety algorithm, as documented ──────────────────────────
#
# ws_reuse_verdict <repo> <expected-native-path> <expected-branch-ref>
#   RS_VERDICT  -> none | reuse | refuse
#   RS_REASON   -> the specific WS-2 condition that refused (empty otherwise)
# Deliberately contains no `git worktree prune`, `git worktree remove`, `git reset`,
# `git clean` or `git stash`: "stop without mutating" is a property of the algorithm
# itself, and B22/no-mutation-verbs below asserts that property on this source text.
RS_VERDICT=""
RS_REASON=""
RS_ADDS=0

ws_reuse_verdict() {
    local repo="$1" want="$2" ref="$3"
    local listing block st
    RS_VERDICT=""
    RS_REASON=""
    # A non-zero exit means ownership cannot be verified — never "no entry".
    listing="$(git -C "$repo" worktree list --porcelain 2>/dev/null)" || {
        RS_VERDICT="refuse"; RS_REASON="list-failed"; return 0
    }
    # Porcelain records are blank-line-separated blocks headed by `worktree <path>`.
    # Exact path identity, per WS-2 — a substring hit is a different worktree.
    block="$(printf '%s\n' "$listing" | awk -v want="$want" '
        /^worktree /            { inb = (substr($0, 10) == want) }
        /^[[:space:]]*$/        { inb = 0 }
        inb                     { print }
    ')"
    if [ -z "$block" ]; then RS_VERDICT="none"; return 0; fi
    if ! printf '%s\n' "$block" | grep -qxF "branch $ref"; then
        RS_VERDICT="refuse"; RS_REASON="branch"; return 0
    fi
    if printf '%s\n' "$block" | grep -qE '^locked([[:space:]]|$)'; then
        RS_VERDICT="refuse"; RS_REASON="locked"; return 0
    fi
    if printf '%s\n' "$block" | grep -qE '^prunable([[:space:]]|$)'; then
        RS_VERDICT="refuse"; RS_REASON="prunable"; return 0
    fi
    st="$(git -C "$want" status --porcelain 2>/dev/null)" || {
        RS_VERDICT="refuse"; RS_REASON="status-failed"; return 0
    }
    if [ -n "$st" ]; then RS_VERDICT="refuse"; RS_REASON="dirty"; return 0; fi
    RS_VERDICT="reuse"
    return 0
}

# ws_create_or_reuse <repo> <raw-path> <native-path> <branch>
# WS-2 -> WS-6: create only on `none`; `reuse` and `refuse` both stop without adding.
ws_create_or_reuse() {
    local repo="$1" raw="$2" native="$3" branch="$4"
    ws_reuse_verdict "$repo" "$native" "refs/heads/$branch"
    [ "$RS_VERDICT" = "none" ] || return 0
    mkdir -p "$(dirname "$raw")"
    RS_ADDS=$((RS_ADDS + 1))
    git -C "$repo" worktree add "$raw" -b "$branch" >/dev/null 2>&1
}

# --- per-case fixture plumbing ----------------------------------------------
RS_RAW=""; RS_NATIVE=""; RS_BRANCH=""; RS_COUNT_BEFORE=0; RS_ADDS_BEFORE=0

wt_total() { git -C "$RS_REPO" worktree list --porcelain | grep -c '^worktree '; }
wt_at()    { git -C "$RS_REPO" worktree list --porcelain | sed -n 's/^worktree //p' | grep -cxF "$1"; }

# rs_case_paths <case> — the WS-2 path for this case, under its own <base>.
rs_case_paths() {
    RS_RAW="$FIXTURE/base-$1/$RS_TASK/$RS_REPO_NAME"
    RS_NATIVE="$(native_path "$RS_RAW")"
    RS_BRANCH="$RS_TYPE/$RS_TASK-$1"
}

# rs_snapshot — the state the refusal must leave untouched.
rs_snapshot() { RS_COUNT_BEFORE="$(wt_total)"; RS_ADDS_BEFORE="$RS_ADDS"; }

# rs_assert_refused <case> <want-reason>
rs_assert_refused() {
    local case="$1" want="$2"
    if [ "$RS_VERDICT" = "refuse" ] && [ "$RS_REASON" = "$want" ]; then
        pass "B22/$case: WS-2 refuses reuse (reason=$want)"
    else
        fail "B22/$case: expected verdict=refuse reason=$want (verdict='$RS_VERDICT', reason='$RS_REASON')"
    fi
    if [ "$RS_ADDS" -eq "$RS_ADDS_BEFORE" ]; then
        pass "B22/$case/no-add: 'git worktree add' was never run"
    else
        fail "B22/$case/no-add: the refusal path ran 'git worktree add' ($RS_ADDS_BEFORE -> $RS_ADDS)"
    fi
    local after; after="$(wt_total)"
    if [ "$after" -eq "$RS_COUNT_BEFORE" ]; then
        pass "B22/$case/count: the registered worktree count is unchanged ($after)"
    else
        fail "B22/$case/count: worktree count changed ($RS_COUNT_BEFORE -> $after) — the refusal mutated the repo"
    fi
}

if [ -z "$RS_TASK" ] || [ -z "$RS_TYPE" ] || [ "$RS_REPO_OUT" != "$RS_REPO_NAME" ]; then
    fail "B22/derive: could not derive a name for the reuse-safety fixture (rc=$RC, out='$OUT', err='$ERR')"
else
    pass "B22/derive: the fixture path is built from a really-derived TASK_NAME/BRANCH_TYPE/REPO_NAME"

    # --- B22/none: the vacuous-pass guard -----------------------------------
    # Every case below asserts "refuse". Without a case proving the same algorithm
    # DOES create when nothing is registered, an always-refusing implementation
    # would pass the whole file.
    rs_case_paths none
    RS_BRANCH="$RS_TYPE/$RS_TASK-none"
    rs_snapshot
    ws_create_or_reuse "$RS_REPO" "$RS_RAW" "$RS_NATIVE" "$RS_BRANCH"
    if [ "$RS_VERDICT" = "none" ] && [ "$RS_ADDS" -eq $((RS_ADDS_BEFORE + 1)) ] && [ "$(wt_at "$RS_NATIVE")" -eq 1 ]; then
        pass "B22/none: no entry at the expected path -> exactly one 'git worktree add' creates it"
    else
        fail "B22/none: expected verdict=none, one add, one registered entry (verdict='$RS_VERDICT', adds=$RS_ADDS_BEFORE->$RS_ADDS, at-path=$(wt_at "$RS_NATIVE"))"
    fi

    # --- B22/clean: the positive control ------------------------------------
    # Same path, second pass: all three conditions hold, so WS-2 reuses.
    rs_snapshot
    ws_create_or_reuse "$RS_REPO" "$RS_RAW" "$RS_NATIVE" "$RS_BRANCH"
    if [ "$RS_VERDICT" = "reuse" ] && [ "$RS_ADDS" -eq "$RS_ADDS_BEFORE" ]; then
        pass "B22/clean: a matching, unlocked, non-prunable, clean worktree is reused without adding"
    else
        fail "B22/clean: expected verdict=reuse with no further add (verdict='$RS_VERDICT', reason='$RS_REASON', adds=$RS_ADDS_BEFORE->$RS_ADDS)"
    fi

    # --- B22/branch: registered at the expected path, on a DIFFERENT branch --
    # A naming collision, not a reusable worktree. Attaching to it would put this
    # session's commits on someone else's branch.
    rs_case_paths branch
    RS_OTHER_BRANCH="chore/$RS_TASK-collision"
    mkdir -p "$(dirname "$RS_RAW")"
    git -C "$RS_REPO" worktree add "$RS_RAW" -b "$RS_OTHER_BRANCH" >/dev/null 2>&1
    rs_snapshot
    ws_create_or_reuse "$RS_REPO" "$RS_RAW" "$RS_NATIVE" "$RS_TYPE/$RS_TASK-branch"
    rs_assert_refused branch branch
    RS_BRANCH_AFTER="$(git -C "$RS_RAW" rev-parse --abbrev-ref HEAD 2>/dev/null)"
    assert_eq "B22/branch/untouched: the colliding worktree is still on its own branch" \
        "$RS_OTHER_BRANCH" "$RS_BRANCH_AFTER"

    # --- B22/locked ---------------------------------------------------------
    rs_case_paths locked
    mkdir -p "$(dirname "$RS_RAW")"
    git -C "$RS_REPO" worktree add "$RS_RAW" -b "$RS_BRANCH" >/dev/null 2>&1
    git -C "$RS_REPO" worktree lock "$RS_RAW" >/dev/null 2>&1
    rs_snapshot
    ws_create_or_reuse "$RS_REPO" "$RS_RAW" "$RS_NATIVE" "$RS_BRANCH"
    rs_assert_refused locked locked
    if git -C "$RS_REPO" worktree list --porcelain | awk -v w="worktree $RS_NATIVE" '
        $0 == w { inb = 1; next } /^[[:space:]]*$/ { inb = 0 } inb && /^locked/ { found = 1 }
        END { exit(found ? 0 : 1) }'; then
        pass "B22/locked/untouched: the entry is still registered and still locked"
    else
        fail "B22/locked/untouched: the refusal unlocked or unregistered the worktree"
    fi

    # --- B22/prunable -------------------------------------------------------
    # The working directory is moved out from under a registered worktree, which is
    # exactly how git reports `prunable`. Refusing here is what keeps the skill from
    # "helpfully" running `git worktree prune` over another session's registration.
    rs_case_paths prunable
    mkdir -p "$(dirname "$RS_RAW")"
    git -C "$RS_REPO" worktree add "$RS_RAW" -b "$RS_BRANCH" >/dev/null 2>&1
    mv "$RS_RAW" "$RS_RAW-moved-away"
    rs_snapshot
    ws_create_or_reuse "$RS_REPO" "$RS_RAW" "$RS_NATIVE" "$RS_BRANCH"
    rs_assert_refused prunable prunable
    if git -C "$RS_REPO" worktree list --porcelain | sed -n 's/^worktree //p' | grep -qxF "$RS_NATIVE"; then
        pass "B22/prunable/untouched: the stale registration survives — no 'git worktree prune' / 'remove' ran"
    else
        fail "B22/prunable/untouched: the stale registration was pruned or removed by the refusal path"
    fi

    # --- B22/dirty ----------------------------------------------------------
    # Another session's in-flight work. The refusal must not reset, stash or delete it.
    rs_case_paths dirty
    mkdir -p "$(dirname "$RS_RAW")"
    git -C "$RS_REPO" worktree add "$RS_RAW" -b "$RS_BRANCH" >/dev/null 2>&1
    printf 'in-flight work from another session\n' > "$RS_RAW/inflight.txt"
    RS_DIRTY_BEFORE="$(git -C "$RS_RAW" status --porcelain)"
    RS_DIRTY_BODY="$(cat "$RS_RAW/inflight.txt")"
    rs_snapshot
    ws_create_or_reuse "$RS_REPO" "$RS_RAW" "$RS_NATIVE" "$RS_BRANCH"
    rs_assert_refused dirty dirty
    assert_eq "B22/dirty/status-untouched: 'git status --porcelain' is byte-identical afterwards" \
        "$RS_DIRTY_BEFORE" "$(git -C "$RS_RAW" status --porcelain 2>/dev/null)"
    if [ -f "$RS_RAW/inflight.txt" ]; then
        assert_eq "B22/dirty/content-untouched: the uncommitted file still holds its exact content" \
            "$RS_DIRTY_BODY" "$(cat "$RS_RAW/inflight.txt")"
    else
        fail "B22/dirty/content-untouched: the uncommitted file was deleted by the refusal path"
    fi

    # --- B22/list-failed ----------------------------------------------------
    # `git worktree list --porcelain` exits non-zero: ownership cannot be verified, so
    # WS-2 stops. The failure mode this guards against is treating "no listing" as
    # "no entry" and falling straight through to `git worktree add`.
    # A PATH shim is used rather than a broken repo path so ONLY the listing fails —
    # everything else in the algorithm stays real (derive-gh.sh's convention).
    cat > "$STUBDIR/git" <<STUB
#!/bin/sh
case " \$* " in
  *" worktree list "*) exit 3 ;;
esac
exec "$REAL_GIT" "\$@"
STUB
    chmod +x "$STUBDIR/git"
    rs_case_paths list-failed
    rs_snapshot
    RS_SAVED_PATH="$PATH"
    PATH="$STUBDIR:$PATH"
    ws_create_or_reuse "$RS_REPO" "$RS_RAW" "$RS_NATIVE" "$RS_BRANCH"
    PATH="$RS_SAVED_PATH"
    rs_assert_refused list-failed list-failed
    if [ ! -e "$RS_RAW" ]; then
        pass "B22/list-failed/no-create: nothing was created at the expected path"
    else
        fail "B22/list-failed/no-create: a worktree directory was created at '$RS_RAW' despite an unverifiable listing"
    fi

    # --- B22/status-failed --------------------------------------------------
    # The entry passes the branch/locked/prunable conditions, but the cleanliness
    # check itself fails. A failed status must never be read as "clean".
    rs_case_paths status-failed
    mkdir -p "$(dirname "$RS_RAW")"
    git -C "$RS_REPO" worktree add "$RS_RAW" -b "$RS_BRANCH" >/dev/null 2>&1
    cat > "$STUBDIR/git" <<STUB
#!/bin/sh
case " \$* " in
  *" status "*) exit 128 ;;
esac
exec "$REAL_GIT" "\$@"
STUB
    chmod +x "$STUBDIR/git"
    rs_snapshot
    RS_SAVED_PATH="$PATH"
    PATH="$STUBDIR:$PATH"
    ws_create_or_reuse "$RS_REPO" "$RS_RAW" "$RS_NATIVE" "$RS_BRANCH"
    PATH="$RS_SAVED_PATH"
    rs_assert_refused status-failed status-failed
    rm -f "$STUBDIR/git"

    # --- B22/no-mutation-verbs ----------------------------------------------
    # The three per-case "untouched" assertions above prove non-mutation for the
    # states they set up. This pins the general property at the source: the
    # documented algorithm reproduced in this file contains no destructive verb at
    # all, so no refusal path — including ones no fixture covers — can reach one.
    RS_ALGO="$(extract_fn ws_reuse_verdict "${BASH_SOURCE[0]}")
$(extract_fn ws_create_or_reuse "${BASH_SOURCE[0]}")"
    RS_BAD=""
    for rs_verb in 'worktree prune' 'worktree remove' 'worktree unlock' 'reset --hard' 'git clean' 'git stash' 'rm -rf'; do
        printf '%s\n' "$RS_ALGO" | grep -qF "$rs_verb" && RS_BAD="$RS_BAD '$rs_verb'"
    done
    if [ -n "$RS_ALGO" ] && [ -z "$RS_BAD" ]; then
        pass "B22/no-mutation-verbs: the WS-2 algorithm carries no prune/remove/reset/clean/stash verb on any path"
    else
        fail "B22/no-mutation-verbs: destructive verbs reachable from the reuse check:$RS_BAD (algo empty=$([ -z "$RS_ALGO" ] && echo yes || echo no))"
    fi

    # --- B22/adds-total -----------------------------------------------------
    # Stated as its own total: across every negative case, the only `git worktree add`
    # the algorithm ever ran is B22/none's.
    if [ "$RS_ADDS" -eq 1 ]; then
        pass "B22/adds-total: exactly one 'git worktree add' across all reuse-safety cases"
    else
        fail "B22/adds-total: expected exactly 1 algorithm-driven 'git worktree add' (got $RS_ADDS)"
    fi
fi

report_shape reuse
finish
