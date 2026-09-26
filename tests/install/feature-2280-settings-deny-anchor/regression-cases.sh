# tests/install/feature-2280-settings-deny-anchor/regression-cases.sh
# Tests: settings.json, hooks/lib/settings-allow-match.js
# Tags: settings, permissions, deny, ssot, scope:issue-specific, pwsh-not-required, TL2
# Table-driven cases for #2280. Ids and command strings are copied verbatim from the
# detail plan's Step 6 tables so a reader can cross-reference the plan.
# Sourced by tests/install/feature-2280-settings-deny-anchor.sh, which owns PASS/FAIL/PEND/ROWS.
# Delimiter is `@@`, not the `|` of skills/_shared/test-design/parser-regex-tests.md:
# `IFS='|'` keeps field-edge whitespace, which would make C11's deliberately padded
# command invisible to a reader. Row shape is therefore checked per row instead.

CROSSCHECK_FIXTURE_SEQ=0

FIXTURE_WRITE_JS='
const fs = require("fs");
const [fixturePath, pattern] = process.argv.slice(-2);
const rule = "Bash(" + pattern + ")";
fs.writeFileSync(fixturePath, JSON.stringify({ permissions: { allow: [rule], deny: [rule] } }));
'

REAL_MODULE_JS='
const [modulePath, settingsPath, commandText] = process.argv.slice(-3);
const { isAllowRuleMatch } = require(modulePath);
console.log(isAllowRuleMatch(commandText, { settingsPath }) ? "MATCHED" : "NO-MATCH");
'

# ---------------------------------------------------------------------------
# Mirror fidelity. Each row runs the SAME pattern through this suite's matcher.sh
# (deny side) and through the real hooks/lib/settings-allow-match.js (allow side) over a
# private fixture, then asserts both the expected verdict AND that the two agree. If the
# mirror ever drifts from patternToRegExp, every downstream row below is worthless.
# Columns: id @@ deny pattern @@ command @@ expected verdict.
# ---------------------------------------------------------------------------
t_mirror_crosscheck() {
    local row id pattern cmd want fixture mine theirs rest
    while IFS= read -r row; do
        case "$row" in ''|'#'*) continue ;; esac
        if ! row_is_well_formed "$row" 4; then
            fail "T-shape: malformed mirror-crosscheck row" \
                "row=[$row] -- want 4 nonempty @@-delimited fields"
            continue
        fi
        id="${row%%@@*}"; rest="${row#*@@}"
        pattern="${rest%%@@*}"; rest="${rest#*@@}"
        cmd="$(printf '%b' "${rest%%@@*}")"; want="${rest##*@@}"
        CROSSCHECK_FIXTURE_SEQ=$((CROSSCHECK_FIXTURE_SEQ + 1))
        fixture="$TMPROOT/crosscheck-$CROSSCHECK_FIXTURE_SEQ.json"
        node -e "$FIXTURE_WRITE_JS" "$(matcher_node_path "$fixture")" "$pattern"
        deny_probe "$fixture" "$cmd"
        mine="$DENY_VERDICT"
        theirs="$(node -e "$REAL_MODULE_JS" "$(matcher_node_path "$ALLOW_MATCH_MODULE")" \
            "$(matcher_node_path "$fixture")" "$cmd" 2>&1)"
        ROWS=$((ROWS + 2))
        assert_eq "$id: mirror verdict for pattern [$pattern]" "$want" "$mine"
        assert_eq "$id: mirror agrees with hooks/lib/settings-allow-match.js" "$mine" "$theirs"
    done <<'TABLE'
C1-exact@@git push --force@@git push --force@@MATCHED
C2-front-anchor@@git push --force@@cd /x && git push --force@@NO-MATCH
C3-leading-star-is-substring@@*push --force@@echo push --force@@MATCHED
C4-word-boundary-guard@@git status*@@git statusfoo && ls@@NO-MATCH
C5-word-boundary-ok@@git status*@@git status --short@@MATCHED
C6-no-guard-after-dash@@head -*@@head -5 f@@MATCHED
C7-case-sensitive@@git push --force@@GIT PUSH --FORCE@@NO-MATCH
C8-metachar-escaped@@git tag v1+2@@git tag v1+2@@MATCHED
C9-metachar-not-regex@@git tag v1+2@@git tag v112@@NO-MATCH
C10-dotall@@git commit *@@git commit -m "a\nb"@@MATCHED
C11-input-trimmed@@git push --force@@  git push --force  @@MATCHED
C12-star-run-collapses@@git push **--force@@git push origin --force@@MATCHED
C13-value-wildcard@@git -C * push --force@@git -C /x push --force@@MATCHED
C14-greedy-absorbs-globals@@git -C * push --force@@git -C /x -c u=v --no-pager push --force@@MATCHED
TABLE
}

# ---------------------------------------------------------------------------
# Matcher robustness: error / edge / idempotency / injection. Every malformed-settings
# shape pins an explicit verdict; a shape that threw inside node would surface here as
# ERROR:node-failed, which is why each row names the verdict rather than "not empty".
# ---------------------------------------------------------------------------
t_matcher_robustness() {
    local fixture="$TMPROOT/robust.json" first second canary

    deny_probe "$TMPROOT/does-not-exist.json" "git push --force"
    ROWS=$((ROWS + 1))
    assert_eq "E1: unreadable settings yields an explicit error verdict, never a silent NO-MATCH" \
        "ERROR:unreadable-settings" "$DENY_VERDICT"

    # E1b: E1 covers a MISSING file; this covers a present-but-unparseable one. Both reach
    # the same catch, and pinning them separately keeps that equivalence visible.
    printf '%s' '{"permissions":{"deny":["Bash(git push --force)"' > "$fixture"
    deny_probe "$fixture" "git push --force"
    ROWS=$((ROWS + 1))
    assert_eq "E1b: malformed JSON yields the same explicit error verdict as a missing file" \
        "ERROR:unreadable-settings" "$DENY_VERDICT"

    printf '%s' '{"permissions":{"deny":[]}}' > "$fixture"
    deny_probe "$fixture" "git push --force"
    ROWS=$((ROWS + 1))
    assert_eq "E2: an empty deny array matches nothing" "NO-MATCH" "$DENY_VERDICT"

    printf '%s' '{"permissions":{"deny":["Read(//x)","Bash(git status)",42]}}' > "$fixture"
    deny_probe "$fixture" "git push --force"
    ROWS=$((ROWS + 1))
    assert_eq "E3a: non-Bash and non-string deny entries are ignored, not crashed on" \
        "NO-MATCH" "$DENY_VERDICT"

    # E3b: same probe text as the pattern body, but wrapped in a non-Bash tool call —
    # only correct here if BASH_RULE_RE's `^Bash\(...\)$` gate actually runs; dropping
    # that gate would let the bare pattern body match and flip this to MATCHED.
    printf '%s' '{"permissions":{"deny":["Read(git push --force)"]}}' > "$fixture"
    deny_probe "$fixture" "git push --force"
    ROWS=$((ROWS + 1))
    assert_eq "E3b: a non-Bash-shaped entry whose body equals the probe text is still ignored" \
        "NO-MATCH" "$DENY_VERDICT"

    deny_probe "$SETTINGS" "git push --force"; first="$DENY_VERDICT"
    deny_probe "$SETTINGS" "git push --force"; second="$DENY_VERDICT"
    ROWS=$((ROWS + 1))
    assert_eq "E4: probing the same command twice is idempotent" "$first" "$second"

    # E4b: E4 alone would spuriously pass a `deny_probe` that always returns "" (both calls
    # equal, still worthless). Pin that the shared value is an actual verdict shape.
    local e4_shape=no
    case "$first" in MATCHED|NO-MATCH|ERROR:*) e4_shape=yes ;; esac
    ROWS=$((ROWS + 1))
    assert_eq "E4b: the idempotent value is a real verdict (MATCHED/NO-MATCH/ERROR:*), not empty" \
        "yes" "$e4_shape"

    printf '%s' '{"env":{}}' > "$fixture"
    deny_probe "$fixture" "git push --force"
    ROWS=$((ROWS + 1))
    assert_eq "E5: settings with no permissions key at all degrades to no rules" \
        "NO-MATCH" "$DENY_VERDICT"

    # E6/E7: a non-array `deny`. Without the Array.isArray guard the string form would
    # iterate CHARACTERS and the object form would throw TypeError -- the mirror follows
    # readAllowPatterns() and degrades both to "no rules" instead.
    printf '%s' '{"permissions":{"deny":"Bash(git push --force)"}}' > "$fixture"
    deny_probe "$fixture" "git push --force"
    ROWS=$((ROWS + 1))
    assert_eq "E6: a string-valued permissions.deny degrades to no rules, never char iteration" \
        "NO-MATCH" "$DENY_VERDICT"

    printf '%s' '{"permissions":{"deny":{"0":"Bash(git push --force)"}}}' > "$fixture"
    deny_probe "$fixture" "git push --force"
    ROWS=$((ROWS + 1))
    assert_eq "E7: an object-valued permissions.deny degrades to no rules, never a throw" \
        "NO-MATCH" "$DENY_VERDICT"

    deny_probe "$SETTINGS" ""
    ROWS=$((ROWS + 1))
    assert_eq "E8: an empty command string yields an explicit verdict against the real rules" \
        "NO-MATCH" "$DENY_VERDICT"

    canary="$TMPROOT/injected-canary"
    deny_probe "$SETTINGS" 'git push --force `touch '"$canary"'` $(touch '"$canary"')'
    ROWS=$((ROWS + 2))
    assert_eq "S1: a command carrying shell metacharacters still yields a verdict" \
        "yes" "$([ -n "$DENY_VERDICT" ] && echo yes || echo no)"
    assert_eq "S2: the matcher never executes the command text it is handed" \
        "absent" "$([ -e "$canary" ] && echo present || echo absent)"
}

# ---------------------------------------------------------------------------
# The #2280 regression table. Columns: id @@ command @@ target deny pattern @@ verdict
# @@ depends-on-anchoring(yes/no). The target pattern is asserted only once deployed in
# settings.json, so a row can name its post-fix target without fabricating a match;
# `any` opts a row out of that assertion. depends-on-anchoring "yes" rows PEND under
# ANCHORED=0 on a mismatch; "no" rows FAIL immediately -- see check_deny_row.
# ---------------------------------------------------------------------------
t_deny_regression_table() {
    local row id cmd pat want depends rest
    while IFS= read -r row; do
        case "$row" in ''|'#'*) continue ;; esac
        if ! row_is_well_formed "$row" 5; then
            fail "T-shape: malformed deny-regression row" \
                "row=[$row] -- want 5 nonempty @@-delimited fields"
            continue
        fi
        id="${row%%@@*}"; rest="${row#*@@}"
        cmd="${rest%%@@*}"; rest="${rest#*@@}"
        pat="${rest%%@@*}"; rest="${rest#*@@}"
        want="${rest%%@@*}"; depends="${rest##*@@}"
        check_deny_row "$id" "$cmd" "$pat" "$want" "$depends"
    done <<'TABLE'
# Negative: the #2280 incident class -- free text that must stop false-positive matching.
# N3: reserved/unused in the source plan table.
N1-sentinel@@echo "<<WORKFLOW_ENFORCE_WORKTREE_OFF_EMERGENCY: previous git push --force attempt failed, escalating>>"@@any@@NO-MATCH@@yes
N2-handoff@@node bin/workflow/handoff-append --summary "handoff before git commit --amend cleanup"@@any@@NO-MATCH@@yes
N4-grep@@grep -rn "push --force" src/@@any@@NO-MATCH@@yes
# N5 pins the `*push *+*` member of the same class: `+` is a refspec force marker, so the
# rule's two wildcards straddle any prose that merely quotes a `push origin +main`.
N5-sentinel-plus-refspec@@echo "<<WORKFLOW_ENFORCE_WORKTREE_OFF_EMERGENCY: an earlier git push origin +main was rejected, escalating>>"@@any@@NO-MATCH@@yes

# N6-N13 extend the same free-text/narration coverage to the other MUST-trigger classes
# (reset --hard, --no-verify, clean -f -d bundled, worktree remove --force, push
# --mirror/--delete/-f, colon-refspec delete) so a silent revert of any one of them is
# caught the same way N1/N2/N5 catch push --force/commit --amend.
N6-reset-hard@@echo "<<WORKFLOW_ENFORCE_WORKTREE_OFF_EMERGENCY: previous git reset --hard attempt failed, escalating>>"@@any@@NO-MATCH@@yes
N7-no-verify@@node bin/workflow/handoff-append --summary "handoff before git commit --no-verify cleanup"@@any@@NO-MATCH@@yes
N8-clean-fd@@grep -rn "git clean -f -d" src/@@any@@NO-MATCH@@yes
N9-worktree-remove@@echo "<<WORKFLOW_ENFORCE_WORKTREE_OFF_EMERGENCY: git worktree remove --force ../wt attempt failed, escalating>>"@@any@@NO-MATCH@@yes
N10-mirror@@node bin/workflow/handoff-append --summary "handoff before git push --mirror cleanup"@@any@@NO-MATCH@@yes
N11-delete@@grep -rn "git push --delete origin feature" src/@@any@@NO-MATCH@@yes
N12-colon-delete@@echo "<<WORKFLOW_ENFORCE_WORKTREE_OFF_EMERGENCY: git push origin :feature-branch attempt failed, escalating>>"@@any@@NO-MATCH@@yes
N13-push-f@@node bin/workflow/handoff-append --summary "handoff before git push -f cleanup"@@any@@NO-MATCH@@yes

# Legitimate, non-destructive git usage: NO-MATCH is the contract. These are the
# counterweight to the P-series -- an overbroad rule (say `Bash(git push *)`) keeps every
# MATCHED row green while quietly denying ordinary work, and only these catch it.
L1-plain-push@@git push@@any@@NO-MATCH@@no
L2-plain-commit@@git commit -m "docs: add regression rows"@@any@@NO-MATCH@@no
L3-reset-soft@@git reset --soft HEAD~1@@any@@NO-MATCH@@no
L4-clean-dry-run@@git clean -n@@any@@NO-MATCH@@no
L5-worktree-remove-no-force@@git worktree remove ../wt@@any@@NO-MATCH@@no

# L6-L8: git push --force-with-lease is explicitly SANCTIONED (settings.json
# permissions.allow, and rules/git.md recommends it over --force) -- an overbroad
# anchored deny rule must never catch it, in any launch form.
L6-force-with-lease@@git push --force-with-lease@@any@@NO-MATCH@@no
L7-force-with-lease-remote@@git push --force-with-lease origin feature@@any@@NO-MATCH@@no
L8-force-with-lease-C@@git -C /x push --force-with-lease@@any@@NO-MATCH@@no

# L9-L11: ordinary/legitimate `cd * && git commit *` compound usage -- must stay NO-MATCH
# because it is harmless. P13-P37 below are also NO-MATCH at the settings.json level, but
# for the opposite reason: no anchored rule spans the `cd &&` prefix at all.
L9-compound-plain-commit@@cd /tmp/x && git commit -m "docs: update"@@any@@NO-MATCH@@no
L10-compound-commit-push@@cd /tmp/x && git commit -m "x" && git push origin main@@any@@NO-MATCH@@no
L11-compound-allow-empty@@cd /tmp/x && git commit --allow-empty -m "x"@@any@@NO-MATCH@@no

# L12-L15: the `-C`/`-c`/`--no-pager` launch forms on ordinary sanctioned git commands
# (status/commit/log/push origin) -- must stay NO-MATCH in every form.
L12-launch-C-status@@git -C /repo status@@any@@NO-MATCH@@no
L13-launch-c-commit@@git -c user.name=x commit -m "x"@@any@@NO-MATCH@@no
L14-launch-nopager-log@@git --no-pager log --oneline -5@@any@@NO-MATCH@@no
L15-launch-C-push@@git -C /x push origin main@@any@@NO-MATCH@@no

# Residual, ACCEPTED: intent.md/outline.md Accepted Tradeoff
# "same-git-invocation free-text crossing (structural limit of glob matching)".
# These MATCH by design -- glob syntax has no quote or word boundary, so a trigger
# string inside a commit message is indistinguishable from the real flag. Not a bug;
# the permanent fix is the argv-walking hook design tracked as #2266. Stable regardless
# of anchoring -- anchoring only fixes the launch-form prefix, not word/quote crossing.
R1-no-verify-residual@@git commit -m "docs: explain --no-verify usage"@@git *--no-verify*@@MATCHED@@no
R2-push-force-residual@@git commit -m "docs: mention git push --force and git commit --amend usage patterns"@@git commit *--amend*@@MATCHED@@no

# Positive: true positives that anchoring must preserve, across the four launch forms.
P1@@git push --force@@git push --force@@MATCHED@@yes
P2@@git push origin +main@@git push *+*@@MATCHED@@yes
P3@@git -C /x push -f@@git -C * push -f*@@MATCHED@@yes
P4@@git commit --amend@@git commit --amend*@@MATCHED@@yes
P5@@git -C /repo push --force@@git -C * push --force@@MATCHED@@yes
P6@@git reset --hard@@git reset --hard*@@MATCHED@@yes
# P7/P19 DEVIATE FROM detail.md, which predicted MATCHED. Derived fact: the `*`
# after `-f` is preceded by a WORD char, so patternToRegExp emits the
# `(?![A-Za-z0-9_])` guard -- `git clean *-f*d*` cannot match the BUNDLED `-fd`
# form at all. Pre-existing (the current rule body is unchanged by #2280), so it is
# pinned as a gap, not a regression. P7b/P19b pin the separated form that does match.
P7@@git clean -fd@@any@@NO-MATCH@@yes
P7b-clean-separated@@git clean -f -d@@git clean *-f*d*@@MATCHED@@yes
P8@@git worktree remove --force ../wt@@git worktree remove*--force*@@MATCHED@@yes
P9@@git push origin :feature-branch@@git push origin :*@@MATCHED@@yes
P10@@git commit --no-verify -m "skip hooks"@@git *--no-verify*@@MATCHED@@yes
P11-global-c@@git -c user.name=x push --force@@git -c * push --force@@MATCHED@@yes
P12-global-nopager@@git --no-pager commit --amend@@git --no-pager commit --amend*@@MATCHED@@yes

# Negative (settings.json alone): a `cd * && git commit ...` compound bypass is NOT
# matched by any single deny rule here -- anchored rules require the string to START with
# a git-launch-form prefix. The removed `cd * && git commit *...` closer sub-family once
# re-caught this shape, but reintroduced #2280's own narration-false-positive bug and was
# redundant with the general fix: hooks/bash-guard/exemptions.js's anySegmentDenyMatched()
# (via isDenyRuleMatch) withholds the allow-rule-match exemption when any segment matches
# an anchored deny rule. Behavioral tests for anySegmentDenyMatched belong in the
# feature-2134-bash-guard suite (tracked as follow-up, not yet landed).
P13-compound-bypass@@cd /tmp/x && git commit --amend -m "test"@@any@@NO-MATCH@@yes
P14-compound-bypass-push@@cd /tmp/x && git commit -m "x" && git push --force@@any@@NO-MATCH@@yes
P15-compound-bypass-resethard@@cd /tmp/x && git commit -m "x" && git reset --hard@@any@@NO-MATCH@@yes

P16-mirror@@git push --mirror@@git push --mirror*@@MATCHED@@yes
P17-delete@@git push --delete origin feature-branch@@git push --delete*@@MATCHED@@yes
P18-force-after-remote@@git push origin feature-branch --force@@git push *--force@@MATCHED@@yes
P19-clean-df@@git clean -df@@any@@NO-MATCH@@yes
P19b-clean-df-separated@@git clean -d -f@@git clean *-d*f*@@MATCHED@@yes
P20-worktree-remove-f@@git worktree remove -f ../wt@@git worktree remove*-f*@@MATCHED@@yes
P21-compound-bypass-push-remote@@cd /tmp/x && git commit -m "x" && git push origin main --force@@any@@NO-MATCH@@yes
P22-compound-bypass-push-origin-colon@@cd /tmp/x && git commit -m "x" && git push -v origin :feature-branch@@any@@NO-MATCH@@yes

# P23-P28 finish the same NO-MATCH sweep across the remaining MUST-trigger tails P13-P15 /
# P21-P22 left uncovered. The clean row uses the SEPARATED `-f -d` form, keeping this
# sweep orthogonal to the P7/P19 word-boundary gap. P37 (after P36 below) closes the
# remaining `+refspec` tail, parallel to P2's bare form.
P23-compound-bypass-push-f@@cd /tmp/x && git commit -m "x" && git push -f@@any@@NO-MATCH@@yes
P24-compound-bypass-mirror@@cd /tmp/x && git commit -m "x" && git push --mirror@@any@@NO-MATCH@@yes
P25-compound-bypass-delete@@cd /tmp/x && git commit -m "x" && git push --delete origin feature-branch@@any@@NO-MATCH@@yes
P26-compound-bypass-no-verify@@cd /tmp/x && git commit --no-verify -m "x"@@any@@NO-MATCH@@yes
P27-compound-bypass-clean-separated@@cd /tmp/x && git commit -m "x" && git clean -f -d@@any@@NO-MATCH@@yes
P28-compound-bypass-worktree-remove-f@@cd /tmp/x && git commit -m "x" && git worktree remove -f ../wt@@any@@NO-MATCH@@yes

# P29-P31 spot-check launch form x trigger pairings the P1-P22 grid leaves implicit:
# each pairs an already-covered global-option form with a trigger it never met.
P29-global-c-resethard@@git -c user.name=x reset --hard@@git -c * reset --hard*@@MATCHED@@yes
P30-global-C-clean@@git -C /repo clean -f -d@@git -C * clean *-f*d*@@MATCHED@@yes
P31-global-nopager-mirror@@git --no-pager push --mirror@@git --no-pager push --mirror*@@MATCHED@@yes

# P32-P36: bare-launch-form MUST-trigger rows the P1-P31 grid left implicit -- the plain
# `-f` short flag and the remote-qualified mirror/delete/refspec-delete spellings, each
# with no `-C`/`-c`/`--no-pager` prefix at all (the simplest, most common invocation shape).
P32-bare-push-f@@git push -f@@git push -f*@@MATCHED@@yes
P33-bare-push-remote-f@@git push origin main -f@@git push *-f*@@MATCHED@@yes
P34-bare-push-mirror@@git push origin --mirror@@git push *--mirror*@@MATCHED@@yes
P35-bare-push-delete@@git push origin --delete branch@@git push *--delete*@@MATCHED@@yes
P36-bare-push-refspec-delete@@git push -v origin :branch@@git push *origin :*@@MATCHED@@yes

# P37 closes the `+refspec` tail P23-P28 deferred (parallel to P2), same NO-MATCH sweep.
P37-compound-bypass-refspec@@cd /tmp/x && git commit -m "x" && git push origin +main@@any@@NO-MATCH@@yes

# OPTIONAL category: unchanged on purpose (leading `*` kept). These pin the zero-diff.
O1@@sudo rm -rf /tmp/x@@*sudo *@@MATCHED@@no
O2@@find / -exec rm -rf {} \;@@*find *-exec *@@MATCHED@@no
O3-docker-unchanged@@docker volume rm myvol@@*docker volume rm*@@MATCHED@@no
O4-aws-unchanged@@aws s3 rm s3://bucket/key@@*aws s3 rm*@@MATCHED@@no
O5-docker-env-wrapper@@env FOO=1 docker volume rm myvol@@*docker volume rm*@@MATCHED@@no

# O6: zero-diff pin for an unrelated workflow-integrity guard rule that lives in the same
# permissions.deny array this fix touches. Nothing in #2280's scope should ever narrow or
# remove it -- if it did, an agent could self-emit the user-verification sentinel unchecked.
O6-user-verification-sentinel-guard@@echo "<<WORKFLOW_MARK_STEP_user_verification: done>>"@@echo "<<WORKFLOW_MARK_STEP_user_verification*>>"@@MATCHED@@no

# Known residual gaps, OUT OF SCOPE for #2280 -- pinned so they stay visible.
# G2: reserved/unused in the source plan table.
G1-aws-profile-gap@@aws --profile prod s3 rm s3://bucket/key@@any@@NO-MATCH@@no
# G3 is anchoring-dependent (unlike G1): TODAY the still-deployed old broad rule
# (`*push --force`) already matches this despite the `--git-dir=` prefix, so it only
# becomes a residual NO-MATCH gap once the anchored, first-token-anchored rule lands.
G3-global-gitdir@@git --git-dir=/tmp/x.git push --force@@any@@NO-MATCH@@yes
# G4 DEVIATES FROM detail.md, which predicted NO-MATCH. Derived fact: the `-C` launch
# form's value wildcard is a greedy `.*`, so `git -C * push --force` absorbs the extra
# global options and DOES match (C14 above pins the mechanism). The gap is narrower
# than the plan assumed; MATCHED holds both before (old rule) and after (anchored rule).
G4-global-combo@@git -C /x -c user.name=y --no-pager push --force@@git -C * push --force@@MATCHED@@no

# G5-G8: wrapper-prefix asymmetry. G5 is NOT a residual gap -- `sudo` prefixes are
# caught by the independent, unanchored OPTIONAL rule `*sudo *` (O1 same rule), so G5
# is MATCHED before AND after anchoring; it never depends on ANCHORED. G6-G8 (env /
# absolute-path / `-P` alias) genuinely fall outside Approach A's four enumerated launch
# forms once anchoring replaces the old broad rule -- but TODAY the old `*push --force`-
# style rule still matches them too, so they only become residual gaps (STANDALONE
# command only) once ANCHORED=1. The chained-after-allowed-prefix form of this same gap
# is independently closed one layer up by hooks/bash-guard/git-canonical.js, pinned in
# tests/feature-2134-bash-guard/cases-allow-rule.sh's chained-deny-bypass-* rows.
G5-sudo-wrapper@@sudo git push --force@@*sudo *@@MATCHED@@no
G6-env-wrapper@@env FOO=1 git push --force@@any@@NO-MATCH@@yes
G7-absolute-path@@/usr/bin/git push --force@@any@@NO-MATCH@@yes
# `-P` is docs-equivalent to `--no-pager` but is a DIFFERENT flag spelling than the four
# forms Approach A enumerates literally, so it is not covered either -- same gap class.
G8-dash-P-alias@@git -P push --force@@any@@NO-MATCH@@yes
TABLE
}

# ---------------------------------------------------------------------------
# Launch-form x MUST-trigger completeness. The contract at the top of the runner script
# is that every MUST-trigger rule is anchored across FOUR launch forms; rather than 30+
# more MATCHED probe rows, this existence-checks that the anchored literal is actually
# deployed for each (trigger x form) pair once write-code lands. Plain nested arrays
# (not an @@ table): a pure `deny_list_has` existence check has no command/verdict pair
# to tabulate. Skipped (PEND) entirely under ANCHORED=0 -- these literals are exactly
# what write-code has not deployed yet.
# ---------------------------------------------------------------------------
t_launch_form_completeness() {
    local triggers=(
        "push --force" "push -f*" "push --mirror*" "push --delete*"
        "push origin :*" "commit --amend*" "reset --hard*"
        "worktree remove*--force*" "*--no-verify*"
        "push *+*" "push *-f*" "clean *-f*d*"
    )
    local form_labels=(bare dashC dashc nopager)
    local form_prefixes=("git " "git -C * " "git -c * " "git --no-pager ")
    local ti fi trig prefix label literal
    for ti in "${!triggers[@]}"; do
        trig="${triggers[$ti]}"
        for fi in "${!form_prefixes[@]}"; do
            label="${form_labels[$fi]}"
            prefix="${form_prefixes[$fi]}"
            literal="${prefix}${trig}"
            ROWS=$((ROWS + 1))
            if [ "$ANCHORED" = "0" ]; then
                pend "LF-$label-[$trig]" "needs anchored rule Bash($literal); write-code pending"
                continue
            fi
            if deny_list_has "$SETTINGS" "$literal"; then
                pass "LF-$label-[$trig] (Bash($literal) deployed)"
            else
                fail "LF-$label-[$trig] -- Bash($literal) absent from permissions.deny" \
                    "expected anchored literal missing"
            fi
        done
    done
}

# ---------------------------------------------------------------------------
# #2280 bug-reproduction evidence at the settings.json level (not just the mechanism
# level C3 already covers): while ANCHORED=0, the CURRENT broad rule must actually
# reproduce the incident against the real deployed file, not merely in a synthetic
# fixture. Once ANCHORED=1 the same probe is expected to have stopped reproducing it.
# ---------------------------------------------------------------------------
t_bug_reproduction_evidence() {
    local cmd got
    cmd='echo "<<WORKFLOW_ENFORCE_WORKTREE_OFF_EMERGENCY: previous git push --force attempt failed, escalating>>"'
    deny_probe "$SETTINGS" "$cmd"
    got="$DENY_VERDICT"
    ROWS=$((ROWS + 1))
    if [ "$ANCHORED" = "0" ]; then
        assert_eq "N1-evidence: the pre-fix broad rule currently reproduces #2280 in settings.json" \
            "MATCHED" "$got"
    else
        assert_eq "N1-evidence: anchoring lands and actually suppresses the #2280 reproduction" \
            "NO-MATCH" "$got"
    fi
}

# ---------------------------------------------------------------------------
# row_is_well_formed selftest: the function is only ever called from inside the table
# loops above, so a broken field-count check would never surface on its own. Exercise it
# directly against one well-formed row and three malformed shapes (short, doubled
# delimiter, trailing empty field) so its true/false contract is pinned independently.
# ---------------------------------------------------------------------------
t_row_well_formed_selftest() {
    local ok
    ROWS=$((ROWS + 1))
    if row_is_well_formed "a@@b@@c@@d" 4; then ok=yes; else ok=no; fi
    assert_eq "row_is_well_formed: a well-formed 4-field row is accepted" "yes" "$ok"

    ROWS=$((ROWS + 1))
    if row_is_well_formed "a@@b@@c" 4; then ok=yes; else ok=no; fi
    assert_eq "row_is_well_formed: a row missing a field (too few @@) is rejected" "no" "$ok"

    ROWS=$((ROWS + 1))
    if row_is_well_formed "a@@@@c@@d" 4; then ok=yes; else ok=no; fi
    assert_eq "row_is_well_formed: a doubled @@ (empty field) is rejected" "no" "$ok"

    ROWS=$((ROWS + 1))
    if row_is_well_formed "a@@b@@c@@" 4; then ok=yes; else ok=no; fi
    assert_eq "row_is_well_formed: a trailing empty field is rejected" "no" "$ok"
}
