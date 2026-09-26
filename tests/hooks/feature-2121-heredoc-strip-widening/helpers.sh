# Tests: hooks/lib/strip-quoted-args.js
# Tags: heredoc, strip-quoted-args, harness, scope:issue-specific
# Harness for feature-2121-heredoc-strip-widening.sh: tallies, the portable
# timeout wrapper, the H0 availability guards, the scratch dir, and the three
# node probes every case file drives (stripped / body_gone / strip_fixture).
# Sourced by feature-2121-heredoc-strip-widening.sh; expects AGENTS_DIR + SQA.

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then pass "$name"
    else fail "$name — want='$want' got='$got'"; fi
}

if [ -f "$AGENTS_DIR/hooks/lib/strip-quoted-args.js" ]; then
    pass "H0: hooks/lib/strip-quoted-args.js present"
else
    fail "H0: hooks/lib/strip-quoted-args.js is MISSING — every case below would be vacuous"
    echo ""; echo "Results: $PASS passed, $FAIL failed"; exit 1
fi

command -v node >/dev/null 2>&1 || { fail "H0: node unavailable — every case below would be vacuous"; echo ""; echo "Results: $PASS passed, $FAIL failed"; exit 1; }

# Scratch dir for the C4 long-body FIXTURE (see run_H6): a 200KB body must not be
# pushed through argv, where Windows' ~32KB command-line limit would kill the
# process and leave an empty stdout that the old `!= "ERROR"` check scored green.
H_TMP="$(mktemp -d)"
trap 'rm -rf "$H_TMP"' EXIT
if command -v cygpath >/dev/null 2>&1; then H_TMP_N="$(cygpath -m "$H_TMP")"; else H_TMP_N="$H_TMP"; fi

# stripped <cmd> → "true" when stripHeredocBody changed the string, else "false";
# "ERROR" on an exception. Change-detection (not the exact output) is the contract:
# callers only care whether the body still reaches the write scanners.
stripped() {
    run_with_timeout 30 node -e '
try {
  const {stripHeredocBody}=require(process.argv[1]);
  const s=process.argv[2];
  process.stdout.write(String(stripHeredocBody(s)!==s));
} catch (e) { process.stdout.write("ERROR"); }
' "$SQA" "$(printf '%b' "$1")" 2>/dev/null
}

# body_gone <cmd> <needle> → "true" when the needle no longer survives the strip.
# Guards against a strip that fires but leaves the payload behind.
body_gone() {
    run_with_timeout 30 node -e '
try {
  const {stripHeredocBody}=require(process.argv[1]);
  process.stdout.write(String(stripHeredocBody(process.argv[2]).indexOf(process.argv[3])===-1));
} catch (e) { process.stdout.write("ERROR"); }
' "$SQA" "$(printf '%b' "$1")" "$2" 2>/dev/null
}

# strip_fixture <sqa> <fixture-file> <needle> — reads the command from a FILE (never
# argv), applies stripHeredocBody once, prints "<changed|unchanged>:<gone|present>".
# No try/catch on purpose: a throw must surface as a non-zero node exit for the
# caller's status check. Callers assert status AND output.
strip_fixture() {
    run_with_timeout 30 node -e '
const fs=require("fs");
const {stripHeredocBody}=require(process.argv[1]);
const s=fs.readFileSync(process.argv[2],"utf8");
const out=stripHeredocBody(s);
process.stdout.write((out!==s?"changed":"unchanged")+":"+(out.indexOf(process.argv[3])===-1?"gone":"present"));
' "$1" "$2" "$3" 2>/dev/null
}
