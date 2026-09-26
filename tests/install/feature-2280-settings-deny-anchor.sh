#!/usr/bin/env bash
# tests/feature-2280-settings-deny-anchor.sh
# Tests: settings.json
# Tags: settings, permissions, deny, ssot, scope:issue-specific, pwsh-not-required, TL2
#
# Run wrapped: bin/run-with-timeout.sh 120 bash tests/feature-2280-settings-deny-anchor.sh
#
# THE INCIDENT (#2280): `*` in `Bash(*push --force*)` matched narration text, not only
# real git invocations, causing false-positive blocks on harmless commands.

set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SETTINGS="$AGENTS_DIR/settings.json"
PART_DIR="$AGENTS_DIR/tests/install/feature-2280-settings-deny-anchor"

# CONTRACT: MUST-trigger rules are anchored to the four git invocation forms (bare /
# `git -C *` / `git -c *` / `git --no-pager`). OPTIONAL rm/find/sudo/docker/aws family
# keeps leading `*` (sudo/env/xargs prefix safety). cd-compound forms are NOT matched
# (P13-P37 = NO-MATCH); bash-guard denies the chain operator itself instead.
# OUT OF SCOPE: deployed ~/.claude/settings.json drift, JSON re-assembly, #2266 redesign.

PASS=0
FAIL=0
PEND=0
ROWS=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; [ -n "${2:-}" ] && echo "    detail: $2"; FAIL=$((FAIL + 1)); }
pend() { echo "PEND: $1"; [ -n "${2:-}" ] && echo "    detail: $2"; PEND=$((PEND + 1)); }

assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then echo "PASS: $name"; PASS=$((PASS + 1))
    else echo "FAIL: $name -- want [$want] got [$got]"; FAIL=$((FAIL + 1)); fi
}

# TL3 gap (what this test does NOT catch):
# - Whether the HOST permission engine reaches the same verdict: matcher.sh is an
#   approximation of the host's glob matching, pinned only by the C1-C14 table.
# - Whether a deny verdict actually blocks the tool call in a live session.
# - Whether `runInTerminal` / `runCommands` (VS Code terminal) consult these rules at all --
#   a known hole recorded in docs/architecture/claude-code/settings.md.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration.

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/sd-2280.XXXXXX")" || { echo "FAIL: harness -- mktemp -d failed"; exit 1; }
trap 'rm -rf "$TMPROOT"' EXIT

. "$PART_DIR/matcher.sh"

# CONFIG-DEPENDENT BRANCH, pinned explicitly rather than read from ambient state: whether
# the anchored MUST-trigger rules are deployed in settings.json yet. Until write-code lands
# them, rows that can only pass under anchoring are reported PEND instead of FAIL, so the
# table is authored and reviewable ahead of the implementation without turning run-all red.

# BIDIRECTIONAL check, not a single presence read: a lone "new rule present?" test would
# silently fold a revert or partial landing (old rule back, or both present) into
# ANCHORED=0 -- all PEND, never FAIL. Reading both literals lets "both present" be caught
# as its own inconsistent state below instead of being absorbed into a branch that hides it.
OLD_RULE_PRESENT=0
NEW_RULE_PRESENT=0
deny_list_has "$SETTINGS" "*push --force" && OLD_RULE_PRESENT=1
deny_list_has "$SETTINGS" "git push --force" && NEW_RULE_PRESENT=1
if [ "$OLD_RULE_PRESENT" = "1" ] && [ "$NEW_RULE_PRESENT" = "1" ]; then
    echo "FAIL: harness -- settings.json carries BOTH Bash(*push --force) (pre-fix) and"
    echo "    Bash(git push --force) (post-fix) -- inconsistent/partial #2280 landing"
    exit 1
fi
# THIRD STATE: neither literal present. Not "not yet fixed" (that is OLD=1/NEW=0) -- the
# force-push deny protection itself is gone, e.g. write-code landed a differently-spelled
# rule. Folding this into ANCHORED=0 would let ~130 depends-on-anchoring rows PEND silently
# forever (exit 0) without ever having verified the fix landed correctly.
if [ "$OLD_RULE_PRESENT" = "0" ] && [ "$NEW_RULE_PRESENT" = "0" ]; then
    echo "FAIL: harness -- settings.json carries NEITHER Bash(*push --force) (pre-fix) nor"
    echo "    Bash(git push --force) (post-fix) -- force-push deny protection is missing entirely"
    exit 1
fi
ANCHORED="$NEW_RULE_PRESENT"

# <depends-on-anchoring> is yes/no: "yes" means this row's correct verdict only holds
# once the anchored rules are deployed (P/N series -- a mismatch under ANCHORED=0 is
# expected and PENDs); "no" means the row's verdict is invariant either way (O/L series,
# and the G-series members that turned out independent -- a mismatch is a real bug and
# FAILs immediately regardless of ANCHORED). Round-4 fix: this used to be unconditional,
# which let a genuinely-wrong "no"-class row (G5) hide behind PEND for two review rounds.
check_deny_row() { # <id> <command> <target-deny-pattern|any> <MATCHED|NO-MATCH> <depends-on-anchoring>
    local id="$1" cmd="$2" pat="$3" want="$4" depends="$5" got detail
    ROWS=$((ROWS + 1))
    deny_probe "$SETTINGS" "$cmd"
    got="$DENY_VERDICT"
    detail="cmd=[$cmd] target-pattern=[$pat]"
    if [ "$got" != "$want" ]; then
        if [ "$ANCHORED" = "0" ] && [ "$depends" = "yes" ]; then
            pend "$id -- want [$want] got [$got]" "$detail (needs the anchored deny rules; write-code pending)"
        else
            fail "$id -- want [$want] got [$got]" "$detail hits=[$DENY_HITS]"
        fi
        return 0
    fi
    # A row naming its target pattern must MATCH *through that pattern*, not through some
    # wider rule that happens to swallow the command -- an overbroad implementation would
    # otherwise turn the whole MATCHED half of the table green. Enforceable only once the
    # rule is deployed; under ANCHORED=0 the target does not exist yet, so the row settles
    # on the verdict alone. `any` opts out where no single rule is the intended one.
    if [ "$want" = "MATCHED" ] && [ "$pat" != "any" ]; then
        if deny_list_has "$SETTINGS" "$pat"; then
            if deny_hits_contain "$pat"; then pass "$id ($want via Bash($pat))"
            else fail "$id -- Bash($pat) is deployed but was not the rule that matched" "$detail hits=[$DENY_HITS]"; fi
            return 0
        fi
        if [ "$ANCHORED" = "1" ]; then
            fail "$id -- the anchored rules landed but Bash($pat) is absent from permissions.deny" \
                "$detail hits=[$DENY_HITS]"
            return 0
        fi
    fi
    pass "$id ($want)"
}

. "$PART_DIR/regression-cases.sh"

t_mirror_crosscheck
t_matcher_robustness
t_deny_regression_table
t_launch_form_completeness
t_bug_reproduction_evidence
t_row_well_formed_selftest

# EXECUTED-ROW BUDGET. Every table increments ROWS; a drifted delimiter or an early return
# in front of a loop would otherwise leave a file that counts only its failures reporting green.
# crosscheck 14 (one verdict row each; the allow-module agreement row retired with #2264) + robustness 13 (12 + E4b shape pin) + regression table 80 (61 prior +
# N6-N13 MUST-trigger narration rows + L6-L15 sanctioned-command counterweights + P37
# refspec compound tail) + launch-form completeness 48 (12 triggers x 4 launch forms -- round-4
# C8 added +refspec/positional-force/git-clean triggers, PEND under ANCHORED=0) +
# bug-reproduction-evidence 1 + row_is_well_formed selftest 4.
ROWS_EXPECTED=161
assert_eq "T-budget: every table executed its full row count" "$ROWS_EXPECTED" "$ROWS"

echo ""
if [ "$ANCHORED" = "0" ]; then
    echo "NOTE: settings.json still carries the pre-fix leading-\`*\` deny rules"
    echo "      (no literal \"Bash(git push --force)\" in permissions.deny)."
    echo "      $PEND row(s) that require the anchored rules are reported PEND, not FAIL."
    echo "      They become enforced automatically once write-code lands Step 1-3."
fi
echo "Total: $PASS passed, $FAIL failed, $PEND pending-implementation"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
