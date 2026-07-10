# shellcheck shell=bash
# Tests: hooks/workflow-run-tests.js
# Tags: workflow, tests, runner, hook, error-and-edge-control, scope:common
# Case group: Control-structure / env-prefix / multiline / quoted-path edge
# cases (ED22 onward), plus git global-option and single-quote sentinel
# exclusion cases (FIX 1 / FIX 2, #1330).
# Sourced by main-workflow-run-tests.sh; relies on helpers from common.sh.

run_error_and_edge_control_tests() {
    echo ""
    echo "=== workflow-run-tests: Edge cases (control-structure / env-prefix) ==="

    # ED22: FOO=1 pytest tests/ + exit=0 → run_tests: pending
    # (env-prefix stripped: 'FOO=1' resolved to 'pytest', which is a test runner)
    SID="ed22-$$-$RANDOM"
    seed_write_tests "$SID" "complete"
    run_run_tests_hook 'FOO=1 pytest tests/' 0 "$SID"
    STATUS=$(get_run_tests_status "$SID")
    if [ "$STATUS" = "pending" ]; then
        pass "ED22. FOO=1 pytest tests/ + exit=0 → run_tests=pending (env-prefix stripped: pytest detected)"
    else
        fail "ED22. FOO=1 pytest tests/ + exit=0 → expected pending, got: $STATUS"
    fi

    # ED23: if false; then pytest tests/; fi + exit=0 → run_tests: pending
    # (then body keyword stripped: pytest in then body IS a test command)
    SID="ed23-$$-$RANDOM"
    seed_write_tests "$SID" "complete"
    run_run_tests_hook 'if false; then pytest tests/; fi' 0 "$SID"
    STATUS=$(get_run_tests_status "$SID")
    if [ "$STATUS" = "pending" ]; then
        pass "ED23. if false; then pytest tests/; fi + exit=0 → run_tests=pending (then-body detection: pytest detected)"
    else
        fail "ED23. if false; then pytest tests/; fi + exit=0 → expected pending, got run_tests=$STATUS"
    fi

    # ED24: until pytest tests/; do : ; done + exit=0 → run_tests: pending
    # (until condition header stripped: pytest in condition IS a test command)
    SID="ed24-$$-$RANDOM"
    seed_write_tests "$SID" "complete"
    run_run_tests_hook 'until pytest tests/; do : ; done' 0 "$SID"
    STATUS=$(get_run_tests_status "$SID")
    if [ "$STATUS" = "pending" ]; then
        pass "ED24. until pytest tests/; do : ; done + exit=0 → run_tests=pending (until condition: pytest detected)"
    else
        fail "ED24. until pytest tests/; do : ; done + exit=0 → expected pending, got run_tests=$STATUS"
    fi

    # ED59: while pytest tests/; do : ; done + exit=0 → run_tests: pending
    # (while condition header stripped: pytest in condition IS a test command;
    #  symmetric positive to ED24's until-header case — CONTROL_COND_HEADER penetration)
    SID="ed59-$$-$RANDOM"
    seed_write_tests "$SID" "complete"
    run_run_tests_hook 'while pytest tests/; do :; done' 0 "$SID"
    STATUS=$(get_run_tests_status "$SID")
    if [ "$STATUS" = "pending" ]; then
        pass "ED59. while pytest tests/; do :; done + exit=0 → run_tests=pending (while condition: pytest detected)"
    else
        fail "ED59. while pytest tests/; do :; done + exit=0 → expected pending, got run_tests=$STATUS"
    fi

    # ED25: elif pytest tests/; then : ; fi + exit=0 → run_tests: pending
    # (elif condition header stripped: pytest in condition IS a test command)
    SID="ed25-$$-$RANDOM"
    seed_write_tests "$SID" "complete"
    run_run_tests_hook 'elif pytest tests/; then : ; fi' 0 "$SID"
    STATUS=$(get_run_tests_status "$SID")
    if [ "$STATUS" = "pending" ]; then
        pass "ED25. elif pytest tests/; then : ; fi + exit=0 → run_tests=pending (elif condition: pytest detected)"
    else
        fail "ED25. elif pytest tests/; then : ; fi + exit=0 → expected pending, got run_tests=$STATUS"
    fi

    # ED26: case "$f" in tests/*) head -n 1 "$f" ;; esac + exit=0 → state absent
    # (case is non-exec header, esac is terminator: head is read-only)
    SID="ed26-$$-$RANDOM"
    run_run_tests_hook 'case "$f" in tests/*) head -n 1 "$f" ;; esac' 0 "$SID"
    if check_state_file_absent "$SID"; then
        pass "ED26. case \"\$f\" in tests/*) head -n 1 \"\$f\" ;; esac + exit=0 → state absent (case/esac: head is read-only)"
    else
        STATUS=$(get_run_tests_status "$SID")
        fail "ED26. case \"\$f\" in tests/*) head -n 1 \"\$f\" ;; esac + exit=0 → expected absent, got run_tests=$STATUS"
    fi

    # ED27: case "$f" in *) pytest tests/ ;; esac + exit=0 → run_tests: pending
    # (pytest in case body IS a test command)
    SID="ed27-$$-$RANDOM"
    seed_write_tests "$SID" "complete"
    run_run_tests_hook 'case "$f" in *) pytest tests/ ;; esac' 0 "$SID"
    STATUS=$(get_run_tests_status "$SID")
    if [ "$STATUS" = "pending" ]; then
        pass "ED27. case \"\$f\" in *) pytest tests/ ;; esac + exit=0 → run_tests=pending (case body: pytest detected)"
    else
        fail "ED27. case \"\$f\" in *) pytest tests/ ;; esac + exit=0 → expected pending, got run_tests=$STATUS"
    fi

    # ED28: pytest "unterminated + exit=0 → state absent (parseFailure: unclosed quote)
    # No seed: parseFailure makes isTestCommand return false, so the hook never
    # touches state. Seeding via markStep would default run_tests=pending and
    # defeat check_state_file_absent (matches sibling state-absent cases ED16/ED26).
    SID="ed28-$$-$RANDOM"
    run_run_tests_hook 'pytest "unterminated' 0 "$SID"
    if check_state_file_absent "$SID"; then
        pass "ED28. pytest \"unterminated + exit=0 → state absent (parseFailure: unclosed quote)"
    else
        STATUS=$(get_run_tests_status "$SID")
        fail "ED28. pytest \"unterminated + exit=0 → expected absent (parseFailure), got run_tests=$STATUS"
    fi

    # ED29: seeded run_tests=complete + unclosed-quote test-looking command → complete preserved
    # (parseFailure → isTestCommand=false → hook early-returns before reading/writing state;
    #  proves a malformed test-looking command does NOT demote an existing complete. Sibling of
    #  ED28: ED28 proves the fresh-state no-op, ED29 proves the no-demotion property.)
    SID="ed29-$$-$RANDOM"
    seed_write_tests "$SID" "complete"
    seed_run_tests "$SID" "complete"
    run_run_tests_hook 'pytest "tests/' 0 "$SID"
    STATUS=$(get_run_tests_status "$SID")
    if [ "$STATUS" = "complete" ]; then
        pass "ED29. pytest \"tests/ (unclosed quote) + seeded run_tests=complete → complete preserved (parseFailure early-return, no demotion)"
    else
        fail "ED29. pytest \"tests/ (unclosed quote) + seeded run_tests=complete → expected complete (no demotion), got run_tests=$STATUS"
    fi

    # ED30: if false; then :; else cat tests/foo.sh; fi + exit=0 → state absent
    # (else body keyword stripped: effective cmd0=cat is read-only)
    SID="ed30-$$-$RANDOM"
    run_run_tests_hook 'if false; then :; else cat tests/foo.sh; fi' 0 "$SID"
    if check_state_file_absent "$SID"; then
        pass "ED30. if false; then :; else cat tests/foo.sh; fi + exit=0 → state absent (else body keyword: cat is read-only)"
    else
        STATUS=$(get_run_tests_status "$SID")
        fail "ED30. if false; then :; else cat tests/foo.sh; fi + exit=0 → expected absent, got run_tests=$STATUS"
    fi

    # ED31: if false; then :; else pytest tests/; fi + exit=0 → run_tests: pending
    # (else body keyword stripped: effective cmd0=pytest is a test runner → detected)
    SID="ed31-$$-$RANDOM"
    seed_write_tests "$SID" "complete"
    run_run_tests_hook 'if false; then :; else pytest tests/; fi' 0 "$SID"
    STATUS=$(get_run_tests_status "$SID")
    if [ "$STATUS" = "pending" ]; then
        pass "ED31. if false; then :; else pytest tests/; fi + exit=0 → run_tests=pending (else body: pytest detected)"
    else
        fail "ED31. if false; then :; else pytest tests/; fi + exit=0 → expected pending, got run_tests=$STATUS"
    fi

    # ED32: select f in tests/*.sh; do head -n 1 "$f"; done + exit=0 → state absent
    # (select is a non-exec header → null; do head is read-only)
    SID="ed32-$$-$RANDOM"
    run_run_tests_hook 'select f in tests/*.sh; do head -n 1 "$f"; done' 0 "$SID"
    if check_state_file_absent "$SID"; then
        pass "ED32. select f in tests/*.sh; do head -n 1 \"\$f\"; done + exit=0 → state absent (select non-exec header + read-only head)"
    else
        STATUS=$(get_run_tests_status "$SID")
        fail "ED32. select f in tests/*.sh; do head -n 1 \"\$f\"; done + exit=0 → expected absent, got run_tests=$STATUS"
    fi

    # ---------------------------------------------------------------------------
    # === C4: special-character / quoted tests/ path coverage ===
    # Quoted paths containing spaces, parens, brackets, and backslashes must be
    # classified correctly for BOTH the read-only exclusion and runner-detection
    # branches. Behavior below verified against the real hook.
    # ---------------------------------------------------------------------------

    # ED33: cat "tests/a b.sh" + exit=0 → state absent (read-only, quoted space path)
    SID="ed33-$$-$RANDOM"
    run_run_tests_hook 'cat "tests/a b.sh"' 0 "$SID"
    if check_state_file_absent "$SID"; then
        pass "ED33. cat \"tests/a b.sh\" + exit=0 → state absent (read-only, quoted space path)"
    else
        STATUS=$(get_run_tests_status "$SID")
        fail "ED33. cat \"tests/a b.sh\" + exit=0 → expected absent (read-only quoted space), got run_tests=$STATUS"
    fi

    # ED34: pytest "tests/a b.py" + exit=0 → run_tests: pending (runner, quoted space path)
    SID="ed34-$$-$RANDOM"
    seed_write_tests "$SID" "complete"
    run_run_tests_hook 'pytest "tests/a b.py"' 0 "$SID"
    STATUS=$(get_run_tests_status "$SID")
    if [ "$STATUS" = "pending" ]; then
        pass "ED34. pytest \"tests/a b.py\" + exit=0 → run_tests=pending (runner, quoted space path)"
    else
        fail "ED34. pytest \"tests/a b.py\" + exit=0 → expected pending (runner quoted space), got run_tests=$STATUS"
    fi

    # ED35: bash "tests/a (b).sh" + exit=0 → run_tests: pending (runner + parens in quoted path)
    SID="ed35-$$-$RANDOM"
    seed_write_tests "$SID" "complete"
    run_run_tests_hook 'bash "tests/a (b).sh"' 0 "$SID"
    STATUS=$(get_run_tests_status "$SID")
    if [ "$STATUS" = "pending" ]; then
        pass "ED35. bash \"tests/a (b).sh\" + exit=0 → run_tests=pending (runner + parens in quoted path)"
    else
        fail "ED35. bash \"tests/a (b).sh\" + exit=0 → expected pending (runner quoted parens), got run_tests=$STATUS"
    fi

    # ED36: bash "tests/a [b].sh" + exit=0 → run_tests: pending (runner + brackets in quoted path)
    SID="ed36-$$-$RANDOM"
    seed_write_tests "$SID" "complete"
    run_run_tests_hook 'bash "tests/a [b].sh"' 0 "$SID"
    STATUS=$(get_run_tests_status "$SID")
    if [ "$STATUS" = "pending" ]; then
        pass "ED36. bash \"tests/a [b].sh\" + exit=0 → run_tests=pending (runner + brackets in quoted path)"
    else
        fail "ED36. bash \"tests/a [b].sh\" + exit=0 → expected pending (runner quoted brackets), got run_tests=$STATUS"
    fi

    # ED37: cat "tests/a\b.sh" + exit=0 → state absent (read-only, backslash in quoted path)
    SID="ed37-$$-$RANDOM"
    run_run_tests_hook 'cat "tests/a\b.sh"' 0 "$SID"
    if check_state_file_absent "$SID"; then
        pass "ED37. cat \"tests/a\\b.sh\" + exit=0 → state absent (read-only, backslash in quoted path)"
    else
        STATUS=$(get_run_tests_status "$SID")
        fail "ED37. cat \"tests/a\\b.sh\" + exit=0 → expected absent (read-only quoted backslash), got run_tests=$STATUS"
    fi

    # ---------------------------------------------------------------------------
    # === C3: long-string edge coverage ===
    # Very long commands must classify the same as their short equivalents:
    # length does not affect read-only exclusion or runner detection.
    # Behavior below verified against the real hook.
    # ---------------------------------------------------------------------------

    # ED38: very long read-only command referencing tests/ → state absent
    # (grep with a ~500-char pattern; whole command is read-only, tests/ is only a grep target)
    SID="ed38-$$-$RANDOM"
    LONG_PATTERN=$(printf 'x%.0s' {1..500})
    run_run_tests_hook "grep $LONG_PATTERN tests/foo.sh" 0 "$SID"
    if check_state_file_absent "$SID"; then
        pass "ED38. grep <500-char-pattern> tests/foo.sh + exit=0 → state absent (long read-only command)"
    else
        STATUS=$(get_run_tests_status "$SID")
        fail "ED38. grep <500-char-pattern> tests/foo.sh + exit=0 → expected absent (long read-only), got run_tests=$STATUS"
    fi

    # ED39: very long valid runner command → run_tests: pending
    # (pytest tests/ followed by many long flags; still a real test runner)
    SID="ed39-$$-$RANDOM"
    seed_write_tests "$SID" "complete"
    LONG_FLAGS=""
    for i in $(seq 1 60); do LONG_FLAGS="$LONG_FLAGS --flag-number-$i=valuevaluevalue"; done
    run_run_tests_hook "pytest tests/$LONG_FLAGS" 0 "$SID"
    STATUS=$(get_run_tests_status "$SID")
    if [ "$STATUS" = "pending" ]; then
        pass "ED39. pytest tests/ <many long flags> + exit=0 → run_tests=pending (long valid runner command)"
    else
        fail "ED39. pytest tests/ <many long flags> + exit=0 → expected pending (long runner), got run_tests=$STATUS"
    fi

    # ---------------------------------------------------------------------------
    # === C2: multiline command coverage ===
    # Real Bash tool commands can span multiple lines. run_run_tests_hook()'s
    # manual escaping does NOT encode literal newlines (invalid JSON), so these
    # cases use run_run_tests_hook_multiline() which builds the payload via
    # node JSON.stringify. Behavior below verified against the real hook.
    # ---------------------------------------------------------------------------

    # ED40: cd repo<newline>pytest tests/ + exit=0 → run_tests: pending
    # (multiline positive: 2nd line `pytest tests/` is a bare runner → active demotion)
    SID="ed40-$$-$RANDOM"
    seed_write_tests "$SID" "complete"
    run_run_tests_hook_multiline "$(printf 'cd repo\npytest tests/')" 0 "$SID"
    STATUS=$(get_run_tests_status "$SID")
    if [ "$STATUS" = "pending" ]; then
        pass "ED40. cd repo <newline> pytest tests/ + exit=0 → run_tests=pending (multiline positive: pytest detected)"
    else
        fail "ED40. cd repo <newline> pytest tests/ + exit=0 → expected pending (multiline runner), got run_tests=$STATUS"
    fi

    # ED40b: cd repo<newline>head tests/foo.sh + exit=0 → run_tests=pending
    # (multiline negative-companion to ED40 for a non-runner second line)
    # parse() does NOT split on newlines, so the whole string collapses into ONE
    # segment with cmd0=`cd` (NOT read-only). The trailing `tests/foo.sh` argument
    # matches the test-path detection regex → the command IS detected → with exit=0
    # and no run-all.sh contract this is an ACTIVE DEMOTION → run_tests=pending.
    # This is a documented fail-safe false-positive (conservative over-demotion;
    # never falsely marks complete) governed by the newline-non-splitting tradeoff.
    SID="ed40b-$$-$RANDOM"
    seed_write_tests "$SID" "complete"
    run_run_tests_hook_multiline "$(printf 'cd repo\nhead tests/foo.sh')" 0 "$SID"
    STATUS=$(get_run_tests_status "$SID")
    if [ "$STATUS" = "pending" ]; then
        pass "ED40b. cd repo <newline> head tests/foo.sh + exit=0 → run_tests=pending (non-read-only cmd0 `cd` + path ref → fail-safe demotion)"
    else
        fail "ED40b. cd repo <newline> head tests/foo.sh + exit=0 → expected pending (newline collapse, cd not read-only, path ref detected), got run_tests=$STATUS"
    fi

    # ED41: for f in tests/*.sh<newline>do<newline>head -n 1 "$f"<newline>done + exit=0 → state absent
    # (multiline negative: loop over tests/ but body cmd `head` is read-only)
    SID="ed41-$$-$RANDOM"
    run_run_tests_hook_multiline "$(printf 'for f in tests/*.sh\ndo\nhead -n 1 "$f"\ndone')" 0 "$SID"
    if check_state_file_absent "$SID"; then
        pass "ED41. for f in tests/*.sh <newline> do <newline> head ... <newline> done + exit=0 → state absent (multiline negative: head is read-only)"
    else
        STATUS=$(get_run_tests_status "$SID")
        fail "ED41. multiline for-loop with read-only body + exit=0 → expected absent, got run_tests=$STATUS"
    fi

    # ED42: for f in tests/*.sh<newline>do<newline>pytest tests/<newline>done + exit=0 → state absent
    # Characterization of a KNOWN newline limitation. parse() does NOT split on
    # newlines, so the whole multiline string is ONE segment with cmd0=`for` (a
    # CONTROL_NONEXEC_HEADER → resolveEffectiveSegment returns null → skipped).
    # The `pytest` in the loop body is therefore NOT detected: multiline loop body
    # after for-header is NOT penetrated — accepted newline limitation
    # (false-negative only, does not reintroduce #1330 false-positives); see
    # detail.md risk #3. Verified against the real hook: state ABSENT (no seed, so
    # the hook never touches state — matches sibling negative case ED41).
    SID="ed42-$$-$RANDOM"
    run_run_tests_hook_multiline "$(printf 'for f in tests/*.sh\ndo\npytest tests/\ndone')" 0 "$SID"
    if check_state_file_absent "$SID"; then
        pass "ED42. for f in tests/*.sh <newline> do <newline> pytest tests/ <newline> done + exit=0 → state absent (multiline loop-body pytest NOT penetrated: accepted newline limitation)"
    else
        STATUS=$(get_run_tests_status "$SID")
        fail "ED42. multiline for-loop with pytest body + exit=0 → expected absent (newline limitation), got run_tests=$STATUS"
    fi

    # ED42b: for f in tests/*.sh; do pytest tests/; done + exit=0 → run_tests: pending
    # SINGLE-LINE penetration positive. Contrast with ED42 (multiline, newline-separated):
    # parse() splits on `;`, so `do pytest tests/` becomes its own segment; stripping `do`
    # yields effective cmd0=`pytest` → detected → active demotion. Single-line `;`-separated
    # loop bodies ARE penetrated and detect real runners. ED42's multiline (newline-separated)
    # loop body is an accepted fail-safe false-negative (parse() does not split on newlines;
    # see detail.md risk #3). Together ED42 and ED42b bound the penetration behavior.
    SID="ed42b-$$-$RANDOM"
    seed_write_tests "$SID" "complete"
    run_run_tests_hook 'for f in tests/*.sh; do pytest tests/; done' 0 "$SID"
    STATUS=$(get_run_tests_status "$SID")
    if [ "$STATUS" = "pending" ]; then
        pass "ED42b. for f in tests/*.sh; do pytest tests/; done + exit=0 → run_tests=pending (single-line ';'-separated loop body penetrated: pytest detected)"
    else
        fail "ED42b. for f in tests/*.sh; do pytest tests/; done + exit=0 → expected pending (single-line loop body penetration), got run_tests=$STATUS"
    fi

    # ---------------------------------------------------------------------------
    # === FIX 1 (#1330): sentinel-echo excluded via READ_ONLY_CMDS ===
    # Workflow sentinel echoes (`echo '<<...>>'` / `echo "<<...>>"`) are excluded
    # from test-detection because `echo` is a member of READ_ONLY_CMDS. There is
    # no separate sentinel-echo branch — the read-only rule is the sole mechanism.
    # This is STRICTER than a raw-text startsWith("echo") prefix match: because
    # the exclusion operates on the resolved effective cmd0 (past env-prefix
    # assignments), it also covers env-prefixed forms like `FOO=1 echo '<<...>>'`
    # that a naive prefix match would miss.
    # ---------------------------------------------------------------------------

    # ED43: echo '<<pytest tests/foo>>' + exit=0 → state absent (read-only echo exclusion)
    SID="ed43-$$-$RANDOM"
    run_run_tests_hook "echo '<<pytest tests/foo>>'" 0 "$SID"
    if check_state_file_absent "$SID"; then
        pass "ED43. echo '<<pytest tests/foo>>' + exit=0 → state absent (read-only echo excluded despite pytest tests/)"
    else
        STATUS=$(get_run_tests_status "$SID")
        fail "ED43. echo '<<pytest tests/foo>>' + exit=0 → expected absent (read-only echo exclusion), got run_tests=$STATUS"
    fi

    # ED44: echo "<<pytest tests/foo>>" + exit=0 → state absent (read-only echo exclusion, double-quote form)
    SID="ed44-$$-$RANDOM"
    run_run_tests_hook 'echo "<<pytest tests/foo>>"' 0 "$SID"
    if check_state_file_absent "$SID"; then
        pass "ED44. echo \"<<pytest tests/foo>>\" + exit=0 → state absent (read-only echo excluded despite pytest tests/)"
    else
        STATUS=$(get_run_tests_status "$SID")
        fail "ED44. echo \"<<pytest tests/foo>>\" + exit=0 → expected absent (read-only echo exclusion), got run_tests=$STATUS"
    fi

    # ED44b: FOO=1 echo '<<pytest tests/foo>>' + exit=0 → state absent (env-prefix + read-only echo exclusion)
    # Effective cmd0 is resolved past the env-prefix assignment to `echo`, which is in
    # READ_ONLY_CMDS → excluded. A naive raw-text startsWith("echo") prefix check would
    # MISS this form (the string starts with "FOO=1"), so this case gives the coverage teeth.
    SID="ed44b-$$-$RANDOM"
    run_run_tests_hook "FOO=1 echo '<<pytest tests/foo>>'" 0 "$SID"
    if check_state_file_absent "$SID"; then
        pass "ED44b. FOO=1 echo '<<pytest tests/foo>>' + exit=0 → state absent (env-prefix resolved: echo is read-only)"
    else
        STATUS=$(get_run_tests_status "$SID")
        fail "ED44b. FOO=1 echo '<<pytest tests/foo>>' + exit=0 → expected absent (env-prefix read-only echo), got run_tests=$STATUS"
    fi

    # ---------------------------------------------------------------------------
    # === FIX 2 (#1330): git global-option skipping before subcommand ===
    # resolveGitSubcommand(argv) now skips leading git global options before
    # reading the subcommand. Value-taking options (-C, -c, --git-dir, ...)
    # consume their following token; `--opt=value` and bare flags are single
    # tokens. So a git non-exec subcommand (diff/log/status) is correctly
    # EXCLUDED even behind global options. Before FIX 2 only bare `git <sub>`
    # and `git -C <path> <sub>` were recognized.
    # ---------------------------------------------------------------------------

    # ED45: git -c foo.bar=baz diff tests/foo.sh + exit=0 → state absent (-c k=v consumes value)
    SID="ed45-$$-$RANDOM"
    run_run_tests_hook 'git -c foo.bar=baz diff tests/foo.sh' 0 "$SID"
    if check_state_file_absent "$SID"; then
        pass "ED45. git -c foo.bar=baz diff tests/foo.sh + exit=0 → state absent (global -c skipped: diff is non-exec)"
    else
        STATUS=$(get_run_tests_status "$SID")
        fail "ED45. git -c foo.bar=baz diff tests/foo.sh + exit=0 → expected absent (global -c), got run_tests=$STATUS"
    fi

    # ED46: git --no-pager diff tests/ + exit=0 → state absent (bare flag single token)
    SID="ed46-$$-$RANDOM"
    run_run_tests_hook 'git --no-pager diff tests/' 0 "$SID"
    if check_state_file_absent "$SID"; then
        pass "ED46. git --no-pager diff tests/ + exit=0 → state absent (bare global flag skipped: diff is non-exec)"
    else
        STATUS=$(get_run_tests_status "$SID")
        fail "ED46. git --no-pager diff tests/ + exit=0 → expected absent (bare global flag), got run_tests=$STATUS"
    fi

    # ED47: git -C a -C b log tests/ + exit=0 → state absent (repeated value-taking option)
    SID="ed47-$$-$RANDOM"
    run_run_tests_hook 'git -C a -C b log tests/' 0 "$SID"
    if check_state_file_absent "$SID"; then
        pass "ED47. git -C a -C b log tests/ + exit=0 → state absent (repeated -C skipped: log is non-exec)"
    else
        STATUS=$(get_run_tests_status "$SID")
        fail "ED47. git -C a -C b log tests/ + exit=0 → expected absent (repeated -C), got run_tests=$STATUS"
    fi

    # ED48: git --git-dir=.git status tests/ + exit=0 → state absent (--opt=value single token)
    SID="ed48-$$-$RANDOM"
    run_run_tests_hook 'git --git-dir=.git status tests/' 0 "$SID"
    if check_state_file_absent "$SID"; then
        pass "ED48. git --git-dir=.git status tests/ + exit=0 → state absent (--opt=value skipped: status is non-exec)"
    else
        STATUS=$(get_run_tests_status "$SID")
        fail "ED48. git --git-dir=.git status tests/ + exit=0 → expected absent (--opt=value), got run_tests=$STATUS"
    fi

    # ED49: seeded run_tests=complete + git --no-pager diff tests/ exit=0 → complete preserved
    # (demotion-protection: the git read-only exclusion protects a prior green state;
    #  a git non-exec subcommand behind a global flag must NOT demote complete → pending.)
    SID="ed49-$$-$RANDOM"
    seed_write_tests "$SID" "complete"
    seed_run_tests "$SID" "complete"
    run_run_tests_hook 'git --no-pager diff tests/' 0 "$SID"
    STATUS=$(get_run_tests_status "$SID")
    if [ "$STATUS" = "complete" ]; then
        pass "ED49. git --no-pager diff tests/ + seeded run_tests=complete → complete preserved (git non-exec exclusion protects green state, no demotion)"
    else
        fail "ED49. git --no-pager diff tests/ + seeded run_tests=complete → expected complete (no demotion), got run_tests=$STATUS"
    fi

    # ---------------------------------------------------------------------------
    # === C2 (continued): git space-separated value-taking global options ===
    # ED50–ED53 exercise the SPACE-SEPARATED form of multi-char value-taking options
    # in GIT_VALUE_OPTS (--work-tree, --namespace, --exec-path, --super-prefix).
    # Each case: option consumes the following token as its value, leaving a non-exec
    # git subcommand (diff/log/status) → state absent.
    # Contrast with ED48's `--opt=value` inline form (single token).
    # ---------------------------------------------------------------------------

    # ED50: git --work-tree /x diff tests/foo.sh + exit=0 → state absent
    # (--work-tree consumes /x; diff is non-exec)
    SID="ed50-$$-$RANDOM"
    run_run_tests_hook 'git --work-tree /x diff tests/foo.sh' 0 "$SID"
    if check_state_file_absent "$SID"; then
        pass "ED50. git --work-tree /x diff tests/foo.sh + exit=0 → state absent (space-sep --work-tree consumed /x: diff is non-exec)"
    else
        STATUS=$(get_run_tests_status "$SID")
        fail "ED50. git --work-tree /x diff tests/foo.sh + exit=0 → expected absent (--work-tree space-sep), got run_tests=$STATUS"
    fi

    # ED51: git --namespace ns log tests/ + exit=0 → state absent
    # (--namespace consumes ns; log is non-exec)
    SID="ed51-$$-$RANDOM"
    run_run_tests_hook 'git --namespace ns log tests/' 0 "$SID"
    if check_state_file_absent "$SID"; then
        pass "ED51. git --namespace ns log tests/ + exit=0 → state absent (space-sep --namespace consumed ns: log is non-exec)"
    else
        STATUS=$(get_run_tests_status "$SID")
        fail "ED51. git --namespace ns log tests/ + exit=0 → expected absent (--namespace space-sep), got run_tests=$STATUS"
    fi

    # ED52: git --exec-path /p status tests/ + exit=0 → state absent
    # (--exec-path consumes /p; status is non-exec)
    SID="ed52-$$-$RANDOM"
    run_run_tests_hook 'git --exec-path /p status tests/' 0 "$SID"
    if check_state_file_absent "$SID"; then
        pass "ED52. git --exec-path /p status tests/ + exit=0 → state absent (space-sep --exec-path consumed /p: status is non-exec)"
    else
        STATUS=$(get_run_tests_status "$SID")
        fail "ED52. git --exec-path /p status tests/ + exit=0 → expected absent (--exec-path space-sep), got run_tests=$STATUS"
    fi

    # ED53: git --super-prefix pre/ diff tests/ + exit=0 → state absent
    # (--super-prefix consumes pre/; diff is non-exec)
    SID="ed53-$$-$RANDOM"
    run_run_tests_hook 'git --super-prefix pre/ diff tests/' 0 "$SID"
    if check_state_file_absent "$SID"; then
        pass "ED53. git --super-prefix pre/ diff tests/ + exit=0 → state absent (space-sep --super-prefix consumed pre/: diff is non-exec)"
    else
        STATUS=$(get_run_tests_status "$SID")
        fail "ED53. git --super-prefix pre/ diff tests/ + exit=0 → expected absent (--super-prefix space-sep), got run_tests=$STATUS"
    fi
}
