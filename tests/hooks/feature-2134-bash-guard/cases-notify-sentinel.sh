# tests/feature-2134-bash-guard/cases-notify-sentinel.sh
# Tests: hooks/bash-guard/detect.js, hooks/bash-guard/judge.js, hooks/bash-guard/message.js, hooks/lib/sentinel-patterns.js, hooks/lib/command-ir.js
# Tags: hook, bash-guard, notify, sentinel, workflow-mark, scope:issue-specific, pwsh-not-required, TL2
# S1-S3: the sentinel half of detectIneffective() (L1 no-echo, L2 unrecognized). Sourced by the dispatcher.

# WHY NOTIFY AND NOT DENY (#2264). A sentinel issued bare, or in a shape the strict regexes
# reject, runs "successfully" and marks nothing -- ineffective, not forbidden, so the guard
# tells the model and lets it run. Strict and LOOKSLIKE-only forms stay silent (workflow-mark
# owns the latter); prose that merely MENTIONS a sentinel must never notify.

s1_sentinel_rows() {
    local name cmd want want_ids got
    while IFS='~' read -r name cmd want want_ids; do
        [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
        name="${name//[[:space:]]/}"
        want="${want//[[:space:]]/}"
        want_ids="${want_ids//[[:space:]]/}"
        cmd="$(mkcmd "$cmd")"
        ROWS=$((ROWS + 1))

        got="$(verdict_code_of "$cmd")"
        assert_eq "S1/$name: verdict|code" "$want" "$got"

        got="$(probe notify-hits "$cmd")"
        assert_eq "S1/$name: detectIneffective notify-id set" "$want_ids" "$got"
    done <<'TABLE'
# --- L1: the sentinel issued as the command itself (echo forgotten) ---
l1-dq           ~ "<<WORKFLOW_MARK_STEP_foo_complete>>"                  ~ notify|BG-NOTIFY-SENTINEL-NO-ECHO      ~ BG-NOTIFY-SENTINEL-NO-ECHO
l1-sq           ~ '<<WORKFLOW_MARK_STEP_foo_complete>>'                  ~ notify|BG-NOTIFY-SENTINEL-NO-ECHO      ~ BG-NOTIFY-SENTINEL-NO-ECHO
l1-dq-reason    ~ "<<WORKFLOW_USER_VERIFIED: looks good>>"               ~ notify|BG-NOTIFY-SENTINEL-NO-ECHO      ~ BG-NOTIFY-SENTINEL-NO-ECHO
l1-bare         ~ <<WORKFLOW_MARK_STEP_foo_complete>>                    ~ deny|BG-HEREDOC                        ~ BG-NOTIFY-SENTINEL-NO-ECHO
# --- L2: echo of a sentinel-shaped token the strict regexes reject ---
l2-bad-status   ~ echo "<<WORKFLOW_MARK_STEP_foo_done>>"                 ~ notify|BG-NOTIFY-SENTINEL-UNRECOGNIZED ~ BG-NOTIFY-SENTINEL-UNRECOGNIZED
l2-sq-non-mark  ~ echo '<<WORKFLOW_USER_VERIFIED: x>>'                   ~ notify|BG-NOTIFY-SENTINEL-UNRECOGNIZED ~ BG-NOTIFY-SENTINEL-UNRECOGNIZED
l2-echo-e       ~ echo -e "<<WORKFLOW_MARK_STEP_foo_complete>>"          ~ notify|BG-NOTIFY-SENTINEL-UNRECOGNIZED ~ BG-NOTIFY-SENTINEL-UNRECOGNIZED
l2-extra-arg    ~ echo "<<WORKFLOW_MARK_STEP_foo_complete>>" now         ~ notify|BG-NOTIFY-SENTINEL-UNRECOGNIZED ~ BG-NOTIFY-SENTINEL-UNRECOGNIZED
l2-after-or     ~ true || echo "<<WORKFLOW_MARK_STEP_foo_done>>"         ~ notify|BG-NOTIFY-SENTINEL-UNRECOGNIZED ~ BG-NOTIFY-SENTINEL-UNRECOGNIZED
# --- L2 negatives: strict per SEGMENT, or LOOKSLIKE-only (workflow-mark owns those) ---
strict-dq       ~ echo "<<WORKFLOW_MARK_STEP_foo_complete>>"             ~ passThrough|BG-NO-HIT                  ~
strict-sq       ~ echo '<<WORKFLOW_MARK_STEP_foo_pending>>'              ~ passThrough|BG-NO-HIT                  ~
strict-reason   ~ echo "<<WORKFLOW_RESET_FROM_detail: reason>>"          ~ passThrough|BG-NO-HIT                  ~
strict-or-true  ~ echo "<<WORKFLOW_MARK_STEP_foo_complete>>" || true     ~ passThrough|BG-NO-HIT                  ~
strict-bg       ~ echo "<<WORKFLOW_MARK_STEP_foo_complete>>" & ls        ~ passThrough|BG-NO-HIT                  ~
lookslike-only  ~ echo "<<WORKFLOW_USER_VERIFIED>>"                      ~ passThrough|BG-NO-HIT                  ~
# --- prose that mentions a sentinel: cmd0 is neither echo nor the token itself ---
commit-msg      ~ git commit -m "mention <<WORKFLOW_USER_VERIFIED: y>> here" ~ passThrough|BG-NO-HIT              ~
grep-pattern    ~ grep "<<WORKFLOW_MARK_STEP" f                          ~ passThrough|BG-NO-HIT                  ~
echo-embedded   ~ echo "run <<WORKFLOW_USER_VERIFIED: y>> later"         ~ passThrough|BG-NO-HIT                  ~
node-summary    ~ node bin/workflow/handoff-append --summary "<<WORKFLOW_USER_VERIFIED: y>>" ~ passThrough|BG-NO-HIT ~
TABLE
}

case_begin "notify-sentinel-classes" "hooks/bash-guard/detect.js"
s1_sentinel_rows
case_end

# IR QUIRK behind these rows: command-ir reads a quoted `"<<WORKFLOW_X>>"` as a `<` redirect
# with target `<WORKFLOW_X>>`, so the token is absent from cooked argv and cmd0 is "". The rows
# pin judge-level behaviour whatever recovery the implementation uses. l1-bare is a real heredoc
# operator, so deny wins by precedence while detectIneffective() still classifies it.
# strict-or-true / strict-bg: `||` and `&` are outside the deny set and effectiveness is judged
# per segment -- a whole-line anchored match would wrongly notify them.

# S2: the notify verdict carries no sample -- the command text never rides along.
case_begin "notify-sentinel-verdict" "hooks/bash-guard/judge.js"
assert_eq "S2: a notify verdict's sample is empty" "" \
    "$(probe judge-sample '"<<WORKFLOW_MARK_STEP_s2canary_complete>>"')"

# S3: when a malformed sentinel is chained with &&, deny wins over notify.
assert_eq "S3: a malformed sentinel chained with && is still a deny (deny > notify)" \
    "deny|BG-CHAIN-AND" "$(verdict_code_of 'echo "<<WORKFLOW_MARK_STEP_x>>" && ls')"
case_end
