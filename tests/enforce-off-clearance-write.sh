#!/usr/bin/env bash
# tests/enforce-off-clearance-write.sh
# Tests: hooks/block-off-clearance-write.js
# Tags: anti-cheat, off-clearance, pretooluse, block-write, vector2, classifier, scope:issue-specific, pwsh-not-required, TL1, hook-registration
#
# #1608 anti-cheat (best-effort): block direct writes to the clearance-token path
# (<workflowDir>/<sid>.off-clearance). Mirrors block-memory-direct.js + adds a vector2
# interpreter-body heuristic (node -e / python -c writing to the token dir).
#
# KNOWN-BYPASS (accepted limitation - detail plan "Anti-cheat trust model"):
#   Dynamic path construction (variable concat / base64 / alternate interpreter),
#   editing the examiner script / codex / this hook itself are NOT detectable.
#   The TRUE gate is Phase2 human approval + audit, NOT this best-effort block.
# Classifier symmetry (test-design.md L36): every block case is paired with a
# sanctioned unrelated-path APPROVE case so the hook does not over-block.
#
# ---------------------------------------------------------------------------
# ASSERTION CONTRACT (this is deliberately strict - see classify() below).
#
# A previous revision asserted "allowed" as merely "the output does not contain
# a block decision". Under that rule a hook CRASH (stack trace to stderr, empty
# stdout), a TIMEOUT, or any unrecognised stdout all scored as PASS - a silent
# false green on exactly the failure modes a security hook must never have.
#
# The real contract of hooks/block-off-clearance-write.js is:
#   - it ALWAYS exits 0 (it never signals via exit code), and
#   - it ALWAYS writes a JSON decision to stdout:
#       {"decision":"approve"} | {"hookSpecificOutput":...allow...}   -> allow
#       {"decision":"block","reason":...}                             -> block
# So an allow is only an allow when the process exited 0 AND affirmatively said
# so. Every other observation (non-zero exit, 124 timeout from run-with-timeout,
# empty stdout, unparseable stdout, hook file missing) is its own distinct
# verdict token and can never be confused with "approve".
# ---------------------------------------------------------------------------

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"; else _AGENTS_DIR_NODE="$AGENTS_DIR"; fi
HOOK="$AGENTS_DIR/hooks/block-off-clearance-write.js"
RWT="$AGENTS_DIR/bin/run-with-timeout.sh"

PASS=0; FAIL=0; SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
make_tmp() { mktemp -d 2>/dev/null || mktemp -d -t 'offwrite'; }
node_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }

HOOK_PRESENT=no; [ -f "$HOOK" ] && HOOK_PRESENT=yes

# run_hook_at <hook-script-path> <tmp_node> <hook-input-json> -> "<rc>|<stdout, newlines stripped>"
# stderr is discarded on purpose: a crashing hook must be detected by rc/stdout,
# not by us eyeballing a stack trace. Parameterized on hook-script-path so the
# DIFF-* differential block (near end of file) can point the SAME invocation
# mechanism at an alternate (pre-PR, main-branch) copy of the hook without
# duplicating the run/redact/rc-capture logic.
run_hook_at() {
    local hook="$1" tn="$2" input="$3" out rc
    [ -f "$hook" ] || { printf 'absent|'; return; }
    out=$(CLAUDE_WORKFLOW_DIR="$tn" AGENTS_CONFIG_DIR="$_AGENTS_DIR_NODE" \
        "$RWT" 12 node "$hook" <<< "$input" 2>/dev/null)
    rc=$?
    printf '%s|%s' "$rc" "$(printf '%s' "$out" | tr -d '\r\n')"
}

# run_hook <tmp_node> <hook-input-json> -> "<rc>|<stdout, newlines stripped>"
# Existing call sites are unchanged: this is just run_hook_at bound to $HOOK.
run_hook() { run_hook_at "$HOOK" "$1" "$2"; }

# classify "<rc>|<out>" -> approve | block | timeout | crash:<rc> | empty | unrecognized | hook-absent
# Single chokepoint so no call site can invent a looser notion of "allowed".
classify() {
    local raw="$1" rc out
    rc="${raw%%|*}"; out="${raw#*|}"
    case "$rc" in
        absent) printf 'hook-absent'; return ;;
        124)    printf 'timeout'; return ;;
        0)      ;;
        *)      printf 'crash:%s' "$rc"; return ;;
    esac
    [ -z "$out" ] && { printf 'empty'; return; }
    case "$out" in
        *'"decision":"block"'*)   printf 'block'; return ;;
        *'"decision":"approve"'*) printf 'approve'; return ;;
    esac
    # Some hooks allow via hookSpecificOutput/permissionDecision instead of a bare
    # decision field; accept those explicitly rather than by absence of "block".
    case "$out" in
        *'"permissionDecision":"allow"'*) printf 'approve'; return ;;
        *'"continue":true'*)              printf 'approve'; return ;;
    esac
    printf 'unrecognized'
}

# assert_verdict <label> <want> <raw "rc|out">
assert_verdict() {
    local label="$1" want="$2" raw="$3" got
    got="$(classify "$raw")"
    if [ "$got" = "$want" ]; then pass "$label -> $got"
    else fail "$label want=$want got=$got  [raw=$(printf '%.200s' "$raw")]"; fi
}
assert_block()   { assert_verdict "$1" block "$2"; }
assert_approve() { assert_verdict "$1" approve "$2"; }

mk_bash_input() { "$RWT" 8 node -e "process.stdout.write(JSON.stringify({tool_name:'Bash',session_id:'wsid',tool_input:{command:process.argv[1]}}))" "$1"; }
mk_file_input() { "$RWT" 8 node -e "process.stdout.write(JSON.stringify({tool_name:process.argv[1],session_id:'wsid',tool_input:{file_path:process.argv[2]}}))" "$1" "$2"; }

TMP=$(make_tmp); TN=$(node_path "$TMP")
TOKEN="$TN/wsid.off-clearance"

# H0 - harness self-check: the hook file must exist, otherwise every verdict below
# is "hook-absent" and the file proves nothing. Asserted so the vacuous run is loud.
if [ "$HOOK_PRESENT" = "yes" ]; then pass "H0 hook file present"; else fail "H0 hook file MISSING at $HOOK - all cases below are vacuous"; fi

# --- block: Bash redirect / tee / cp to token path ---
assert_block "B1 redirect > token"        "$(run_hook "$TN" "$(mk_bash_input "echo x > $TOKEN")")"
assert_block "B2 tee token"               "$(run_hook "$TN" "$(mk_bash_input "echo x | tee $TOKEN")")"
assert_block "B3 cp to token"             "$(run_hook "$TN" "$(mk_bash_input "cp /etc/hosts $TOKEN")")"

# --- block: Write / Edit tool on token path ---
assert_block "B4 Write token file_path"   "$(run_hook "$TN" "$(mk_file_input Write "$TOKEN")")"
assert_block "B5 Edit token file_path"    "$(run_hook "$TN" "$(mk_file_input Edit "$TOKEN")")"

# --- block: vector2 interpreter-body heuristic (node -e writing into token dir) ---
V2CMD="node -e \"require('fs').writeFileSync(process.env.CLAUDE_WORKFLOW_DIR + '/wsid.off-clearance','forged')\""
assert_block "B6 vector2 node -e .off-clearance" "$(run_hook "$TN" "$(mk_bash_input "$V2CMD")")"

# --- approve: sanctioned unrelated paths (CPR-5 counterparts) ---
# These are the cases the strict classifier matters most for: before it, a crashed
# hook produced no block message and therefore "passed" all three.
assert_approve "A1 redirect > unrelated file"  "$(run_hook "$TN" "$(mk_bash_input "echo x > $TN/notes.txt")")"
assert_approve "A2 Write unrelated file_path"  "$(run_hook "$TN" "$(mk_file_input Write "$TN/other.json")")"
assert_approve "A3 harmless node -e (no token)" "$(run_hook "$TN" "$(mk_bash_input "node -e \"console.log(1+1)\"")")"

# ============================================================================
# #1709b (S-3) - read/write classification rewrite: positive read-only ALLOWLIST.
#
# The old classifier was a negative denylist ("interpreter one-liner + the literal
# string off-clearance -> block"), which both over-blocks (legitimate READS of a
# token are refused) and is bypassable (any constructed/interpolated path escapes).
# The replacement is a positive allowlist of read-only SHAPES, anchored end-to-end,
# with a language-specific PATH_ARG grammar:
#   node / python : single-quoted literals, backtick- and backslash-free
#                   double-quoted literals, process.env.X / os.environ['X']
#   PowerShell    : single-quoted literals and bare $env:NAME ONLY
#                   (no double-quoted form at all - PowerShell interpolates inside "")
# A shared INTERPOLATION_RE prefilter rejects backtick, backslash, $( , ${ , @(
# and f-string markers (f' / f") BEFORE any shape matching runs, so a payload that
# merely LOOKS like a read shape cannot smuggle a subexpression through its argument.
# Anything the grammar cannot extract and prove read-only is fail-closed blocked.
#
# Not-weaker-than-pre-PR corpus check (DIFF-*, near end of file, supervisor-
# audit-5): re-running this suite's OWN cases can only prove this branch's
# hook agrees with itself - it can never catch a BLOCK->APPROVE regression on
# a payload the suite doesn't already contain, which is exactly how the
# process.env indirection regression below (SA5) slipped through review. The
# DIFF-* block instead invokes BOTH this branch's hook AND a separate, clean
# pre-PR checkout of the same hook (C:/git/agents/hooks/block-off-clearance-
# write.js, main branch) against an identical curated payload corpus and
# asserts this branch is never weaker: whenever the pre-PR hook blocks, this
# branch's hook must also block. This branch blocking a payload the pre-PR
# hook approved is expected (that is what H2/H3/SA5 hardening is for) and is
# not a failure. Gracefully skipped when the reference checkout is absent.
#
# Table-driven per skills/_shared/test-design/parser-regex-tests.md.
# The TABLE heredoc is QUOTED, so $( ), ${ }, backticks and backslashes in the
# payload column survive verbatim and are never subject to shell expansion; the
# @TOK@ / @DIR@ placeholders are substituted in-loop instead.
# Columns: name | want | payload   (payload is the remainder of the line, so it
# may itself contain '|'; no current payload does)
# ============================================================================
while IFS='|' read -r name want payload; do
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="$(trim "$name")"; want="${want//[[:space:]]/}"; payload="$(trim "$payload")"
    payload="${payload//@TOK@/$TOKEN}"
    payload="${payload//@DIR@/$TN}"
    assert_verdict "$name" "$want" "$(run_hook "$TN" "$(mk_bash_input "$payload")")"
done <<'TABLE'
# --- APPROVE: read-only shapes the allowlist must recognise (RED before the rewrite) ---
RD1 node -e readFileSync(process.env.X + '/...off-clearance')      | approve | node -e "console.log(require('fs').readFileSync(process.env.CLAUDE_WORKFLOW_DIR + '/wsid.off-clearance','utf8'))"
RD2 python3 -c open(<token>).read()                        | approve | uv run python -c "print(open('@TOK@').read())"
RD3 pwsh Get-Content -Raw '<token>' (single-quoted arg)    | approve | pwsh -Command "Get-Content -Raw '@TOK@'"
RD4 pwsh Get-Content -Raw $env:OFF_TOKEN (bare env form)   | approve | pwsh -Command 'Get-Content -Raw $env:OFF_TOKEN'
# Non-interpreter reads - regression guard: never blocked, must stay that way (CPR-5).
RD5 cat <token> (plain read, non-interpreter)              | approve | cat @TOK@
RD6 ls <workflow dir> (directory listing)                  | approve | ls @DIR@
# --- BLOCK: write paths. Anything not a proven read-only shape is blocked, ---
# --- whatever it superficially resembles.                                  ---
WR1 node -e execSync('touch <token>') (indirect write)     | block   | node -e "require('child_process').execSync('touch @TOK@')"
WR2 python3 -c os.system('rm <token>')                     | block   | uv run python -c "import os; os.system('rm @TOK@')"
WR3 python3 -c pathlib Path(<token>).touch()               | block   | uv run python -c "from pathlib import Path; Path('@TOK@').touch()"
WR4 read shape + trailing unlinkSync (prefix is not a read)| block   | node -e "console.log(require('fs').readFileSync('@TOK@')); require('fs').unlinkSync('@TOK@')"
# Unextractable body (unquoted shell variable) -> cannot be proven read-only.
# cmd DOES mention off-clearance (via the @TOK@ assignment), so tier-2 fail-closed
# still applies (M1 fix #1780: the whole-cmd gate only short-circuits to approve
# when off-clearance is absent from cmd entirely - see WR6/WR7 below for that case).
WR5 unextractable body mentioning token -> fail-closed (M1) | block   | P=@TOK@; node -e $BODY
# WR5-class companion (#1780 M1, security-scanner round): the token can flow
# through TWO consecutive assignment-only segments before reaching the
# unquoted interpreter body, not just one. bashHitsToken folds in every
# contiguous assignment-only segment immediately preceding the interpreter
# segment, so this must still fail closed exactly like WR5.
WR10 token via TWO chained assignment segments -> fail-closed | block   | A=1; B=@TOK@; node -e $BODY
# M1 fix #1780: trailing shell syntax after the closing quote breaks the anchored
# extractor (extractInterpreterBody expects the closing quote at end-of-string),
# but neither command mentions off-clearance anywhere, so the tier-1 whole-cmd
# gate approves immediately instead of fail-closed-blocking an unrelated command.
WR6 unrelated node -e with output redirect -> approve (M1)  | approve | node -e "console.log(1)" > out.txt
WR7 unrelated node -e chained with && -> approve (M1)       | approve | node -e "console.log(1)" && echo done
# H-1 fix #1780: extractInterpreterBody used to be end-of-string-anchored
# (\1\s*$), so it only ever captured the LAST quoted -e/-c/-Command argument.
# A forging body followed by a trailing unrelated interpreter call extracted
# "done" instead of the actual forging body, so the Tier-2 body-level
# off-clearance prefilter never saw it and wrongly APPROVED. The fix
# (extractAllInterpreterBodies) scans every quoted body globally and requires
# every -e/-c/-Command flag to yield one; ANY body mentioning the token that
# isn't a recognized read-only shape blocks the whole command.
WR8 forging body precedes a trailing unrelated echo -e -> block (H-1)  | block | node -e "require('fs').writeFileSync('@TOK@','x')" && echo -e 'done'
# Companion: TWO cleanly-extractable bodies, only the first mentions the token.
WR9 two node -e bodies, only first mentions token -> block (H-1)       | block | node -e "require('fs').writeFileSync('@TOK@','x')" && node -e "console.log(1)"
# H-A fix (security-scanner round 4): a clean, quoted, token-free FIRST body
# followed by a SECOND -e/-c/-Command flag in the same segment whose argument
# is unquoted (or an unmodeled quote form such as bash ANSI-C $'...') used to
# be invisible to both the body list and the flag count, so the clean first
# body alone made the whole segment look approved even though the hidden
# second body actually referenced the token. extractAllInterpreterBodies now
# counts EVERY -e/-c/-Command occurrence via invocationCount regardless of
# whether a quote follows, so an uncounted body always inflates flagCount
# past bodies.length and the segment fails closed. `$BODY` / `$'...'` are left
# unexpanded (TABLE heredoc is quoted) - the hook sees the literal text, which
# is exactly the adversarial shape it must not be fooled by.
WR11 clean quoted 1st body + unquoted 2nd body w/ token -> block (H-A)      | block | node -e "console.log(1)" -e $BODY @TOK@
WR12 clean quoted 1st body + ANSI-C 2nd body w/ token -> block (H-A)        | block | node -e "console.log(1)" -e $'@TOK@'
# Companion: the flag-counting heuristic is text-based, not command-aware - a
# second `-c`/`-e`-shaped flag belonging to the SAME node invocation's own
# argument list (not a distinct interpreter call) is still counted, and an
# unquoted argument after it still can't be proven token-free. This is the
# same fail-closed behavior as WR11/WR12, not a new code path - verified by
# running the hook directly (not assumed) before encoding as expected.
WR13 clean 1st body + unrelated unquoted '-c' arg w/ token -> block (H-A)   | block | node -e "console.log(1)" @TOK@ --other -c foo
# --- APPROVE: false-block repro already fixed (supervisor-audit-4) - a `cd` ---
# --- into a token-named directory must not taint an unrelated clean         ---
# --- interpreter segment elsewhere on the line.                             ---
WR14 cd into off-clearance-named dir + clean node -e -> approve            | approve | cd /some/off-clearance-1780/dir && node -e "console.log(1)"
# WR15 (#1780, superseded by F-2 / security-scanner round 6): originally the
# interpreter segment was clean and the `--detail` flag lived in a different,
# non-interpreter segment; H3's segmentArgvHasBareTokenArg() used to SKIP any
# argv token containing whitespace before calling hitsToken(), on the theory
# that a genuine path argument is always a single whitespace-free token while
# "about <token>" is multi-word descriptive text. F-2 (security-scanner round
# 6) found that theory false: a genuine quoted path CAN contain a spaced
# directory component (e.g. a Windows profile path) and is indistinguishable
# from descriptive text by whitespace alone. The fix gates on path-separator
# presence instead of whitespace-absence, so an argv token that embeds a real
# path - even wrapped in descriptive prose, even with whitespace - is now a
# path candidate and fails closed when its basename is the token. This WR15
# payload's --detail value literally embeds the token's full path (with `/`
# separators), so it now correctly BLOCKs (was APPROVE pre-F-2; the old
# expectation was invalidated by the fix, not by a test bug in isolation).
# See WR15b below for the genuinely non-path descriptive-text control that
# preserves the original CPR-5 intent this case used to cover.
WR15 clean node -e && unrelated --detail flag EMBEDS token path -> block (F-2)  | block   | node -e "console.log(1)" && bin/supervisor-report --detail "about @TOK@"
# WR15b control (F-2 CPR-5 counterpart): a --detail value that merely NAMES
# the token by a descriptive word (no `/` or `\` path separator anywhere) is
# not a path candidate under F-2's gate and must stay approved - this is the
# case the original WR15 comment was actually describing.
WR15b clean node -e && unrelated --detail flag NAMES token, no separator -> approve (F-2 control) | approve | node -e "console.log(1)" && bin/supervisor-report --detail "about the off-clearance token feature"
# H-B fix (security-scanner round 4, ReDoS): the old body-extraction regex used
# backtracking alternation over backslash/backtick escapes and could take
# seconds on a crafted run of backticks inside an interpreter body. The new
# scanQuotedBody() walks the string once, consuming each backtick-escape pair
# in O(1), so a long backtick run stays linear-time. This body DOES embed the
# token after the backticks and closes its quote cleanly, so extraction
# succeeds (bodies.length=1) but INTERPOLATION_RE rejects the backtick before
# any read-only shape can match -> block. Verified directly against the hook:
# completes in well under 1s even at 500 backticks (vs. the old regex's
# catastrophic behavior on comparable input). A dedicated wall-clock timing
# assertion for this shape runs separately below, after the TABLE (a fixed
# per-line payload here can't also drive a $SECONDS-based timing check).
WR16 500-backtick body + token, cleanly closed -> block (H-B)              | block | node -e "````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````@TOK@"
# --- INTERPOLATION_RE BEFORE shape matching, so a read-looking shell never ---
# --- gets to vouch for its own argument.                                   ---
IP1 pwsh Get-Content "$( Remove-Item <token> )"            | block   | pwsh -Command "Get-Content \"$( Remove-Item '@TOK@' )\""
IP2 pwsh double-quoted $env: arg (unconditionally refused) | block   | pwsh -Command "Get-Content \"$env:CLAUDE_WORKFLOW_DIR/wsid.off-clearance\""
IP3 powershell array subexpression @( Remove-Item <token> )| block   | powershell -Command "Get-Content @(Remove-Item '@TOK@')"
IP4 node template literal (backtick + ${ }) -> prefilter   | block   | node -e "console.log(require('fs').readFileSync(`${process.env.X}/x.off-clearance`))"
IP5 python f-string executing popen('rm <token>') in path  | block   | uv run python -c "print(open(f'{__import__(\"os\").popen(\"rm @TOK@\").read()}').read())"
# Accepted constraint (documented, not a bug): a backslash-containing literal is
# refused because backslash is a PowerShell escape introducer and a regex grammar
# cannot tell it apart from an escape. Use '/'-separated paths or a bare $env:NAME.
IP6 backslash-containing literal -> block (accepted)       | block   | pwsh -Command "Get-Content 'C:\Users\x\.off-clearance'"
# H1 fix #1780: a bare unbraced shell variable ($P, no braces/parens) inside a
# double-quoted -e body is expanded by the shell BEFORE node ever runs, so the
# text the hook sees ('$P' + '/x.off-clearance') is NOT what actually reaches
# existsSync() at runtime - the old INTERPOLATION_RE only rejected $( / ${ / @( /
# backtick / backslash / f-strings and missed this bare-$ vector entirely, so the
# SQ grammar (which permits '$' inside single quotes) matched it as an inert
# literal and approved. Must fail closed on any bare $ that isn't the sanctioned
# pwsh $env: form (see RD4/IP2 above for the $env: carve-out / refusal split).
IP7 bare $VAR shell-expands before node runs -> block (H1)  | block   | P=x; node -e "console.log(require('fs').existsSync('$P' + '/x.off-clearance'))"
# --- H3 (#1780 security-scanner round 5): segmentArgvHasBareTokenArg() - a ---
# --- segment whose argv contains a bare token-basename argument is now a   ---
# --- hit, unless the command is on READ_ONLY_ARG_COMMAND_RE.              ---
H3-1 ln -s /tmp/x <token> -> block (H3)                     | block   | ln -s /tmp/x @TOK@
H3-2 sed -i 's/a/b/' <token> -> block (H3)                  | block   | sed -i "s/a/b/" @TOK@
H3-3 touch <token> -> block (H3)                            | block   | touch @TOK@
H3-4 dd of=<token> -> block (H3)                            | block   | dd of=@TOK@
H3-5 install /tmp/x <token> -> block (H3)                   | block   | install /tmp/x @TOK@
# H3 control - READ_ONLY_ARG_COMMAND_RE carve-out: read-only commands taking
# the token as a bare argv arg must stay approved (unaffected by H3).
H3-6 cat <token> (bare arg, read-only allowlist) -> approve (H3 control) | approve | cat @TOK@
# --- H2 (#1780 security-scanner round 5): INTERPRETER_RE now also matches ---
# --- bash|sh|zsh|dash|busybox and long-flag forms --eval/--command, with  ---
# --- extractAllInterpreterBodies' flagRe updated in lockstep.             ---
H2-1 bash -c body writing token via shell redirect -> block (H2)    | block   | bash -c "echo x > @TOK@"
H2-2 sh -c body removing token -> block (H2)                        | block   | sh -c "rm @TOK@"
H2-3 bash --eval body mentioning token -> block (H2)                | block   | bash --eval "echo x > @TOK@"
# H2 control - INTERPRETER_RE widening to bash/sh must not cause blanket
# false-positives on unrelated bash -c usage with no token mention anywhere.
H2-4 bash -c "echo hello" (no token mention) -> approve (H2 control) | approve | bash -c "echo hello"
# --- SA5 (supervisor-audit-5): env-var indirection regression. Tier-2's ---
# --- per-body substring check missed process.env/os.environ/$env: derefs ---
# --- that never spell the token out literally in the body text itself; ---
# --- bodyDerefsTokenViaAssignment() resolves such derefs against a       ---
# --- preceding/same-segment NAME=value assignment and fails closed when  ---
# --- the assigned value carries the token. Same class for bare $VAR argv ---
# --- args into non-interpreter write verbs (ln/touch), which previously ---
# --- only blocked the `export A=<token>` form (export's own argv spells ---
# --- the token out) but missed the plain-assignment form.                ---
SA5-1 A=<token> node -e process.env.A writeFileSync -> block (SA5)          | block   | A=@TOK@ node -e "require('fs').writeFileSync(process.env.A,'x')"
SA5-2 A=<token> python os.environ['A'] bracket-deref write -> block (SA5)   | block   | A=@TOK@ uv run python -c "import os; open(os.environ['A'],'w').write('x')"
SA5-3 A=<token>; ln -s /tmp/x $A -> block (SA5)                             | block   | A=@TOK@; ln -s /tmp/x $A
SA5-4 A=<token>; touch $A -> block (SA5)                                    | block   | A=@TOK@; touch $A
# Controls - an unrelated env var must never false-positive (CPR-5 counterpart).
SA5-5 A=hello; ln -s /tmp/x $A -> approve (SA5 control)                     | approve | A=hello; ln -s /tmp/x $A
SA5-6 A=hello node -e process.env.A writeFileSync -> approve (SA5 control)  | approve | A=hello node -e "require('fs').writeFileSync(process.env.A,'x')"
# NOTE: process.env['A'] BRACKET form is intentionally not covered here -
# ENV_DEREF_NAME_RE only recognises process.env.NAME (dot form) for node,
# not process.env['NAME']; a payload using the unrecognised shape would not
# exercise the fix. The WR15-style descriptive multi-word --detail control
# already exists above and is not duplicated here.
# --- F1C (security-scanner round 6, F-1 + F-1 follow-up): clustered/abbreviated ---
# --- interpreter flags carrying a token via an env-var assignment.               ---
# F1C-1/F1C-2: bash `$VAR` / `${VAR}` dereference inside a clustered short-option
# invocation (`bash -ce`, `sh -ec`) was previously invisible to ENV_DEREF_NAME_RE
# (it modeled only the node/python/pwsh dereference spellings), so a preceding
# `A=<token> bash -ce "echo \$A"` fell through as "out of scope" even though the
# body clearly leaks the token via $A. Fixed by adding the bash `$NAME`/`${NAME}`
# alternative to ENV_DEREF_NAME_RE.
F1C-1 A=<token> bash -ce "echo \$A" -> block (F-1 bash $VAR deref)          | block   | A=@TOK@ bash -ce "echo \$A"
F1C-2 A=<token> sh -ec "echo \$A" -> block (F-1 sh $VAR deref)              | block   | A=@TOK@ sh -ec "echo \$A"
# F1C-3: python3 -uc clustered flag + os.environ bracket-deref - this shape was
# already recognised pre-fix (ENV_DEREF_NAME_RE always modeled os.environ[...]),
# included here as a regression guard so a future change to CLUSTER_FLAG /
# ENV_DEREF_NAME_RE cannot silently reopen it.
F1C-3 A=<token> python3 -uc os.environ['A'] deref -> block (regression guard) | block | A=@TOK@ python3 -uc "import os; print(os.environ['A'])"
# F1C-4: pwsh's OWN `$env:NAME=value` assignment syntax (direct sibling of bash
# `NAME=value`) has a cmd0 starting with `$`, so the bash-only assignment-prefix
# regex never recognised it as an assignment-only segment. A preceding
# `$env:A='<token>'; pwsh -Command "...$env:A..."` therefore never folded its
# assignment into the following pwsh segment's Tier-1 gate text, so the whole
# invocation fell through as "nothing to protect" even though the pwsh body
# dereferences the token via $env:A. Fixed by teaching isAssignmentOnlySegment
# (PWSH_ENV_ASSIGN_ONLY_RE) and both assignRe lookups about the `$env:NAME=`
# prefix form.
F1C-4 pwsh $env:A=<token> chain; pwsh -Command uses $env:A -> block (F-1 follow-up) | block | $env:A='@TOK@'; pwsh -Command "[IO.File]::WriteAllText($env:A,'x')"
# F1C-5 control (CPR-5 counterpart): the same clustered-flag shape with NO
# off-clearance token anywhere must stay approved - INTERPRETER_RE may still
# match (bash -ex superficially resembles the clustered -e alternation), but
# Tier-1's "off-clearance" gate text check must short-circuit to approve since
# nothing in scope mentions the token.
F1C-5 bash -ex script.sh (no token anywhere) -> approve (F1C control)       | approve | bash -ex script.sh
TABLE

# ---------------------------------------------------------------------------
# WR16 timing companion (H-B, ReDoS regression guard). WR16 above already
# asserts the VERDICT for a 500-backtick interpreter body; this section
# additionally times that same shape end-to-end through run_hook (RWT wrapper
# + node startup included) and asserts a generous, non-flaky upper bound -
# no existing timing-assertion precedent in this suite, so this is kept as
# simple as possible per test/macos-timeout.md guidance (a loose bound, not a
# tight one). The old backtracking body-extraction regex could take seconds
# to minutes on adversarial backtick runs; scanQuotedBody() is linear-time,
# so this should complete in well under a second in practice - the 5s bound
# below is deliberately loose to avoid CI flakiness, not a tight SLA.
# ---------------------------------------------------------------------------
BT500=''
while IFS= read -r __l; do BT500="$__l"; done <<'CMD'
node -e "````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````````@TOK@"
CMD
BT500="${BT500//@TOK@/$TOKEN}"
_BT_START_NS=$(date +%s%N 2>/dev/null || echo 0)
BT500_RAW="$(run_hook "$TN" "$(mk_bash_input "$BT500")")"
_BT_END_NS=$(date +%s%N 2>/dev/null || echo 0)
if [ "$_BT_START_NS" != "0" ] && [ "$_BT_END_NS" != "0" ] && [ "$_BT_END_NS" -gt "$_BT_START_NS" ]; then
    _BT_MS=$(( (_BT_END_NS - _BT_START_NS) / 1000000 ))
    if [ "$_BT_MS" -lt 5000 ]; then pass "WR16b 500-backtick body completes under 5s (${_BT_MS}ms, H-B)"
    else fail "WR16b 500-backtick body took ${_BT_MS}ms (>=5000ms, H-B ReDoS regression?)"; fi
else
    echo "NOTE: WR16b timing skipped - date +%s%N unsupported/non-monotonic on this platform"
fi
# Re-classify the same run rather than re-invoking the hook a second time, so
# the timing measurement above and the verdict below are the SAME call.
assert_block "WR16b 500-backtick body verdict (same run as timing)" "$BT500_RAW"

# ---------------------------------------------------------------------------
# KNOWN-BYPASS - recorded, NOT asserted. INTERPRETER_RE only recognises the
# -e / -c / -Command one-liner forms, so `deno eval <body>` is not classified at
# all and slips past this hook entirely. Consistent with the file's stated trust
# model (best-effort deterrent; the real gate is Phase2 human approval + audit).
# Do NOT convert this into a pass/fail assertion - it would encode a false contract.
# The verdict is still run through classify(), so a crash/timeout here is reported
# as such instead of being narrated as "not blocked".
# ---------------------------------------------------------------------------
KB1=''
while IFS= read -r __l; do KB1="$__l"; done <<'CMD'
deno eval "Deno.writeTextFileSync('@TOK@','x')"
CMD
KB1="${KB1//@TOK@/$TOKEN}"
KB1_VERDICT="$(classify "$(run_hook "$TN" "$(mk_bash_input "$KB1")")")"
case "$KB1_VERDICT" in
    block)   echo "NOTE: KNOWN-BYPASS 'deno eval' is currently blocked (INTERPRETER_RE widened) - gap closed, no assertion either way." ;;
    approve) echo "NOTE: KNOWN-BYPASS 'deno eval \"Deno.writeTextFileSync(<token>)\"' is NOT blocked (INTERPRETER_RE matches only -e/-c/-Command). Accepted gap - recorded, not asserted." ;;
    *)       echo "NOTE: KNOWN-BYPASS 'deno eval' produced verdict '$KB1_VERDICT' (neither approve nor block) - harness/hook anomaly, still not asserted." ;;
esac

# ---------------------------------------------------------------------------
# DIFF-* : not-weaker-than-pre-PR differential harness (supervisor-audit-5).
#
# Rationale (replaces the removed "full-suite PASS is itself the regression
# assertion" claim near the top of this file, which the audit found factually
# wrong): this suite can only re-run its OWN cases, so it can never by itself
# detect a BLOCK->APPROVE regression on a payload the suite doesn't already
# contain - exactly how the SA5 process.env indirection regression slipped
# through review. This block instead runs an identical curated payload
# corpus through BOTH this branch's hook and a separate, clean pre-PR
# checkout of the same hook on main (C:/git/agents/hooks/block-off-clearance-
# write.js) and asserts this branch is never weaker: whenever the pre-PR
# hook's verdict is block, this branch's verdict must also be block. This
# branch blocking something the pre-PR hook approved is expected (H2/H3/SA5
# hardening) and is NOT a failure - only the reverse direction is checked.
# ---------------------------------------------------------------------------
DIFF_ALT_AGENTS_DIR="C:/git/agents"
DIFF_ALT_HOOK="$DIFF_ALT_AGENTS_DIR/hooks/block-off-clearance-write.js"
if [ -d "$DIFF_ALT_AGENTS_DIR" ] && [ -f "$DIFF_ALT_HOOK" ]; then
    while IFS='|' read -r name payload; do
        [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
        name="$(trim "$name")"; payload="$(trim "$payload")"
        payload="${payload//@TOK@/$TOKEN}"
        payload="${payload//@DIR@/$TN}"
        diff_input="$(mk_bash_input "$payload")"
        diff_local="$(classify "$(run_hook_at "$HOOK" "$TN" "$diff_input")")"
        diff_main="$(classify "$(run_hook_at "$DIFF_ALT_HOOK" "$TN" "$diff_input")")"
        if [ "$diff_main" = "block" ] && [ "$diff_local" != "block" ]; then
            fail "DIFF $name: pre-PR(main)=block this-branch=$diff_local (REGRESSION - weaker than main)"
        else
            pass "DIFF $name: main=$diff_main this-branch=$diff_local (not weaker)"
        fi
    done <<'DIFFCORPUS'
DIFF-1 SA5 regression payload: A=<token> node -e process.env.A     | A=@TOK@ node -e "require('fs').writeFileSync(process.env.A,'x')"
DIFF-2 SA5 ln bare $A indirection                                  | A=@TOK@; ln -s /tmp/x $A
DIFF-3 SA5 touch bare $A indirection                                | A=@TOK@; touch $A
DIFF-4 H3 ln -s /tmp/x <token> direct                               | ln -s /tmp/x @TOK@
DIFF-5 H3 sed -i <token> direct                                     | sed -i "s/a/b/" @TOK@
DIFF-6 H3 touch <token> direct                                      | touch @TOK@
DIFF-7 H3 dd of=<token> direct                                      | dd of=@TOK@
DIFF-8 H2 bash -c redirect > <token>                                | bash -c "echo x > @TOK@"
DIFF-9 WR1 node -e execSync('touch <token>') indirect write         | node -e "require('child_process').execSync('touch @TOK@')"
DIFF-10 B1 redirect > <token>                                       | echo x > @TOK@
DIFFCORPUS
    echo "NOTE: DIFF corpus ran against pre-PR reference at $DIFF_ALT_HOOK"
else
    echo "NOTE: DIFF corpus skipped - pre-PR reference checkout not found at $DIFF_ALT_AGENTS_DIR (optional fixture)"
    SKIP=$((SKIP + 1))
fi

rm -r -f "$TMP" 2>/dev/null || true

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
