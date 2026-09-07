# tests/feature-2210-block-recursive-delete/helpers.sh
# Tests: hooks/block-recursive-delete.js
# Tags: scope:issue-specific, recursive-delete, hook, helpers, TL2
#
# Shared harness for the #2210 suite. False-green guard: a crash, a timeout
# kill, or empty stdout is a FAILURE, never "well, it didn't block".

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# Delegates to the portable wrapper; `timeout` alone is absent on macOS.
run_with_timeout() {
    "$AN/bin/run-with-timeout.sh" "$@"
}

# Git-Bash MSYS rewrites a POSIX-looking argv element into a Windows path
# before node sees it, corrupting fixtures; a no-op on POSIX hosts.
export MSYS_NO_PATHCONV=1

# Built through node so embedded quotes, newlines and backslashes survive.
payload_cmd() {
    node -e 'process.stdout.write(JSON.stringify({tool_name:process.argv[2],tool_input:{command:process.argv[1]}}))' \
        -- "$1" "${2:-Bash}"
}

# runCommands shape — the array tool-command-text.js joins with "\n".
payload_commands() {
    node -e 'process.stdout.write(JSON.stringify({tool_name:"runCommands",tool_input:{commands:process.argv.slice(1)}}))' \
        -- "$@"
}

run_hook() {
    printf '%s' "$1" | run_with_timeout 60 node "$HOOK" 2>/dev/null
}

# Only silence/block are credited; any other shape is reported distinguishably
# so a hook emitting a new verdict fails loudly instead of scoring as a pass.
# Approve IS the empty output: an explicit decision:"approve" would bypass the
# permission prompt, so the guard stays silent when it has no objection (C15).
verdict_of() {
    printf '%s' "$1" | node -e '
let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{
  if (d.trim() === "") { process.stdout.write("approve"); return; }
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
    # No empty-output guard: silence is the approve verdict. A crashed hook is
    # already caught above by its non-zero exit.
    verdict="$(verdict_of "$out")"
    if [ "$verdict" = "$want" ]; then
        pass "$desc"; return 0
    fi
    fail "$desc — expected $want, got verdict '$verdict' from: $out"; return 1
}

expect_block() { _assert_verdict block "$1" "$2"; }

expect_approve() { _assert_verdict approve "$1" "$2"; }

expect_block_cmd()   { expect_block   "$1" "$(payload_cmd "$2" "${3:-Bash}")"; }
expect_approve_cmd() { expect_approve "$1" "$(payload_cmd "$2" "${3:-Bash}")"; }

# Pure bash, no pipe: a short-circuiting `grep -q` would SIGPIPE the producer.
has() { case "$3" in (*"$2"*) pass "$1";; (*) fail "$1 -- missing [$2] in: $3";; esac; }

# Absence side of has(): a blocked command's own text must not leak back out.
lacks() { case "$3" in (*"$2"*) fail "$1 -- unexpectedly found [$2] in: $3";; (*) pass "$1";; esac; }

# Folds a Node unit file's exit status into this suite's tally as one pass/fail,
# so a broken unit file cannot silently vanish from the printed results.
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
