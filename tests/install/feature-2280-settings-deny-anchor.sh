#!/usr/bin/env bash
# tests/install/feature-2280-settings-deny-anchor.sh
# Tests: settings.json
# Tags: settings, permissions, deny, ssot, scope:issue-specific, pwsh-not-required, TL2
#
# Run wrapped: bin/run-with-timeout.sh 120 bash tests/install/feature-2280-settings-deny-anchor.sh
#
# THE INCIDENT (#2280): `*` in `Bash(*push --force*)` matched narration text, not only
# real git invocations, causing false-positive blocks on harmless commands.

set -uo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SETTINGS="$SCRIPT_CHECKOUT_ROOT/settings.json"
PART_DIR="$SCRIPT_CHECKOUT_ROOT/tests/install/feature-2280-settings-deny-anchor"

# CONTRACT: MUST-trigger rules are anchored to the four git invocation forms (bare /
# `git -C *` / `git -c *` / `git --no-pager`). OPTIONAL rm/find/sudo/docker/aws family
# keeps leading `*` (sudo/env/xargs prefix safety). cd-compound forms are NOT matched
# (P13-P37 = NO-MATCH); bash-guard denies the chain operator itself instead.
# OUT OF SCOPE: deployed ~/.claude/settings.json drift, JSON re-assembly, #2266 redesign.

. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

PEND=0
ROWS=0

# fail/assert_eq stay local, after the harness: the detail line and <name> <want> <got> order differ.
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
    dp_get "$id" # the caller queued ($id, $SETTINGS, $cmd) and ran the batch
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

# #2403: the read-only allow enumeration (former lines 21-75) retired into bash-guard's N3-N5
# classes. Checked as a CLASS (any cmd0 / git read spelling), not a line list, so a re-added
# variant spelling (`Bash(git log*)`) fails too; permissions.allow only -- deny is untouched.
# RA_KEPT: every permissions.allow entry OUTSIDE the retired block (former lines 21-75), all 67,
# so the retirement cannot take a non-read-only entry with it. Heredoc: entries carry quotes.
RA_KEPT="$(cat <<'KEPT'
["Read(**/.env.example)","Read(**/.env.sample)","Read(**/.env.template)","Read(**/.env.dist)",
 "Grep(**/.env.example)","Grep(**/.env.sample)","Grep(**/.env.template)","Grep(**/.env.dist)",
 "Bash(git add .)","Bash(git add -A)","Bash(git add *)","Bash(git -C * add *)",
 "Bash(git push)","Bash(git push origin *)","Bash(git -C * push)","Bash(git -C * push origin *)",
 "Bash(git -C * push -u origin *)","Bash(git push -u origin *)",
 "Bash(git push *--force-with-lease*)","Bash(git -C * push *--force-with-lease*)",
 "Bash(git fetch origin *)","Bash(git -C * fetch origin *)",
 "Bash(git fetch --prune origin)","Bash(git -C * fetch --prune origin)",
 "Bash(git pull --rebase --autostash origin *)","Bash(git -C * pull --rebase --autostash origin *)",
 "Write(**/.git/info/pending-branch-delete)",
 "Bash(Remove-Item -LiteralPath \"**\\.git\\info\\pending-branch-delete\")",
 "Bash(rm \"**/.git/info/pending-branch-delete\")",
 "Bash(git commit *)","Bash(git -C * commit *)","Bash(cd * && git commit *)",
 "Bash(chmod +x *.sh)","Bash(chmod +x */hooks/*)",
 "Bash(echo \"<<WORKFLOW_MARK_STEP_*>>\")","Bash(echo '<<WORKFLOW_MARK_STEP_*>>')",
 "Bash(echo \"<<WORKFLOW_RESEARCH_NOT_NEEDED: *>>\")","Bash(echo \"<<WORKFLOW_OUTLINE_NOT_NEEDED: *>>\")",
 "Bash(echo \"<<WORKFLOW_DETAIL_NOT_NEEDED: *>>\")","Bash(echo \"<<WORKFLOW_RUN_TESTS_NOT_NEEDED: *>>\")",
 "Bash(echo \"<<WORKFLOW_ENFORCE_WORKTREE_ON: *>>\")","Bash(echo \"<<WORKFLOW_ENFORCE_WORKFLOW_ON: *>>\")",
 "Bash(echo \"<<WORKFLOW_NEXT_STEP_PAUSE: *>>\")","Bash(echo \"<<WORKFLOW_NEXT_STEP_RESUME: *>>\")",
 "Bash(echo \"<<WORKFLOW_ISSUE_CLOSE_VERIFIED_END: *>>\")","Bash(doc-append *)",
 "Write(**/tests/**)","Edit(**/tests/**)","WebSearch",
 "WebFetch(domain:developer.mozilla.org)","WebFetch(domain:docs.python.org)","WebFetch(domain:learn.microsoft.com)",
 "WebFetch(domain:man7.org)","WebFetch(domain:docs.anthropic.com)","WebFetch(domain:platform.openai.com)",
 "WebFetch(domain:ai.google.dev)","WebFetch(domain:docs.github.com)","WebFetch(domain:github.com)",
 "WebFetch(domain:code.claude.com)","WebFetch(domain:platform.claude.com)","WebFetch(domain:anthropic.com)",
 "WebFetch(domain:modelcontextprotocol.io)","WebFetch(domain:spec.modelcontextprotocol.io)",
 "WebFetch(domain:code.visualstudio.com)",
 "Bash(node * hooks/cleanup-orphan-dir.js *)","Bash(node *\\hooks\\cleanup-orphan-dir.js *)",
 "mcp__codegraph__codegraph_explore"]
KEPT
)"
export RA_KEPT
# One node emits all four modes as NUL-delimited records (retired, kept, kept-count, extra);
# a load error is emitted for every mode, exactly as each per-mode call used to print it.
RETIRED_ALLOW_JS='
const fs = require("fs");
const settingsPath = process.argv[process.argv.length - 1];
const MODES = ["retired", "kept", "kept-count", "extra"];
const emit = (vals) => process.stdout.write(vals.map((v) => String(v) + "\0").join(""));
let allow, KEPT;
try { allow = JSON.parse(fs.readFileSync(settingsPath, "utf8")).permissions.allow; }
catch (e) { emit(MODES.map(() => "ERROR:unreadable-settings")); process.exit(0); }
if (!Array.isArray(allow)) { emit(MODES.map(() => "ERROR:no-allow-array")); process.exit(0); }
try { KEPT = JSON.parse(process.env.RA_KEPT || ""); } catch (e) { emit(MODES.map(() => "ERROR:bad-RA_KEPT")); process.exit(0); }
const RETIRED = /^Bash\((cd \* && )?(git (-C \* )?(status|log|diff|show|branch|tag|remote|rev-parse|stash)|head|tail|less|wc|file|stat|ls|find|tree|du|df|grep|rg|ag|which|type|command|uname|pwd)\b/;
emit([
  allow.filter((e) => typeof e === "string" && RETIRED.test(e)).join(","),
  KEPT.filter((e) => !allow.includes(e)).join(","),
  KEPT.length,
  allow.filter((e) => !KEPT.includes(e)).length,
]);
'
t_retired_readonly_allow() {
    local ra=()
    dp_node_path "$SETTINGS"
    mapfile -d '' -t ra < <(node -e "$RETIRED_ALLOW_JS" "$DP_NODE_PATH")
    if (( ${#ra[@]} != 4 )); then
        echo "FAIL: harness -- retired-allow batch returned ${#ra[@]} records (want 4)"; exit 1
    fi
    ROWS=$((ROWS + 1))
    assert_eq "RA1: no read-only Bash allow spelling (git read / ls / grep / find ...) remains in permissions.allow" \
        "" "${ra[0]}"
    ROWS=$((ROWS + 1))
    assert_eq "RA2: every non-read-only allow entry (all 67 outside the retired block) is kept" \
        "" "${ra[1]}"
    ROWS=$((ROWS + 1))
    assert_eq "RA2b: the pinned kept list itself is complete (vacuity guard)" \
        "67" "${ra[2]}"
    ROWS=$((ROWS + 1))
    assert_eq "RA4: permissions.allow is exactly the kept set (nothing beyond the 67 remains)" \
        "0" "${ra[3]}"
    ROWS=$((ROWS + 1))
    if deny_list_has "$SETTINGS" "git push --force"; then pass "RA3: the force-push deny survives the allow retirement"
    else fail "RA3: the force-push deny survives the allow retirement" "Bash(git push --force) missing from permissions.deny"; fi
}
t_retired_readonly_allow

# EXECUTED-ROW BUDGET. Every table increments ROWS; a drifted delimiter or an early return
# in front of a loop would otherwise leave a file that counts only its failures reporting green.
# crosscheck 14 (one verdict row each; the allow-module agreement row retired with #2264) + robustness 13 (12 + E4b shape pin) + regression table 80 (61 prior +
# N6-N13 MUST-trigger narration rows + L6-L15 sanctioned-command counterweights + P37
# refspec compound tail) + launch-form completeness 48 (12 triggers x 4 launch forms -- round-4
# C8 added +refspec/positional-force/git-clean triggers, PEND under ANCHORED=0) +
# bug-reproduction-evidence 1 + row_is_well_formed selftest 4 + retired read-only allow 5 (#2403).
ROWS_EXPECTED=166
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
