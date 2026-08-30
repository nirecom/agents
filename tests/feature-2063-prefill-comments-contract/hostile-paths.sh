#!/usr/bin/env bash
# tests/feature-2063-prefill-comments-contract/hostile-paths.sh
# Tests: skills/workflow-init/SKILL.md, bin/workflow/render-issue-comments
# Tags: workflow-init, prompt-contract, static-grep, issue-comments, tl2, scope:issue-specific

# W9, W9b, W9c, W12 (#2063, security): the <CHECKPOINT> placeholder and the $AGENTS_CONFIG_DIR the command resolves the CLI through are values, never fragments of shell — one row per hostile shape a user-owned path may legitimately contain, plus the apostrophe handed over as argv data and the apostrophe pushed back through the real template.

# TL3 gap: whether the agent performs the documented steps is not observable — only
# the structure of what it is told to do is. Mitigated at WORKFLOW_USER_VERIFIED
# preflight via bin/check-verification-gate.sh category: skill-orchestration.

set -u
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_lib.sh"

# --- W9 (security): the checkpoint path is a value, never a fragment of shell ---
# W2/W4 use one tame temp path, so a template that forgot its quotes -- or a CLI that
# re-enters a shell with the path -- passes them both. The plans dir is user-owned
# (`C:\Users\First Last\...` is ordinary), so the path is attacker-adjacent input.
markers_found() {  # any side effect a hostile path talked the shell into performing
    find "$TMPD" -name 'PWNED*' 2>/dev/null | head -5 | tr '\n' ' '
}

INJ_ROOT="$TMPD/inj"
INJ_CWD="$TMPD/injcwd"
mkdir -p "$INJ_ROOT" "$INJ_CWD"

if [ -z "$CMD_TEMPLATE" ]; then
    fail "W9: the B1 template quotes its <CHECKPOINT> placeholder (no command to inspect)"
    fail "W9/spaces-raw: a path with spaces survives the template as written (no command to execute)"
else
    # SINGLE quotes, not "any quotes". The path is pasted in as literal text, so under
    # double quotes `$(...)`, backticks and `\` still expand — a template quoted that way
    # executes a hostile directory name. Single quotes are the only form under which
    # every shape in the table below is inert.
    case "$CMD_TEMPLATE" in
        *"'<CHECKPOINT>'"*)
            pass "W9: the B1 template wraps <CHECKPOINT> in single quotes" ;;
        *'"<CHECKPOINT>"'*)
            fail "W9: the B1 template double-quotes <CHECKPOINT> — a pasted path containing \$( ) or backticks still executes: '$CMD_TEMPLATE'" ;;
        *)
            fail "W9: the B1 template leaves <CHECKPOINT> unquoted — an agent pasting a path with a space produces a broken command: '$CMD_TEMPLATE'" ;;
    esac

    # The agent-faithful case: the literal path text is pasted into the template as
    # written. A space is the everyday shape, so this must hold with no help from us.
    SPACE_DIR="$INJ_ROOT/plans dir with spaces"
    mkdir -p "$SPACE_DIR"
    cp "$TMPD/ckpt.json" "$SPACE_DIR/ckpt.json"
    CMD_RAW="$(subst_raw "$CMD_TEMPLATE" "$(nodepath "$SPACE_DIR/ckpt.json")" "$N")"
    W9_RAW_OUT="$(cd "$INJ_CWD" && bash -c "$CMD_RAW" 2>"$TMPD/w9raw.err")"
    W9_RAW_RC=$?
    assert_eq "W9/spaces-raw: a path with spaces survives the template as written" "0" "$W9_RAW_RC"
    case "$W9_RAW_OUT" in
        *'first prefill remark'*) pass "W9/spaces-raw: the comment body still reaches stdout" ;;
        *) fail "W9/spaces-raw: no comment body on stdout: err='$(head -c 160 "$TMPD/w9raw.err")'" ;;
    esac
fi

# One row per hostile shape a path may legitimately contain, `name|class|dirname`. Every
# row substitutes RAW — literal path text, no quoting added here — so the subject is the
# quoting SKILL.md's template carries. The heredoc is quoted: $( ) and backticks arrive
# literal. Class `renders` = a single-quoted template must run it to completion; class
# `inert` = the path breaks the command string (a literal `'` closes the template's own
# quote), so the only contract is "no side effect" — no static template can carry a path
# containing its own quote character, and failing loudly is the defensible behaviour.
while IFS='~' read -r W9_NAME W9_CLASS W9_DIR; do
    [ -n "${W9_NAME:-}" ] || continue
    if [ -z "$CMD_TEMPLATE" ]; then
        fail "W9/$W9_NAME: not observable (no command to execute)"
        continue
    fi
    W9_PATH="$INJ_ROOT/$W9_DIR"
    if ! mkdir -p "$W9_PATH" 2>/dev/null || [ ! -d "$W9_PATH" ]; then
        echo "SKIP: W9/$W9_NAME: Skipped-Because: this filesystem refuses a directory named [$W9_DIR], so the shape cannot be staged here"
        continue
    fi
    cp "$TMPD/ckpt.json" "$W9_PATH/ckpt.json" 2>/dev/null || true
    W9_CMD="$(subst_raw "$CMD_TEMPLATE" "$(nodepath "$W9_PATH/ckpt.json")" "$N")"
    W9_OUT="$(cd "$INJ_CWD" && bash -c "$W9_CMD" 2>"$TMPD/w9.err")"
    W9_RC=$?
    W9_RAN=$((${W9_RAN:-0} + 1))
    if [ "$W9_CLASS" = "renders" ]; then
        assert_eq "W9/$W9_NAME: a valid checkpoint under this path exits 0" "0" "$W9_RC"
        case "$W9_OUT" in
            '## Issue comments'*) pass "W9/$W9_NAME: the rendered section is intact" ;;
            *) fail "W9/$W9_NAME: stdout is not the comments section: '$(printf '%s' "$W9_OUT" | head -c 120)' err='$(head -c 160 "$TMPD/w9.err")'" ;;
        esac
    else
        # Whatever the exit status, a command string this path broke must not have
        # rendered a section anyway — a partial parse falling back elsewhere would.
        case "$W9_OUT" in
            '') pass "W9/$W9_NAME: the broken command string produced no output at all" ;;
            *) fail "W9/$W9_NAME: a command string this path broke still produced output: '$(printf '%s' "$W9_OUT" | head -c 120)'" ;;
        esac
    fi
done <<'TABLE'
spaces~renders~plans dir with spaces
dollar-substitution~renders~plans$(touch PWNED-DOLLAR)dir
backticks~renders~plans`touch PWNED-TICK`dir
semicolon~renders~plans;touch PWNED-SEMI;dir
ampersand~renders~plans&touch PWNED-AMP&dir
redirect~renders~plans dir > PWNED-REDIR
append-redirect~renders~plans dir >> PWNED-APPEND
pipe-to-command~renders~plans dir | touch PWNED-PIPE
subshell-parens~renders~plans(touch PWNED-PAREN)dir
double-quote~renders~plans"dir
backslash-escape~renders~plans\$(touch PWNED-ESC)dir
single-quote~inert~plans'dir
TABLE

# --- W9b: the apostrophe path itself is fine — only interpolation is the blocker ----
# The `single-quote~inert` row above accepts failure, because a path carrying the
# template's own quote character breaks the command STRING. Left there alone, a CLI
# that simply cannot open a path containing an apostrophe passes the whole file. So the
# same directory is rendered once more with the path handed over as DATA — an argv
# element the shell never re-parses, which is what any caller building the invocation
# programmatically does — and success is REQUIRED. Together the two rows separate the
# defect from the shape: the string is what breaks, never `O'Brien` in a home directory.
W9B_CLI="$AGENTS_DIR/bin/workflow/render-issue-comments"
W9B_PATH="$INJ_ROOT/plans'dir"
if [ ! -f "$W9B_CLI" ]; then
    fail "W9b/apostrophe-argv: not observable — bin/workflow/render-issue-comments does not exist"
    fail "W9b/apostrophe-argv: not observable — no rendered section to inspect"
elif ! mkdir -p "$W9B_PATH" 2>/dev/null || [ ! -d "$W9B_PATH" ]; then
    echo "SKIP: W9b/apostrophe-argv: Skipped-Because: this filesystem refuses a directory named [plans'dir], so the shape cannot be staged here"
else
    cp "$TMPD/ckpt.json" "$W9B_PATH/ckpt.json"
    W9B_OUT="$(cd "$INJ_CWD" && node "$W9B_CLI" --checkpoint "$(nodepath "$W9B_PATH/ckpt.json")" --issue "$N" 2>"$TMPD/w9b.err")"
    W9B_RC=$?
    assert_eq "W9b/apostrophe-argv: an apostrophe in the checkpoint path is not itself a failure" "0" "$W9B_RC"
    case "$W9B_OUT" in
        '## Issue comments'*'first prefill remark'*)
            pass "W9b/apostrophe-argv: the section renders in full from behind the apostrophe" ;;
        *)
            fail "W9b/apostrophe-argv: stdout is not the rendered section: '$(printf '%s' "$W9B_OUT" | head -c 160)' err='$(head -c 160 "$TMPD/w9b.err")'" ;;
    esac
fi

# --- W9c: the apostrophe at the TEMPLATE boundary, not only at the CLI's argv -------
# W9b hands the path over as argv, bypassing the template; the `single-quote~inert` row
# accepts failure. Between them nothing requires the SKILL.md command to WORK for a
# checkout under `C:\Users\O'Brien\...`. W9 fixes the quoting form as single quotes, and a
# literal `'` cannot sit inside a single-quoted span, so B1 has to TELL the agent how to
# escape it before pasting. Only a real shell paste crosses that boundary, so the argv
# route W9b takes cannot cover it; the rule is therefore EXTRACTED and APPLIED, never
# recognized by keyword. A wrong documented replacement produces a wrong transform and
# fails here — which a test carrying its own idea of the escape sequence could not do.
W9C_TO="$(SKILL_LINE_IN="$B1_LINE" node -e '
const line = process.env.SKILL_LINE_IN || "";
const AP = "\u0027";
const re = /`([^`]*)`/g;
const spans = []; let m;
while ((m = re.exec(line)) !== null) spans.push({ text: m[1], start: m.index, end: re.lastIndex });
for (let i = 0; i < spans.length; i++) {
  if (spans[i].text !== AP) continue;
  for (let j = i + 1; j < spans.length; j++) {
    if (spans[j].text.length < 2 || spans[j].text.indexOf(AP) === -1) continue;
    if (!/\b(with|by|as|into)\b/i.test(line.slice(spans[i].end, spans[j].start)) &&
        !/(→|->)/.test(line.slice(spans[i].end, spans[j].start))) break;
    process.stdout.write(spans[j].text);
    process.exit(0);
  }
}
process.stdout.write("");
')"
if [ -n "$W9C_TO" ]; then
    pass "W9c: the B1 line carries an extractable apostrophe-escaping rule (replacement: [$W9C_TO])"
else
    fail "W9c: SKILL.md has no escaping rule to test yet — the B1 line names no \`'\` → replacement pair, and under W9's mandatory single quoting a path containing an apostrophe cannot be pasted at all: '$(printf '%s' "$B1_LINE" | head -c 200)'"
fi
W9C_PATH="$INJ_ROOT/plans-apostrophe/plans'dir"
W9C_STAGED=0
if [ -z "$W9C_TO" ] || [ -z "$CMD_TEMPLATE" ]; then
    fail "W9c/apostrophe-template: the real B1 template is not yet required to survive an apostrophe path (no escaping rule to apply)"
    fail "W9c/apostrophe-template: the rendered section is not observable (no escaping rule to apply)"
elif ! mkdir -p "$W9C_PATH" 2>/dev/null || [ ! -d "$W9C_PATH" ]; then
    echo "SKIP: W9c/apostrophe-template: Skipped-Because: this filesystem refuses a directory named [plans'dir], so the shape cannot be staged here"
else
    W9C_STAGED=1
    cp "$TMPD/ckpt.json" "$W9C_PATH/ckpt.json"
    # SKILL.md's own replacement, applied literally — the transform is the document's.
    W9C_ESCAPED="$(W9C_TO_IN="$W9C_TO" node -e '
process.stdout.write(process.argv[1].split("\u0027").join(process.env.W9C_TO_IN || ""));
' "$(nodepath "$W9C_PATH/ckpt.json")")"
    W9C_OUT="$(cd "$INJ_CWD" && bash -c "$(subst_raw "$CMD_TEMPLATE" "$W9C_ESCAPED" "$N")" 2>"$TMPD/w9c.err")"
    W9C_RC=$?
    assert_eq "W9c/apostrophe-template: the escaped path renders through the real B1 template" "0" "$W9C_RC"
    case "$W9C_OUT" in
        '## Issue comments'*'first prefill remark'*)
            pass "W9c/apostrophe-template: the section renders in full through the template itself" ;;
        *)
            fail "W9c/apostrophe-template: stdout is not the rendered section: '$(printf '%s' "$W9C_OUT" | head -c 160)' err='$(head -c 160 "$TMPD/w9c.err")'" ;;
    esac
fi

# --- W9c/control: the case above is sensitive to WHAT the rule says -----------------
# Applying an extracted rule only proves something if a DIFFERENT rule would have been
# caught. `\'` is the classic wrong answer — a backslash escapes nothing inside single
# quotes — so putting it through the same template must NOT render the section. If it
# does, the run above is passing on something other than the escaping and W9c is back to
# where C3 found it. The wrong sequence is hardcoded on purpose: it is the control, not
# the subject, and it is never the value the passing path uses.
if [ "$W9C_STAGED" != "1" ]; then
    fail "W9c/control: a wrong escaping rule cannot be shown to fail (the apostrophe path was not staged)"
else
    W9C_BAD="$(node -e '
process.stdout.write(process.argv[1].split("\u0027").join("\\\u0027"));
' "$(nodepath "$W9C_PATH/ckpt.json")")"
    W9C_BAD_OUT="$(cd "$INJ_CWD" && bash -c "$(subst_raw "$CMD_TEMPLATE" "$W9C_BAD" "$N")" 2>/dev/null)"
    case "$W9C_BAD_OUT" in
        *'## Issue comments'*)
            fail "W9c/control: a knowingly wrong escaping rule still rendered the section — W9c is not testing the rule" ;;
        *)
            pass "W9c/control: a knowingly wrong escaping rule renders nothing, so W9c tests the rule itself" ;;
    esac
fi

# --- W12 (security): the EXECUTABLE half of the command carries a hostile path too --
# Every row above varies <CHECKPOINT> and leaves the other half of the B1 command — the
# path the CLI itself is resolved through, $AGENTS_CONFIG_DIR — on the tame worktree.
# A checkout under `C:\Users\First Last\...` is ordinary, so that half is user-owned
# input on the same footing: unquoted, it word-splits on the first space and the step
# fails for every such user, and `$( )` in the directory name is the injection shape.
W12_CFG="$TMPD"'/cfg $(touch PWNED-CFG)&;dir'
if [ -z "$CMD_TEMPLATE" ]; then
    fail "W12: the B1 command runs with the CLI under a hostile path (no command to execute)"
    fail "W12: the rendered section is intact from the relocated tree (no command to execute)"
    fail "W12: no side effect from the hostile executable path (no command to execute)"
elif ! mkdir -p "$W12_CFG" 2>/dev/null || [ ! -d "$W12_CFG" ]; then
    echo "SKIP: W12: Skipped-Because: this filesystem refuses a directory named [$W12_CFG], so the shape cannot be staged here"
else
    # Relocating the tree only proves something if the command actually resolves the CLI
    # through the variable being relocated; otherwise every assertion below is vacuous.
    case "$CMD_TEMPLATE" in
        *AGENTS_CONFIG_DIR*)
            pass "W12: the B1 command resolves the CLI through \$AGENTS_CONFIG_DIR (the relocation is observable)" ;;
        *)
            fail "W12: the B1 command never names AGENTS_CONFIG_DIR, so relocating the tree proves nothing: '$CMD_TEMPLATE'" ;;
    esac
    cp -R "$AGENTS_DIR/bin" "$W12_CFG/bin" 2>/dev/null || true
    # The checkpoint stays tame here: exactly one variable changes, so a failure names
    # the executable path rather than being shared with the W9 rows above.
    W12_CMD="$(subst_raw "$CMD_TEMPLATE" "$(nodepath "$TMPD/ckpt.json")" "$N")"
    W12_OUT="$(cd "$INJ_CWD" && AGENTS_CONFIG_DIR="$(nodepath "$W12_CFG")" bash -c "$W12_CMD" 2>"$TMPD/w12.err")"
    W12_RC=$?
    assert_eq "W12: the B1 command exits 0 with the CLI under a path with spaces and metacharacters" "0" "$W12_RC"
    case "$W12_OUT" in
        '## Issue comments'*) pass "W12: the rendered section is intact from the relocated tree" ;;
        *) fail "W12: stdout is not the comments section: '$(printf '%s' "$W12_OUT" | head -c 120)' err='$(head -c 160 "$TMPD/w12.err")'" ;;
    esac
    case "$W12_OUT" in
        *'first prefill remark'*) pass "W12: the comment body still reaches stdout from the relocated tree" ;;
        *) fail "W12: no comment body on stdout: err='$(head -c 160 "$TMPD/w12.err")'" ;;
    esac
    W12_MARKS="$(markers_found)"
    if [ -z "$W12_MARKS" ]; then
        pass "W12: the metacharacters in the executable path produced no side effect"
    else
        fail "W12: the executable path was re-entered by a shell — marker file(s) created: $W12_MARKS"
    fi
fi

# The load-bearing half: no row may have talked a shell into doing anything.
# With no row executed there is nothing to have executed, so absence of markers proves
# nothing — the two assertions below are reported unmet rather than trivially met.
if [ "${W9_RAN:-0}" -lt 1 ]; then
    fail "W9: no hostile-path row executed — the side-effect assertions are unfalsifiable"
    fail "W9: no hostile-path row executed — the stray-file assertion is unfalsifiable"
else
    W9_MARKS="$(markers_found)"
    if [ -z "$W9_MARKS" ]; then
        pass "W9: none of the $W9_RAN hostile checkpoint paths produced a side effect under the fixture"
    else
        fail "W9: a hostile checkpoint path executed — marker file(s) created: $W9_MARKS"
    fi
    W9_CWD_LEFTOVERS="$(find "$INJ_CWD" -type f 2>/dev/null | head -5 | tr '\n' ' ')"
    assert_eq "W9: the run directory is still empty — the CLI wrote no stray file" "" "$W9_CWD_LEFTOVERS"
fi

finish
