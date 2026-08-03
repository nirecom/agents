#!/usr/bin/env bash
# tests/fix-1780-round12-classifier-attack-shapes.sh
# Tests: hooks/block-clearance-token-write.js, hooks/block-clearance-token-write/dispatch.js, hooks/block-clearance-token-write/bash-scan.js, hooks/block-clearance-token-write/interpreter-scan.js, hooks/block-clearance-token-write/nested-bodies.js, hooks/lib/write-tools.js, hooks/lib/tool-command-text.js
# Tags: off-clearance, session-marker, protected-basename, classifier, dispatch, tool-shape, notebook-edit, run-commands, run-in-terminal, redirect, symlink, hardlink, variable-expansion, glob, brace-expansion, ansi-c-quoting, interpreter, heredoc, here-string, eval, pipeline, over-block, cpr5, security, pretooluse, block-write, scope:issue-specific, pwsh-not-required, TL2
# TL3 gap (what this test does NOT catch):
# - The hook firing as a REAL PreToolUse hook inside a live claude -p session.
#   Here it is a node subprocess fed synthetic stdin; that the entrypoint is
#   REGISTERED for these tool names is asserted statically by
#   tests/enforce-protected-marker-write.sh (X6).
# - Real shell / OS execution. That `{f..f}` expands, that `$'\x66'` decodes, that
#   `ln -s` creates a path the marker reader will follow — all PREMISES. What is
#   asserted is the classifier's reading of the spelling.
# Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: hook-registration.
#
# ---------------------------------------------------------------------------
# WHAT THIS FILE DEFENDS (#1780 round-12, /review-tests gap 4)
#
# hooks/lib/session-markers.js authorizes on a marker file's EXISTENCE alone. One
# `<sid>.workflow-off`, however it comes to exist, is full session clearance —
# so this classifier is a DENYLIST guarding a one-shot privilege escalation, and
# a denylist is only as good as its coverage of the shapes it never saw.
#
# The round-12 split moved that coverage across four new modules (dispatch.js,
# bash-scan.js, interpreter-scan.js, nested-bodies.js) plus two shared SSOTs
# (write-tools.js, tool-command-text.js). Existing suites reached them through a
# handful of shapes. This file asserts the MATRIX, on the premise that a bypass
# needs only ONE uncovered cell:
#
#   AXIS 1 — the tool shape the call arrives in. Claude Code ships five
#     edit/write tools and three command tools, and they do NOT agree on the
#     payload key (`file_path` / `path` / `notebook_path` / `edits[].*`;
#     `command` / `commands[]`). A guard that reads one key is bypassed by a
#     client that speaks another — no cleverness required, just a different
#     harness. `runCommands` is the recorded precedent: dispatch.js read
#     `.command` only and every runCommands call sailed past with `undefined`
#     (see hooks/lib/tool-command-text.js header). Sections T and P.
#
#   AXIS 2 — the shell shape that produces the file. Redirects are the obvious
#     one; symlink/hardlink, variable indirection, glob and brace expansion,
#     ANSI-C decoding, interpreter one-liners, heredocs, here-strings, eval and
#     pipelines all end with the same file existing. Section W.
#
# EVERY BLOCK ROW IS PAIRED (skills/_shared/test-design/parser-regex-tests.md).
# A row that only asserts BLOCK cannot distinguish "the classifier understood
# this shape" from "the classifier blocks everything that mentions a path", and
# the second is the failure mode that gets a guard switched off. Each block row
# therefore has a control differing by EXACTLY the protected property — the same
# shape onto an ordinary file, or the same path one character short of a
# protected suffix. Section O sizes the over-block on its own.
#
# Sections:
#   T  edit/write tool shapes x payload keys        (block + innocent controls)
#   P  command tool parity: Bash / runInTerminal / runCommands[i]   (CPR-5)
#   W  attack-shape matrix over shell commands      (each row paired)
#   O  over-block sizing + accepted, NAMED over-blocks
#
# NOT DUPLICATED HERE: command substitution and backtick shapes are the subject
# of tests/fix-1780-round11-substitution-additivity.sh in full; only a single
# parity row appears below so the matrix is not silently missing the axis.
# ---------------------------------------------------------------------------

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"; else _AGENTS_DIR_NODE="$AGENTS_DIR"; fi

HOOK="$AGENTS_DIR/hooks/block-clearance-token-write.js"
RWT="$AGENTS_DIR/bin/run-with-timeout.sh"
PB_NODE="$_AGENTS_DIR_NODE/hooks/lib/protected-basenames.js"
WT_NODE="$_AGENTS_DIR_NODE/hooks/lib/write-tools.js"
TCT_NODE="$_AGENTS_DIR_NODE/hooks/lib/tool-command-text.js"

PASS=0; FAIL=0; SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }
make_tmp() { mktemp -d 2>/dev/null || mktemp -d -t 'r12shp'; }
node_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

# rules/test/fixture-isolation.md: never let the hook resolve the live session,
# and never let anything downstream append to the developer's real plans dir.
unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID 2>/dev/null || true

# H0 - harness self-check: without the hook every verdict below is vacuous.
if [ -f "$HOOK" ]; then pass "H0 hook file present"
else
    fail "H0 hook file MISSING at $HOOK - every case below would be vacuous"
    echo ""; echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"; exit 1
fi

# Dual-pinned throwaway workflow dir (pinning one of the pair only is the classic
# contamination bug). The hook creates no files; the pin also keeps the
# workflow-dir qualifier resolving to the fixture rather than the real dir.
SANDBOX=$(make_tmp); WF=$(node_path "$SANDBOX")
export CLAUDE_WORKFLOW_DIR="$WF" WORKFLOW_PLANS_DIR="$WF"
cleanup() { [ -n "${SANDBOX:-}" ] && [ -d "$SANDBOX" ] && rm -r -f "$SANDBOX" 2>/dev/null; return 0; }
trap cleanup EXIT

# --- protected names DERIVED from the SSOT, never hardcoded (CPR-2) ---------
MARKER_SUFFIX=$("$RWT" 10 node -e \
    "process.stdout.write('.' + require(process.argv[1]).SESSION_MARKER_KINDS[0])" "$PB_NODE" 2>/dev/null)
TOKEN_SUFFIX=$("$RWT" 10 node -e \
    "process.stdout.write(require(process.argv[1]).OFF_CLEARANCE_TOKEN_SUFFIXES[0])" "$PB_NODE" 2>/dev/null)
if [ -z "$MARKER_SUFFIX" ] || [ -z "$TOKEN_SUFFIX" ]; then
    fail "H1 protected-basename SSOT is introspectable (hooks/lib/protected-basenames.js exports)"
    echo ""; echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"; exit 1
fi
pass "H1 protected-basename SSOT introspected: marker=[$MARKER_SUFFIX] token=[$TOKEN_SUFFIX]"

SID="s1"
MK="$WF/${SID}${MARKER_SUFFIX}"        # the marker path an attacker wants to exist
TOK="$WF/${SID}${TOKEN_SUFFIX}"        # its clearance-token sibling (CPR-5)
OK="$WF/notes.txt"                     # the innocent counterpart every control uses
# The marker minus its LAST character. Every "one char short" control is built
# from this, so the control differs from its block row by exactly one byte of the
# protected suffix and nothing else.
MK_SHORT="$WF/${SID}${MARKER_SUFFIX%?}"

# ===========================================================================
# Harness
# ===========================================================================
# run_hook <tool_name> <tool_input JSON> -> "<rc>|<stdout, newlines stripped>"
# The payload is assembled by node rather than by string concatenation so that a
# command containing quotes, newlines or backslashes reaches the hook byte-exact
# — the shapes most likely to be mis-escaped are exactly the interesting ones.
run_hook() {
    local tool="$1" ti="$2" input out rc
    input=$("$RWT" 10 node -e \
        'process.stdout.write(JSON.stringify({tool_name:process.argv[1],session_id:"s1",cwd:process.argv[3],tool_input:JSON.parse(process.argv[2])}))' \
        "$tool" "$ti" "$WF" 2>/dev/null)
    [ -z "$input" ] && { printf 'nopayload|'; return; }
    out=$(printf '%s' "$input" | CLAUDE_WORKFLOW_DIR="$WF" WORKFLOW_PLANS_DIR="$WF" \
        AGENTS_CONFIG_DIR="$_AGENTS_DIR_NODE" "$RWT" 15 node "$HOOK" 2>/dev/null)
    rc=$?
    printf '%s|%s' "$rc" "$(printf '%s' "$out" | tr -d '\r\n')"
}

# classify "<rc>|<out>" -> approve | block | timeout | crash:<rc> | empty |
#                          unrecognized | nopayload
# An allow is only an allow when the hook exited 0 AND affirmatively said so: a
# crash, a timeout or unparseable stdout must never be readable as "approve",
# because on this hook "approve" is the direction that grants the escalation.
classify() {
    local raw="$1" rc out
    rc="${raw%%|*}"; out="${raw#*|}"
    case "$rc" in
        nopayload) printf 'nopayload'; return ;;
        124)       printf 'timeout'; return ;;
        0)         ;;
        *)         printf 'crash:%s' "$rc"; return ;;
    esac
    [ -z "$out" ] && { printf 'empty'; return; }
    case "$out" in
        *'"decision":"block"'*)   printf 'block'; return ;;
        *'"decision":"approve"'*) printf 'approve'; return ;;
    esac
    case "$out" in
        *'"permissionDecision":"deny"'*)  printf 'block'; return ;;
        *'"permissionDecision":"allow"'*) printf 'approve'; return ;;
        *'"continue":true'*)              printf 'approve'; return ;;
    esac
    printf 'unrecognized'
}

# --- tool_input builders ----------------------------------------------------
ti_key()   { "$RWT" 10 node -e 'const o={};o[process.argv[2]]=process.argv[1];process.stdout.write(JSON.stringify(o))' "$1" "$2"; }
# The top-level file_path points at an INNOCENT file, so only a walker that
# descends into edits[] can see the protected target.
ti_edits() { "$RWT" 10 node -e 'const e={};e[process.argv[2]]=process.argv[1];process.stdout.write(JSON.stringify({file_path:process.argv[3],edits:[e]}))' "$1" "$2" "$OK"; }
ti_cmd()   { "$RWT" 10 node -e 'process.stdout.write(JSON.stringify({command:process.argv[1]}))' "$1"; }
ti_cmds()  { "$RWT" 10 node -e 'process.stdout.write(JSON.stringify({commands:process.argv.slice(1)}))' "$@"; }

assert_tool() {
    local label="$1" want="$2" tool="$3" ti="$4" got
    got="$(classify "$(run_hook "$tool" "$ti")")"
    if [ "$got" = "$want" ]; then pass "$label -> $got"
    else fail "$label want=$want got=$got"; fi
}
# assert_cmd <label> <want> <command>  — the Bash-shaped shorthand.
assert_cmd() {
    local label="$1" want="$2" cmd="$3" got
    got="$(classify "$(run_hook Bash "$(ti_cmd "$cmd")")")"
    if [ "$got" = "$want" ]; then pass "$label -> $got"
    else fail "$label want=$want got=$got  [cmd=$(printf '%.180s' "$cmd")]"; fi
}
assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then pass "$name"
    else fail "$name - want=$(printf '%q' "$want") got=$(printf '%q' "$got")"; fi
}

# ===========================================================================
# Section T — AXIS 1a: the edit/write tool family x payload keys.
#
# The tool names and the keys are read from hooks/lib/write-tools.js, so adding a
# sixth edit tool to the SSOT without teaching the walker about it FAILS HERE
# rather than shipping as an untested cell. Every cell is asserted independently
# (the protected path appears in that one key and nowhere else), so a regression
# in one key cannot hide behind another key still carrying the value.
#
# NotebookEdit / notebook_path is the cell no existing suite reached: it is the
# one tool in the family whose conventional key is neither `file_path` nor
# `path`, which is exactly the shape a key-specific reader misses.
# ===========================================================================
run_T_tool_shapes() {
    local tools keys tool key
    tools=$("$RWT" 10 node -e \
        'process.stdout.write(require(process.argv[1]).EDIT_WRITE_TOOL_NAMES.join(" "))' "$WT_NODE" 2>/dev/null)
    if [ -z "$tools" ]; then
        fail "T0 write-tools SSOT is introspectable (EDIT_WRITE_TOOL_NAMES export)"
        return
    fi
    assert_eq "T0 write-tools SSOT introspected" "yes" "yes"
    echo "      (edit/write tools under test: $tools)"

    for tool in $tools; do
        for key in file_path path notebook_path; do
            # Top-level key: the protected MARKER.
            assert_tool "T1 $tool.$key -> marker" block "$tool" "$(ti_key "$MK" "$key")"
        done
        # CPR-5: the clearance TOKEN is the marker's symmetric sibling — same
        # privilege, different suffix family. One assertion per tool is enough to
        # prove the token family is not routed differently.
        assert_tool "T2 $tool.file_path -> token" block "$tool" "$(ti_key "$TOK" file_path)"
        # Per-edit key, with an innocent top-level file_path.
        for key in file_path path; do
            assert_tool "T3 $tool.edits[].$key -> marker" block "$tool" "$(ti_edits "$MK" "$key")"
        done
        # --- controls -------------------------------------------------------
        # Same envelope, ordinary path: proves T1/T3 block on the NAME, not on
        # the tool name or the payload shape.
        assert_tool "T4 $tool.file_path -> ordinary file (control)" approve "$tool" "$(ti_key "$OK" file_path)"
        assert_tool "T4 $tool.edits[] -> ordinary file (control)"   approve "$tool" "$(ti_edits "$OK" file_path)"
        # One character short of the protected suffix. This is the tightest
        # control available: it differs from T1 by a single byte.
        assert_tool "T5 $tool.file_path -> marker minus last char (control)" approve "$tool" "$(ti_key "$MK_SHORT" file_path)"
    done

    # Tools NOT in either SSOT list are not this hook's business. Blocking them
    # would make every Read/Grep of a marker fail — a guard nobody can live with
    # is a guard that gets switched off.
    assert_tool "T6 Read (unregistered tool) with a marker path"  approve Read "$(ti_key "$MK" file_path)"
    assert_tool "T6 Grep (unregistered tool) with a marker path"  approve Grep "$(ti_key "$MK" file_path)"
}
run_T_tool_shapes

# ===========================================================================
# Section P — AXIS 1b: command tool parity (CPR-5).
#
# hooks/lib/tool-command-text.js exists because dispatch.js once read
# `tool_input.command` only: a `runCommands` call carries `commands[]` instead,
# so it arrived as `undefined` and was scanned clean. That is a silent FULL
# bypass, not a degraded check, and it is invisible to any suite that only ever
# sends `Bash`.
#
# Parity is asserted by running the SAME attack text through every registered
# command tool. commands[1] is asserted separately from commands[0] because the
# join is what makes a non-first element reachable — a reader that took only
# `commands[0]` would pass the [0] row and fail here.
# ===========================================================================
run_P_command_parity() {
    local tools
    tools=$("$RWT" 10 node -e \
        'process.stdout.write(require(process.argv[1]).COMMAND_TOOL_NAMES.join(" "))' "$TCT_NODE" 2>/dev/null)
    if [ -z "$tools" ]; then
        fail "P0 tool-command-text SSOT is introspectable (COMMAND_TOOL_NAMES export)"
        return
    fi
    echo "      (command tools under test: $tools)"

    local attack="echo x > $MK" control="echo x > $OK" tool ti
    for tool in $tools; do
        case "$tool" in
            runCommands) ti="$(ti_cmds "$attack")" ;;
            *)           ti="$(ti_cmd  "$attack")" ;;
        esac
        assert_tool "P1 $tool -> redirect onto a marker" block "$tool" "$ti"
        case "$tool" in
            runCommands) ti="$(ti_cmds "$control")" ;;
            *)           ti="$(ti_cmd  "$control")" ;;
        esac
        assert_tool "P1 $tool -> redirect onto an ordinary file (control)" approve "$tool" "$ti"
    done

    # The non-first element. Element [0] is innocent, so only a reader that sees
    # the WHOLE array can block.
    assert_tool "P2 runCommands[1] (element 0 innocent) -> marker" block runCommands "$(ti_cmds "echo hi" "echo x > $MK")"
    assert_tool "P2 runCommands[1] both elements innocent (control)" approve runCommands "$(ti_cmds "echo hi" "echo x > $OK")"
    # A non-redirect shape through the array shape, so P2 is not read as a
    # property of redirects specifically.
    assert_tool "P3 runCommands[0] -> symlink onto a marker" block runCommands "$(ti_cmds "ln -s /tmp/x $MK")"
    assert_tool "P3 runCommands[0] -> symlink onto an ordinary file (control)" approve runCommands "$(ti_cmds "ln -s /tmp/x $OK")"
}
run_P_command_parity

# ===========================================================================
# Section W — AXIS 2: the shell shapes that end with the marker existing.
#
# Table format `name|want|command`, iterated with IFS='|' read. `want` sits
# SECOND so that a command containing `|` (pipelines — several rows here) lands
# whole in the last field instead of being truncated by the column split.
#
# Placeholders are substituted from the SSOT-derived values above:
#   @MK@       the marker path            @TOK@     its clearance-token sibling
#   @OK@       an ordinary file           @MKSHORT@ the marker minus its last char
#   @WF@       the fixture workflow dir
#
# PAIRING. Every block row is immediately followed by its control. The pairs are
# built so the control differs by EXACTLY the protected property:
#   W-redir / W-redir-ok      same redirect, ordinary path
#   W-glob  / W-glob-ok       a `?` that CAN complete the suffix vs one that
#                             cannot contribute a literal character to it
#   W-brace / W-brace-ok      a brace alternative that rebuilds the marker vs
#                             alternatives none of which do
#   W-ansi  / W-ansi-short    an ANSI-C escape decoding to the final character
#                             vs the same string one character short
#   W-node  / W-node-ok       an interpreter one-liner that WRITES vs one that
#                             does not name a protected path at all
#   W-var-gap                 the #1780 N-1 shape: an assignment separated from
#                             its use by an unrelated command. Contiguity is not
#                             a shell scoping rule, and a scanner that assumes it
#                             is has a one-command bypass.
# ===========================================================================
run_W_attack_shapes() {
    local name want cmd tbl
    tbl="$SANDBOX/W.tbl"
    sed -e "s#@MKSHORT@#$MK_SHORT#g" -e "s#@MK@#$MK#g" -e "s#@TOK@#$TOK#g" \
        -e "s#@OK@#$OK#g" -e "s#@WF@#$WF#g" > "$tbl"
    while IFS='|' read -r name want cmd; do
        [ -z "${name:-}" ] && continue
        case "$name" in \#*) continue ;; esac
        name="$(printf '%s' "$name" | sed 's/^ *//; s/ *$//')"
        want="$(printf '%s' "$want" | sed 's/^ *//; s/ *$//')"
        # `\n` in the command column becomes a real newline: heredoc rows are
        # multi-line by nature, and a line-based table that cannot express a
        # newline simply has no heredoc coverage.
        # Only `\n` is decoded — deliberately NOT printf '%b', which would also
        # eat the `\x66` in the ANSI-C row that is itself under test.
        cmd="$(printf '%s' "$cmd" | sed -e 's/^ *//' -e 's/\\n/\n/g')"
        assert_cmd "W $name" "$want" "$cmd"
    done < "$tbl"
    # The table is materialized to a file first (the sed above consumes stdin),
    # so the loop must read from that file rather than from the drained stdin.
    # Guard against the silent-empty failure mode: a table that produced no rows
    # would otherwise report a clean run having asserted nothing.
    if [ "$(grep -c '^[A-Za-z]' "$tbl")" -lt 10 ]; then
        fail "W table produced fewer than 10 rows - the section is vacuous"
    fi
}

run_W_attack_shapes <<'TABLE'
# --- redirects and file-creating verbs -------------------------------------
W-redir        | block   | echo x > @MK@
W-redir-ok     | approve | echo x > @OK@
W-append       | block   | echo x >> @MK@
W-append-ok    | approve | echo x >> @OK@
W-tee          | block   | echo x | tee @MK@
W-tee-ok       | approve | echo x | tee @OK@
W-touch        | block   | touch @MK@
W-touch-ok     | approve | touch @OK@
W-cp           | block   | cp /etc/hosts @MK@
W-cp-ok        | approve | cp /etc/hosts @OK@
W-mv           | block   | mv /tmp/a @MK@
W-mv-ok        | approve | mv /tmp/a @OK@
W-install      | block   | install /tmp/x @MK@
W-install-ok   | approve | install /tmp/x @OK@
W-dd           | block   | dd if=/dev/null of=@MK@
W-dd-ok        | approve | dd if=/dev/null of=@OK@
W-printf       | block   | printf 'x' > @MK@
W-printf-ok    | approve | printf 'x' > @OK@
# Deletion is forgery too: removing a token is how a one-shot clearance is
# replayed, so the guard is not "creation" but "write to the name".
W-rm           | block   | rm -f @MK@
W-rm-ok        | approve | rm -f @OK@
W-rm-token     | block   | rm -f @TOK@
# --- link shapes: no bytes are written, yet the marker path comes to exist --
W-symlink      | block   | ln -s /tmp/x @MK@
W-symlink-ok   | approve | ln -s /tmp/x @OK@
W-symlink-tok  | block   | ln -s /tmp/x @TOK@
W-hardlink     | block   | ln /tmp/x @MK@
W-hardlink-ok  | approve | ln /tmp/x @OK@
# --- indirection: the protected name never appears in write position -------
W-var          | block   | A=@MK@; touch $A
W-var-ok       | approve | A=@OK@; touch $A
W-var-gap      | block   | A=@MK@; echo hi; touch $A
W-var-gap-ok   | approve | A=@OK@; echo hi; touch $A
W-pwshvar      | block   | $env:A=@MK@; touch $env:A
W-pwshvar-ok   | approve | $env:A=@OK@; touch $env:A
# --- shell expansion: the name is ASSEMBLED, not typed ----------------------
W-glob         | block   | touch @MKSHORT@?
W-glob-ok      | approve | touch /tmp/logs-2024?
W-brace        | block   | touch @MKSHORT@{f..f}
W-brace-ok     | approve | touch @MKSHORT@{x,y}
W-ansi         | block   | touch $'@MKSHORT@\x66'
W-ansi-short   | approve | touch $'@MKSHORT@'
# Command substitution has its own file (round-11); one parity row only, so the
# matrix is not silently missing the axis. The control writes OUTSIDE the
# workflow dir on purpose: a substitution target inside it is unresolvable AND
# workflow-scoped, which is the separate `workflow-dynamic` block kind (Section
# O7's neighbour) rather than the protected-name decision this pair is about.
W-subst        | block   | touch "$(printf '%s' @MK@)"
W-subst-ok     | approve | touch "$(printf '%s' /tmp/notes.txt)"
# --- interpreters: no shell write verb is involved at all -------------------
W-node         | block   | node -e "require('fs').writeFileSync('@MK@','x')"
W-node-ok      | approve | node -e "console.log(1)"
W-node-read    | approve | node -e "console.log(require('fs').readFileSync('@MK@','utf8'))"
W-python       | block   | python3 -c "open('@MK@','w').write('x')"
W-python-ok    | approve | python3 -c "print(1)"
W-awk          | block   | awk 'BEGIN{print "x" > "@MK@"}'
W-awk-ok       | approve | awk 'BEGIN{print "x"}'
W-pwsh         | block   | pwsh -Command "Set-Content @MK@ x"
W-pwsh-ok      | approve | pwsh -Command "Get-Date"
# --- stdin routes: the program text is not on argv --------------------------
W-heredoc      | block   | cat <<EOF > @MK@\nx\nEOF
W-heredoc-ok   | approve | cat <<EOF > @OK@\nx\nEOF
W-heredoc-prog | block   | node <<EOF\nrequire('fs').writeFileSync('@MK@','x')\nEOF
W-heredoc-prog-ok | approve | node <<EOF\nconsole.log(1)\nEOF
W-herestring   | block   | sh <<< 'rm @MK@'
W-herestring-ok | approve | sh <<< 'rm @OK@'
W-pipe-sh      | block   | echo 'rm @MK@' | sh
W-pipe-sh-ok   | approve | echo 'rm @OK@' | sh
W-eval         | block   | eval rm @MK@
W-eval-ok      | approve | eval rm @OK@
TABLE

# ===========================================================================
# Section O — over-block sizing, and the over-blocks that are ACCEPTED.
#
# A denylist this broad is only usable if ordinary work survives it. These rows
# are the cost side of the ledger: if a change to the classifier starts blocking
# them, the guard has become the kind of obstacle that gets disabled, which
# costs more protection than the change buys.
#
# The last two rows record over-blocks that are DELIBERATE and named. They are
# pinned so the behaviour is a decision on the record rather than folklore: both
# err toward blocking a command that merely NAMES a protected path, which is the
# fail-closed direction, and neither can grant clearance.
# ===========================================================================
run_O_over_block() {
    assert_cmd "O1 ordinary redirect in the workflow dir" approve "echo x > $OK"
    assert_cmd "O1 ordinary append to a log"              approve "echo x >> $WF/run.log"
    assert_cmd "O1 dynamic redirect to \$LOG"             approve 'echo x > $LOG'
    assert_cmd "O1 dynamic redirect to \$TMPDIR/out.txt"  approve 'echo x > $TMPDIR/out.txt'
    # Outside the workflow dir. A glob INSIDE it is blocked by design (the
    # `workflow-glob` kind) — see O7 below, which pins that as a pair with this.
    assert_cmd "O2 bulk delete by glob outside the workflow dir" approve "rm -rf /tmp/build/*"
    assert_cmd "O2 mkdir"                                 approve "mkdir -p $WF/sub"
    assert_cmd "O2 git log redirected to a file"          approve "git log > $WF/out.txt"
    # Reading a marker is not writing it. `cat`/`less`/`grep` are on the
    # read-only allowlist precisely so inspection stays possible.
    assert_cmd "O3 cat a marker (read, not write)"        approve "cat $MK"
    assert_cmd "O3 less a marker (read, not write)"       approve "less $MK"
    assert_cmd "O3 grep a marker (read, not write)"       approve "grep -n x $MK"
    # ...but the one allowlisted reader that can CREATE a file is re-checked on
    # its arguments: `less -o FILE` writes FILE.
    assert_cmd "O4 less -o onto a marker (allowlisted reader that writes)" block "less -o $MK /etc/hosts"
    # A near-miss name that merely CONTAINS the suffix without ending in it.
    assert_cmd "O5 name containing but not ending with the suffix" approve "echo x > $WF/notes${MARKER_SUFFIX}x"
    assert_cmd "O5 name one character short of the suffix"         approve "touch $MK_SHORT"

    # --- accepted, named over-blocks ---------------------------------------
    # Both of these are commands that only MENTION a marker path. The scanner
    # does not model argument position finely enough to clear them, and the
    # widening direction is the safe one for a denylist guarding an existence
    # check. Recorded here so a future narrowing is a deliberate change with a
    # failing test to update, not an accident.
    assert_cmd "O6 accepted over-block: marker as a cp SOURCE" block "cp $MK /tmp/backup"
    assert_cmd "O6 accepted over-block: echo naming a marker"  block "echo $MK"

    # O7 — the `workflow-glob` kind, paired with O2. A wildcard delete INSIDE the
    # workflow dir cannot be shown NOT to sweep up a marker, so it is blocked;
    # the identical shape outside that dir (O2) is not. The pair is what states
    # that the rule is scoped to the directory rather than to the wildcard.
    assert_cmd "O7 wildcard delete INSIDE the workflow dir" block "rm -rf $WF/build/*"
}
run_O_over_block

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
