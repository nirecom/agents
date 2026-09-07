# Tests: skills, skills/_shared, hooks/bash-guard/judge.js, rules
# Tags: prompt-issuance, bash-guard, inventory, scope:issue-specific
# P0..P5 for #2132 (detail.md S6). Sourced by feature-2132-prompt-issuance.sh;
# needs AGENTS_DIR, AN, TSV, PROBE, pass/fail/assert_eq, run_with_timeout.
# P0/P1/P5 measure CURRENT repo state and are GREEN today; P2/P3/P4 assert the
# post-conversion state and are RED until the conversion lands.

# Ledger schema: <path>:<line> TAB <class> TAB <command-text>, command-text a
# verbatim substring of that file at that line.

read_row_field() { printf '%s' "$1" | cut -f"$2"; }

run_P0() {
    if [ ! -f "$TSV" ]; then
        fail "P0: inventory.tsv missing — every #2132 case would be vacuous"
        return
    fi
    local n_issuance n_allow n_quote n_bad
    n_issuance=$(awk -F'\t' '!/^#/ && NF>=3 && $2=="issuance"' "$TSV" | wc -l | tr -d ' ')
    n_allow=$(awk -F'\t' '!/^#/ && NF>=3 && $2=="allow-rule-covered"' "$TSV" | wc -l | tr -d ' ')
    n_quote=$(awk -F'\t' '!/^#/ && NF>=3 && $2=="quotation"' "$TSV" | wc -l | tr -d ' ')
    # A ledger that silently shrank to zero rows would make P1/P2 pass on nothing.
    [ "$n_issuance" -ge 30 ] && pass "P0: ledger carries $n_issuance issuance rows (>=30)" \
        || fail "P0: ledger carries only $n_issuance issuance rows — expected >=30"
    [ "$n_allow" -ge 11 ] && pass "P0: ledger carries $n_allow allow-rule-covered rows (>=11)" \
        || fail "P0: ledger carries only $n_allow allow-rule-covered rows — expected >=11"
    [ "$n_quote" -ge 12 ] && pass "P0: ledger carries $n_quote quotation rows (>=12)" \
        || fail "P0: ledger carries only $n_quote quotation rows — expected >=12"
    # Class vocabulary integrity: a typo'd class silently drops a row from P1/P2.
    n_bad=$(awk -F'\t' '!/^#/ && NF>=3 && $2!="issuance" && $2!="allow-rule-covered" && $2!="quotation"' "$TSV" | wc -l | tr -d ' ')
    assert_eq "P0: every ledger row carries a known class" "0" "$n_bad"
}

# P1 (GREEN today) — drift check. The ledger is a hand-curated snapshot, so it
# rots the moment a prompt file is renumbered. Each row must still be findable at
# its recorded path:line; the same string is what P2 feeds the judge.
run_P1() {
    local row site cls cmd relpath lineno line
    while IFS= read -r row; do
        case "$row" in ''|'#'*) continue ;; esac
        site=$(read_row_field "$row" 1)
        cls=$(read_row_field "$row" 2)
        cmd=$(printf '%s' "$row" | cut -f3-)
        [ -n "$cls" ] || continue
        relpath="${site%:*}"; lineno="${site##*:}"
        if [ ! -f "$AGENTS_DIR/$relpath" ]; then
            fail "P1 $site: file no longer exists — ledger is stale"
            continue
        fi
        line=$(sed -n "${lineno}p" "$AGENTS_DIR/$relpath")
        case "$line" in
            *"$cmd"*) pass "P1 $site ($cls): recorded text still present at that line" ;;
            *) fail "P1 $site ($cls): recorded text NOT at that line — ledger drifted; line reads '$line'" ;;
        esac
    done < "$TSV"
}

# P2 (RED until the conversion lands) — the point of #2132. Every issuance and
# allow-rule-covered command a prompt tells Claude to run must be judged `allow`
# by the #2134 guard; anything else is a prompt that induces a permission ask.
run_P2() {
    local out rc site verdict n=0
    out=$(run_with_timeout 60 node "$PROBE" "$AN" "$TSV" 2>&1); rc=$?
    case "$out" in
        MISSING-JUDGE*)
            fail "P2: hooks/bash-guard/judge.js unavailable — ${out#MISSING-JUDGE	}"
            return ;;
    esac
    if [ "$rc" -ne 0 ]; then
        fail "P2: judge probe exited $rc — output: $out"
        return
    fi
    local control_verdict=""
    while IFS=$'\t' read -r site verdict; do
        [ -n "$site" ] || continue
        if [ "$site" = "__CONTROL_DENY__" ]; then
            control_verdict="$verdict"
            continue
        fi
        n=$((n + 1))
        assert_eq "P2 $site: judged allow" "allow" "$verdict"
    done <<EOF
$out
EOF
    # Attributability control (mirrors cases-tool-scope.sh T2 / cases-fail-open.sh
    # O4): a known-deny compound command must still come back `deny` through the
    # same judge() helper. Without this, a judge() that vacuously allowed
    # everything (e.g. wrong PreToolUse envelope shape) would make every "allow"
    # assertion above pass for the wrong reason.
    assert_eq "P2 control: a known-deny compound command is still judged deny" "deny" "$control_verdict"
    # Without this the loop could score zero rows and P2 would report nothing.
    [ "$n" -ge 41 ] && pass "P2: judge probe returned $n verdicts (>=41)" \
        || fail "P2: judge probe returned only $n verdicts — expected one per issuance/allow-rule-covered row"
}

# P3 (RED until the conversion lands) — residual-form sweep. P1/P2 only see rows
# someone remembered to log; this catches the ask-inducing FORMS anywhere under
# skills/, so a conversion that misses a site is still caught.
run_P3() {
    local hits control
    # Positive control: a fixture built to match each sweep pattern, so a pattern that
    # typo'd dead (or a skills/ tree that vanished) cannot pass the zero-match rows below
    # for the wrong reason.
    control="$P2_TMPROOT/p3-positive-control.md"
    printf '%s\n' '`FOO=$(bar)`' '`ls | tail -5`' '`echo $(pwd)`' 'eval "$(setup)"' > "$control"

    # R1 capture->stdout: `VAR=$(...)` assignments in prompt prose.
    hits=$(grep -cE '`[A-Z_]+=\$\(' "$control")
    [ "$hits" -ge 1 ] && pass "P3 R1 control: capture-into-variable pattern is live" \
        || fail "P3 R1 control: capture-into-variable pattern matched nothing in a known-matching fixture"
    hits=$(grep -rnE '`[A-Z_]+=\$\(' "$AGENTS_DIR/skills" --include='*.md' | wc -l | tr -d ' ')
    assert_eq "P3 R1: no capture-into-variable command forms remain under skills/" "0" "$hits"
    # R3 pipe extraction: `... | tail -` / `| cut -d` post-processing chains.
    hits=$(grep -cE '`[^`]*\| *(tail|cut|tr|head) ' "$control")
    [ "$hits" -ge 1 ] && pass "P3 R3 control: pipe-extraction pattern is live" \
        || fail "P3 R3 control: pipe-extraction pattern matched nothing in a known-matching fixture"
    hits=$(grep -rnE '`[^`]*\| *(tail|cut|tr|head) ' "$AGENTS_DIR/skills" --include='*.md' | wc -l | tr -d ' ')
    assert_eq "P3 R3: no pipe-extraction command forms remain under skills/" "0" "$hits"
    # R4 arg substitution: `$(pwd)` / `$(git rev-parse ...)` inline arguments.
    hits=$(grep -cE '`[^`]*\$\((pwd|git rev-parse)' "$control")
    [ "$hits" -ge 1 ] && pass "P3 R4 control: inline argument-substitution pattern is live" \
        || fail "P3 R4 control: inline argument-substitution pattern matched nothing in a known-matching fixture"
    hits=$(grep -rnE '`[^`]*\$\((pwd|git rev-parse)' "$AGENTS_DIR/skills" --include='*.md' | wc -l | tr -d ' ')
    assert_eq "P3 R4: no inline argument-substitution forms remain under skills/" "0" "$hits"
    # R2 multi-line snippet: an `eval "$(...)"` bootstrap is the extreme case.
    hits=$(grep -cF 'eval "$(' "$control")
    [ "$hits" -ge 1 ] && pass "P3 R2 control: eval-bootstrap pattern is live" \
        || fail "P3 R2 control: eval-bootstrap pattern matched nothing in a known-matching fixture"
    hits=$(grep -rnF 'eval "$(' "$AGENTS_DIR/skills" --include='*.md' | wc -l | tr -d ' ')
    assert_eq "P3 R2: no eval-bootstrap command forms remain under skills/" "0" "$hits"
}

# P4 (RED until the conversion lands) — R2's shared extraction. workflow-init and
# clarify-intent both inline the same record-complexity-and-skip pipeline
# (ledger rows workflow-init:83 / clarify-intent:107); the conversion moves it to
# one shared file so the two cannot drift apart (CPR-SSOT).
run_P4() {
    local shared="skills/_shared/complexity-and-outline-skip.md" f
    if [ -f "$AGENTS_DIR/$shared" ]; then
        pass "P4: $shared exists"
    else
        fail "P4: $shared missing — the duplicated skip pipeline was not extracted"
    fi
    for f in skills/workflow-init/SKILL.md skills/clarify-intent/SKILL.md; do
        if grep -qF "complexity-and-outline-skip" "$AGENTS_DIR/$f" 2>/dev/null; then
            pass "P4: $f references the shared skip procedure"
        else
            fail "P4: $f still carries its own copy of the skip pipeline"
        fi
    done
}

# P5 (GREEN today) — curated exclusions. quotation rows NAME a prohibited form as
# prose; converting them would destroy the rule text they document. They are
# drift-checked by P1 and must never be handed to the judge.
run_P5() {
    local judged quoted overlap
    judged=$(awk -F'\t' '!/^#/ && NF>=3 && ($2=="issuance"||$2=="allow-rule-covered") {print $1}' "$TSV" | sort -u)
    quoted=$(awk -F'\t' '!/^#/ && NF>=3 && $2=="quotation" {print $1}' "$TSV" | sort -u)
    overlap=$(comm -12 <(printf '%s\n' "$judged") <(printf '%s\n' "$quoted") | grep -c . | tr -d ' ')
    assert_eq "P5: no site is both judged and curated-excluded" "0" "$overlap"
    # rules/ is outside the conversion scope entirely; its rows must stay quotation.
    local rules_nonquote
    rules_nonquote=$(awk -F'\t' '!/^#/ && NF>=3 && $1 ~ /^rules\// && $2!="quotation"' "$TSV" | wc -l | tr -d ' ')
    assert_eq "P5: every rules/ row is classed quotation" "0" "$rules_nonquote"
}
