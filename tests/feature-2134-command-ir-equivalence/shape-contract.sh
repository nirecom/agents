#!/usr/bin/env bash
# tests/feature-2134-command-ir-equivalence/shape-contract.sh
# Tests: hooks/lib/command-ir.js
# Tags: hook, command-ir, equivalence, snapshot, TL1, scope:issue-specific
#
# Direct pin on the public shape. For 10 representative cases, pins the Object.keys(parse(cmd))
# array "including order", and pins JSON.stringify(parse(cmd)) as a byte string.
# If Step 2 adds new analysis info as an enumerable property, the snapshot (snapshot.sh) side
# could slip through in the worst case, but this file will always fail -- that's the reason
# this file exists. When it fails, the fix is not to rewrite the expected value but to fix how
# analysis is attached (make it non-enumerable).

set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENTS_DIR="$(cd "$DIR/../.." && pwd)"

command -v node >/dev/null 2>&1 || { echo "SKIP: node not found"; exit 77; }

# Fixture isolation (rules/test/fixture-isolation.md): don't pass the parent session id to the child node.
unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID

npath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
IR_JS="$(npath "$AGENTS_DIR/hooks/lib/command-ir.js")"
RUNNER="$AGENTS_DIR/bin/run-with-timeout.sh"

PASS=0; FAIL=0; ROWS=0
assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then echo "PASS: $name"; PASS=$((PASS + 1))
    else echo "FAIL: $name"; echo "    want: $want"; echo "    got:  $got"; FAIL=$((FAIL + 1)); fi
}

# Returns the Object.keys(ir) array (including order) and JSON.stringify(ir) on one line.
shape_probe() {
    bash "$RUNNER" 30 node -e '
      const { parse } = require(process.argv[1]);
      const ir = parse(process.argv[2]);
      process.stdout.write(JSON.stringify(Object.keys(ir)) + "~" + JSON.stringify(ir));
    ' "$IR_JS" "$1" 2>/dev/null
}

# Table: id ~ cmd(newlines encoded as \n) ~ want_keys ~ want_json
# want is "the current implementation's measured value", not an ideal shape (Step 1's job is
# to pin, not to correct).
while IFS='~' read -r id cmd_enc want_keys want_json; do
    [ -z "$id" ] && continue
    case "$id" in \#*) continue ;; esac
    ROWS=$((ROWS + 1))
    cmd="$(printf '%b' "$cmd_enc")"
    assert_eq "$id: Object.keys order + JSON.stringify bytes" "$want_keys~$want_json" "$(shape_probe "$cmd")"
done <<'TABLE'
s01-simple~ls~["segments","separators","cmd0","argv","redirects","kind","rawText","parseFailure"]~{"segments":[{"cmd0":"ls","cmd0Raw":"ls","argv":[],"argvRaw":[],"redirects":[],"kind":"simple","rawText":"ls"}],"separators":[],"cmd0":"ls","argv":[],"redirects":[],"kind":"simple","rawText":"ls","parseFailure":false}
s02-empty~~["segments","cmd0","argv","redirects","kind","rawText","separators","parseFailure"]~{"segments":[],"cmd0":"","argv":[],"redirects":[],"kind":"empty","rawText":"","separators":[],"parseFailure":false}
s03-and~a && b~["segments","separators","cmd0","argv","redirects","kind","rawText","parseFailure"]~{"segments":[{"cmd0":"a","cmd0Raw":"a","argv":[],"argvRaw":[],"redirects":[],"kind":"simple","rawText":"a"},{"cmd0":"b","cmd0Raw":"b","argv":[],"argvRaw":[],"redirects":[],"kind":"simple","rawText":"b"}],"separators":["&&"],"cmd0":"a","argv":[],"redirects":[],"kind":"pipeline","rawText":"a && b","parseFailure":false}
s04-pipe~a | b~["segments","separators","cmd0","argv","redirects","kind","rawText","parseFailure"]~{"segments":[{"cmd0":"a","cmd0Raw":"a","argv":[],"argvRaw":[],"redirects":[],"kind":"simple","rawText":"a"},{"cmd0":"b","cmd0Raw":"b","argv":[],"argvRaw":[],"redirects":[],"kind":"simple","rawText":"b"}],"separators":["|"],"cmd0":"a","argv":[],"redirects":[],"kind":"pipeline","rawText":"a | b","parseFailure":false}
s05-redirect~echo hi > out.txt~["segments","separators","cmd0","argv","redirects","kind","rawText","parseFailure"]~{"segments":[{"cmd0":"echo","cmd0Raw":"echo","argv":["hi"],"argvRaw":["hi"],"redirects":[{"op":">","fd":"1","target":"out.txt"}],"kind":"simple","rawText":"echo hi > out.txt"}],"separators":[],"cmd0":"echo","argv":["hi"],"redirects":[{"op":">","fd":"1","target":"out.txt"}],"kind":"simple","rawText":"echo hi > out.txt","parseFailure":false}
s06-subshell~(cd x && ls)~["segments","separators","cmd0","argv","redirects","kind","rawText","parseFailure"]~{"segments":[{"cmd0":"cd","cmd0Raw":"cd","argv":["x"],"argvRaw":["x"],"redirects":[],"kind":"simple","rawText":"cd x","sub":true},{"cmd0":"ls","cmd0Raw":"ls","argv":[],"argvRaw":[],"redirects":[],"kind":"simple","rawText":"ls","sub":true}],"separators":["(","&&",")"],"cmd0":"cd","argv":["x"],"redirects":[],"kind":"subshell","rawText":"(cd x && ls)","parseFailure":false}
s07-env-prefix~A=1 B=2 bash x.sh~["segments","separators","cmd0","argv","redirects","kind","rawText","parseFailure"]~{"segments":[{"cmd0":"A=1","cmd0Raw":"A=1","argv":["B=2","bash","x.sh"],"argvRaw":["B=2","bash","x.sh"],"redirects":[],"kind":"simple","rawText":"A=1 B=2 bash x.sh"}],"separators":[],"cmd0":"A=1","argv":["B=2","bash","x.sh"],"redirects":[],"kind":"simple","rawText":"A=1 B=2 bash x.sh","parseFailure":false}
s08-fd-dup~git merge 2>&1~["segments","separators","cmd0","argv","redirects","kind","rawText","parseFailure"]~{"segments":[{"cmd0":"git","cmd0Raw":"git","argv":["merge"],"argvRaw":["merge"],"redirects":[{"op":"2>","fd":"2","target":"&1"}],"kind":"simple","rawText":"git merge 2>&1"}],"separators":[],"cmd0":"git","argv":["merge"],"redirects":[{"op":"2>","fd":"2","target":"&1"}],"kind":"simple","rawText":"git merge 2>&1","parseFailure":false}
s09-heredoc~cat <<'EOF'\nbody\nEOF~["segments","separators","cmd0","argv","redirects","kind","rawText","parseFailure"]~{"segments":[{"cmd0":"cat","cmd0Raw":"cat","argv":[],"argvRaw":[],"redirects":[{"op":"<","fd":"1","target":"<EOF"}],"kind":"simple","rawText":"cat <<'EOF'"}],"separators":[],"cmd0":"cat","argv":[],"redirects":[{"op":"<","fd":"1","target":"<EOF"}],"kind":"simple","rawText":"cat <<'EOF'\nbody\nEOF","parseFailure":false}
s10-parse-failure~git merge 'unclosed~["segments","cmd0","argv","redirects","kind","rawText","separators","parseFailure"]~{"segments":[],"cmd0":"","argv":[],"redirects":[],"kind":"empty","rawText":"git merge 'unclosed","separators":[],"parseFailure":true}
TABLE

# redirects[].targetRaw is non-enumerable. It must not appear in JSON.stringify yet must still
# be readable -- the direct pin paired with the JSON byte-string pin above (without it, "gone"
# and "hidden" can't be told apart).
TR="$(bash "$RUNNER" 30 node -e '
  const { parse } = require(process.argv[1]);
  const r = parse(process.argv[2]).redirects[0];
  process.stdout.write(JSON.stringify([("targetRaw" in r), r.targetRaw, Object.keys(r)]));
' "$IR_JS" 'echo hi > "my file.txt"' 2>/dev/null)"
ROWS=$((ROWS + 1))
assert_eq "s11-targetRaw stays non-enumerable but readable" '[true,"\"my file.txt\"",["op","fd","target"]]' "$TR"

# analysisOf(ir) contract (Step 2 export, not yet implemented): moved to the sibling
# shape-contract-analysis.sh, which the dispatcher (feature-2134-command-ir-equivalence.sh)
# registers as a CONDITIONAL case -- the same non-blocking-until-Step-2 mechanism already used
# for ownership-doc.sh, gated on the same OWNERSHIP_DOC signal file. Keeping s12-s14 in THIS
# file's BLOCKING_CASES entry would make an expected Step-2 RED indistinguishable from a real
# Step-1 regression in the s01-s11 rows above; splitting the file lets the dispatcher tell them
# apart the way it already does for ownership-doc.sh.

ROWS_EXPECTED=11
if [ "$ROWS" = "$ROWS_EXPECTED" ]; then
    echo "PASS: row budget: $ROWS_EXPECTED shape rows executed"; PASS=$((PASS + 1))
else
    echo "FAIL: row budget: executed=$ROWS expected=$ROWS_EXPECTED (an empty or unreachable table reports green otherwise)"; FAIL=$((FAIL + 1))
fi

echo ""
echo "Total: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
