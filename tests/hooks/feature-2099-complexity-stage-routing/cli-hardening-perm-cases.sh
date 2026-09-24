#!/bin/bash
# tests/feature-2099-complexity-stage-routing/cli-hardening-perm-cases.sh
# Tests: bin/workflow/record-complexity-evaluation, bin/workflow/read-complexity-evaluation, bin/workflow/record-complexity-and-skip
# Tags: complexity, routing, cli, permissions, hardening, scope:issue-specific
# Sourced by ../feature-2099-complexity-stage-routing.sh — helpers come from there.
# The H-PERM family, split out of cli-hardening-cases.sh at the 500-line HARD
# limit (rules/coding/file-split.md Pattern A). One axis: what the writers do
# when the filesystem refuses the write they were told to make — loudly, or by
# reporting a success that never landed.

# The disk says no at WRITE time, not at open-the-directory time (H-ENV).
d2099h_perm_probe() {
    local f="$TMPDIR_BASE/perm-probe.txt"
    printf 'locked\n' > "$f"
    chmod 444 "$f" 2>/dev/null || { echo "no-chmod"; return; }
    if printf 'overwritten\n' >> "$f" 2>/dev/null; then echo "not-enforced"; else echo "enforced"; fi
    chmod 644 "$f" 2>/dev/null || true
}

# One write through whichever writer CLI is under test, with that CLI's own
# interpreter and required arguments. `record-complexity-and-skip` is a bash
# script: run through `node` it dies on a syntax error before touching the disk,
# and "non-zero exit, nothing written" would then be true of every permission
# case for the wrong reason — Node's parser, not the wrapper's error handling.
d2099h_write_invoke() {
    local bin="$1" sid="$2" signals="$3" runner
    runner=$(d2099_cli_runner "$bin")
    case "$bin" in
        "$BIN_RECORD_SKIP")
            run_with_timeout "$runner" "$bin" --session "$sid" \
                --signals "$signals" --target outline 2>&1 ;;
        *)
            run_with_timeout "$runner" "$bin" --session "$sid" --signals "$signals" 2>&1 ;;
    esac
}

# H-PERM: both writer CLIs must fail loudly on an unwritable EXISTING state file,
# leave its bytes intact and print no receipt; the reader stays fail-open.
d2099h_readonly_state_file() {
    local bin sid p before rc out enforced
    enforced=$(d2099h_perm_probe)
    if [ "$enforced" != "enforced" ]; then
        skip "H-PERM read-only state file — this platform does not enforce chmod 444 on files ($enforced)"

        # SKIPPED: a record onto a state file the process cannot write
        # Because: the filesystem here ignores the read-only bit, so the case
        #   would assert on a write that always succeeds — a false green.
        # L3 gap: only a POSIX CI runner shows whether the writer reports the
        #   EACCES or reports success on a record that never landed.
        return
    fi

    for bin in "$BIN_RECORD" "$BIN_RECORD_SKIP"; do
        sid=$(new_session perm)
        # S2-architecture, because H-PERM-6 below reads `--stage detail` and
        # wants the pre-existing record to come back HIGH. S2 is detail's
        # solo_escalation; S1-multi-file escalates write_code only, so detail
        # would read back low (detail.md D2) and the assertion would fail for a
        # routing reason rather than a permission one.
        run_with_timeout node "$BIN_RECORD" --session "$sid" --signals "S2-architecture" >/dev/null 2>&1
        p="$WORKFLOW_DIR/$sid.json"
        if [ ! -f "$p" ]; then
            fail "H-PERM [$(basename "$bin")] unattributable: no state file at $p to make read-only"
            continue
        fi
        before=$(cksum < "$p")
        chmod 444 "$p" 2>/dev/null || true

        rc=0
        out=$(d2099h_write_invoke "$bin" "$sid" "S3-security") || rc=$?
        chmod 644 "$p" 2>/dev/null || true
        if [ "$rc" -ne 0 ]; then
            pass "H-PERM-1 [$(basename "$bin")] a record onto an unwritable state file exits non-zero ($rc)"
        else
            fail "H-PERM-1 [$(basename "$bin")] a record onto an unwritable state file exited 0 — a lost evaluation reported as success"
        fi
        assert_not_contains "H-PERM-2 [$(basename "$bin")] ... and prints no success receipt" \
            "RECORDED_COMPLEXITY" "$out"
        assert_eq "H-PERM-3 [$(basename "$bin")] ... leaving the earlier record byte-identical" \
            "$before" "$(cksum < "$p")"
        if [ -n "$(printf '%s' "$out" | tr -d '[:space:]')" ]; then
            pass "H-PERM-4 [$(basename "$bin")] ... and says something diagnostic"
        else
            fail "H-PERM-4 [$(basename "$bin")] ... but produced NO diagnostic output at all"
        fi

        # The reader is fail-open: an unwritable file is still readable, so the
        # earlier evaluation must come back rather than degrade to NONE.
        chmod 444 "$p" 2>/dev/null || true
        rc=0
        out=$(run_with_timeout node "$BIN_READ" --session "$sid" --stage detail 2>/dev/null) || rc=$?
        chmod 644 "$p" 2>/dev/null || true
        assert_eq "H-PERM-5 [$(basename "$bin")] read still exits 0 over a read-only state file" "0" "$rc"
        assert_eq "H-PERM-6 [$(basename "$bin")] ... returning the record that was already there" \
            "level=high" "$(printf '%s\n' "$out" | head -1)"
    done
}

# --- H-PERM-CREATE: the first-ever write, denied at the FILE ------------------
# The creation path is the one H-PERM cannot reach: there, a record already
# exists. A read-only directory would express it, but this platform ignores
# directory mode (block below), while it does enforce the file bit — so the
# target path is pre-created empty and read-only. The wrapper's first write for
# that session is then a create-shaped write onto a path it cannot touch.
d2099h_creation_denied_file() {
    local sid p rc out before enforced ctl_sid ctl_rc=0
    enforced=$(d2099h_perm_probe)
    if [ "$enforced" != "enforced" ]; then
        skip "H-PERM-CREATE unwritable creation target — this platform does not enforce chmod 444 on files ($enforced)"
        return
    fi

    # Sanctioned half first: the same call on a writable path must SUCCEED, or
    # the denial below proves nothing about permissions.
    ctl_sid=$(new_session permcreatectl)
    out=$(d2099h_write_invoke "$BIN_RECORD_SKIP" "$ctl_sid" "S1-multi-file") || ctl_rc=$?
    if [ "$ctl_rc" -ne 0 ]; then
        fail "H-PERM-CREATE-0 unattributable: record-complexity-and-skip fails on a WRITABLE state path too (exit $ctl_rc), so a denial below would prove nothing about permissions. Output: [$out]"
        return
    fi
    pass "H-PERM-CREATE-0 record-complexity-and-skip succeeds on a writable state path (control)"

    sid="s2099-permcreate-$$-$RANDOM"
    p="$WORKFLOW_DIR/$sid.json"
    : > "$p"
    before=$(cksum < "$p")
    chmod 444 "$p" 2>/dev/null || true
    rc=0
    out=$(d2099h_write_invoke "$BIN_RECORD_SKIP" "$sid" "S3-security") || rc=$?
    chmod 644 "$p" 2>/dev/null || true

    if [ "$rc" -ne 0 ]; then
        pass "H-PERM-CREATE-1 record-complexity-and-skip exits non-zero when its target state file cannot be written ($rc)"
    else
        fail "H-PERM-CREATE-1 record-complexity-and-skip exited 0 onto an unwritable target — a skip judgment reported as recorded but never stored"
    fi
    assert_not_contains "H-PERM-CREATE-2 ... and prints no success receipt" "RECORDED_COMPLEXITY" "$out"
    assert_eq "H-PERM-CREATE-3 ... leaving the unwritable target byte-identical" "$before" "$(cksum < "$p")"
    if [ -n "$(printf '%s' "$out" | tr -d '[:space:]')" ]; then
        pass "H-PERM-CREATE-4 ... and says something diagnostic"
    else
        fail "H-PERM-CREATE-4 ... but produced NO diagnostic output at all"
    fi
}

# --- H-PERM-READ: the read side of the same axis ------------------------------
# H-PERM above denies the WRITE and keeps the file readable. The opposite denial
# — a state file that exists and is valid but cannot be OPENED (EACCES on read,
# the shape an `su`-created or umask-hostile file takes) — is a different code
# path in the reader: not "no record" (ENOENT) and not "bad record" (parse
# error), but "the record is there and I am not allowed to see it". detail.md
# D5 makes the reader fail-open, so the contract is NONE + exit 0, and the
# hazard is a reader that instead crashes the consumer, or that reports the
# EACCES by pasting the path/contents it just failed to read.
d2099h_unreadable_probe() {
    local f="$TMPDIR_BASE/perm-read-probe.txt"
    printf 'locked\n' > "$f"
    chmod 000 "$f" 2>/dev/null || { echo "no-chmod"; chmod 644 "$f" 2>/dev/null || true; return; }
    if cat "$f" >/dev/null 2>&1; then echo "not-enforced"; else echo "enforced"; fi
    chmod 644 "$f" 2>/dev/null || true
}

d2099h_unreadable_state_file() {
    local sid p before after rc out err enforced canary="S6-long-plan"
    enforced=$(d2099h_unreadable_probe)
    if [ "$enforced" != "enforced" ]; then
        skip "H-PERM-READ unreadable state file — this platform does not enforce chmod 000 on files ($enforced)"

        # SKIPPED: a read of a state file the process may not open
        # Because: the filesystem here (MINGW64/Windows, or a root-owned runner)
        #   grants the read anyway, so the case would assert on a successful
        #   open — the NONE fallback would never be exercised.
        # L3 gap: only a POSIX CI runner shows whether the reader fails open to
        #   NONE or propagates the EACCES to the consumer.
        return
    fi

    sid=$(new_session permunread)
    run_with_timeout node "$BIN_RECORD" --session "$sid" \
        --signals "S2-architecture,$canary" >/dev/null 2>&1
    p="$WORKFLOW_DIR/$sid.json"
    if [ ! -f "$p" ]; then
        fail "H-PERM-READ unattributable: no state file at $p to make unreadable"
        return
    fi
    before=$(cksum < "$p")
    chmod 000 "$p" 2>/dev/null || true

    rc=0
    out=$(run_with_timeout node "$BIN_READ" --session "$sid" --stage detail 2>"$TMPDIR_BASE/permread.err") || rc=$?
    err=$(cat "$TMPDIR_BASE/permread.err" 2>/dev/null)
    chmod 644 "$p" 2>/dev/null || true
    after=$(cksum < "$p")

    assert_eq "H-PERM-READ-1 read exits 0 over a state file it cannot open — the consumer is not crashed by a permission bit" \
        "0" "$rc"
    assert_eq "H-PERM-READ-2 ... and fails open to the documented NONE, not a level it could not have read" \
        "NONE" "$(printf '%s\n' "$out" | head -1)"
    # Leakage: the reader never got the bytes, so anything from inside the file
    # appearing on either stream means it read (or guessed) what it must not.
    assert_not_contains "H-PERM-READ-3 ... leaking no stored signal id into stdout" "$canary" "$out"
    assert_not_contains "H-PERM-READ-3b ... nor into stderr" "$canary" "$err"
    assert_not_contains "H-PERM-READ-3c ... nor any raw state-record field name" "complexity_evaluation" "$out$err"
    assert_eq "H-PERM-READ-4 ... and leaves the file's bytes exactly as they were" "$before" "$after"
}

# SKIPPED: a record into a state DIRECTORY that denies creation (chmod 555)
# Because: this platform (MINGW64 on Windows) does not enforce directory mode —
#   an empirical probe created a file inside a 555 dir without error, so the
#   case can only ever pass vacuously here.
# L3 gap: a POSIX CI runner would show whether a first-ever record for a session
#   (no state file yet, so the write is a CREATE) fails loudly or reports success.
d2099h_readonly_state_dir_gap() {
    skip "H-PERM-DIR record into a creation-denying state directory — see the Skipped-Because block above"
}

d2099h_readonly_state_file
d2099h_unreadable_state_file
d2099h_creation_denied_file
d2099h_readonly_state_dir_gap
