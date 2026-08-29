#!/bin/bash
# tests/feature-2099-complexity-stage-routing/signals-file-security-cases.sh
# Tests: bin/workflow/record-complexity-evaluation, bin/workflow/derive-complexity-level, bin/workflow/record-complexity-and-skip, hooks/workflow-state/complexity-routing.js
# Tags: complexity, routing, cli, security, signals-file, path-traversal, secret-leakage, adversarial, scope:issue-specific
# Sourced by ../feature-2099-complexity-stage-routing.sh AFTER traversal-attack-cases.sh (d2099t_snapshot comes from there).
# --signals-file is the only #2099 arg handed to fs.readFileSync, so it is the only
# one where a path decides which bytes get read, echoed and persisted. SF-1..SF-25
# are the path axis (CWE-22/CWE-78); SF-26.. the secret-leakage axis (OWASP ASVS
# V8) that LI-6 cannot reach, every LI-6 payload being dropped by the sanitizer.
# lang-check: ignore -- SF-9 fixture path deliberately includes non-ASCII (Japanese) text

D2099SF_OUT="$TMPDIR_BASE/sf-outside"
# Unique per run so a hit is unambiguous, and shaped to survive canonicalization:
# a marker the sanitizer strips for free would make every "never disclosed"
# assertion below green regardless of the code.
D2099SF_CANARY="SF_OUTSIDE_CANARY_CONTENT_d2099_$$_$RANDOM"
D2099SF_SECRET="sk-d2099FAKEnotarealkey0123456789abcd"

d2099sf_setup() {
    mkdir -p "$D2099SF_OUT/nested"
    printf '%s\n' "$D2099SF_CANARY" > "$D2099SF_OUT/canary.txt"
    printf '%s\n' "$D2099SF_SECRET" > "$D2099SF_OUT/nested/secret.txt"
}

# Does this filesystem enforce an unreadable file? Windows runners ignore chmod
# 000, and a case built on it would assert on a read that always succeeds — the
# same false green cli-hardening-perm-cases.sh guards against.
d2099sf_unreadable_probe() {
    local f="$TMPDIR_BASE/sf-unreadable-probe.txt"
    printf 'x\n' > "$f"
    chmod 000 "$f" 2>/dev/null || { echo "no-chmod"; return; }
    if cat "$f" >/dev/null 2>&1; then echo "not-enforced"; else echo "enforced"; fi
    chmod 644 "$f" 2>/dev/null || true
}

# One --signals-file invocation of one CLI, with that CLI's OWN interpreter
# (record-complexity-and-skip is bash; through `node` it dies on a syntax error
# before its validation runs) and that CLI's own required arguments. Sets
# D2099SF_RC / D2099SF_TEXT rather than printing, so stdout+stderr stay whole.
D2099SF_RC=0
D2099SF_TEXT=""
d2099sf_invoke() {
    local bin="$1" sid="$2" p="$3" runner
    runner=$(d2099_cli_runner "$bin")
    D2099SF_RC=0
    case "$bin" in
        "$BIN_DERIVE")
            D2099SF_TEXT=$(run_with_timeout "$runner" "$bin" --stage detail --signals-file "$p" 2>&1) || D2099SF_RC=$? ;;
        "$BIN_RECORD_SKIP")
            D2099SF_TEXT=$(run_with_timeout "$runner" "$bin" --session "$sid" \
                --signals-file "$p" --target outline 2>&1) || D2099SF_RC=$? ;;
        *)
            D2099SF_TEXT=$(run_with_timeout "$runner" "$bin" --session "$sid" --signals-file "$p" 2>&1) || D2099SF_RC=$? ;;
    esac
}

# Attribution guard (test-design.md classifier/guard): a CLI that refuses EVERY
# --signals-file refuses the hostile ones for free. Identical call path, ordinary
# in-scope file — so a green reject corpus means validation, not a dead runner.
d2099sf_control() {
    local bin="$1" sid f
    f="$WORKFLOW_PLANS_DIR/sf-control-signals.txt"
    printf 'S2-architecture' > "$f"
    sid=$(new_session sfctl)
    d2099sf_invoke "$bin" "$sid" "$f"
    if [ "$D2099SF_RC" -eq 0 ]; then echo "yes"; else echo "no rc=$D2099SF_RC out=[$D2099SF_TEXT]"; fi
}

# --- SF-1: the hostile-path reject corpus ------------------------------------
# What this corpus pins is the OBSERVED refusal — non-zero exit, no receipt, no
# event, no disclosure — NOT the existence of a traversal validator: the CLIs
# hold no allowlist, and these paths are refused by readFileSync's own errno.
# Absolute-out-of-scope and symlink-out-of-scope are therefore deliberately
# ABSENT: those files ARE read and their contents disclosed, so an assertion
# here would pin vulnerable behavior as correct. SF-32 reports that gap instead.
d2099sf_corpus() {
    printf '%s\n' \
        "nonexistent|$TMPDIR_BASE/sf-absent-$RANDOM.txt" \
        "traversal-rel|../../d2099-sf-no-such-dir/absent.txt" \
        "traversal-deep|$TMPDIR_BASE/sf-outside/../../../d2099-sf-absent.txt" \
        "directory|$D2099SF_OUT" \
        "directory-nested|$D2099SF_OUT/nested" \
        "empty-path|"
}

d2099sf_reject_corpus() {
    local bin="$1" tag label p ctl sid before_wf before_out after_out
    ctl=$(d2099sf_control "$bin")
    tag=$(basename "$bin")
    assert_eq "SF-CTL [$tag] control: an ordinary in-scope signals file is accepted" "yes" "$ctl"

    d2099sf_setup
    before_wf=$(d2099t_snapshot "$WORKFLOW_DIR")
    before_out=$(d2099t_snapshot "$D2099SF_OUT")

    while IFS='|' read -r label p; do
        [ -n "$label" ] || continue
        sid=$(new_session "sf-$label")
        d2099sf_invoke "$bin" "$sid" "$p"

        if [ "$D2099SF_RC" -eq 0 ]; then
            fail "SF-1-$label [$tag] ACCEPTED a --signals-file that names no readable file: [$p] — output: [$D2099SF_TEXT]"
        elif [ "$ctl" != "yes" ]; then
            fail "SF-1-$label [$tag] unattributable: an ordinary signals file is rejected too, so [$p] proves no validation"
        else
            pass "SF-1-$label [$tag] rejects [$p] (exit $D2099SF_RC)"
        fi

        assert_not_contains "SF-2-$label [$tag] ... printing no success receipt" \
            "RECORDED_COMPLEXITY" "$D2099SF_TEXT"
        # The errno diagnostic may name the PATH the caller already chose; it must
        # never carry a byte of any file's CONTENT.
        assert_not_contains "SF-3-$label [$tag] ... and disclosing no out-of-tree file content" \
            "$D2099SF_CANARY" "$D2099SF_TEXT"
        assert_not_contains "SF-3s-$label [$tag] ... nor the secret stored beside it" \
            "$D2099SF_SECRET" "$D2099SF_TEXT"
        assert_eq "SF-4-$label [$tag] ... leaving that session with no evaluation event" \
            "ce=0 skip=0" "$(d2099_side_effects "$sid")"
    done < <(d2099sf_corpus)

    after_out=$(d2099t_snapshot "$D2099SF_OUT")
    # Sessions are seeded inside the loop, so the state dir legitimately grows;
    # what must not change is the out-of-tree tree the hostile paths pointed at.
    assert_eq "SF-5 [$tag] the out-of-tree canary tree is byte-identical after the whole reject corpus" \
        "$before_out" "$after_out"
    if [ -z "$(grep -rl -- "$D2099SF_CANARY" "$WORKFLOW_DIR" "$WORKFLOW_PLANS_DIR" 2>/dev/null)" ]; then
        pass "SF-6 [$tag] no file under the state or plans dir holds the out-of-tree canary after the reject corpus"
    else
        fail "SF-6 [$tag] a rejected --signals-file read still landed the out-of-tree canary on disk"
    fi
    assert_not_contains "SF-7 [$tag] unattributable check: the state dir snapshot was non-empty before the corpus" \
        "__NO_DIR__" "$before_wf"
}

# --- SF-8: unreadable file (POSIX only) --------------------------------------
d2099sf_unreadable() {
    local bin tag sid f enforced before
    enforced=$(d2099sf_unreadable_probe)
    if [ "$enforced" != "enforced" ]; then
        skip "SF-8 unreadable --signals-file — this platform does not enforce chmod 000 on files ($enforced)"

        # SKIPPED: a --signals-file the process may stat but not read
        # Because: the filesystem here ignores the mode bits, so the CLI reads
        #   the file successfully and the case would assert nothing.
        # TL3 gap: only a POSIX runner shows whether EACCES is reported as a
        #   refusal or swallowed into a silent zero-signal record.
        return
    fi
    f="$TMPDIR_BASE/sf-locked-signals.txt"
    printf '%s\n' "$D2099SF_SECRET" > "$f"
    chmod 000 "$f" 2>/dev/null || true
    for bin in "$BIN_RECORD" "$BIN_DERIVE" "$BIN_RECORD_SKIP"; do
        tag=$(basename "$bin")
        sid=$(new_session sflock)
        before=$(d2099_side_effects "$sid")
        d2099sf_invoke "$bin" "$sid" "$f"
        if [ "$D2099SF_RC" -ne 0 ]; then
            pass "SF-8 [$tag] an unreadable --signals-file is refused (exit $D2099SF_RC)"
        else
            fail "SF-8 [$tag] an unreadable --signals-file was accepted (exit 0) — output: [$D2099SF_TEXT]"
        fi
        assert_not_contains "SF-9 [$tag] ... with the EACCES diagnostic disclosing none of the file's bytes" \
            "$D2099SF_SECRET" "$D2099SF_TEXT"
        assert_eq "SF-10 [$tag] ... and no evaluation appended as a side effect of the refused read" \
            "$before" "$(d2099_side_effects "$sid")"
    done
    chmod 644 "$f" 2>/dev/null || true
}

# --- SF-11: the sanctioned half (CPR-ORTH) -----------------------------------
# A validator written as a blunt "reject anything unusual" would pass every case
# above while breaking a real PLANS_DIR under a home directory with spaces in it.
d2099sf_sanctioned_paths() {
    local dir f sid lvl out rc
    dir="$WORKFLOW_PLANS_DIR/Ana Lopez/complexity signals/2099 (v2)/deep/nest"
    if ! mkdir -p "$dir" 2>/dev/null; then
        skip "SF-11 this filesystem refuses the space-bearing nested plans directory, so the sanctioned-path control cannot be staged here"
        return
    fi
    f="$dir/session complexity signals.txt"
    printf 'S2-architecture' > "$f"

    sid=$(new_session sfok)
    rc=0
    out=$(run_with_timeout node "$BIN_RECORD" --session "$sid" --signals-file "$f" 2>&1) || rc=$?
    assert_eq "SF-11 record-complexity-evaluation accepts a deeply nested, space-bearing in-scope signals file (exit 0)" "0" "$rc"
    assert_contains "SF-12 ... printing the documented receipt for the signal that file held" \
        "RECORDED_COMPLEXITY level=high signals=S2-architecture" "$out"
    assert_eq "SF-13 ... having appended exactly one evaluation" "ce=1 skip=0" "$(d2099_side_effects "$sid")"
    lvl=$(run_with_timeout node "$BIN_READ" --session "$sid" --stage detail 2>/dev/null | head -1)
    assert_eq "SF-14 ... which reads back at the level that signal implies" "level=high" "$lvl"

    rc=0
    out=$(run_with_timeout node "$BIN_DERIVE" --stage detail --signals-file "$f" 2>&1) || rc=$?
    assert_eq "SF-15 derive-complexity-level answers from the same awkward in-scope path (exit 0)" "0" "$rc"
    assert_eq "SF-16 ... in the documented level= protocol" "level=high" "$(printf '%s\n' "$out" | head -1)"

    sid=$(new_session sfokw)
    rc=0
    out=$(run_with_timeout bash "$BIN_RECORD_SKIP" --session "$sid" \
        --signals-file "$f" --target outline 2>/dev/null) || rc=$?
    assert_eq "SF-17 record-complexity-and-skip resolves that path too, on a clean exit" "0" "$rc"
    assert_eq "SF-18 ... answering with the skip mode and nothing else on stdout" "judgment" "$out"
}

# --- SF-19: a filename that LOOKS like a command ------------------------------
# The path is the vector here, not the content: an unquoted expansion of
# "$SIGNALS_FILE" anywhere in the bash wrapper would run these substitutions.
# `"` `\` `*` `?` `<` `>` `|` `:` are omitted — Windows rejects them in a filename.
d2099sf_metacharacter_filename() {
    local dir f sid rc out pwned
    dir="$WORKFLOW_PLANS_DIR/sf-meta"
    mkdir -p "$dir" 2>/dev/null || true
    # The canary targets are BARE names, never absolute: a `/` inside a filename
    # is not a filename at all, and staging would fail for a reason unrelated to
    # the CLIs. Executed, they land in whatever directory the wrapper ran from —
    # so the sweep below covers the fixture root and that directory both.
    f="$dir/sig \$(touch sf-pwned-a) \`touch sf-pwned-b\` ;touch sf-pwned-c& 日本語 (v2) '"'"'q'"'"' #1.txt"
    if ! printf 'S2-architecture' > "$f" 2>/dev/null; then
        skip "SF-19 this filesystem refuses the metacharacter/Unicode signals-file name, so the execution canary cannot be staged here"
        return
    fi

    sid=$(new_session sfmeta)
    rc=0
    # to_node_path, as every other case that hands a fixture path to node does:
    # MSYS argument mangling declines to translate a POSIX path carrying `;`/`&`/
    # backticks, and the untranslated form dies with ENOENT before the CLI's own
    # handling is reached — a failure about the shell bridge, not about the CLI.
    out=$(cd "$dir" && run_with_timeout bash "$BIN_RECORD_SKIP" --session "$sid" \
        --signals-file "$(to_node_path "$f")" --target outline 2>&1) || rc=$?
    assert_eq "SF-19 the wrapper reads a signals file whose NAME carries shell metacharacters (exit 0)" "0" "$rc"
    assert_contains "SF-20 ... treating the name as a path and the file's content as the signal list" \
        "RECORDED_COMPLEXITY level=high signals=S2-architecture" "$out"
    pwned=$(find "$TMPDIR_BASE" "$dir" -name 'sf-pwned-*' 2>/dev/null | head -5)
    assert_eq "SF-21 ... with no command substitution embedded in that name ever executed" "" "$pwned"
}

# --- SF-33: an EMPTY in-scope file is the zero-signal input, not an error -----
# The path edge that sits between the two verdicts: readable, in scope, and
# carrying nothing. `--signals ""` is documented as valid zero-signal input, so
# its by-file twin must route the same way rather than fail or escalate.
d2099sf_empty_file() {
    local f sid rc out
    f="$WORKFLOW_PLANS_DIR/sf-empty-signals.txt"
    : > "$f"

    sid=$(new_session sfempty)
    rc=0
    out=$(run_with_timeout node "$BIN_RECORD" --session "$sid" --signals-file "$f" 2>&1) || rc=$?
    assert_eq "SF-33 record-complexity-evaluation accepts an empty in-scope signals file (exit 0)" "0" "$rc"
    assert_contains "SF-34 ... recording it as the zero-signal evaluation" \
        "RECORDED_COMPLEXITY level=low signals=" "$out"
    assert_eq "SF-35 ... having appended exactly one evaluation" "ce=1 skip=0" "$(d2099_side_effects "$sid")"

    rc=0
    out=$(run_with_timeout node "$BIN_DERIVE" --stage detail --signals-file "$f" 2>&1) || rc=$?
    assert_eq "SF-36 derive-complexity-level reads the same empty file without erroring (exit 0)" "0" "$rc"
    assert_eq "SF-37 ... routing zero signals to the low level, not escalating on absence" \
        "level=low" "$(printf '%s\n' "$out" | head -1)"
}

# --- SF-22: rejected reads are idempotent ------------------------------------
# A refused read must be refused the SAME way every time and accumulate no temp
# or lock artifacts — the shape a retry loop would amplify into a disclosure surface.
d2099sf_reject_idempotency() {
    local sid p first n before_files after_files i
    p="$D2099SF_OUT"
    sid=$(new_session sfidem)
    before_files=$(find "$WORKFLOW_DIR" -type f 2>/dev/null | wc -l | tr -d ' ')
    d2099sf_invoke "$BIN_RECORD" "$sid" "$p"
    first="rc=$D2099SF_RC"
    for i in 2 3; do
        d2099sf_invoke "$BIN_RECORD" "$sid" "$p"
        assert_eq "SF-22 repetition $i of the refused read exits identically" "$first" "rc=$D2099SF_RC"
    done
    assert_eq "SF-23 three refused reads left the session with no evaluation event" \
        "ce=0 skip=0" "$(d2099_side_effects "$sid")"
    after_files=$(find "$WORKFLOW_DIR" -type f 2>/dev/null | wc -l | tr -d ' ')
    assert_eq "SF-24 ... and no temp or lock artifact beside the state file" "$before_files" "$after_files"
    n=$(find "$WORKFLOW_DIR" "$WORKFLOW_PLANS_DIR" \( -name '*.tmp' -o -name '*.lock' \) 2>/dev/null | wc -l | tr -d ' ')
    assert_eq "SF-25 ... nor any stray .tmp/.lock under the fixture roots" "0" "$n"
}

# --- SF-26: secret leakage, the half that actually holds (OWASP ASVS V8) -----
# A plain single-line secret-SHAPED token — no control character, no receipt
# marker — is the input LI-6 never tries, so LI-6 stays green whether or not real
# protection exists. The stateless deriver is the boundary that genuinely holds.
d2099sf_secret_containment() {
    local f sid rc out
    d2099sf_setup
    f="$WORKFLOW_PLANS_DIR/sf-secret-signals.txt"
    printf 'S2-architecture,%s' "$D2099SF_SECRET" > "$f"

    rc=0
    out=$(run_with_timeout node "$BIN_DERIVE" --stage detail \
        --signals "S2-architecture,$D2099SF_SECRET" 2>&1) || rc=$?
    assert_not_contains "SF-26 derive never echoes a secret-shaped --signals token into its answer or diagnostics (rc=$rc)" \
        "$D2099SF_SECRET" "$out"
    assert_eq "SF-27 ... still answering in the documented level= protocol" "level=high" "$(printf '%s\n' "$out" | head -1)"

    rc=0
    out=$(run_with_timeout node "$BIN_DERIVE" --stage detail --signals-file "$f" 2>&1) || rc=$?
    assert_not_contains "SF-28 ... and none either when the same token arrives by --signals-file (rc=$rc)" \
        "$D2099SF_SECRET" "$out"

    # The wrapper's stdout is the channel callers capture into SKIP_MODE. The
    # delegate's receipt is redirected to stderr precisely so it cannot
    # contaminate that capture; this pins the separation for a secret-shaped token.
    sid=$(new_session sfsecret)
    rc=0
    out=$(run_with_timeout bash "$BIN_RECORD_SKIP" --session "$sid" \
        --signals-file "$f" --target outline 2>/dev/null) || rc=$?
    assert_eq "SF-29 the wrapper's stdout channel carries only the skip mode" "judgment" "$out"
    assert_not_contains "SF-30 ... so a secret-shaped token in the signals file never reaches the SKIP_MODE capture" \
        "$D2099SF_SECRET" "$out"
}

# --- SF-31: the disclosure gaps this suite must NOT pin as correct -----------
# Reported rather than asserted (test-design.md: never assert vulnerable
# behavior as if it were the contract). Each line names an exact reproduction.
d2099sf_disclosure_gap() {
    local sid rc out state
    sid=$(new_session sfsecretrec)
    rc=0
    out=$(run_with_timeout node "$BIN_RECORD" --session "$sid" \
        --signals "S2-architecture,$D2099SF_SECRET" 2>&1) || rc=$?
    assert_eq "SF-31 record-complexity-evaluation accepts a secret-shaped --signals token (exit 0)" "0" "$rc"
    assert_not_contains "SF-31b ... without echoing it in the RECORDED_COMPLEXITY receipt (#2099 Finding A)" \
        "$D2099SF_SECRET" "$out"
    state=$(cat "$WORKFLOW_DIR/$sid.json" 2>/dev/null || true)
    assert_not_contains "SF-31c ... nor persisting it verbatim in the session's state file" \
        "$D2099SF_SECRET" "$state"

    skip "SF-32 --signals-file accepts any absolute path and follows symlinks out of PLANS_DIR: the record CLI reads a single-line out-of-tree file and both echoes and persists its content as a signal. No allowlist, prefix check or realpath containment guards that argument, so the absolute-path and symlink cases are omitted from the SF-1 corpus."
}

d2099sf_reject_corpus "$BIN_RECORD"
d2099sf_reject_corpus "$BIN_DERIVE"
d2099sf_reject_corpus "$BIN_RECORD_SKIP"
d2099sf_unreadable
d2099sf_sanctioned_paths
d2099sf_metacharacter_filename
d2099sf_empty_file
d2099sf_reject_idempotency
d2099sf_secret_containment
d2099sf_disclosure_gap
