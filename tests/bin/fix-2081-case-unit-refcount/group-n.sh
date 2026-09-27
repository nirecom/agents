# Group N: injection safety — case extraction is static, never eval'd (#2081)
# Tests: bin/lib/test-retire-predicate/case-parser.sh, bin/lib/test-retire-predicate.sh
# Tags: TL2, audit-tests, retire, scope:issue-specific
# Sourced by tests/bin/fix-2081-case-unit-refcount.sh
#
# The parser greps case_begin/case_end lines with grep/awk/parameter expansion
# only — never eval/source. A marker line carrying a command substitution or a
# shell metacharacter must be parsed as text (→ malformed), with zero execution
# side effect. Overlaps B(e) but isolates the extraction path's safety.

if ! require_fn trp_enumerate_cases "N0"; then return 0; fi

N_REPO="$(make_repo)"
add_src "$N_REPO" "bin/n-live.sh"
N_CANARY="$TMPDIR_BASE/n-canary-$$"
rm -f "$N_CANARY"

# (1) command substitution inside the target quotes — expansion form, malformed.
add_raw "$N_REPO" "n-cmdsub.sh" <<EOF
#!/usr/bin/env bash
# Tests: bin/n-live.sh
# Tags: TL2, scope:issue-specific
case_begin "n" "\$(touch $N_CANARY)"
case_end
EOF
# (2) metacharacter target — malformed, must not run rm/touch.
add_raw "$N_REPO" "n-meta.sh" <<EOF
#!/usr/bin/env bash
# Tests: bin/n-live.sh
# Tags: TL2, scope:issue-specific
case_begin "n" "x; touch $N_CANARY"
case_end
EOF
# (3) backtick substitution — malformed, must not run.
add_raw "$N_REPO" "n-backtick.sh" <<EOF
#!/usr/bin/env bash
# Tests: bin/n-live.sh
# Tags: TL2, scope:issue-specific
case_begin "n" "\`touch $N_CANARY\`"
case_end
EOF
commit_repo "$N_REPO" "group-n injection fixtures"

for _n_f in n-cmdsub.sh n-meta.sh n-backtick.sh; do
    run_enum "$N_REPO" "tests/$_n_f"
    assert_eq "N1 [$_n_f] injection marker parsed as malformed, not run" \
        "1" "${_TRP_MARKER_MALFORMED:-x}"
    if [[ -e "$N_CANARY" ]]; then
        fail "N2 [$_n_f] extraction EXECUTED the injected command (canary created)"
        rm -f "$N_CANARY"
    else
        pass "N2 [$_n_f] no execution side effect from extraction"
    fi
done
unset _n_f

# N3 — a legitimate static target that merely LOOKS suspicious in text is still
# handled statically: a valid case whose target is a real path enumerates with
# the literal target, no shell interpretation.
add_src "$N_REPO" "bin/n-ok.sh"
add_raw "$N_REPO" "n-ok.sh" <<'EOF'
#!/usr/bin/env bash
# Tests: bin/n-ok.sh
# Tags: TL2, scope:issue-specific
case_begin "ok" "bin/n-ok.sh"
case_end
EOF
commit_repo "$N_REPO" "group-n valid static target"
run_enum "$N_REPO" "tests/n-ok.sh"
assert_eq "N3 valid static target extracted literally" \
    "bin/n-ok.sh" "$(join_sp "${TRP_CASE_TARGETS[@]:-}")"
assert_eq "N3b valid static target not malformed" "0" "${_TRP_MARKER_MALFORMED:-x}"
