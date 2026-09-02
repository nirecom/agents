# tests/feature-2119-settings-allow-ssot/retirement.sh
# Tests: bin/review-settings-allow, hooks/pre-commit
# Tags: install, settings, permissions, retirement, scope:issue-specific, pwsh-not-required, TL2
# T33: the reviewer and its commit-time gate are DELETED, not merely unused. Sourced by
# tests/feature-2119-settings-allow-ssot.sh, which owns PASS/FAIL/ROWS and assert_eq.

RETIRED_REVIEWER_REL="bin/review-settings-allow"
RETIRED_REVIEWER="$AGENTS_DIR/$RETIRED_REVIEWER_REL"
PRECOMMIT_REL="hooks/pre-commit"
PRECOMMIT="$AGENTS_DIR/$PRECOMMIT_REL"

# WHY A TEST FOR A DELETION. The reviewer existed to nag a human into re-syncing hand-typed
# allow rules; once they are generated there is no mirror to review, so its only remaining
# behaviour is blocking a commit over a drift that cannot exist. Left on disk it stays wired
# into muscle memory and gets re-enabled by accident.

t33_probe() { # <id> -> verdict
    case "$1" in
        reviewer-gone)
            # -e, not -f: a leftover directory or symlink of that name is equally not-deleted.
            if [ -e "$RETIRED_REVIEWER" ]; then printf 'STILL-PRESENT'; else printf 'deleted'; fi
            ;;
        precommit-no-invocation)
            [ -f "$PRECOMMIT" ] || { printf '<MISSING:%s>' "$PRECOMMIT_REL"; return; }
            if grep -q -- 'review-settings-allow' "$PRECOMMIT"; then printf 'STILL-WIRED'; else printf 'unwired'; fi
            ;;
        precommit-no-gate)
            # The gate's own locals and labels all carry the `_sa_` prefix, so the prefix
            # outliving the invocation line is exactly the half-deletion this row catches.
            [ -f "$PRECOMMIT" ] || { printf '<MISSING:%s>' "$PRECOMMIT_REL"; return; }
            if grep -q -- '_sa_' "$PRECOMMIT"; then printf 'GATE-REMAINS'; else printf 'gate-removed'; fi
            ;;
        precommit-parses)
            # Cutting a block out of the middle of a shell script is how an unbalanced `fi`
            # gets in. The remaining hook has to still be a valid script.
            [ -f "$PRECOMMIT" ] || { printf '<MISSING:%s>' "$PRECOMMIT_REL"; return; }
            if bash -n "$PRECOMMIT" 2>/dev/null; then printf 'parses'; else printf 'SYNTAX-ERROR'; fi
            ;;
    esac
}

t33_retirement_table() {
    local id want label
    while IFS='|' read -r id want label; do
        [ -n "$id" ] || continue
        ROWS=$((ROWS + 1))
        assert_eq "T33[$id]: $label" "$want" "$(t33_probe "$id")"
    done <<'T33_CASES'
reviewer-gone|deleted|bin/review-settings-allow is gone from the tree -- the generated rules have no hand-maintained mirror left for it to review
precommit-no-invocation|unwired|hooks/pre-commit no longer invokes the retired reviewer, so a settings.json commit cannot be blocked by a drift that can no longer exist
precommit-no-gate|gate-removed|hooks/pre-commit carries no `_sa_` gate remnant either -- the whole block left, not just the call line
precommit-parses|parses|hooks/pre-commit still passes `bash -n` after the block was cut out (an unbalanced fi would disable EVERY pre-commit check, not only this one)
T33_CASES
}

t33_retirement_table

T39_ABSENT=""
T39_FINDING=""
T39_ARMED=""

# T39 -- THE GATE IS RUN, NOT GREPPED. T33 proves the text is gone from the file; it cannot prove
# the hook still WORKS, and a deletion that leaves the reviewer wired in through some other name,
# or that quietly disables everything after it, greps clean. So hooks/pre-commit is executed in a
# sandbox repo shaped exactly as the gate armed on -- its own git repo, carrying the install/
# inputs, with the hook invoked from a copy inside it so `$0` resolves _cfg_dir to the sandbox.
#
# THE POSITIVE CONTROL IS IN THE SAME RUN. A `.env` is staged alongside; the gate that blocks it
# sits BELOW the retired block, so "the retired gate said nothing" and "execution reached past
# where it used to be" are established by one invocation. Without it, a hook truncated at line 5
# would look exactly like a hook whose gate was cleanly removed.
t39_sandbox() { # <dir> <absent|finding>
    local d="$1"
    mkdir -p "$d/hooks/lib" "$d/install" "$d/bin" "$d/fixture"
    git init -q "$d"
    git -C "$d" config core.hooksPath /dev/null 2>/dev/null || true
    git -C "$d" config user.email "test@example.com"
    git -C "$d" config user.name "Test"
    git -C "$d" config commit.gpgsign false
    cp "$PRECOMMIT" "$d/hooks/pre-commit"
    cp "$AGENTS_DIR/hooks/lib/load-env.sh" "$d/hooks/lib/load-env.sh"
    printf '%s\n' '# fixture SSOT' 'bin/fx-tool' > "$d/install/settings-allow-commands.txt"
    printf '%s\n' '#!/usr/bin/env node' > "$d/install/gen-settings-allow.js"
    printf '%s\n' '{}' > "$d/settings.json"
    git -C "$d" add -A
    ENFORCE_WORKTREE=off git -C "$d" commit -q -m "seed"
    # The drift the retired gate existed to catch, plus the control the surviving gate catches.
    printf '%s\n' 'bin/fx-added' >> "$d/install/settings-allow-commands.txt"
    printf '%s\n' '{ "permissions": { "allow": ["Bash(t39-hand-written *)"] } }' > "$d/settings.json"
    printf '%s\n' 'T39_CANARY=1' > "$d/fixture/.env"
    git -C "$d" add -A -- settings.json install/settings-allow-commands.txt fixture/.env
    [ "$2" = "finding" ] || return 0
    printf '%s\n' '#!/bin/sh' 'echo "fixture reviewer finding"' 'exit 1' > "$d/bin/review-settings-allow"
    chmod +x "$d/bin/review-settings-allow"
}

# The arming preconditions, restated here because after the deletion there is nowhere else left to
# read them from: the sandbox carries the gate's own input file and is its own agents session repo
# with the hook copy inside it. A fixture that stopped meeting them would make every row below
# pass without the gate having been retired at all.
t39_arming() { # <dir> -> armed | NOT-ARMED:<reason>
    [ -f "$1/hooks/pre-commit" ] || { printf 'NOT-ARMED:no-hook-copy'; return; }
    [ -f "$1/install/settings-allow-commands.txt" ] || { printf 'NOT-ARMED:no-ssot'; return; }
    local common
    common="$(git -C "$1" rev-parse --git-common-dir 2>/dev/null || true)"
    [ -n "$common" ] || { printf 'NOT-ARMED:not-a-repo'; return; }
    printf 'armed'
}

t39_probe() { # <absent|finding> -> "<retired>/<control>" | sentinel
    [ -f "$PRECOMMIT" ] || { printf '<MISSING:%s>' "$PRECOMMIT_REL"; return; }
    command -v git >/dev/null 2>&1 || { printf '<MISSING:git>'; return; }
    local d out rc retired control
    d="$TMPROOT/t39-$1"
    t39_sandbox "$d" "$1"
    rc=0
    out="$( ( cd "$d" || exit 127
              # CODE_LANG is unset with the rest: its gate sits between the arming block and the
              # control, so an inherited value would decide the verdict from outside the fixture.
              unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID AGENTS_CONFIG_DIR CODE_LANG
              ENFORCE_WORKTREE=off; export ENFORCE_WORKTREE
              run_with_timeout 60 bash hooks/pre-commit ) 2>&1 )" || rc=$?
    if printf '%s\n' "$out" | grep -q 'review-settings-allow'; then retired="RETIRED-GATE-FIRED"; else retired="silent"; fi
    if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -q '\.env file(s) staged for commit'; then
        control="fired"
    else
        control="MISSED"
    fi
    printf '%s/%s' "$retired" "$control"
}

t39_setup() {
    T39_ABSENT="$(t39_probe absent)"
    T39_FINDING="$(t39_probe finding)"
    T39_ARMED="$(t39_arming "$TMPROOT/t39-absent")"
}

t39_behaviour_table() {
    local id want got label
    while IFS='|' read -r id want label; do
        [ -n "$id" ] || continue
        case "$id" in
            arming)  got="$T39_ARMED" ;;
            absent)  got="$T39_ABSENT" ;;
            finding) got="$T39_FINDING" ;;
        esac
        ROWS=$((ROWS + 1))
        assert_eq "T39[$id]: $label" "$want" "$got"
    done <<'T39_CASES'
arming|armed|PRECONDITION: the sandbox meets every condition the deleted gate armed on, so a silent run below is evidence of retirement rather than of a fixture that never triggered it
absent|silent/fired|with no bin/review-settings-allow anywhere, a commit in that repo is NOT blocked -- and the .env gate further down the same hook still blocks it, so the run really did execute past where the gate used to be
finding|silent/fired|CPR-ORTH: the gate's OTHER fail-closed branch is gone too -- an executable reviewer that reports a finding no longer blocks either, which a deletion that left the invocation behind would fail
T39_CASES
}

t39_setup
t39_behaviour_table
