#!/usr/bin/env bash
# Part of tests/enforce-system-ops-classifier.sh (rules/coding/file-split.md).
# Section E - the SYSTEM_OPS_APPROVED bypass branch, in both of its halves:
# the INHERITED env value (only the exact string "1" bypasses) and the INLINE
# spellings the model could write into its own payload (never bypass).

# ===========================================================================
# Section E - the SYSTEM_OPS_APPROVED branch. Source contract (lines 5-6, 55-56):
# ONLY an inherited process env value that is exactly the string "1" bypasses.
# Row `env-inline-prefix` and `env-inline-export` are the security-critical
# pair named in rules/user-escalation.md: a bypass the model can write into its
# own Bash payload is not a bypass at all.
# ===========================================================================
run_E_inherited() {
while IFS='|' read -r name want envspec cmd; do
    [ -z "$name" ] && continue
    case "$name" in \#*) continue ;; esac
    name="$(printf '%s' "$name" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    want="$(printf '%s' "$want" | tr -d '[:space:]')"
    envspec="$(printf '%s' "$envspec" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    cmd="$(printf '%s' "$cmd" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    assert_eq "E $name" "$want" "$(run_cmd "$cmd" Bash "$envspec")"
done <<'TABLE'
env-unset-blocks         | BLOCK | unset | winget install jq
env-inherited-1-allows   | ALLOW | 1     | winget install jq
env-inherited-1-allows-F | ALLOW | 1     | mkfs.ext4 /dev/sdb1
env-inherited-0-blocks   | BLOCK | 0     | winget install jq
env-inherited-true-blocks| BLOCK | true  | winget install jq
env-inherited-yes-blocks | BLOCK | yes   | winget install jq
env-inherited-01-blocks  | BLOCK | 01    | winget install jq
env-inherited-empty-block| BLOCK |       | winget install jq
TABLE
}

# The inline forms carry no env argument on purpose: they must be blocked with
# the variable UNSET in the hook's own environment, which is exactly the state a
# real session is in when the model writes the prefix into its Bash payload.
run_E_inline() {
while IFS='|' read -r name want cmd; do
    [ -z "$name" ] && continue
    case "$name" in \#*) continue ;; esac
    name="$(printf '%s' "$name" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    want="$(printf '%s' "$want" | tr -d '[:space:]')"
    cmd="$(printf '%s' "$cmd" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    assert_eq "E $name" "$want" "$(run_cmd "$cmd")"
done <<'TABLE'
env-inline-prefix        | BLOCK | SYSTEM_OPS_APPROVED=1 winget install jq
env-inline-export        | BLOCK | export SYSTEM_OPS_APPROVED=1 && winget install jq
env-inline-export-semi   | BLOCK | export SYSTEM_OPS_APPROVED=1; apt install jq
env-inline-in-bash-c     | BLOCK | bash -c 'export SYSTEM_OPS_APPROVED=1; winget install jq'
env-inline-env-cmd       | BLOCK | env SYSTEM_OPS_APPROVED=1 winget install jq
TABLE
}
