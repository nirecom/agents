# tests/feature-2210-block-recursive-delete/helpers.sh
# Tests: hooks/block-recursive-delete.js
# Tags: scope:issue-specific, recursive-delete, hook, helpers, TL2
#
# Shared harness for the #2210 suite: tallies, payload builders for the three
# command-tool shapes, and the block/approve assertions. Adapted from the
# run_hook/expect_block/expect_approve helpers in tests/main-block-credentials.sh,
# with the false-green guard from feature-2120's assert_allowed: a crash, a
# timeout kill, or empty stdout is a FAILURE, never "well, it didn't block".
# No cases live here — every assertion is in a sibling cases-*.sh.

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# run_with_timeout <secs> <command> [args...] — delegates to the canonical
# CPR-SSOT portable wrapper (rules/test/macos-timeout.md) instead of
# reimplementing the timeout/perl-alarm fallback locally (finding 11).
run_with_timeout() {
    "$AN/bin/run-with-timeout.sh" "$@"
}

# On Windows Git-Bash, MSYS auto-converts a bare-looking POSIX path argument
# ("/bin/rm -rf dir" passed as one argv element) into a Windows path before
# node ever sees it (e.g. "/bin/rm" -> "C:/Program Files/Git/usr/bin/rm"),
# silently corrupting command-text fixtures that happen to start with `/`.
# This is a host-shell artifact, not a hook behavior — disabling it here
# keeps every payload builder below byte-for-byte faithful to the literal
# test string on this platform; POSIX hosts don't set MSYS_NO_PATHCONV at
# all, so this is a no-op there.
export MSYS_NO_PATHCONV=1

# payload_cmd <command-text> [tool_name] — Bash / runInTerminal shape
# ({"command": "..."}). Built through node so embedded quotes, newlines and
# backslashes survive verbatim instead of being mangled by shell quoting.
payload_cmd() {
    node -e 'process.stdout.write(JSON.stringify({tool_name:process.argv[2],tool_input:{command:process.argv[1]}}))' \
        -- "$1" "${2:-Bash}"
}

# payload_commands <cmd> [cmd ...] — runCommands shape ({"commands": [...]}),
# the array tool-command-text.js joins with "\n".
payload_commands() {
    node -e 'process.stdout.write(JSON.stringify({tool_name:"runCommands",tool_input:{commands:process.argv.slice(1)}}))' \
        -- "$@"
}

run_hook() {
    printf '%s' "$1" | run_with_timeout 60 node "$HOOK" 2>/dev/null
}

# verdict_of <hook stdout> → "block" | "approve" | "unknown-decision:<v>" |
# "no-decision:<keys>" | "non-object" | "unparseable". Only the two canonical
# verdicts are credited; anything else is reported distinguishably so a hook that
# starts emitting a new shape fails loudly instead of scoring as a pass.
verdict_of() {
    printf '%s' "$1" | node -e '
let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{
  const lines=d.trim().split("\n").filter(Boolean);
  for(let i=lines.length-1;i>=0;i--){
    let j; try { j=JSON.parse(lines[i]); } catch(e) { continue; }
    if (!j || typeof j !== "object" || Array.isArray(j)) { process.stdout.write("non-object"); return; }
    if (j.decision === "block") { process.stdout.write("block"); return; }
    if (j.decision === "approve") { process.stdout.write("approve"); return; }
    if (Object.prototype.hasOwnProperty.call(j, "decision")) {
      process.stdout.write("unknown-decision:" + String(j.decision)); return;
    }
    process.stdout.write("no-decision:" + Object.keys(j).join(",")); return;
  }
  process.stdout.write("unparseable");
});'
}

# reason_of <hook stdout> → the decoded `reason` string (empty when absent)
reason_of() {
    printf '%s' "$1" | node -e '
let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{
  const lines=d.trim().split("\n").filter(Boolean);
  for(let i=lines.length-1;i>=0;i--){try{const j=JSON.parse(lines[i]);if(j&&typeof j.reason==="string"){process.stdout.write(j.reason);return;}}catch(e){}}
});'
}

_assert_verdict() {
    local want="$1" desc="$2" payload="$3" out st verdict
    out="$(run_hook "$payload")"; st=$?
    if [ "$st" -ne 0 ]; then
        fail "$desc — hook exited non-zero ($st): crash or timeout, not a verdict"; return 1
    fi
    if [ -z "$out" ]; then
        fail "$desc — hook produced EMPTY stdout: no verdict was emitted"; return 1
    fi
    verdict="$(verdict_of "$out")"
    if [ "$verdict" = "$want" ]; then
        pass "$desc"; return 0
    fi
    fail "$desc — expected $want, got verdict '$verdict' from: $out"; return 1
}

# expect_block <desc> <payload> — the guard fires.
expect_block() { _assert_verdict block "$1" "$2"; }

# expect_approve <desc> <payload> — the guard stays silent (zero false positives).
expect_approve() { _assert_verdict approve "$1" "$2"; }

# expect_block_cmd / expect_approve_cmd <desc> <command-text> [tool_name] —
# the common case: a Bash-shaped payload built from a command string.
expect_block_cmd()   { expect_block   "$1" "$(payload_cmd "$2" "${3:-Bash}")"; }
expect_approve_cmd() { expect_approve "$1" "$(payload_cmd "$2" "${3:-Bash}")"; }

# has <label> <needle> <haystack> — pure-bash substring assertion (no pipe, so a
# short-circuiting `grep -q` cannot SIGPIPE the producer and bury the results).
has() { case "$3" in (*"$2"*) pass "$1";; (*) fail "$1 -- missing [$2] in: $3";; esac; }

# lacks <label> <needle> <haystack> — pure-bash substring ABSENCE assertion, the
# negation of has() (C8: guards against a blocked command's own secret-looking
# text leaking back through the hook's reason/stdout/stderr).
lacks() { case "$3" in (*"$2"*) fail "$1 -- unexpectedly found [$2] in: $3";; (*) pass "$1";; esac; }

# run_unit_suite <label> <node-script-path> — runs a plain-Node unit-test file
# (tests/lib/test-recursive-delete-*.js) and folds its result into the SAME
# top-level PASS/FAIL tally this shell suite already prints (C1: these two
# files existed but were never invoked from anywhere runnable — see
# tests/_archive/feature-424-command-parser.sh for the precedent this mirrors).
# The .js file does its own PASS:/FAIL: accounting internally and exits
# non-zero on any internal failure; here it is credited as exactly one
# pass/fail so a broken unit file cannot silently vanish from the tally.
run_unit_suite() {
    local label="$1" script="$2" out st
    out="$(run_with_timeout 60 node "$script" 2>&1)"; st=$?
    printf '%s\n' "$out"
    if [ "$st" -eq 0 ]; then
        pass "$label (node unit suite exited 0)"
    else
        fail "$label (node unit suite exited $st) — see output above"
    fi
}
