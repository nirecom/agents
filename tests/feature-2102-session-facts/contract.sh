#!/usr/bin/env bash
# Tests: bin/workflow/read-session-facts, bin/workflow/lib/session-facts/keys.js, bin/workflow/lib/session-facts/collect.js, bin/workflow/lib/session-facts/gate-facts.js
# Tags: tl2, workflow, session-facts, contract, keys, budget, scope:issue-specific, pwsh-not-required

# The v1 output contract: same eight keys, same order, every time, whatever the session
# looks like. A consumer SKILL.md parses positionally-stable KEY=VALUE lines, so a key
# that silently appears, vanishes or moves is a breaking change that must cost a
# FACTS_VERSION bump. This file is the machine that charges that cost.

# TL3 gap (what this test does NOT catch): whether the model actually reads
# FACTS_VERSION before consuming the keys. Closest-to-action mitigation:
# WORKFLOW_USER_VERIFIED preflight, bin/check-verification-gate.sh category:
# skill-orchestration.

set -uo pipefail

command -v node >/dev/null 2>&1 || { echo "SKIP: node not available"; exit 77; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
nrm() { cygpath -m "$1" 2>/dev/null || echo "$1"; }
REPO_N="$(nrm "$REPO_ROOT")"
RSF="$REPO_N/bin/workflow/read-session-facts"
KEYS_MOD="$REPO_N/bin/workflow/lib/session-facts/keys.js"; export KEYS_MOD
GATE_FACTS_SRC="$REPO_ROOT/bin/workflow/lib/session-facts/gate-facts.js"

TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT
WORKFLOW_DIR="$TMPDIR_BASE/wf"; PLANS_DIR="$TMPDIR_BASE/plans"
mkdir -p "$WORKFLOW_DIR" "$PLANS_DIR"
CLAUDE_WORKFLOW_DIR="$(nrm "$WORKFLOW_DIR")"; export CLAUDE_WORKFLOW_DIR
WORKFLOW_PLANS_DIR="$(nrm "$PLANS_DIR")"; export WORKFLOW_PLANS_DIR
unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
check() { if [ "$3" = "$2" ]; then pass "$1"; else fail "$1 -- expected [$2] got [$3]"; fi; }
check_not_contains() {
  case "$3" in *"$2"*) fail "$1 -- did NOT expect [$2] in: $3" ;; *) pass "$1" ;; esac
}
run_with_timeout() {
  if command -v timeout >/dev/null 2>&1; then timeout 120 "$@"
  else perl -e 'alarm 120; exec @ARGV' -- "$@"; fi
}

# A config dir that mirrors the real layout, so bin/confirm-off can actually resolve
# get-config-var and load-env.js. Without the lib siblings every gate would read ERROR
# and the value assertions below would be measuring the fixture, not the CLI.
mk_cfg() {
  local d="$1"
  mkdir -p "$d/bin" "$d/hooks/lib"
  cp "$REPO_ROOT/bin/get-config-var" "$d/bin/"
  cp "$REPO_ROOT/bin/confirm-off" "$d/bin/"
  cp "$REPO_ROOT/hooks/lib/load-env.js" "$d/hooks/lib/"
  cp "$REPO_ROOT/hooks/lib/agents-config-dir.js" "$d/hooks/lib/"
  cp "$REPO_ROOT/hooks/lib/path-normalize.js" "$d/hooks/lib/"
  chmod +x "$d/bin/get-config-var" "$d/bin/confirm-off" 2>/dev/null || true
}
CFG_FULL="$TMPDIR_BASE/cfg-full"; mk_cfg "$CFG_FULL"
printf 'CONFIRM_TESTS=off\nCONFIRM_CODE=on\n' > "$CFG_FULL/.env"
CFG_BARE="$TMPDIR_BASE/cfg-bare"; mkdir -p "$CFG_BARE"

OUTF="$TMPDIR_BASE/out.txt"; ERRF="$TMPDIR_BASE/err.txt"
OUT=""; ERR=""; RC=0
run_facts() {
  local cfg="$1"; shift
  RC=0
  AGENTS_CONFIG_DIR="$(nrm "$cfg")" run_with_timeout node "$RSF" "$@" >"$OUTF" 2>"$ERRF" || RC=$?
  OUT="$(cat "$OUTF" 2>/dev/null || echo "")"
  ERR="$(cat "$ERRF" 2>/dev/null || echo "")"
}
keys_of() { printf '%s\n' "$1" | sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)=.*$/\1/p' | tr '\n' ' '; }
# keys_of DROPS every line that is not KEY=VALUE, so a banner, a warning or a spoofed
# record rides along invisibly. strict_keys_of reports the offender in place instead,
# and check_shape adds the two facts a key list cannot carry: how many lines there were,
# and whether the output was newline-terminated rather than truncated mid-line.
strict_keys_of() {
  [ -n "$1" ] || return 0
  printf '%s\n' "$1" | awk '{
    if ($0 ~ /^[A-Za-z_][A-Za-z0-9_]*=/) { k = $0; sub(/=.*/, "", k); printf "%s ", k }
    else { printf "BADLINE[%s] ", $0 }
  }'
}
check_shape() {
  local id="$1" f="$2"
  check "$id: exactly 8 lines" 8 "$(wc -l < "$f" | tr -d ' ')"
  check "$id: the last byte is a newline (nothing truncated)" 1 "$(tail -c 1 "$f" | wc -l | tr -d ' ')"
  check "$id: every line is KEY=VALUE, in the expected order" "$EXPECTED_KEYS" \
    "$(strict_keys_of "$(cat "$f" 2>/dev/null || echo "")")"
}

# The v1 key list, retyped here on purpose. This is the ONE deliberate CPR-SSOT
# exception in the suite: keys.js and this literal are two independent witnesses to the
# same external contract, so changing either side alone must go red. Deriving the
# expectation from keys.js would make the test agree with any edit, including a wrong one.
EXPECTED_KEYS="FACTS_VERSION SESSION_ID PLANS_DIR GATE_CONFIRM_TESTS GATE_CONFIRM_CODE COMPLEXITY_LEVEL_write_tests COMPLEXITY_LEVEL_write_code COMPLEXITY_SIGNALS "

echo "=== C1: keys.js is the implementation-side witness of the same list ==="
KEYS_JS="$(run_with_timeout node -e '
  try {
    const m = require(process.env.KEYS_MOD);
    process.stdout.write((m.FACTS_V1_KEYS || []).join(" ") + " ");
  } catch (e) { process.stdout.write("MODULE_LOAD_FAILED"); }' 2>/dev/null || echo "MODULE_LOAD_FAILED")"
check "C1a: FACTS_V1_KEYS matches the independently retyped list, in order" "$EXPECTED_KEYS" "$KEYS_JS"
check "C1b: the list is exactly eight keys" 8 "$(printf '%s' "$EXPECTED_KEYS" | wc -w | tr -d ' ')"

echo ""
echo "=== C2: a typical session -- full key set, in order, FACTS_VERSION first ==="
# Typical = a resolvable PLANS_DIR, a recorded complexity evaluation, both gates
# answerable. This is the shape the reader will actually meet in write-tests.
run_with_timeout node -e '
  const fs = require("fs"), path = require("path");
  const steps = {};
  fs.writeFileSync(path.join(process.env.CLAUDE_WORKFLOW_DIR, "c2.json"), JSON.stringify({
    steps,
    complexity_evaluation: {
      level: "high",
      levels: { detail: "high", write_tests: "high", write_code: "low" },
      signals: ["S1-multi-file", "S2-architecture"],
      recorded_at: "2026-09-04T00:00:00.000Z",
    },
  }));'
run_facts "$CFG_FULL" --session c2
check "C2a: exits 0" 0 "$RC"
check "C2b: the emitted keys match the expected list, in order" "$EXPECTED_KEYS" "$(keys_of "$OUT")"
check "C2c: line 1 is the version line" "FACTS_VERSION=1" "$(printf '%s\n' "$OUT" | head -n 1)"
check "C2d: the session id is echoed back" "SESSION_ID=c2" "$(printf '%s\n' "$OUT" | sed -n '2p')"
check_not_contains "C2e: no ACTION line (this CLI reports, it does not decide)" "ACTION=" "$OUT"
check_not_contains "C2f: no NEXT_SKILL line" "NEXT_SKILL=" "$OUT"
check_not_contains "C2g: no NEXT_HINT line" "NEXT_HINT=" "$OUT"
check "C2h: no line is emitted twice" 8 "$(printf '%s\n' "$OUT" | sed -n 's/=.*//p' | sort -u | wc -l | tr -d ' ')"
check_shape "C2i" "$OUTF"
# Non-vacuity for check_shape: the strict reader must actually flag a non-conforming line
# rather than skip it the way keys_of does.
check "C2j: control -- strict_keys_of names an injected banner line" \
  "FACTS_VERSION BADLINE[WARNING: spoofed] SESSION_ID " \
  "$(strict_keys_of "$(printf 'FACTS_VERSION=1\nWARNING: spoofed\nSESSION_ID=c2')")"

echo ""
echo "=== C2u: a UUID-shaped --session id (the real CLAUDE_SESSION_ID shape) is accepted ==="
# Every other fixture in this file is pure alphanumeric ("c2", "c3nostate", ...); a
# regression narrowing SESSION_ID_RE to reject hyphens would leave all of them green
# while rejecting 100% of real sessions -- CLAUDE_SESSION_ID is always a UUID. This is
# the accept-side counterpart of security.sh S1's reject table (CPR-ORTH).
UUID_SID="b923a2da-5f5d-494b-bfb3-568dce3bf8e9"
UUID_SID_LIT="$UUID_SID" run_with_timeout node -e '
  const fs = require("fs"), path = require("path");
  fs.writeFileSync(path.join(process.env.CLAUDE_WORKFLOW_DIR, process.env.UUID_SID_LIT + ".json"), JSON.stringify({
    steps: {},
    complexity_evaluation: {
      level: "high",
      levels: { detail: "high", write_tests: "high", write_code: "low" },
      signals: ["S1-multi-file"],
      recorded_at: "2026-09-04T00:00:00.000Z",
    },
  }));'
run_facts "$CFG_FULL" --session "$UUID_SID"
check "C2u-a: a UUID session id exits 0 (SESSION_ID_RE accepts hyphens)" 0 "$RC"
check "C2u-b: the emitted keys match the expected list, in order" "$EXPECTED_KEYS" "$(keys_of "$OUT")"
check "C2u-c: the UUID session id is echoed back verbatim" "SESSION_ID=$UUID_SID" "$(printf '%s\n' "$OUT" | sed -n '2p')"

echo ""
echo "=== C3: the key set never shrinks -- three degraded fixtures ==="
# Values may degrade to NONE/ERROR; keys may not disappear. A consumer that indexes the
# output by key must never have to branch on a key's absence.
run_facts "$CFG_FULL" --session c3nostate
check "C3a: no state file -- exits 0" 0 "$RC"
check "C3a2: no state file -- all eight keys present, in order" "$EXPECTED_KEYS" "$(keys_of "$OUT")"
check_shape "C3a3: no state file" "$OUTF"
run_facts "$CFG_BARE" --session c3noenv
check "C3b: no .env and no get-config-var -- exits 0" 0 "$RC"
check "C3b2: no .env -- all eight keys present, in order" "$EXPECTED_KEYS" "$(keys_of "$OUT")"
check_shape "C3b3: no .env" "$OUTF"
run_with_timeout node -e '
  const fs = require("fs"), path = require("path");
  fs.writeFileSync(path.join(process.env.CLAUDE_WORKFLOW_DIR, "c3nocx.json"),
    JSON.stringify({ steps: {} }));'
run_facts "$CFG_FULL" --session c3nocx
check "C3c: state file without a complexity record -- exits 0" 0 "$RC"
check "C3c2: no complexity record -- all eight keys present, in order" "$EXPECTED_KEYS" "$(keys_of "$OUT")"
check_shape "C3c3: no complexity record" "$OUTF"

echo ""
echo "=== C4: key names are static literals, not derived from ROUTING_STAGES ==="
# Injected via --require so the CLI's own module graph sees the stub. If key names were
# generated from the stage list, a fourth stage would add a ninth key.
STUB="$TMPDIR_BASE/stub-stages.js"
printf '%s\n' \
  '"use strict";' \
  'const Module = require("module");' \
  'const origLoad = Module._load;' \
  'Module._load = function (request, parent, isMain) {' \
  '  const m = origLoad.apply(this, arguments);' \
  '  if (m && Array.isArray(m.ROUTING_STAGES) && m.ROUTING_STAGES.indexOf("fake_stage_2102") === -1) {' \
  '    try { m.ROUTING_STAGES = Object.freeze(m.ROUTING_STAGES.concat(["fake_stage_2102"])); } catch (_) {}' \
  '  }' \
  '  return m;' \
  '};' > "$STUB"
WFS="$REPO_N/hooks/workflow-state"; export WFS
STUB_PROOF="$(run_with_timeout node --require "$STUB" -e '
  const wf = require(process.env.WFS);
  process.stdout.write(String(wf.ROUTING_STAGES.length));' 2>/dev/null || echo "STUB_FAILED")"
check "C4a: the stub really adds a fourth routing stage (non-vacuity)" 4 "$STUB_PROOF"
RC=0
AGENTS_CONFIG_DIR="$(nrm "$CFG_FULL")" run_with_timeout node --require "$STUB" "$RSF" \
  --session c2 >"$OUTF" 2>"$ERRF" || RC=$?
OUT="$(cat "$OUTF" 2>/dev/null || echo "")"
check "C4b: under the stub the key set is unchanged" "$EXPECTED_KEYS" "$(keys_of "$OUT")"
check "C4c: under the stub the key count is still eight" 8 "$(printf '%s\n' "$OUT" | grep -c '=' || true)"

echo ""
echo "=== C5: output size budget -- 512 bytes for a typical session ==="
# #2102 exists to cut tokens. Measured today: ~243 bytes. The budget is the guard that
# forces "are we reversing the point of this issue?" the next time a key is proposed.
run_facts "$CFG_FULL" --session c2
BYTES="$(wc -c < "$OUTF" | tr -d ' ')"
if [ "${BYTES:-99999}" -le 512 ]; then pass "C5a: stdout is $BYTES bytes (budget 512)"
else fail "C5a: stdout is $BYTES bytes -- over the 512-byte budget"; fi
if [ "${BYTES:-0}" -gt 0 ]; then pass "C5b: the budget was measured on real output"
else fail "C5b: the budget was measured on real output -- stdout was empty"; fi

echo ""
echo "=== C6: the two gate children are launched in parallel (structural pin) ==="
# Wall-clock is too environment-dependent to assert, so the pin is on the shape:
# a synchronous spawn per gate serialises them. Measured on Windows for the eight-key
# contract: sequential 2,579 ms vs parallel 1,695 ms -- and the three calls this CLI
# replaces cost 2,533 ms. A sequential implementation is therefore SLOWER than the
# status quo it replaces, which inverts the whole point of the issue.
if [ -f "$GATE_FACTS_SRC" ]; then
  pass "C6a: gate-facts.js exists"
  check "C6b: no execFileSync in gate-facts.js" 0 "$(grep -cF -- "execFileSync" "$GATE_FACTS_SRC" || true)"
  check "C6c: no spawnSync in gate-facts.js" 0 "$(grep -cF -- "spawnSync" "$GATE_FACTS_SRC" || true)"
else
  fail "C6a: gate-facts.js exists -- not found at $GATE_FACTS_SRC"
fi

echo ""
echo "=== C6 (behavioral): the two gate children actually run concurrently ==="
# C6a-c pin the STRUCTURE (no sync spawn literal); this proves the BEHAVIOR that
# structural pin exists to protect. Both CONFIRM_TESTS and CONFIRM_CODE are answered by
# invoking bin/confirm-off once per gate (values.sh (a) differentially checks the
# bundled reader's GATE_* output against exactly that direct call) -- so an instrumented
# confirm-off that timestamps its own start and completion turns "launched in parallel"
# into a barrier-file fact: true concurrency means both starts land before either
# finishes; a sequential (even if async) rewrite would show one gate's completion before
# the other's start. Wall-clock DURATION is still not asserted (C6's own comment already
# explains why that is environment-unstable) -- only the before/after ORDER is.
run_timed() { # <marker-dir> <gate-name> -- writes Date.now() (ms) start/done markers
  local mdir="$1" gate="$2"
  run_with_timeout node -e 'require("fs").writeFileSync(process.argv[1], String(Date.now()))' \
    "$mdir/${gate}.start"
  sleep 0.3
  run_with_timeout node -e 'require("fs").writeFileSync(process.argv[1], String(Date.now()))' \
    "$mdir/${gate}.done"
}
is_concurrent() { # <marker-dir> -- true iff the later start precedes the earlier finish
  local mdir="$1" t_s c_s t_d c_d last_start first_done
  t_s="$(cat "$mdir/CONFIRM_TESTS.start" 2>/dev/null || echo 0)"
  c_s="$(cat "$mdir/CONFIRM_CODE.start" 2>/dev/null || echo 0)"
  t_d="$(cat "$mdir/CONFIRM_TESTS.done" 2>/dev/null || echo 0)"
  c_d="$(cat "$mdir/CONFIRM_CODE.done" 2>/dev/null || echo 0)"
  last_start=$t_s; [ "$c_s" -gt "$last_start" ] && last_start=$c_s
  first_done=$t_d; [ "$c_d" -lt "$first_done" ] && first_done=$c_d
  [ "$last_start" -gt 0 ] && [ "$first_done" -gt 0 ] && [ "$last_start" -lt "$first_done" ]
}

# Control (non-vacuity): before trusting is_concurrent's verdict on gate-facts.js, prove
# the detector itself tells the two cases apart -- two genuinely sequential calls must
# read as NOT concurrent, and two genuinely backgrounded calls must read as concurrent.
MARKERS_SEQ="$TMPDIR_BASE/markers-seq"; mkdir -p "$MARKERS_SEQ"
run_timed "$MARKERS_SEQ" CONFIRM_TESTS
run_timed "$MARKERS_SEQ" CONFIRM_CODE
if is_concurrent "$MARKERS_SEQ"; then
  fail "C6-ctrl-a: two sequential calls were wrongly read as concurrent"
else
  pass "C6-ctrl-a: two sequential calls are correctly read as NOT concurrent"
fi
MARKERS_PAR="$TMPDIR_BASE/markers-par"; mkdir -p "$MARKERS_PAR"
run_timed "$MARKERS_PAR" CONFIRM_TESTS &
run_timed "$MARKERS_PAR" CONFIRM_CODE &
wait
if is_concurrent "$MARKERS_PAR"; then
  pass "C6-ctrl-b: two backgrounded calls are correctly read as concurrent"
else
  fail "C6-ctrl-b: two backgrounded calls were wrongly read as NOT concurrent"
fi

# The actual pin: run the real bundled reader (bin/workflow/read-session-facts) against
# an instrumented confirm-off, and judge gate-facts.js's own launch pattern by the same
# detector just proven sound above. Neither read-session-facts nor gate-facts.js exists
# yet, so this is expected to fail honestly -- the wrapper's markers are simply never
# written -- rather than pass vacuously; matches C6a's own not-found failure mode.
CFG_TIMED="$TMPDIR_BASE/cfg-timed"; mk_cfg "$CFG_TIMED"
printf 'CONFIRM_TESTS=off\nCONFIRM_CODE=on\n' > "$CFG_TIMED/.env"
MARKERS_LIVE="$TMPDIR_BASE/markers-live"; mkdir -p "$MARKERS_LIVE"
MARKERS_LIVE_N="$(nrm "$MARKERS_LIVE")"
mv "$CFG_TIMED/bin/confirm-off" "$CFG_TIMED/bin/confirm-off-real"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -u' \
  'gate="${1:-unknown}"' \
  "node -e 'require(\"fs\").writeFileSync(process.argv[1], String(Date.now()))' \"$MARKERS_LIVE_N/\${gate}.start\"" \
  'sleep 0.3' \
  "node -e 'require(\"fs\").writeFileSync(process.argv[1], String(Date.now()))' \"$MARKERS_LIVE_N/\${gate}.done\"" \
  'exec bash "$(dirname "$0")/confirm-off-real" "$@"' > "$CFG_TIMED/bin/confirm-off"
chmod +x "$CFG_TIMED/bin/confirm-off" 2>/dev/null || true
RC=0
AGENTS_CONFIG_DIR="$(nrm "$CFG_TIMED")" run_with_timeout node "$RSF" --session c6behav \
  >"$OUTF" 2>"$ERRF" || RC=$?
ERR="$(cat "$ERRF" 2>/dev/null || echo "")"
if [ -f "$MARKERS_LIVE/CONFIRM_TESTS.start" ] && [ -f "$MARKERS_LIVE/CONFIRM_CODE.start" ] \
   && [ -f "$MARKERS_LIVE/CONFIRM_TESTS.done" ] && [ -f "$MARKERS_LIVE/CONFIRM_CODE.done" ]; then
  if is_concurrent "$MARKERS_LIVE"; then
    pass "C6d: gate-facts.js launches both gate children concurrently"
  else
    fail "C6d: gate-facts.js's two gate children did not overlap -- sequential execution"
  fi
else
  fail "C6d: gate-facts.js not yet implemented -- the instrumented confirm-off children never ran (no barrier files under $MARKERS_LIVE); stderr: $ERR"
fi

echo ""
echo "=== C7: usage errors are exit 1, silent on stdout, loud on stderr ==="
# Fail-closed: a caller must never mistake a usage error for a fact set.
for bad in "--session" "--session|c 2" "--session|c2|--bogus" "" ; do
  RC=0
  if [ -z "$bad" ]; then
    AGENTS_CONFIG_DIR="$(nrm "$CFG_FULL")" run_with_timeout node "$RSF" >"$OUTF" 2>"$ERRF" || RC=$?
    label="no arguments"
  else
    IFS='|' read -r -a argv <<< "$bad"
    AGENTS_CONFIG_DIR="$(nrm "$CFG_FULL")" run_with_timeout node "$RSF" "${argv[@]}" >"$OUTF" 2>"$ERRF" || RC=$?
    label="$bad"
  fi
  check "C7: [$label] exits 1" 1 "$RC"
  check "C7: [$label] writes nothing to stdout" 0 "$(wc -c < "$OUTF" | tr -d ' ')"
  if [ -s "$ERRF" ]; then pass "C7: [$label] explains itself on stderr"
  else fail "C7: [$label] explains itself on stderr -- stderr was empty"; fi
  # Without this, C7 would be green merely because the CLI file is absent: node also
  # exits 1 with a non-empty stderr for a missing module.
  check_not_contains "C7: [$label] the exit 1 came from argument parsing" \
    "Cannot find module" "$(cat "$ERRF" 2>/dev/null || echo "")"
done

echo ""
echo "=== C8: the snapshot carries the two gate verdicts, never the .env behind them ==="
# The reader opens the config dir's .env to answer two boolean questions, and its output
# is pasted into a transcript. Anything else living in that file -- API keys, tokens --
# must not ride along (OWASP ASVS V8). The eight-key contract implies this, but a
# key-name assertion cannot see a secret smuggled into a VALUE, so it is witnessed here
# on the raw bytes of both streams.
CFG_SEC="$TMPDIR_BASE/cfg-sec"; mk_cfg "$CFG_SEC"
SECRET="sk-2102-must-not-leak"
printf 'CONFIRM_TESTS=off\nCONFIRM_CODE=on\nANTHROPIC_API_KEY=%s\n' "$SECRET" > "$CFG_SEC/.env"
check "C8a: the fixture .env really carries the secret (non-vacuity)" 1 \
  "$(grep -cF -- "$SECRET" "$CFG_SEC/.env" 2>/dev/null || true)"
run_facts "$CFG_SEC" --session c8
check_not_contains "C8b: the secret is absent from stdout" "$SECRET" "$OUT"
check_not_contains "C8c: the secret is absent from stderr" "$SECRET" "$ERR"
check_not_contains "C8d: the secret's variable name is absent too" "ANTHROPIC_API_KEY" "$OUT"
# C8b-C8d are "absent" assertions and empty output satisfies them for free; this pins
# that the run under measurement actually produced the gate lines.
check "C8e: the run really emitted the gate facts (non-vacuity)" "$EXPECTED_KEYS" "$(keys_of "$OUT")"
check_shape "C8f" "$OUTF"

echo ""
echo "=== C9: exit 3 degrades a VALUE -- the eight-line shape is unchanged ==="
# The fail-closed PLANS_DIR path is the one place the CLI exits nonzero while still
# reporting. A build that abandoned the contract there -- dropping keys, or appending a
# diagnostic to stdout -- would leave the caller parsing a shape it never expects.
RC=0
WORKFLOW_PLANS_DIR="plans" AGENTS_CONFIG_DIR="$(nrm "$CFG_FULL")" \
  run_with_timeout node "$RSF" --session c2 >"$OUTF" 2>"$ERRF" || RC=$?
check "C9a: a relative WORKFLOW_PLANS_DIR exits 3" 3 "$RC"
check_shape "C9b" "$OUTF"
check "C9c: PLANS_DIR is the degraded value, not a diagnostic" "PLANS_DIR=NONE" \
  "$(sed -n '3p' "$OUTF")"
if [ -s "$ERRF" ]; then pass "C9d: the reason went to stderr"
else fail "C9d: the reason went to stderr -- stderr was empty"; fi

echo ""
echo "=== C10: the reader is idempotent and leaves the three dirs untouched ==="
# A "reader" that writes is a hidden mutation on the hot path: two identical calls must
# be indistinguishable, and the state, plans and config dirs must survive byte-identical.
dir_fp() {
  FP_DIRS="$1" run_with_timeout node -e '
    const fs = require("fs"), path = require("path"), crypto = require("crypto");
    const out = [];
    const walk = (root, rel) => {
      let ents;
      try { ents = fs.readdirSync(path.join(root, rel), { withFileTypes: true }); }
      catch (e) { out.push(rel + " <unreadable>"); return; }
      ents.map((e) => e.name).sort().forEach((name) => {
        const r = rel ? rel + "/" + name : name;
        const full = path.join(root, r);
        let st;
        try { st = fs.statSync(full); } catch (e) { out.push(r + " <gone>"); return; }
        if (st.isDirectory()) { out.push(r + "/ dir"); walk(root, r); return; }
        let h = "<unreadable>";
        try { h = crypto.createHash("sha256").update(fs.readFileSync(full)).digest("hex"); } catch (e) {}
        out.push(r + " " + st.size + " " + h);
      });
    };
    for (const d of process.env.FP_DIRS.split(":::")) { out.push("== " + d); walk(d, ""); }
    process.stdout.write(out.join("\n"));' 2>/dev/null || echo "FP_FAILED"
}
FP_TARGETS="$CLAUDE_WORKFLOW_DIR:::$WORKFLOW_PLANS_DIR:::$(nrm "$CFG_FULL")"
FP_BEFORE="$(dir_fp "$FP_TARGETS")"
run_facts "$CFG_FULL" --session c2
OUT1="$OUT"; ERR1="$ERR"; RC1="$RC"
run_facts "$CFG_FULL" --session c2
FP_AFTER="$(dir_fp "$FP_TARGETS")"
check "C10a: identical stdout across two identical calls" "$OUT1" "$OUT"
check "C10b: identical stderr across two identical calls" "$ERR1" "$ERR"
check "C10c: identical exit status" "$RC1" "$RC"
check "C10d: the runs really produced facts (non-vacuity)" "$EXPECTED_KEYS" "$(strict_keys_of "$OUT1")"
check "C10e: state, plans and config dirs are byte-identical afterwards" "$FP_BEFORE" "$FP_AFTER"
# Control: without this, C10e would also pass a fingerprint that sees nothing at all.
printf 'x\n' > "$WORKFLOW_DIR/fp-control.txt"
if [ "$(dir_fp "$FP_TARGETS")" = "$FP_BEFORE" ]; then
  fail "C10f: control -- the fingerprint did not notice an added file"
else pass "C10f: control -- the fingerprint notices an added file"; fi
rm -f "$WORKFLOW_DIR/fp-control.txt"

echo ""
echo "=== Results ==="
echo "Total: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
