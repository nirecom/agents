# shellcheck shell=bash
# Tests: bin/supervisor-report, hooks/lib/supervisor-state-writer.js, skills/supervisor-report/SKILL.md
# Tags: rules-injection, supervisor-report, shell-injection, argv-safety, canary, table-driven, security, TL2, scope:issue-specific

# WHY (CPR-WPH): `--detail` is the one supervisor-report field whose value is free text the
# model composes from whatever it just observed — a hook's stderr, a failing command line, a
# path. Those routinely contain `$(`, backticks, `;`, `&&` and newlines. If any layer between
# the model and the audit trail hands that text to a shell, an observation about a bad
# command becomes the execution of one, with the developer's own privileges.

# Two properties are asserted per payload. FIRST, nothing executes: every row plants a
# canary path inside its payload and the canary directory must stay empty. SECOND, the
# observation survives INTACT — a CLI that defends itself by silently stripping the
# dangerous-looking characters files a detail that no longer describes what happened, which
# is a quieter version of the same loss. Round-trip equality is therefore compared against
# the exact bytes passed in, via JSON so a newline or a control character stays one line.

# The severity/categories fields are read back alongside, because a payload carrying an
# embedded newline and a well-formed `--severity error` line is the argv-splitting attack:
# if anything re-tokenized the detail, the persisted severity would be the injected one and
# not the one the caller passed. Assumes AGENTS_DIR, TMPDIR_BASE, SR_CLI, WORKFLOW_PLANS_DIR,
# fresh_workflow_dir(), run_with_timeout(), pass(), fail() from the entry file.

echo ""
echo "=== S11: --detail payloads are data, not commands ==="

if [ ! -f "$SR_CLI" ]; then
    fail "S11: IMPLEMENTATION MISSING: bin/supervisor-report"
else
    DI_CANARY="$TMPDIR_BASE/di-canary"
    rm -rf "$DI_CANARY"; mkdir -p "$DI_CANARY"

    # Reads back the single persisted finding as one line, JSON-encoding the detail so a
    # newline or a control byte inside it cannot break the field separators.
    cat > "$TMPDIR_BASE/di-readback.js" <<'DI_READ_EOF'
"use strict";
const fs = require("fs");
const path = require("path");
const file = path.join(process.argv[2], `${process.argv[3]}-supervisor-state.json`);
let f = [];
try { f = JSON.parse(fs.readFileSync(file, "utf8")).layer1.findings || []; } catch (_) { f = []; }
if (f.length !== 1) { process.stdout.write("N=" + f.length); process.exit(0); }
const x = f[0];
process.stdout.write(
  "N=1 SEV=" + x.severity +
  " CATS=" + (x.categories || []).join(",") +
  " DETAIL=" + JSON.stringify(String(x.detail))
);
DI_READ_EOF

    # di_payload <variant> — prints the payload for that row. Each hostile row embeds the
    # canary path so the ONLY way the canary appears is the payload being executed.
    di_payload() {
        case "$1" in
            cmdsub)    printf 'observed: $(touch %s/cmdsub) in the log' "$DI_CANARY" ;;
            backtick)  printf 'observed: `touch %s/backtick` in the log' "$DI_CANARY" ;;
            chain)     printf 'ran: x ; touch %s/semi && touch %s/andand' "$DI_CANARY" "$DI_CANARY" ;;
            newline)   printf 'first line\n--severity error\ntouch %s/nl' "$DI_CANARY" ;;
            ctrl)      printf 'bell\007 and an escape \033[31mred\033[0m' ;;
            quotes)    printf 'he said "stop" and '"'"'go'"'"' at once' ;;
            leading)   printf -- '--severity' ;;
            benign)    printf 'an ordinary observation with no metacharacters' ;;
        esac
    }

    DI_N=0
    # di_case <variant> <want-rc> <description>
    di_case() {
        local variant="$1" wantrc="$2" desc="$3" payload sid wf rc=0 out got want
        DI_N=$((DI_N + 1))
        sid="s11sid2037-$DI_N"
        wf="$(fresh_workflow_dir)"
        payload="$(di_payload "$variant")"
        out="$(run_with_timeout 60 env \
            "AGENTS_CONFIG_DIR=$AGENTS_DIR" \
            "CLAUDE_WORKFLOW_DIR=$wf" \
            "WORKFLOW_PLANS_DIR=$WORKFLOW_PLANS_DIR" \
            node "$SR_CLI" --categories other --severity notice \
                --detail "$payload" --reporter di-probe --session-id "$sid" 2>&1)" || rc=$?
        got="$(node "$TMPDIR_BASE/di-readback.js" "$WORKFLOW_PLANS_DIR" "$sid" 2>/dev/null || echo "N=ERR")"
        if [ "$rc" != "$wantrc" ]; then
            fail "S11 [$variant]: exit $rc, want $wantrc — $desc; output: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200)"
            return
        fi
        if [ "$wantrc" != "0" ]; then
            if [ "$got" = "N=0" ]; then
                pass "S11 [$variant]: rejected (exit $rc) and nothing was appended — $desc"
            else
                fail "S11 [$variant]: rejected (exit $rc) but a record was still written ($got) — a CLI that appends before validating corrupts the audit trail"
            fi
            return
        fi
        # The bytes that were actually handed to the CLI, encoded the same way the readback
        # encodes what came back. Building the expectation from the SAME variable that was
        # passed in is what makes this a round-trip rather than two restatements of a literal.
        # The `--` is load-bearing: without it node claims a flag-shaped payload as one of its
        # own options and exits 9, which would make the expectation an empty string.
        want="$(node -e 'process.stdout.write("DETAIL=" + JSON.stringify(String(process.argv[1])))' -- "$payload")"
        if [ "$got" != "N=1 SEV=notice CATS=other $want" ]; then
            fail "S11 [$variant]: the persisted record is not the one that was passed. want 'N=1 SEV=notice CATS=other $want', got '$got' — $desc"
        else
            pass "S11 [$variant]: accepted, and the payload round-trips byte for byte with severity/categories untouched — $desc"
        fi
    }

    di_case cmdsub   0 "a \$(...) command substitution stays literal text"
    di_case backtick 0 "a backtick substitution stays literal text"
    di_case chain    0 "';' and '&&' command chaining stays literal text"
    di_case newline  0 "an embedded newline carrying a well-formed '--severity error' does not re-tokenize into a flag"
    di_case ctrl     0 "control and ANSI-escape bytes survive without being executed or stripped"
    di_case quotes   0 "both quote styles inside one value survive intact"
    di_case leading  0 "a value that is itself flag-shaped is consumed as the value of --detail"
    di_case benign   0 "the benign control: an ordinary sentence is accepted and stored unchanged"
    # NEGATIVE CONTROL: every row above answers exit 0, so without a row that answers
    # something else the table would also be satisfied by a CLI that accepts anything and
    # by a harness whose exit-code comparison is broken.
    DI_N=$((DI_N + 1))
    DI_SID_MISSING="s11sid2037-$DI_N"
    DI_MISS_WF="$(fresh_workflow_dir)"
    DI_MISS_RC=0
    DI_MISS_OUT="$(run_with_timeout 60 env \
        "AGENTS_CONFIG_DIR=$AGENTS_DIR" \
        "CLAUDE_WORKFLOW_DIR=$DI_MISS_WF" \
        "WORKFLOW_PLANS_DIR=$WORKFLOW_PLANS_DIR" \
        node "$SR_CLI" --categories other --severity notice \
            --reporter di-probe --session-id "$DI_SID_MISSING" 2>&1)" || DI_MISS_RC=$?
    DI_MISS_GOT="$(node "$TMPDIR_BASE/di-readback.js" "$WORKFLOW_PLANS_DIR" "$DI_SID_MISSING" 2>/dev/null || echo "N=ERR")"
    if [ "$DI_MISS_RC" != "0" ] && [ "$DI_MISS_GOT" = "N=0" ]; then
        pass "S11 [no-detail]: omitting --detail entirely exits $DI_MISS_RC and stores nothing — the rows above measure the payload, not a CLI that says yes to everything"
    else
        fail "S11 [no-detail]: want a non-zero exit and no record, got rc=$DI_MISS_RC record='$DI_MISS_GOT' — the accepted rows above cannot be distinguished from a CLI with no validation at all; output: $(printf '%s' "$DI_MISS_OUT" | tr '\n' ' ' | cut -c1-200)"
    fi

    # --- S11-canary: the whole point of the table. Every hostile row named a distinct file
    # inside this directory; if any layer between argv and the JSON store reached a shell,
    # at least one of them now exists. ---
    DI_HITS="$(ls -A "$DI_CANARY" 2>/dev/null | tr '\n' ' ')"
    if [ -z "$DI_HITS" ]; then
        pass "S11-canary: no payload created any file — $DI_N row(s) of shell metacharacters reached the audit trail as data"
    else
        fail "S11-canary: the payload(s) EXECUTED — canary file(s) present: $DI_HITS. Reporting an observation about a dangerous command now runs it"
    fi

    # --- S11-canary-ctl: the non-vacuity control. S11-canary asserts an empty directory,
    # which is also what a broken canary path, a wrong variable or an `ls` that never looks
    # would produce. So the identical detector is run against a file created on purpose. ---
    : > "$DI_CANARY/control-proof"
    DI_CTL="$(ls -A "$DI_CANARY" 2>/dev/null | tr '\n' ' ')"
    if [ -n "$DI_CTL" ]; then
        pass "S11-canary-ctl: the same probe DOES see a file when one exists ($DI_CTL) — S11-canary's emptiness is evidence, not a blind spot"
    else
        fail "S11-canary-ctl: a file was created at $DI_CANARY/control-proof and the probe still reported the directory empty — S11-canary cannot detect an execution and proves nothing"
    fi
    rm -rf "$DI_CANARY"
fi
