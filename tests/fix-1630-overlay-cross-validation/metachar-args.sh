# tests/fix-1630-overlay-cross-validation/metachar-args.sh
# Tests: hooks/enforce-worktree/main-worktree-allows/finalize-worker-overlay.js
# Tags: worktree, enforce, hook, overlay, security, injection, scope:issue-specific
#
# STATUS: RED. Sourced by tests/fix-1630-overlay-cross-validation.sh, after
# run_xv_family_cases (the XV_* fixture globals are set there).
#
# Two defects, one theme: what the overlay accepts INSIDE an argument.
#
# The overlay is a HARD gate. Whatever it matches is handed back to bash as an
# `eval` string, so every byte of every argument is re-parsed by the shell. The
# gate's only protection against that is a per-argument token check — and the
# token check has two holes:
#
#   C. `isUnderPlansDir` rejects only `$`, backtick and `~`. A plans-dir
#      argument may therefore still carry `; & | < > ( ) ' "` or whitespace,
#      each of which is a shell control character in the eval that follows. A
#      state-file argument of the form
#          <plans>/a';gh issue close 999;'b
#      is a path under the plans dir by every check the gate makes, and a
#      command separator by the time bash sees it. Same for the run-initial.sh
#      `id` arguments, whose first token is interpolated the same way.
#
#   D. The argument loop reads `const spec = argSpec[i]` and does
#      `if (spec === undefined) continue;` BEFORE `rejectsUnsafeToken(tok)`.
#      Any position past the end of argSpec is therefore accepted UNVALIDATED.
#      Today no registry entry has argCountMax > argSpec.length, so the branch
#      is unreachable through the shipped registry — which is precisely why it
#      is dangerous: it is a silent trapdoor that opens the first time someone
#      widens a count bound, with no test to notice. It is pinned here twice:
#      structurally (the registry invariant) and dynamically (the branch).
#
# Pairing: every BLOCK/reject row below sits next to the byte-identical clean
# row that must stay ALLOW/accept, so neither "reject everything" nor "accept
# everything" can satisfy this section.
#
# TL3 gap (what this TL2 test does NOT catch): a real /issue-close-finalize run
# whose state-file path genuinely contains one of these characters, and the
# behaviour of the actual bash that evaluates the returned string. Both are
# reasoned about from the payload shape here, never executed.

# Token table: `%` separator (the tokens themselves carry `|`).
run_plansdir_table() {
    local name token want
    while IFS='%' read -r name token want; do
        name="$(_trim "$name")"
        [ -z "$name" ] && continue
        case "$name" in \#*) continue ;; esac
        assert_eq "$name" \
            "$(AGENTS_CONFIG_DIR="$XV_ACD" WORKFLOW_PLANS_DIR="$XV_PLANS" \
                overlay_probe plansdir "${XV_PLANS}/$(_trim "$token")" "$XV_REPO")" \
            "$(_trim "$want")"
    done
}

# run-initial.sh with an attacker-chosen FIRST argument. Same shape as the
# suite's build_initial, which hardcodes the clean "1234".
build_initial_arg1() {
    local acd_val="$1" scripts="$2" mwt_val="$3" arg1="$4"
    printf 'eval "$(AGENTS_CONFIG_DIR="%s" FINALIZE_SCRIPTS_DIR="%s" MAIN_WORKTREE_PATH="%s" bash "%s/run-initial.sh" "%s" "1234" "")"' \
        "$acd_val" "$scripts" "$mwt_val" "$scripts" "$arg1"
}

run_overlay_metachar_cases() {
    run_metachar_token_cases
    run_metachar_hook_cases
    run_extra_arg_cases
}

# ============================================================================
# C1 — token validation, asserted on the module.
#
# Driven through the `plansdir` probe op, which uses isUnderPlansDir directly
# when it is exported and otherwise drives the token through a run-loop-step
# payload that is identical in every other respect. Either way the verdict comes
# from the shipped validation path, never from a copy of it in the test.
#
# SET-A here is the shell-control set the eval re-parses: ; & | < > ( ) ' "
# backtick $ ~ and whitespace. `$`, backtick and `~` are the three the current
# regex already covers — they are the ALREADY-GREEN half of the table and stay
# in it as the proof that the pin measures the real predicate.
#
# ARG-tok-dquote is green for a different, weaker reason: ONE `"` unbalances the
# payload, so the outer wrapper regex refuses it before the token is ever
# examined. ARG-tok-dquote-pair is the same character re-balanced — it reaches
# the token check and is accepted, so it is the row that actually measures the
# quote handling. The pair is kept together deliberately: it documents that the
# green row proves nothing about the predicate on its own.
# ============================================================================
run_metachar_token_cases() {
    run_plansdir_table <<'TABLE'
ARG-tok-semicolon    % a;b            % rejected
ARG-tok-amp          % a&b            % rejected
ARG-tok-pipe         % a|b            % rejected
ARG-tok-lt           % a<b            % rejected
ARG-tok-gt           % a>b            % rejected
ARG-tok-lparen       % a(b            % rejected
ARG-tok-rparen       % a)b            % rejected
ARG-tok-squote       % a'b            % rejected
ARG-tok-dquote       % a"b            % rejected
ARG-tok-dquote-pair  % a"q"b          % rejected
ARG-tok-injection    % a';gh issue close 999;'b % rejected
ARG-tok-dollar       % a$b            % rejected
ARG-tok-backtick     % a`b            % rejected
ARG-tok-tilde        % a~b            % rejected
TABLE

    # Paired ALLOW controls — the shapes a real finalize state file actually
    # has. A fix that rejects on any of these has broken the feature, and one
    # that "fixes" the table by rejecting everything fails right here.
    run_plansdir_table <<'TABLE'
ARG-tok-plain        % state.json                        % accepted
ARG-tok-real         % sid-finalize-state-1234.json      % accepted
ARG-tok-nested       % sub/sid-issue-close-outcome.json  % accepted
ARG-tok-dashes       % a-b_c.1234.json                   % accepted
TABLE

    # Whitespace: a space is not in the current regex either, and it splits the
    # eval into two words. The control is the same token with the space removed.
    assert_eq "ARG-tok-space whitespace inside a plans-dir token is rejected" \
        "$(AGENTS_CONFIG_DIR="$XV_ACD" WORKFLOW_PLANS_DIR="$XV_PLANS" \
            overlay_probe plansdir "$XV_PLANS/a b.json" "$XV_REPO")" "rejected"
    assert_eq "ARG-tok-space-control the same token without the space is accepted" \
        "$(AGENTS_CONFIG_DIR="$XV_ACD" WORKFLOW_PLANS_DIR="$XV_PLANS" \
            overlay_probe plansdir "$XV_PLANS/ab.json" "$XV_REPO")" "accepted"
}

# ============================================================================
# C2 / C3 — the same payloads at the hook boundary.
#
# The unit rows above say the token is accepted; these say what that costs: the
# PreToolUse hook returns ALLOW for a command whose eval carries a second
# command. Each is paired with the byte-identical clean invocation, which must
# stay ALLOW so the fix cannot be "block the whole overlay".
# ============================================================================
run_metachar_hook_cases() {
    local rc

    rc=0
    run_guard "$(build_bash_payload "$(build_loop_step "$XV_ACD" "$XV_SCRIPTS" "$XV_SCRIPTS" "$XV_PLANS/a';gh issue close 999;'b" "accept")")" \
        "$XV_REPO" "AGENTS_CONFIG_DIR=$XV_ACD" "WORKFLOW_PLANS_DIR=$XV_PLANS" || rc=$?
    assert_block "ARG-hook loop-step state file carrying a quoted command separator" "$rc"

    rc=0
    run_guard "$(build_bash_payload "$(build_loop_step "$XV_ACD" "$XV_SCRIPTS" "$XV_SCRIPTS" "$XV_PLANS/state.json" "accept")")" \
        "$XV_REPO" "AGENTS_CONFIG_DIR=$XV_ACD" "WORKFLOW_PLANS_DIR=$XV_PLANS" || rc=$?
    assert_allow "ARG-hook the identical loop-step with a clean state file (pair)" "$rc"

    rc=0
    run_guard "$(build_bash_payload "$(build_loop_step "$XV_ACD" "$XV_SCRIPTS" "$XV_SCRIPTS" "$XV_PLANS/a>b.json" "accept")")" \
        "$XV_REPO" "AGENTS_CONFIG_DIR=$XV_ACD" "WORKFLOW_PLANS_DIR=$XV_PLANS" || rc=$?
    assert_block "ARG-hook loop-step state file carrying a redirection" "$rc"

    rc=0
    run_guard "$(build_bash_payload "$(build_initial_arg1 "$XV_ACD" "$XV_SCRIPTS" "$XV_REPO" "1;gh issue close 999")")" \
        "$XV_REPO" "AGENTS_CONFIG_DIR=$XV_ACD" "WORKFLOW_PLANS_DIR=$XV_PLANS" || rc=$?
    assert_block "ARG-hook run-initial issue id carrying a command separator" "$rc"

    rc=0
    run_guard "$(build_bash_payload "$(build_initial_arg1 "$XV_ACD" "$XV_SCRIPTS" "$XV_REPO" "1234")")" \
        "$XV_REPO" "AGENTS_CONFIG_DIR=$XV_ACD" "WORKFLOW_PLANS_DIR=$XV_PLANS" || rc=$?
    assert_allow "ARG-hook the identical run-initial with a clean issue id (pair)" "$rc"
}

# ============================================================================
# D — arguments beyond argSpec.
#
# ARG-spec-shape is the structural half: it is GREEN today and its job is to
# STAY green. It fails the moment any entry declares an argCountMax it has no
# argSpec entry for — i.e. the moment the `spec === undefined` trapdoor becomes
# reachable from the shipped registry.
#
# ARG-extra-* is the behavioural half. The probe raises run-loop-step's
# argCountMax by one for the duration of a single call (the registry is exported
# by reference) and restores it immediately, so the unvalidated branch is
# actually entered. A poisoned extra token must be refused; the clean extra
# token must still match, which is what keeps this from being "reject anything
# with three arguments".
# ============================================================================
run_extra_arg_cases() {
    assert_eq "ARG-spec-shape every registry entry declares a spec for every argument it accepts" \
        "$(AGENTS_CONFIG_DIR="$XV_ACD" overlay_probe specshape)" "ok"

    # NOTE: a backslash is deliberately absent from the reject set — it is a
    # legitimate separator inside a Windows plans-dir path, so pinning it as
    # unsafe would break the feature on the platform this suite runs on.
    extra_probe() {
        AGENTS_CONFIG_DIR="$XV_ACD" WORKFLOW_PLANS_DIR="$XV_PLANS" \
            overlay_probe matchextra "$1" "$XV_REPO"
    }

    assert_eq "ARG-extra-redirect an argument past argSpec is still token-checked (redirection)" \
        "$(extra_probe "a<b")" "null"
    assert_eq "ARG-extra-semicolon an argument past argSpec is still token-checked (separator)" \
        "$(extra_probe "a;gh issue close 999")" "null"
    assert_eq "ARG-extra-pipe an argument past argSpec is still token-checked (pipe)" \
        "$(extra_probe "a|b")" "null"
    assert_eq "ARG-extra-clean a clean argument past argSpec is not rejected by count alone (pair)" \
        "$(extra_probe "1234")" "run-loop-step.js"
}
