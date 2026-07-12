# Common helpers sourced by all feature-parallel-sessions-worktree-bash-patterns parts.
# Defines MODULE path, classify_cmd, assert_classify, and PASS/FAIL counters.
# Caller (parent dispatch) must export AGENTS_DIR before sourcing.

set -u

if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi
MODULE="${_AGENTS_DIR_NODE}/hooks/lib/bash-write-patterns.js"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

TMPDIR_BASE="$(node -e "
const os=require('os'),path=require('path'),fs=require('fs');
const d=path.join(os.tmpdir(),'pst-bp-'+process.pid).replace(/\\\\/g,'/');
fs.mkdirSync(d,{recursive:true});
console.log(d);
" 2>/dev/null)"
[ -z "$TMPDIR_BASE" ] && TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        "$@"
    fi
}

# Classify a command. Prints "read", "write", or "ERROR: ...".
classify_cmd() {
    run_with_timeout 30 node -e "
      try {
        const m = require('$MODULE');
        const fn = m.classify;
        const arg = process.argv[1];
        let v;
        if (arg === '__NULL__') v = null;
        else if (arg === '__UNDEF__') v = undefined;
        else if (arg === '__NUM__') v = 123;
        else v = arg;
        console.log(fn(v));
      } catch (e) {
        console.log('ERROR: ' + e.message);
      }
    " -- "$1" 2>/dev/null
}

assert_classify() {
    local desc="$1" cmd="$2" expected="$3"
    local got
    got="$(classify_cmd "$cmd")"
    if [ "$got" = "$expected" ]; then
        pass "$desc -> $expected"
    else
        fail "$desc: expected '$expected', got '$got' (cmd: $(printf '%q' "$cmd"))"
    fi
}

# --- IR write-predicate drivers (post-#1296/#1400/#1401 retire migration) ------
# The rm/cp/mv/posix-redir/pwsh/git WRITE_PATTERNS entries were retired: classify()
# of those commands now returns "read". In-scope BLOCKING moved to IR predicates
# consulted at the enforce-worktree fast-allow gate. The migrated contract for a
# retired-command "write" case is therefore: classify()=="read" AND the matching
# isXWriteIR() predicate is true. These drivers mirror the production path
# (classify(parse(cmd))) — see tests/fix-1391 / feature-canary5-6git for siblings.

# pred_targets <fn> <cmd> → "true"|"false" — predicate in bash-write-targets.js.
pred_targets() {
    run_with_timeout 30 node -e "
      const m=require('${_AGENTS_DIR_NODE}/hooks/lib/bash-write-targets');
      const {parse}=require('${_AGENTS_DIR_NODE}/hooks/lib/command-ir');
      const fn=m[process.argv[1]];
      if (typeof fn !== 'function') { process.stdout.write('ERROR:not-exported'); process.exit(0); }
      try { process.stdout.write(String(fn(parse(process.argv[2])))); }
      catch (e) { process.stdout.write('ERROR:threw'); }
    " -- "$1" "$2" 2>/dev/null
}

# git_write_ir <cmd> → "true"|"false" — isGitWriteIR in patterns.js.
git_write_ir() {
    run_with_timeout 30 node -e "
      const {isGitWriteIR}=require('${_AGENTS_DIR_NODE}/hooks/lib/bash-write-patterns/patterns');
      const {parse}=require('${_AGENTS_DIR_NODE}/hooks/lib/command-ir');
      try { process.stdout.write(String(isGitWriteIR(parse(process.argv[1])))); }
      catch (e) { process.stdout.write('ERROR:threw'); }
    " -- "$1" 2>/dev/null
}

# assert_write_ir <desc> <cmd> <predicate> — new-contract write assertion:
# classify()=="read" AND the named predicate is true. <predicate> ∈
# { posix | pwsh | fileop | subst | git }.
assert_write_ir() {
    local desc="$1" cmd="$2" pred="$3"
    local cls predval fn
    cls="$(classify_cmd "$cmd")"
    case "$pred" in
        posix)  fn=isPosixRedirWriteIR; predval="$(pred_targets "$fn" "$cmd")" ;;
        pwsh)   fn=isPwshWriteIR;       predval="$(pred_targets "$fn" "$cmd")" ;;
        fileop) fn=isFileOpWriteIR;     predval="$(pred_targets "$fn" "$cmd")" ;;
        subst)  fn=isCommandSubstWriteIR; predval="$(pred_targets "$fn" "$cmd")" ;;
        newline) fn=isNewlineInjectedWriteIR; predval="$(pred_targets "$fn" "$cmd")" ;;
        git)    fn=isGitWriteIR;        predval="$(git_write_ir "$cmd")" ;;
        *)      fail "$desc: unknown predicate '$pred'"; return ;;
    esac
    if [ "$cls" = "read" ] && [ "$predval" = "true" ]; then
        pass "$desc -> read + ${fn}=true (retired-write new contract)"
    else
        fail "$desc: expected classify=read + ${fn}=true, got classify='$cls' ${fn}='$predval' (cmd: $(printf '%q' "$cmd"))"
    fi
}
