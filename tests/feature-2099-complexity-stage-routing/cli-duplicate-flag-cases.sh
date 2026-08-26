#!/bin/bash
# tests/feature-2099-complexity-stage-routing/cli-duplicate-flag-cases.sh
# Tests: bin/workflow/record-complexity-evaluation, bin/workflow/read-complexity-evaluation, bin/workflow/derive-complexity-level, bin/workflow/record-complexity-and-skip
# Tags: complexity, routing, cli, argument-parsing, security, edge-cases, scope:issue-specific
# Sourced by ../feature-2099-complexity-stage-routing.sh AFTER record-read-cases.sh.
# The sibling hardening suites pass each flag ONCE; a flag repeated with a
# different value is the parser state nothing covers — and the one an
# orchestrator produces by accident, when a skill line already carrying
# `--signals "<csv>"` gets a second one appended by a wrapper's own default.
D2099DF_A="S1-multi-file"

# S1/S2 route detail differently (low vs high, detail.md D2), so first-wins,
# last-wins and merge are three distinguishable outcomes. S3-security does NOT
# work here: detail's escalation sets omit it, so S1 and S3 both route detail
# low and every duplicate-resolution rule would look alike through
# `--stage detail`.
D2099DF_B="S2-architecture"

# The contract. detail.md fixes no duplicate-flag rule, so BOTH principled
# answers pass and the AMBIGUOUS middles fail: (a) reject — non-zero exit, a
# diagnostic, and NOTHING persisted; or (b) last-wins, the conventional CLI
# default (getopt, git, docker), identical to passing only the last occurrence.
# first-wins and merge are refused: they let the value a reader sees at the
# visible tail of the line be overridden by an earlier one, so
# `--signals X --signals ""` would record the zero-signal LOW while reading as X.
# Determinism is required either way — a parser answering differently on two
# identical invocations makes every routing decision unreproducible.
d2099df_assert() {
    local id="$1" dup="$2" dup_again="$3" first="$4" last="$5" mutated="$6"
    if [ "$dup" != "$dup_again" ]; then
        fail "$id the duplicated flag produced a DIFFERENT answer on an identical second run — [$dup] then [$dup_again]"
        return
    fi
    case "$dup" in
        rc=0*)
            if [ "$dup" = "$last" ]; then
                pass "$id resolves last-wins, the conventional CLI default ($dup)"
            elif [ "$dup" = "$first" ]; then
                fail "$id resolved FIRST-wins [$dup] — the value a reader sees last on the line is not the one that acted"
            else
                fail "$id produced neither the first-only [$first] nor the last-only [$last] outcome: [$dup] — a merged or invented value"
            fi ;;
        *)
            if [ "$mutated" = "mutated" ]; then
                fail "$id was rejected ($dup) but the session state CHANGED — a rejection must persist nothing"
            else
                pass "$id is rejected cleanly, with no state written ($dup)"
            fi ;;
    esac
}

# One invocation through the CLI's OWN interpreter (d2099_cli_runner — the
# wrapper is bash while its siblings are node), reduced to exit code + first line.
d2099df_run() {
    local bin="$1"; shift
    local rc=0 out
    out=$(run_with_timeout "$(d2099_cli_runner "$bin")" "$bin" "$@" 2>&1) || rc=$?
    printf 'rc=%s out=[%s]' "$rc" "$(printf '%s\n' "$out" | head -1)"
}

# What a WRITE CLI actually stored, read back through the reader — the outcome
# that matters for record/record-and-skip, whose stdout is only a receipt.
d2099df_stored() {
    printf 'rc=0 out=[stored:%s]' "$(run_with_timeout node "$BIN_READ" --session "$1" --stage detail 2>/dev/null | tr '\n' ';')"
}

# Did anything land in this session? The no-mutation half of a rejection.
d2099df_mutation() {
    if [ "$(d2099_side_effects "$1")" = "ce=0 skip=0" ]; then printf 'clean'; else printf 'mutated'; fi
}

# A write CLI's baseline: one session, one single-flag call, its read-back.
# When that single call records nothing the pair is unattributable, and the
# reason belongs in the failure message rather than in a bare empty string. The
# note travels through a FILE, not a variable: every baseline is read through a
# command substitution, whose subshell would discard an assignment.
D2099DF_WHY="$TMPDIR_BASE/d2099df-why"
d2099df_baseline() {
    local tag="$1"; shift
    local sid out rc=0
    sid=$(new_session "$tag")
    out=$(run_with_timeout "$(d2099_cli_runner "$1")" "$@" --session "$sid" 2>&1) || rc=$?
    if [ "$(d2099_side_effects "$sid")" != "ce=1 skip=0" ]; then
        printf 'the single-flag control recorded nothing (exit %s: %s)' \
            "$rc" "$(printf '%s\n' "$out" | head -1)" > "$D2099DF_WHY"
    fi
    d2099df_stored "$sid"
}

d2099df_why() {
    if [ -s "$D2099DF_WHY" ]; then cat "$D2099DF_WHY"; else printf 'both routed to the same level'; fi
}

# A write CLI's duplicate run: exit code if it refused, read-back if it accepted.
# Echoes "<outcome>|<clean|mutated>".
d2099df_dup_write() {
    local tag="$1"; shift
    local sid out; sid=$(new_session "$tag")
    out=$(d2099df_run "$@" --session "$sid")
    case "$out" in rc=0*) out=$(d2099df_stored "$sid") ;; esac
    printf '%s|%s' "$out" "$(d2099df_mutation "$sid")"
}

# --- DF-1: record-complexity-evaluation --signals twice ----------------------
d2099df_record_signals() {
    local first last dup dup2 zero
    : > "$D2099DF_WHY"
    first=$(d2099df_baseline dfrec-a "$BIN_RECORD" --signals "$D2099DF_A")
    last=$(d2099df_baseline dfrec-b "$BIN_RECORD" --signals "$D2099DF_B")
    if [ "$first" = "$last" ]; then
        fail "DF-1 unattributable: the two baseline signal sets read back identically ($first) — $(d2099df_why)"
        return
    fi

    dup=$(d2099df_dup_write dfrec-dup "$BIN_RECORD" --signals "$D2099DF_A" --signals "$D2099DF_B")
    dup2=$(d2099df_dup_write dfrec-dup2 "$BIN_RECORD" --signals "$D2099DF_A" --signals "$D2099DF_B")
    d2099df_assert "DF-1 record-complexity-evaluation --signals twice" \
        "${dup%|*}" "${dup2%|*}" "$first" "$last" "${dup##*|}"

    # The dangerous pairing on its own axis: a visible signal set followed by the
    # zero-signal value (detail.md item 10). Under first-wins this records the
    # HIGH while the line ends in "", the direction that hides an escalation.
    zero=$(d2099df_baseline dfrec-zerobase "$BIN_RECORD" --signals "")
    dup=$(d2099df_dup_write dfrec-zero "$BIN_RECORD" --signals "$D2099DF_B" --signals "")
    dup2=$(d2099df_dup_write dfrec-zero2 "$BIN_RECORD" --signals "$D2099DF_B" --signals "")
    d2099df_assert "DF-1z record-complexity-evaluation --signals <ids> then --signals \"\"" \
        "${dup%|*}" "${dup2%|*}" "$last" "$zero" "${dup##*|}"
}

# --- DF-2/DF-8: a duplicated --session on each write CLI ----------------------
# The wrong half of the pair must stay untouched whichever answer the parser
# gives: a record landing in BOTH sessions is what neither behaviour permits.
d2099df_two_session_write() {
    local id="$1" bin="$2"; shift 2
    local sid_a sid_b rc=0 both ctrl ctrl_rc=0 ctrl_out tag
    # The session tag comes from the BINARY's name, never from the case id: the
    # id is prose with spaces, and the CLIs' --session regex rejects those, so a
    # tag built from it would fail on the session id rather than the duplicate.
    tag="df-$(basename "$bin")"
    # Attributability control: the SAME call with one --session must record.
    # Without it a CLI that refuses every invocation — today's, which has no
    # signals-only form yet — would satisfy the reject branch and go green.
    ctrl=$(new_session "$tag-ctrl")
    ctrl_out=$(run_with_timeout "$(d2099_cli_runner "$bin")" "$bin" --session "$ctrl" "$@" 2>&1) || ctrl_rc=$?
    if [ "$(d2099_side_effects "$ctrl")" != "ce=1 skip=0" ]; then
        fail "$id unattributable: the same call with a SINGLE --session recorded nothing (exit $ctrl_rc: $(printf '%s\n' "$ctrl_out" | head -1)), so a duplicate being refused proves nothing"
        return
    fi
    sid_a=$(new_session "$tag-a")
    sid_b=$(new_session "$tag-b")
    run_with_timeout "$(d2099_cli_runner "$bin")" "$bin" --session "$sid_a" --session "$sid_b" "$@" >/dev/null 2>&1 || rc=$?
    both="$(d2099_side_effects "$sid_a")/$(d2099_side_effects "$sid_b")"
    case "$rc:$both" in
        0:"ce=0 skip=0/ce=1 skip=0")
            pass "$id --session twice resolves last-wins: only the second session holds the record" ;;
        0:"ce=1 skip=0/ce=0 skip=0")
            fail "$id --session twice resolved FIRST-wins — the record landed in the session the command line does not end with" ;;
        0:*)
            fail "$id --session twice exited 0 with side effects [$both] — never both sessions, never neither" ;;
        *:"ce=0 skip=0/ce=0 skip=0")
            pass "$id rejects a duplicated --session (exit $rc) and writes to neither session" ;;
        *)
            fail "$id rejected a duplicated --session (exit $rc) but still wrote something [$both]" ;;
    esac
}

# --- DF-3/DF-4: read-complexity-evaluation -----------------------------------
# --stage detail vs write_code splits S1-multi-file low/high (detail.md D2); the
# --session pair couples a recorded id with an unrecorded one, whose answer is
# the NONE fallback. A reader has no state to mutate, so `clean` is structural.
d2099df_read_flags() {
    local sid sid_none first last dup dup2
    sid=$(new_session dfread)
    run_with_timeout node "$BIN_RECORD" --session "$sid" --signals "$D2099DF_A" >/dev/null 2>&1
    sid_none=$(new_session dfread-none)

    first=$(d2099df_run "$BIN_READ" --session "$sid" --stage detail)
    last=$(d2099df_run "$BIN_READ" --session "$sid" --stage write_code)
    if [ "$first" = "$last" ]; then
        fail "DF-3 unattributable: --stage detail and --stage write_code answer identically ($first), so the duplicate cannot be resolved either way"
    else
        dup=$(d2099df_run "$BIN_READ" --session "$sid" --stage detail --stage write_code)
        dup2=$(d2099df_run "$BIN_READ" --session "$sid" --stage detail --stage write_code)
        d2099df_assert "DF-3 read-complexity-evaluation --stage twice" "$dup" "$dup2" "$first" "$last" "clean"
    fi

    first=$(d2099df_run "$BIN_READ" --session "$sid" --stage detail)
    last=$(d2099df_run "$BIN_READ" --session "$sid_none" --stage detail)
    if [ "$first" = "$last" ]; then
        fail "DF-4 unattributable: a recorded and an unrecorded session read back identically ($first)"
    else
        dup=$(d2099df_run "$BIN_READ" --session "$sid" --session "$sid_none" --stage detail)
        dup2=$(d2099df_run "$BIN_READ" --session "$sid" --session "$sid_none" --stage detail)
        d2099df_assert "DF-4 read-complexity-evaluation --session twice" "$dup" "$dup2" "$first" "$last" "clean"
    fi
}

# --- DF-5/DF-6: derive-complexity-level --------------------------------------
# Stateless, so this is purely the parser. Pre-implementation the binary is
# absent, both arms report the same non-zero loader error and the baselines
# collapse — which is an explicit FAIL naming that error, never a skip: a skip
# here would be the silent opt-out that hides the CLI still being missing.
d2099df_derive_flags() {
    local id="$1" flag="$2" v_first="$3" v_last="$4"
    shift 4
    local first last dup dup2
    first=$(d2099df_run "$BIN_DERIVE" "$@" "$flag" "$v_first")
    last=$(d2099df_run "$BIN_DERIVE" "$@" "$flag" "$v_last")
    if [ "$first" = "$last" ]; then
        fail "$id unattributable: both single-flag baselines of derive-complexity-level $flag answer identically ($first), so the duplicate cannot be resolved either way"
        return
    fi
    dup=$(d2099df_run "$BIN_DERIVE" "$@" "$flag" "$v_first" "$flag" "$v_last")
    dup2=$(d2099df_run "$BIN_DERIVE" "$@" "$flag" "$v_first" "$flag" "$v_last")
    d2099df_assert "$id derive-complexity-level $flag twice" "$dup" "$dup2" "$first" "$last" "clean"
}

# --- DF-7: record-complexity-and-skip ----------------------------------------
# The bash wrapper does its own presence detection (detail.md item 11), so it
# owns a SECOND parser: a duplicate resolved here differently than by the node
# CLI it delegates to is a split-brain contract, invisible to either suite alone.
d2099df_wrapper_signals() {
    local first last dup dup2
    : > "$D2099DF_WHY"
    first=$(d2099df_baseline dfwrap-a "$BIN_RECORD_SKIP" --signals "$D2099DF_A" --target outline)
    last=$(d2099df_baseline dfwrap-b "$BIN_RECORD_SKIP" --signals "$D2099DF_B" --target outline)
    if [ "$first" = "$last" ]; then
        fail "DF-7 unattributable: the wrapper's two baseline signal sets read back identically ($first) — $(d2099df_why)"
        return
    fi
    dup=$(d2099df_dup_write dfwrap-dup "$BIN_RECORD_SKIP" --signals "$D2099DF_A" --signals "$D2099DF_B" --target outline)
    dup2=$(d2099df_dup_write dfwrap-dup2 "$BIN_RECORD_SKIP" --signals "$D2099DF_A" --signals "$D2099DF_B" --target outline)
    d2099df_assert "DF-7 record-complexity-and-skip --signals twice" \
        "${dup%|*}" "${dup2%|*}" "$first" "$last" "${dup##*|}"
}

d2099df_record_signals
d2099df_two_session_write "DF-2 record-complexity-evaluation" "$BIN_RECORD" --signals "$D2099DF_B"
d2099df_read_flags
d2099df_derive_flags "DF-5" --stage detail write_code --signals "$D2099DF_A"
d2099df_derive_flags "DF-6" --signals "S2-architecture" "" --stage detail
d2099df_wrapper_signals
d2099df_two_session_write "DF-8 record-complexity-and-skip" "$BIN_RECORD_SKIP" --signals "$D2099DF_B" --target outline
