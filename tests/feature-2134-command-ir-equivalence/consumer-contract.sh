#!/usr/bin/env bash
# tests/feature-2134-command-ir-equivalence/consumer-contract.sh
# Tests: hooks/lib/command-ir.js, hooks/enforce-worktree/shared-cmd-utils.js, hooks/lib/bash-write-patterns.js, hooks/lib/bash-write-targets.js
# Tags: hook, command-ir, equivalence, snapshot, consumer-contract, TL1, scope:issue-specific
#
# Where snapshot.sh guards parse()'s "shape", this guards the verdict consumers derive from
# the same IR -- even with the same shape, actual behavior changes if how it's read changes
# (detail.md S1-5). Covers hasShellChaining / hasCommandSequencing / rejectInterpreterAndChaining,
# and classify() / collectWriteTargetsFromSegments(), which take the IR directly.

set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENTS_DIR="$(cd "$DIR/../.." && pwd)"

command -v node >/dev/null 2>&1 || { echo "SKIP: node not found"; exit 77; }

# Fixture isolation (rules/test/fixture-isolation.md): pure function calls only, but the
# parent session's id must always be dropped -- the child node inheriting it could touch real session state.
unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID

npath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
AGENTS_N="$(npath "$AGENTS_DIR")"
RUNNER="$AGENTS_DIR/bin/run-with-timeout.sh"

PASS=0; FAIL=0; ROWS=0
assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then echo "PASS: $name"; PASS=$((PASS + 1))
    else echo "FAIL: $name"; echo "    want: $want"; echo "    got:  $got"; FAIL=$((FAIL + 1)); fi
}

# Returns the four predicates' values as one "chain,seq,interp,classify,targetsJson" line.
# If require fails, returns <REQUIRE-FAILED:...> -- a guard so a missing consumer module
# isn't mistaken for the green of "everything is false".
consumer_probe() {
    bash "$RUNNER" 30 node -e '
      const A = process.argv[1];
      const cmd = process.argv[2];
      // Turn a require failure into a "visible got" of <REQUIRE-FAILED:...>. node -e does not
      // allow a top-level return, so an early exit is expressed via the function return value.
      const run = () => {
        let parse, U, classify, collect;
        try {
          ({ parse } = require(A + "/hooks/lib/command-ir.js"));
          U = require(A + "/hooks/enforce-worktree/shared-cmd-utils.js");
          ({ classify } = require(A + "/hooks/lib/bash-write-patterns.js"));
          ({ collectWriteTargetsFromSegments: collect } = require(A + "/hooks/lib/bash-write-targets.js"));
        } catch (e) {
          return "<REQUIRE-FAILED:" + String((e && e.message) || e) + ">";
        }
        const ir = parse(cmd);
        let targets;
        try { targets = JSON.stringify(collect(ir.segments || [])); }
        catch (e) { targets = "<THREW:" + String((e && e.message) || e) + ">"; }
        let kind;
        try { kind = String(classify(ir)); } catch (e) { kind = "<THREW>"; }
        return [
          String(U.hasShellChaining(cmd)),
          String(U.hasCommandSequencing(cmd)),
          String(U.rejectInterpreterAndChaining(cmd)),
          kind,
          targets,
        ].join(",");
      };
      process.stdout.write(run());
    ' "$AGENTS_N" "$1" 2>/dev/null
}

# Table: id ~ cmd(newlines encoded as \n, backslashes as \\) ~ want
# want = hasShellChaining,hasCommandSequencing,rejectInterpreterAndChaining,classify,collectWriteTargets
#
# want is the current implementation's measured value, not an ideal shape (Step 1's job is to
# pin, not to correct). Known current defects are baked in as-is too -- c16's escaped-`&&`
# misdetection, c17's `-exec rm {} \;` misdetection, and c19's leak of operators inside a
# heredoc body. If these flip from true to false at Step 2, that's the fail-closed guard
# under-detecting, so per detail.md S2-7 it must be plugged by adding a heredoc condition on
# the shared-cmd-utils.js side. Any other verdict change is a parser bug and must not be made
# to pass by rewriting the expected value.
while IFS='~' read -r id cmd_enc want; do
    [ -z "$id" ] && continue
    case "$id" in \#*) continue ;; esac
    ROWS=$((ROWS + 1))
    cmd="$(printf '%b' "$cmd_enc")"
    assert_eq "$id: consumer verdicts" "$want" "$(consumer_probe "$cmd")"
done <<'TABLE'
c01-single~git status~false,false,false,read,{"targets":null,"parseFailure":false}
c02-and-chain~git merge && git push~true,true,true,read,{"targets":null,"parseFailure":false}
c03-semicolon~git stash; git pull~true,true,true,read,{"targets":null,"parseFailure":false}
c04-or-chain~make || echo failed~true,true,true,read,{"targets":null,"parseFailure":false}
c05-pipe-tee~git merge | tee log.txt~true,false,true,read,{"targets":[{"resolveVia":"ancestor","path":"log.txt"}],"parseFailure":false}
c06-trailing-amp~git pull &~true,false,true,read,{"targets":null,"parseFailure":false}
c07-leading-amp~& git.exe status~true,false,true,read,{"targets":null,"parseFailure":false}
c08-fd-dup~git merge 2>&1~false,false,false,read,{"targets":null,"parseFailure":false}
c09-multi-redirect~git status 2>&1 1>&2 >/dev/null~false,false,false,read,{"targets":null,"parseFailure":false}
c10-redirect-write~echo hi > out.txt~false,false,false,read,{"targets":[{"resolveVia":"ancestor","path":"out.txt"}],"parseFailure":false}
c11-append-write~echo hi >> out.txt~false,false,false,read,{"targets":[{"resolveVia":"ancestor","path":"out.txt"}],"parseFailure":false}
c12-devnull-only~echo hi >/dev/null~false,false,false,read,{"targets":null,"parseFailure":false}
c13-subst~git merge --ff-only $(rm -rf /)~true,false,true,read,{"targets":[{"resolveVia":"ancestor","path":"/"}],"parseFailure":false}
c14-backtick~echo `date`~true,false,true,read,{"targets":null,"parseFailure":false}
c15-sq-and~echo 'a && b'~false,false,false,read,{"targets":null,"parseFailure":false}
c16-escaped-and~echo a \\&\\& b~true,false,true,read,{"targets":null,"parseFailure":false}
c17-find-exec~find . -name '*.tmp' -exec rm {} \\;~true,true,true,read,{"targets":null,"parseFailure":false}
c18-heredoc-cat~cat <<'EOF'\nbody\nEOF~true,false,true,read,{"targets":null,"parseFailure":false}
c19-heredoc-body-ops~cat <<'EOF'\na && b; c > d\nEOF~true,false,true,read,{"targets":null,"parseFailure":false}
c20-heredoc-to-file~cat > out.txt <<'EOF'\nx\nEOF~true,false,true,write,{"targets":[{"resolveVia":"ancestor","path":"out.txt"}],"parseFailure":false}
c21-heredoc-python~python3 <<'PY'\nprint(1)\nPY~true,false,true,write,{"targets":null,"parseFailure":false}
c22-newline-pair~ls\nrm -rf x~false,false,true,read,{"targets":null,"parseFailure":false}
c23-interpreter-head~bash tests/x.sh~false,false,true,read,{"targets":null,"parseFailure":false}
c24-interpreter-after-and~git pull && bash -c script.sh~true,true,true,read,{"targets":null,"parseFailure":false}
c25-env-prefix~A=1 B=2 bash x.sh~false,false,true,read,{"targets":null,"parseFailure":false}
c26-xargs-pipe~find . -name '*.tmp' | xargs rm~true,false,true,read,{"targets":null,"parseFailure":false}
c27-xargs-pipe-redirect~find . -name '*.tmp' | xargs rm > out.log~true,false,true,read,{"targets":[{"resolveVia":"ancestor","path":"out.log"}],"parseFailure":false}
c28-subshell~(cd x && ls)~true,true,true,read,{"targets":null,"parseFailure":false}
c29-unclosed-quote~git merge 'unclosed~true,true,true,write,{"targets":null,"parseFailure":false}
c30-empty~~false,false,false,read,{"targets":null,"parseFailure":false}
c31-cp-write~cp a.txt b.txt~false,false,false,read,{"targets":[{"resolveVia":"ancestor","path":"b.txt"}],"parseFailure":false}
c32-rm-write~rm -rf build~false,false,false,read,{"targets":[{"resolveVia":"ancestor","path":"build"}],"parseFailure":false}
c33-tee-write~echo x | tee /tmp/out~true,false,true,read,{"targets":[{"resolveVia":"ancestor","path":"/tmp/out"}],"parseFailure":false}
c34-sentinel-dq~echo "<<WORKFLOW_MARK_STEP_x>>"~false,false,false,read,{"targets":null,"parseFailure":false}
c35-quoted-target~echo hi > "my file.txt"~false,false,false,read,{"targets":[{"resolveVia":"ancestor","path":"my file.txt"}],"parseFailure":false}
TABLE

# A pin naming the fail-closed path directly. Same input as c29 but a different role -- c29 is
# a single input's verdict row, this pins "the correspondence between the parseFailure state and
# the verdict" (the backstop for S2-4 not adding new failure conditions).
FC="$(bash "$RUNNER" 30 node -e '
  const A = process.argv[1];
  const { parse } = require(A + "/hooks/lib/command-ir.js");
  const U = require(A + "/hooks/enforce-worktree/shared-cmd-utils.js");
  const { classify } = require(A + "/hooks/lib/bash-write-patterns.js");
  const cmd = "git merge \x27unclosed";
  const ir = parse(cmd);
  process.stdout.write(JSON.stringify([
    ir.parseFailure,
    U.hasShellChaining(cmd),
    U.hasCommandSequencing(cmd),
    U.rejectInterpreterAndChaining(cmd),
    classify(ir),
  ]));
' "$AGENTS_N" 2>/dev/null)"
ROWS=$((ROWS + 1))
assert_eq "c36-fail-closed: parseFailure forces every consumer to the safe verdict" \
    '[true,true,true,true,"write"]' "$FC"

# That a consumer can read a non-enumerable IR property. shape-contract.sh pins the "doesn't
# show up in JSON" side; this pins the "a consumer actually reads it" side. isPosixRedirWriteIR
# is a consumer that reads redirects[].targetRaw, and if Step 2 drops targetRaw, a fd-dup turns
# into a write (over-detection).
TR="$(bash "$RUNNER" 30 node -e '
  const A = process.argv[1];
  const { parse } = require(A + "/hooks/lib/command-ir.js");
  const { isPosixRedirWriteIR } = require(A + "/hooks/lib/bash-write-targets.js");
  process.stdout.write(JSON.stringify([
    isPosixRedirWriteIR(parse("git merge 2>&1")),
    isPosixRedirWriteIR(parse("echo hi > out.txt")),
    isPosixRedirWriteIR(parse("echo hi >/dev/null")),
    isPosixRedirWriteIR(parse("echo x | tee /tmp/out")),
  ]));
' "$AGENTS_N" 2>/dev/null)"
ROWS=$((ROWS + 1))
assert_eq "c37-targetRaw: fd-dup stays read while a real redirect target is a write" \
    '[false,true,false,true]' "$TR"

# c38: negative-assertion control (protection-fix-tests.md Pattern 1). A spread/
# degraded IR (drops non-enumerable props like `.analysis`) fed to classify()
# must NOT silently weaken the verdict vs. the unspread IR -- see
# docs/architecture/claude-code/shell-command-parsing.md for the full rationale.
# Uses a real top-level redirect (c20's shape), not a heredoc-body operator --
# post-Step-2 that no longer classifies as a real write (see c19).
C38_CMD=$'cat > out.txt <<\'EOF\'\nx\nEOF'
SPREAD="$(bash "$RUNNER" 30 node -e '
  const A = process.argv[1];
  const { parse } = require(A + "/hooks/lib/command-ir.js");
  const { classify } = require(A + "/hooks/lib/bash-write-patterns.js");
  const cmd = process.argv[2];
  const ir = parse(cmd);
  const spread = { ...ir };
  process.stdout.write(JSON.stringify([String(classify(ir)), String(classify(spread))]));
' "$AGENTS_N" "$C38_CMD" 2>/dev/null)"
ROWS=$((ROWS + 1))
assert_eq "c38-spread-ir-no-weaken: a spread/degraded IR classifies identically to the correct IR (positive control: both 'write')" \
    '["write","write"]' "$SPREAD"
# want stays ["write","write"]: c20's command is a genuine top-level redirect
# both before and after Step 2, so this remains a valid positive control.

# c39: stripEnvPrefix's degenerate all-assignment input, exercised through the exported
# resolveEffectiveSegment (stripEnvPrefix itself is not exported). `A=1` alone has no token
# after the assignment, so argv.findIndex(...) returns -1 and the whole segment resolves to
# null -- a consumer that read cmd0 without checking for null would report the assignment
# itself ("A=1") as the command, which is how #1425-style over-blocking on a bare assignment
# would reappear.
AEP="$(bash "$RUNNER" 30 node -e '
  const A = process.argv[1];
  const { parse, resolveEffectiveSegment } = require(A + "/hooks/lib/command-ir.js");
  const ir = parse("A=1");
  process.stdout.write(JSON.stringify(resolveEffectiveSegment(ir.segments[0])));
' "$AGENTS_N" 2>/dev/null)"
ROWS=$((ROWS + 1))
assert_eq "c39-env-prefix-all-assignment: a bare 'A=1' resolves to no effective command (null)" \
    "null" "$AEP"

# Budget for the number of rows executed. Doesn't read as green even if the table goes empty or a heredoc terminator drifts.
ROWS_EXPECTED=39
if [ "$ROWS" = "$ROWS_EXPECTED" ]; then
    echo "PASS: row budget: $ROWS_EXPECTED consumer rows executed"; PASS=$((PASS + 1))
else
    echo "FAIL: row budget: executed=$ROWS expected=$ROWS_EXPECTED (an empty or unreachable table reports green otherwise)"; FAIL=$((FAIL + 1))
fi

echo ""
echo "Total: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
