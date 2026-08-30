# tests/feature-2119-settings-allow-ssot/precommit-real-commit.sh
# Tests: hooks/pre-commit, bin/review-settings-allow
# Tags: install, settings, permissions, ssot, scope:issue-specific, pwsh-not-required, TL2

# T20-T21: the gate as git actually runs it. Sourced AFTER precommit.sh, whose repo helpers
# (init_fixture_repo, mk_hook_repo, install_review_script, stage_trivial) this part reuses.

RC_OUT=""
RC_RC=0

# T20 -- THROUGH GIT, NOT AROUND IT. precommit.sh runs `bash hooks/pre-commit` with
# core.hooksPath pointed at /dev/null, which proves the script's logic and nothing about the
# wiring: a hook git never invokes blocks no commits at all. Here core.hooksPath is real, the
# assertion is `git commit`'s own exit status, and the allowed row additionally checks that a
# commit object was created -- "rc 0" from a hook that ran and a repository that refused to
# record anything are not the same outcome.
# The core.hooksPath wiring, named once (CPR-SSOT) so precommit-synchronized.sh can build its
# own repo shape and still route through the identical shim rather than a second copy of it.
wire_real_hook() { # <repo>
    mkdir -p "$1/githooks"
    printf '%s\n' '#!/bin/bash' > "$1/githooks/pre-commit"
    printf 'exec bash %s "$@"\n' "'$PRECOMMIT'" >> "$1/githooks/pre-commit"
    chmod +x "$1/githooks/pre-commit" 2>/dev/null || true
    git -C "$1" config core.hooksPath githooks
}

mk_real_hook_repo() { # <name> <review> <ssot> <gen> -> dir
    local dir
    dir="$(mk_hook_repo "$1" "$2" "$3" "$4")"
    wire_real_hook "$dir"
    printf '%s\n' "$dir"
}

# A repository with no agents shape at all: the one a globally installed core.hooksPath routes
# through this same hook.
mk_plain_repo() { # <name> <hook-source-repo> -> dir
    local dir="$TMPROOT/$1"
    init_fixture_repo "$dir"
    printf '%s\n' 'plain repo' > "$dir/README.md"
    git -C "$dir" add -A
    git -C "$dir" commit -q -m "initial" 2>/dev/null
    mkdir -p "$dir/githooks"
    cp "$2/githooks/pre-commit" "$dir/githooks/pre-commit"
    chmod +x "$dir/githooks/pre-commit" 2>/dev/null || true
    git -C "$dir" config core.hooksPath githooks
    printf '%s\n' "$dir"
}

run_real_commit() { # <repo> <agents-config-dir> [enforce-worktree]
    RC_OUT=""; RC_RC=0
    RC_OUT="$( (cd "$1" && unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID && \
        run_with_timeout 90 env "AGENTS_CONFIG_DIR=$2" "ENFORCE_WORKTREE=${3:-off}" \
        git commit -q -m "fixture commit") 2>&1 )" || RC_RC=$?
}

commit_count() { git -C "$1" rev-list --count HEAD 2>/dev/null || printf '0'; }

# Same discrimination precommit.sh uses: a commit that died for an unrelated reason is not
# evidence about THIS gate, and treating it as evidence is how a broken fixture reports green.
commit_verdict() { # <repo> <cfg-dir> -> allowed|blocked-by-gate|blocked-other
    stage_trivial "$1"
    run_real_commit "$1" "$2"
    [ "$RC_RC" -eq 0 ] && { printf 'allowed'; return; }
    if printf '%s\n' "$RC_OUT" | grep -Eqi 'review-settings-allow|Settings Allow'; then
        printf 'blocked-by-gate'
    else
        printf 'blocked-other'
    fi
}

t20_probe() { # <id> -> verdict | sentinel
    local repo before
    case "$1" in
        missing-reviewer)
            repo="$(mk_real_hook_repo t20-missing none yes yes)"
            commit_verdict "$repo" "$repo" ;;
        noexec-reviewer)
            repo="$(mk_real_hook_repo t20-noexec noexec yes yes)"
            commit_verdict "$repo" "$repo" ;;
        clean-commit)
            repo="$(mk_real_hook_repo t20-clean rc0 yes yes)"
            commit_verdict "$repo" "$repo" ;;
        commit-recorded)
            repo="$(mk_real_hook_repo t20-recorded rc0 yes yes)"
            before="$(commit_count "$repo")"
            stage_trivial "$repo"
            run_real_commit "$repo" "$repo"
            [ "$(commit_count "$repo")" = "$((before + 1))" ] && { printf 'yes'; return; }
            printf 'no' ;;
        harness-canary)
            repo="$(mk_real_hook_repo t20-canary rc0 yes yes)"
            stage_trivial "$repo"
            run_real_commit "$repo" "$repo" on
            [ "$RC_RC" -ne 0 ] && { printf 'blocked'; return; }
            printf 'NOT-BLOCKED' ;;
    esac
}

t20_real_commit_table() {
    local id want label
    while IFS='|' read -r id want label; do
        [ -n "$id" ] || continue
        ROWS=$((ROWS + 1))
        assert_eq "T20[$id]: $label" "$want" "$(t20_probe "$id")"
    done <<'T20_CASES'
harness-canary|blocked|CANARY: git really invokes the hook through core.hooksPath -- ENFORCE_WORKTREE=on stops this same commit
missing-reviewer|blocked-by-gate|a real `git commit` is refused when bin/review-settings-allow is absent
noexec-reviewer|blocked-by-gate|and refused when the reviewer exists but cannot be executed (a 100644 mode in a fresh clone)
clean-commit|allowed|a reviewer that exits 0 lets the real commit through
commit-recorded|yes|and the commit object is actually recorded, so "allowed" is not a hook that never ran
T20_CASES
}

# T21 -- THE OTHER VERDICT OF THE agents-REPO CLASSIFIER. A global core.hooksPath routes every
# repository on the machine through this hook, and this gate is agents-only. Every T8/T20 row
# runs in a repo that IS the agents repo, so a wiring that forgot _is_agents_session_repo
# entirely passes all of them -- and then fail-closes every commit in every unrelated project
# on the machine, since those repos have no bin/review-settings-allow at all. The config dir and
# the committing repo are therefore separate repositories here (CPR-ORTH, Pattern 4).
t21_probe() { # <id> -> verdict | sentinel
    local cfg foreign
    case "$1" in
        foreign-no-reviewer)
            cfg="$(mk_real_hook_repo t21-cfg-none none no no)"
            foreign="$(mk_plain_repo t21-foreign-none "$cfg")"
            commit_verdict "$foreign" "$cfg" ;;
        foreign-failing-reviewer)
            cfg="$(mk_real_hook_repo t21-cfg-rc3 rc3 yes yes)"
            foreign="$(mk_plain_repo t21-foreign-rc3 "$cfg")"
            commit_verdict "$foreign" "$cfg" ;;
        agents-failing-reviewer)
            cfg="$(mk_real_hook_repo t21-cfg-control rc3 yes yes)"
            commit_verdict "$cfg" "$cfg" ;;
    esac
}

t21_foreign_repo_table() {
    local id want label
    while IFS='|' read -r id want label; do
        [ -n "$id" ] || continue
        ROWS=$((ROWS + 1))
        assert_eq "T21[$id]: $label" "$want" "$(t21_probe "$id")"
    done <<'T21_CASES'
foreign-no-reviewer|allowed|a foreign repository commits normally even though it has no bin/review-settings-allow
foreign-failing-reviewer|allowed|and even when the config dir's reviewer would have failed: the gate never runs there
agents-failing-reviewer|blocked-by-gate|POSITIVE CONTROL: the identical failing reviewer DOES block when the committing repo is the agents repo
T21_CASES
}

t20_real_commit_table
t21_foreign_repo_table
