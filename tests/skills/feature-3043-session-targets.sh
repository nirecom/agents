#!/usr/bin/env bash
# tests/skills/feature-3043-session-targets.sh
# Tests: skills/issue-close-finalize/scripts/from-session-targets.sh
# Tags: feature-3043, issue-close-finalize, from-session, gh-stub, scope:issue-specific, TL2
# #3043 (D2): `--from-session` finalizes only the session's CLOSED-by-merge targets. An OPEN or
# unknown issue gets one guidance line naming `/issue-close-finalize <ref>` and no outcome entry;
# when nothing is closed, the empty bag (`--session <sid> --empty`) is written.
# Assumed invocation: `bash from-session-targets.sh --session <sid> --owner-repo <owner/repo>`.
# TL3 gap: a real gh against GitHub and the model reading the guidance lines are not exercised;
# nor is the model running the finalize pipeline once per handed-back TARGET (the test loops it).

set -uo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

TMP_ROOT="$(make_tmp)"
[[ -n "$TMP_ROOT" && -d "$TMP_ROOT" ]] || { echo "cannot create a temp root" >&2; exit 1; }
readonly TMP_ROOT
trap 'rm -rf "$TMP_ROOT"' EXIT
harness_isolate "$TMP_ROOT/iso"
unset CLAUDE_CODE_SESSION_ID
cd "$TMP_ROOT" || exit 1

SCRIPT="$SCRIPT_CHECKOUT_ROOT/skills/issue-close-finalize/scripts/from-session-targets.sh"
STUB_LIB="$SCRIPT_CHECKOUT_ROOT/tests/lib/gh-state-stub.js"
# The per-issue gh stub of tests/lib/gh-state-stub.js; the node side prints its dir and preload.
STUB_DIR="$TMP_ROOT/stub"
node -e 'require(process.argv[1]).makeGhStub(process.argv[2])' "$STUB_LIB" "$STUB_DIR" || { echo "gh stub setup failed" >&2; exit 1; }
STUB_PRELOAD="$STUB_DIR/gh-stub-preload.js"
if command -v cygpath >/dev/null 2>&1; then STUB_PRELOAD="$(cygpath -m "$STUB_PRELOAD")"; STUB_DIR="$(cygpath -u "$STUB_DIR")"; fi
export PATH="$STUB_DIR:$PATH" NODE_OPTIONS="--require \"$STUB_PRELOAD\"" GH_STUB_LOG="$TMP_ROOT/gh.log"

write_intent() { # <sid> <ref>...
  local sid="$1"; shift
  { printf '# Intent\n\n## Issues\n'; printf -- '- %s\n' "$@"; } >"$WORKFLOW_PLANS_DIR/$sid-intent.md"
}
outcome_of() { printf '%s/%s.control/issue-close-outcome.json' "$WORKFLOW_STATE_DIR" "$1"; }
# targets <sid> <gh-map-json> — one run; stdout+stderr in $TMP_ROOT/<sid>.out, rc in $RC.
targets() {
  RC=0
  GH_STUB_MAP="$2" run_with_timeout 60 bash "$SCRIPT" --session "$1" --owner-repo o/r >"$TMP_ROOT/$1.out" 2>&1 || RC=$?
}
issue_count() { # <outcome-file> — number of entries, or "absent"
  [ -f "$1" ] || { echo absent; return; }
  node -e 'try { console.log(JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).issues.length); } catch (_) { console.log("unreadable"); }' "$1"
}

case_begin "from-session-open-and-unknown-get-guidance-only" "skills/issue-close-finalize/scripts/from-session-targets.sh"
if [ ! -f "$SCRIPT" ]; then
  fail "open/unknown issues get a guidance line and no entry" "NOT YET IMPLEMENTED: from-session-targets.sh does not exist"
else
  write_intent s3043g '#701' '#702' '#703'
  targets s3043g '{"701":"CLOSED","702":"OPEN","703":"FAIL"}'
  out="$(cat "$TMP_ROOT/s3043g.out")"
  if [ "$RC" -ne 0 ]; then
    fail "open/unknown issues get a guidance line and no entry" "rc=$RC: $out"
  elif [ "$(grep -c -- '/issue-close-finalize #702' "$TMP_ROOT/s3043g.out")" -ne 1 ] || [ "$(grep -c -- '/issue-close-finalize #703' "$TMP_ROOT/s3043g.out")" -ne 1 ]; then
    fail "open/unknown issues get a guidance line and no entry" "want one /issue-close-finalize line each for #702 and #703: $out"
  elif grep -q -- '/issue-close-finalize #701' "$TMP_ROOT/s3043g.out"; then
    fail "open/unknown issues get a guidance line and no entry" "the closed #701 must not get a guidance line: $out"
  elif ! grep -q '#701' "$TMP_ROOT/s3043g.out"; then
    fail "open/unknown issues get a guidance line and no entry" "the closed target #701 is not handed back: $out"
  elif [ "$(issue_count "$(outcome_of s3043g)")" != absent ]; then
    fail "open/unknown issues get a guidance line and no entry" "an outcome was written: $(cat "$(outcome_of s3043g)")"
  else
    pass "open/unknown issues get a guidance line and no entry; the closed target is handed back"
  fi
fi
case_end

case_begin "from-session-nothing-closed-writes-empty-bag" "skills/issue-close-finalize/scripts/from-session-targets.sh"
if [ ! -f "$SCRIPT" ]; then
  fail "nothing closed writes the empty bag" "NOT YET IMPLEMENTED: from-session-targets.sh does not exist"
else
  write_intent s3043h '#702'
  targets s3043h '{"702":"OPEN"}'
  got="$(issue_count "$(outcome_of s3043h)")"
  if [ "$RC" -ne 0 ] || [ "$got" != 0 ]; then
    fail "nothing closed writes the empty bag" "rc=$RC entries=$got: $(cat "$TMP_ROOT/s3043h.out")"
  elif ! grep -q -- '/issue-close-finalize #702' "$TMP_ROOT/s3043h.out"; then
    fail "nothing closed writes the empty bag" "the open #702 got no guidance line: $(cat "$TMP_ROOT/s3043h.out")"
  else
    pass "nothing closed writes the empty bag and still guides the open issue"
  fi
fi
case_end

case_begin "from-session-gh-sees-owner-repo" "skills/issue-close-finalize/scripts/from-session-targets.sh"
if [ ! -f "$SCRIPT" ]; then
  fail "the owner repo reaches the state lookup" "NOT YET IMPLEMENTED: from-session-targets.sh does not exist"
else
  rm -f "$GH_STUB_LOG"
  write_intent s3043i 'r2#9'
  targets s3043i '{"o/r2#9":"CLOSED"}'
  if [ "$RC" -ne 0 ]; then
    fail "the owner repo reaches the state lookup" "rc=$RC: $(cat "$TMP_ROOT/s3043i.out")"
  elif ! grep -q '"--repo","o/r2"' "$GH_STUB_LOG" 2>/dev/null; then
    fail "the owner repo reaches the state lookup" "r2#9 was not resolved through o/r: gh log=$(cat "$GH_STUB_LOG" 2>/dev/null) out=$(cat "$TMP_ROOT/s3043i.out")"
  elif grep -q -- '/issue-close-finalize' "$TMP_ROOT/s3043i.out"; then
    fail "the owner repo reaches the state lookup" "a resolvable CLOSED issue got a guidance line: $(cat "$TMP_ROOT/s3043i.out")"
  else
    pass "--owner-repo resolves a shorthand ref for the state lookup"
  fi
fi
case_end

# Mixed CLOSED/OPEN: the refs the script hands back (lines without a guidance command) are the
# dispatch set; finalizing that set through the real writer leaves entries for CLOSED refs only.
WRITER="$SCRIPT_CHECKOUT_ROOT/bin/issue-close-write-outcome.js"
handed_back() { # <out-file> — the refs on TARGET lines, repo kept, sorted, space-joined
  sed -n 's/^TARGET //p' "$1" | tr -d '\r' | sort | tr '\n' ' ' | sed 's/ $//'
}
entries_by_state() { # <outcome-file> — "N:state" per entry, sorted, space-joined
  node -e 'let b = { issues: [] }; try { b = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); } catch (_) {} console.log((b.issues || []).filter((e) => e).map((e) => e.issueNumber + ":" + e.state).sort().join(" "));' "$1"
}

case_begin "from-session-mixed-dispatches-only-closed-and-writes-their-entries" "skills/issue-close-finalize/scripts/from-session-targets.sh"
if [ ! -f "$SCRIPT" ]; then
  fail "mixed CLOSED/OPEN dispatches only CLOSED" "NOT YET IMPLEMENTED: from-session-targets.sh does not exist"
else
  MAP='{"801":"CLOSED","802":"OPEN","803":"CLOSED"}'
  write_intent s3043j '#801' '#802' '#803'
  targets s3043j "$MAP"
  got="$(handed_back "$TMP_ROOT/s3043j.out")"
  if [ "$RC" -ne 0 ]; then
    fail "mixed CLOSED/OPEN dispatches only CLOSED" "rc=$RC: $(cat "$TMP_ROOT/s3043j.out")"
  elif [ "$got" != "#801 #803" ]; then
    fail "mixed CLOSED/OPEN dispatches only CLOSED" "want handed-back #801 #803, got '$got': $(cat "$TMP_ROOT/s3043j.out")"
  else
    OUTF="$(outcome_of s3043j)"; mkdir -p "$(dirname "$OUTF")"
    : >"$TMP_ROOT/s3043j-write.out"
    # One writer run per handed-back target, as the skill runs the finalize pipeline per TARGET.
    for ref in $got; do
      GH_STUB_MAP="$MAP" run_with_timeout 60 node "$WRITER" --session-id s3043j --out-file "$OUTF" --owner-repo o/r \
        "${ref#\#}" succeeded written_by_step_6h succeeded succeeded succeeded >>"$TMP_ROOT/s3043j-write.out" 2>&1
    done
    ent="$(entries_by_state "$OUTF")"
    if [ "$ent" != "801:succeeded 803:succeeded" ]; then
      fail "mixed CLOSED/OPEN writes entries only for CLOSED" "want '801:succeeded 803:succeeded', got '$ent': $(cat "$TMP_ROOT/s3043j-write.out")"
    else
      pass "only CLOSED refs are dispatched and get outcome entries; the OPEN #802 gets none"
    fi
  fi
fi
case_end

case_begin "from-session-same-n-in-two-repos-hands-back-both" "skills/issue-close-finalize/scripts/from-session-targets.sh"
write_intent s3043l '#42' 'x/y#42'
targets s3043l '{"o/r#42":"CLOSED","x/y#42":"CLOSED"}'
got="$(handed_back "$TMP_ROOT/s3043l.out")"
if [ "$RC" -ne 0 ]; then
  fail "same N in two repos hands back both" "rc=$RC: $(cat "$TMP_ROOT/s3043l.out")"
elif [ "$(tr -d '\r' <"$TMP_ROOT/s3043l.out" | grep -cx 'TARGET #42')" -ne 1 ] || [ "$(tr -d '\r' <"$TMP_ROOT/s3043l.out" | grep -cx 'TARGET x/y#42')" -ne 1 ]; then
  fail "same N in two repos hands back both" "want exactly 'TARGET #42' and 'TARGET x/y#42': $(cat "$TMP_ROOT/s3043l.out")"
elif [ "$got" != "#42 x/y#42" ]; then
  fail "same N in two repos hands back both" "want handed-back '#42 x/y#42', got '$got'"
else
  pass "#42 (home o/r) and x/y#42 are two TARGET lines"
fi
case_end

# seed_bag <sid> — an outcome bag holding one recorded entry; prints its path and keeps a copy at <path>.orig.
seed_bag() {
  local f; f="$(outcome_of "$1")"
  mkdir -p "$(dirname "$f")"
  printf '{"homeRepo":"o/r","issues":[{"issueNumber":901,"state":"succeeded"}]}\n' >"$f"
  cp "$f" "$f.orig"
  printf '%s' "$f"
}

case_begin "from-session-nothing-closed-keeps-recorded-bag" "skills/issue-close-finalize/scripts/from-session-targets.sh"
write_intent s3043m '#702'
BAG="$(seed_bag s3043m)"
targets s3043m '{"702":"OPEN"}'
if [ "$RC" -ne 0 ]; then
  fail "nothing closed keeps a recorded bag" "rc=$RC: $(cat "$TMP_ROOT/s3043m.out")"
elif ! cmp -s "$BAG" "$BAG.orig"; then
  fail "nothing closed keeps a recorded bag" "the bag changed: $(cat "$BAG")"
elif ! grep -q '^NO_TARGETS:' "$TMP_ROOT/s3043m.out"; then
  fail "nothing closed keeps a recorded bag" "no NO_TARGETS: line: $(cat "$TMP_ROOT/s3043m.out")"
else
  pass "with no CLOSED target, a bag holding a recorded entry stays byte-identical"
fi
case_end

case_begin "from-session-unreadable-intent-fails-and-keeps-bag" "skills/issue-close-finalize/scripts/from-session-targets.sh"
mkdir -p "$WORKFLOW_PLANS_DIR/s3043n-intent.md"
BAG="$(seed_bag s3043n)"
targets s3043n '{"702":"CLOSED"}'
if [ "$RC" -ne 1 ]; then
  fail "an unreadable intent fails" "want rc 1, got rc=$RC: $(cat "$TMP_ROOT/s3043n.out")"
elif ! grep -q 'could not read closes_issues' "$TMP_ROOT/s3043n.out"; then
  fail "an unreadable intent fails" "rc 1 must come from the unreadable intent: $(cat "$TMP_ROOT/s3043n.out")"
elif grep -qE '^(NO_TARGETS:|TARGET )' "$TMP_ROOT/s3043n.out"; then
  fail "an unreadable intent fails" "no NO_TARGETS:/TARGET line expected: $(cat "$TMP_ROOT/s3043n.out")"
elif ! cmp -s "$BAG" "$BAG.orig"; then
  fail "an unreadable intent fails" "the bag changed: $(cat "$BAG")"
else
  pass "an unreadable intent exits 1, hands back nothing, and leaves the bag as is"
fi
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
