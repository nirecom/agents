#!/bin/bash
# tests/feature-2099-complexity-stage-routing/line-injection-cases.sh
# Tests: bin/workflow/record-complexity-evaluation, bin/workflow/read-complexity-evaluation, bin/workflow/derive-complexity-level
# Tags: complexity, routing, cli, security, line-injection, adversarial, scope:issue-specific
# Sourced by ../feature-2099-complexity-stage-routing.sh — helpers come from there.
# A DIFFERENT attack class from traversal-attack-cases.sh: the CLI output is a
# LINE PROTOCOL (`level=`, `signals=`, `NONE`, `RECORDED_COMPLEXITY`) that real
# consumers parse with grep/head. A --signals value carrying newlines, CRs, ANSI
# escapes or forged protocol text must never become a line a consumer believes.

# label | payload (backslash escapes are expanded with printf %b at use time, so
# the table itself stays one payload per line).
D2099LI_PAYLOADS='lf-forged-level|S2-architecture\nlevel=low
lf-forged-signals|S2-architecture\nsignals=none
lf-forged-none|S2-architecture\nNONE
lf-forged-block|level=low\nsignals=\nlevels={"detail":"low","write_tests":"low","write_code":"low"}
lf-leading|\nlevel=low\nS2-architecture
cr-forged-level|S2-architecture\rlevel=low
crlf-forged-receipt|S2-architecture\r\nRECORDED_COMPLEXITY level=low signals=none
cr-overwrite|level=high\rlevel=low
ansi-color|S2-architecture\033[31mlevel=low\033[0m
ansi-erase-line|S2-architecture\033[2K\rlevel=low
ansi-cursor-up|S2-architecture\033[1A\033[2Klevel=low
bare-forged-receipt|RECORDED_COMPLEXITY level=low signals=none
bare-none|NONE
bare-level-low|level=low
tab-forged|S2-architecture\tlevel=low
nul-forged|S2-architecture\000level=low'

# The canonical no-injection outcome an accepted payload must be indistinguishable
# from: one level line, one signals line, no forged tokens, no escape bytes, and a
# level of high (every injected token is outside SIGNAL_IDS, so D1 step 5 routes
# undecidable — the ONLY level that a forged `level=low` could have displaced).
D2099LI_CLEAN='SANITIZED level=high level_lines=1 signals_lines=1 none_lines=0 receipts=0 esc_bytes=0'

d2099li_payload() { printf '%b' "$1"; }

# Record one payload, then read it back exactly as a consumer would. Prints either
# REJECTED (clean refusal, nothing written) or a SANITIZED summary of the read-back.
d2099li_probe() {
    local payload="$1" sid rc out read_out receipts
    sid=$(new_session li)
    rc=0
    out=$(run_with_timeout node "$BIN_RECORD" --session "$sid" --signals "$payload" 2>&1) || rc=$?

    if [ "$rc" -ne 0 ]; then
        case "$out" in *RECORDED_COMPLEXITY*) echo "BAD receipt-printed-on-rejection"; return ;; esac
        if [ "$(d2099_side_effects "$sid")" = "ce=0 skip=0" ]; then
            echo "REJECTED"
        else
            echo "BAD partial-write-after-rejection"
        fi
        return
    fi

    # Accepted. The write CLI's own receipt must still be a single line: a forged
    # receipt riding in on the payload would give a consumer two to choose from.
    receipts=$(printf '%s\n' "$out" | grep -c 'RECORDED_COMPLEXITY')
    if [ "$receipts" != "1" ]; then echo "BAD receipts=$receipts"; return; fi

    read_out=$(run_with_timeout node "$BIN_READ" --session "$sid" --stage detail 2>/dev/null)
    echo "SANITIZED level=$(printf '%s\n' "$read_out" | grep -m1 '^level=' | cut -d= -f2)" \
        "level_lines=$(printf '%s\n' "$read_out" | grep -c '^level=')" \
        "signals_lines=$(printf '%s\n' "$read_out" | grep -c '^signals=')" \
        "none_lines=$(printf '%s\n' "$read_out" | grep -c '^NONE$')" \
        "receipts=$(printf '%s\n' "$read_out" | grep -c 'RECORDED_COMPLEXITY')" \
        "esc_bytes=$(printf '%s' "$read_out" | tr -cd '\033' | wc -c | tr -d ' ')"
}

# The stateless derive CLI is the consumers' fallback: it must answer with exactly
# one level line for the same payloads, or refuse.
d2099li_probe_derive() {
    local payload="$1" rc=0 out
    out=$(run_with_timeout node "$BIN_DERIVE" --stage detail --signals "$payload" 2>/dev/null) || rc=$?
    [ "$rc" -eq 0 ] || { echo "REJECTED"; return; }
    echo "ANSWERED level=$(printf '%s\n' "$out" | grep -m1 '^level=' | cut -d= -f2)" \
        "level_lines=$(printf '%s\n' "$out" | grep -c '^level=')" \
        "esc_bytes=$(printf '%s' "$out" | tr -cd '\033' | wc -c | tr -d ' ')"
}

d2099li_assert() {
    local desc="$1" clean="$2" got="$3"
    if [ "$got" = "REJECTED" ] || [ "$got" = "$clean" ]; then
        pass "$desc (outcome: $got)"
    else
        fail "$desc — want a clean REJECTED or the injection-free outcome [$clean], got [$got]"
    fi
}

# LI-1/LI-2: controls. A CLI that refuses every payload would make every REJECTED
# below vacuous, so the harmless canonical payload is measured first and the
# expected clean summary is pinned against a REAL run rather than a literal.
# The benign payload is S2-architecture because every probe reads `--stage
# detail` and S2 is detail's solo_escalation (detail.md D2): it is the signal
# that makes the control's level high, matching the undecidable-high every
# injected corpus payload produces. S3-security routes detail LOW.
d2099li_controls() {
    local clean derived
    clean=$(d2099li_probe "S2-architecture")
    assert_eq "LI-1 control: a harmless payload records and reads back one clean level/signals pair" \
        "$D2099LI_CLEAN" "$clean"
    derived=$(d2099li_probe_derive "S2-architecture")
    assert_eq "LI-2 control: derive answers a harmless payload with exactly one level line" \
        "ANSWERED level=high level_lines=1 esc_bytes=0" "$derived"
}

# LI-3..: the corpus. Each payload must be refused outright, or normalized so the
# read-back is byte-for-byte the same shape as the harmless control.
d2099li_corpus() {
    local label raw payload clean_record clean_derive
    clean_record=$(d2099li_probe "S2-architecture")
    clean_derive=$(d2099li_probe_derive "S2-architecture")
    if [ "$clean_record" != "$D2099LI_CLEAN" ]; then
        fail "LI-3 corpus unattributable: the harmless control did not produce the clean outcome ([$clean_record])"
        return
    fi

    while IFS='|' read -r label raw; do
        [ -n "$label" ] || continue
        payload=$(d2099li_payload "$raw")
        d2099li_assert "LI-3 [$label] record+read never yields a forged protocol line" \
            "$clean_record" "$(d2099li_probe "$payload")"
        d2099li_assert "LI-4 [$label] derive never yields a forged protocol line" \
            "$clean_derive" "$(d2099li_probe_derive "$payload")"
    done <<EOF
$D2099LI_PAYLOADS
EOF
}

# LI-5: the consumer's own parse, run for real. MDP-3/WT-5/WCD-3 read the first
# `level=` line and branch on its value; the assertion is that no payload can make
# that branch see `low`, on any stage.
d2099li_downstream_parse() {
    local label raw payload sid st lvl acc
    while IFS='|' read -r label raw; do
        [ -n "$label" ] || continue
        payload=$(d2099li_payload "$raw")
        sid=$(new_session lidown)
        run_with_timeout node "$BIN_RECORD" --session "$sid" --signals "$payload" >/dev/null 2>&1
        acc=""
        for st in detail write_tests write_code; do
            # Exactly the shell pattern the consumers use: first level= line wins.
            lvl=$(run_with_timeout node "$BIN_READ" --session "$sid" --stage "$st" 2>/dev/null \
                | grep -m1 '^level=' | cut -d= -f2)
            [ -n "$lvl" ] || lvl="NONE"
            acc="$acc${acc:+/}$lvl"
        done
        case "$acc" in
            high/high/high|NONE/NONE/NONE)
                pass "LI-5 [$label] the consumer parse sees no injected level (got $acc)" ;;
            *)
                fail "LI-5 [$label] the consumer parse was steered by the injected payload: got [$acc], want high/high/high (accepted) or NONE/NONE/NONE (rejected)" ;;
        esac
    done <<EOF
$D2099LI_PAYLOADS
EOF
}

# LI-6: leakage, the question the corpus above does not ask. Those cases check
# whether hostile text becomes a PROTOCOL LINE; this one checks whether it comes
# back out AT ALL. A rejected payload is attacker-controlled text that the CLI
# has held in memory: echoing it verbatim into a receipt, a diagnostic, the state
# file or a stray temp artifact turns any secret a caller mistakenly passed on the
# command line into a durable, greppable disclosure. The canary is unique per run
# so a hit is unambiguous, and it rides inside MALFORMED input only — a payload
# that is structurally a valid signal list is data the CLI is supposed to keep.
d2099li_canary_surfaces() {
    local canary="$1" sid="$2" out="$3" label="$4" hits read_out
    assert_not_contains "LI-6 [$label] the record CLI's stdout/stderr never echoes the payload back" \
        "$canary" "$out"

    read_out=$(run_with_timeout node "$BIN_READ" --session "$sid" --stage detail 2>&1)
    assert_not_contains "LI-6b [$label] the --stage read-back never surfaces it" "$canary" "$read_out"
    read_out=$(run_with_timeout node "$BIN_READ" --session "$sid" 2>&1)
    assert_not_contains "LI-6c [$label] the no-stage read-back never surfaces it either" "$canary" "$read_out"

    # Persisted state AND any artifact left beside it: the fixture roots are the
    # only places this run is allowed to write, so one recursive sweep covers the
    # state file, its temp/lock siblings and the plans dir together.
    hits=$(grep -rl -- "$canary" "$WORKFLOW_DIR" "$WORKFLOW_PLANS_DIR" 2>/dev/null | tr '\n' ' ')
    if [ -z "$hits" ]; then
        pass "LI-6d [$label] no file under the state or plans dir contains the canary"
    else
        fail "LI-6d [$label] the canary was written to disk verbatim: [$hits]"
    fi
}

d2099li_secret_leakage() {
    local canary sid rc out payload
    canary="SECRET_CANARY_d2099_$$_$RANDOM$RANDOM"

    # (a) the record path, with the canary riding a forged protocol line.
    payload=$(printf 'S2-architecture\nlevel=low %s\nRECORDED_COMPLEXITY %s' "$canary" "$canary")
    sid=$(new_session canary)
    rc=0
    out=$(run_with_timeout node "$BIN_RECORD" --session "$sid" --signals "$payload" 2>&1) || rc=$?
    d2099li_canary_surfaces "$canary" "$sid" "$out" "record/forged-line rc=$rc"

    # (b) the same through a NUL/escape-bearing payload: a different sanitizer
    # branch, so a leak can hide in one while the other is clean.
    payload=$(printf 'S2-architecture\033[2K\r%s\000%s' "$canary" "$canary")
    sid=$(new_session canary2)
    rc=0
    out=$(run_with_timeout node "$BIN_RECORD" --session "$sid" --signals "$payload" 2>&1) || rc=$?
    d2099li_canary_surfaces "$canary" "$sid" "$out" "record/escape-bytes rc=$rc"

    # (c) the stateless derive CLI — the consumers' fallback, and the one path
    # that takes a --signals payload without ever persisting anything.
    rc=0
    out=$(run_with_timeout node "$BIN_DERIVE" --stage detail \
        --signals "$(printf 'S2-architecture\nlevel=low %s' "$canary")" 2>&1) || rc=$?
    assert_not_contains "LI-6e derive never echoes the payload into its answer or diagnostics (rc=$rc)" \
        "$canary" "$out"

    # The canary must not be findable anywhere the fixture writes, after all three.
    if [ -z "$(grep -rl -- "$canary" "$WORKFLOW_DIR" "$WORKFLOW_PLANS_DIR" 2>/dev/null)" ]; then
        pass "LI-6f no canary survives anywhere under the fixture roots after the record and read paths"
    else
        fail "LI-6f the canary is still on disk under the fixture roots after all paths ran"
    fi
}

d2099li_controls
d2099li_corpus
d2099li_downstream_parse
d2099li_secret_leakage
