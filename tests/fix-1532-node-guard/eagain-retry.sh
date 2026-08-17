# Part of tests/fix-1532-node-guard-*.sh (sourced, not standalone).
# Tests: bin/get-config-var, bin/confirm-off, bin/resolve-session-id, bin/resolve-worktree-path, bin/is-github-dotcom-remote
# Tags: bin, polyglot-guard, node-misinvocation, eagain, retry, scope:issue-specific, pwsh-not-required, TL2

# E1-E5: the guard's EAGAIN RETRY branch. The write loop has two error branches --
# `err.code === "EAGAIN"` retries, anything else gives the diagnostic up -- and N6
# (early-closed pipe, EPIPE) only ever reaches the second one. These rows reach the first.

# HOW, AND WHY IT IS DETERMINISTIC. Not by manufacturing a real non-blocking fd 2 (a race,
# and unreachable on Windows), but by loading a preload with `node --require` that replaces
# fs.writeSync with one that throws a synthetic EAGAIN for the first N calls. The guard
# calls `require("fs").writeSync(2, msg)` -- resolved from the CJS module cache at call
# time -- so the preload's assignment to that same cached object is what the guard runs.
# The substitution is total and timing-free: same process, same code path, no scheduler.

# WHAT THE PRELOAD IS NOT ALLOWED TO DO: change the observable output when it injects
# nothing. E1 is that control -- preload loaded, zero failures injected, stderr required to
# be byte-identical to a run without the preload at all. Without E1 every row below could
# be green while the patch silently failed to attach.

echo "=== E: EAGAIN retry branch for $GUARD_TARGET ==="

E_TMP="$TESTTMP/eagain-retry"
E_PRELOAD="$E_TMP/eagain-preload.js"
E_TARGET="$(target_path "$GUARD_TARGET")"
mkdir -p "$E_TMP"

# The preload lives in TESTTMP, never in the repo tree (rules/test/fixture-isolation.md).
# The attempt counter is written through the CAPTURED ORIGINAL writeSync on a freshly
# opened fd: routing it through the patched export would recurse, and routing it through
# fs.writeFileSync would depend on whether that helper happens to call the export.
cat > "$E_PRELOAD" <<'EAGAIN_PRELOAD'
const fs = require("fs");
const orig = fs.writeSync;
const failFor = Number(process.env.FIX1532_EAGAIN_N || "0"); // <0 means "always"
const code = process.env.FIX1532_EAGAIN_CODE || "EAGAIN";
const counter = process.env.FIX1532_EAGAIN_COUNTER || "";
// SHORT-WRITE INJECTION (review round 3, codex C5). fs.writeSync is allowed by POSIX
// to return a count SMALLER than the buffer it was handed without raising an error --
// a legal short write, not a failure. The EAGAIN knobs above can only produce "all of
// it" or "an exception", so a truncated diagnostic would be invisible to every row.
// "one" returns 1 byte, "half" returns floor(len/2), "zero" returns 0 -- and in each
// case only that prefix is really written, so stderr shows exactly what the return
// value claimed.
const shortMode = process.env.FIX1532_SHORT_MODE || "";
let calls = 0;
function writeNumber(path, n) {
  if (!path) return;
  try {
    const fd = fs.openSync(path, "w");
    orig.call(fs, fd, String(n));
    fs.closeSync(fd);
  } catch (e) { /* the counter is diagnostics, never the thing under test */ }
}
function record(n) { writeNumber(counter, n); }
function recordBytes(n) { writeNumber(counter ? counter + ".bytes" : "", n); }
fs.writeSync = function (...args) {
  calls += 1;
  record(calls);
  if (failFor < 0 || calls <= failFor) {
    const err = new Error("synthetic " + code + " (attempt " + calls + ")");
    err.code = code;
    throw err;
  }
  if (shortMode) {
    const buf = typeof args[1] === "string"
      ? Buffer.from(args[1], "utf8")
      : Buffer.from(args[1]);
    let n;
    if (shortMode === "one") n = Math.min(1, buf.length);
    else if (shortMode === "half") n = Math.floor(buf.length / 2);
    else n = 0;
    if (n > 0) orig.call(fs, args[0], buf.subarray(0, n));
    recordBytes(n);
    return n;
  }
  return orig.apply(fs, args);
};
EAGAIN_PRELOAD

# E_RC / E_COUNT are the last invocation's exit status and observed writeSync attempt
# count. 30 s is a hard ceiling, not a hint: "the retry loop is bounded" is one of the
# claims, and a hang must be reported as a failure rather than as a stalled suite.
E_RC=""
E_COUNT=""
E_SHORT_BYTES=""
e_invoke() { # <prefix> <n> <code> [short-mode]
  local p="$1" n="$2" code="$3" short="${4:-}"
  rm -f "$p.count" "$p.count.bytes"
  FIX1532_EAGAIN_N="$n" FIX1532_EAGAIN_CODE="$code" FIX1532_EAGAIN_COUNTER="$p.count" \
    FIX1532_SHORT_MODE="$short" \
    run_with_timeout 30 node --require "$E_PRELOAD" "$E_TARGET" >"$p.out" 2>"$p.err"
  E_RC=$?
  if [ -f "$p.count" ]; then E_COUNT="$(cat "$p.count")"; else E_COUNT="0"; fi
  if [ -f "$p.count.bytes" ]; then E_SHORT_BYTES="$(cat "$p.count.bytes")"; else E_SHORT_BYTES=""; fi
}

# The unpatched reference. Captured through the same redirections as every patched run, so
# a byte comparison against it isolates the injection and nothing else.
E_REF="$E_TMP/reference"
e_reference() {
  run_with_timeout 30 node "$E_TARGET" >"$E_REF.out" 2>"$E_REF.err"
  local rc=$? bytes
  check "E0rc[$GUARD_TARGET]: the unpatched reference run exits $GUARD_EXIT_CODE" "$GUARD_EXIT_CODE" "$rc"
  bytes="$(wc -c < "$E_REF.err" | tr -d ' ')"
  if [ "$bytes" -gt 0 ]; then
    pass "E0[$GUARD_TARGET]: the unpatched reference wrote a $bytes-byte diagnostic, so a byte comparison against it means something"
    return 0
  fi
  fail "E0[$GUARD_TARGET]: the unpatched reference produced an EMPTY diagnostic -- every 'byte-identical to the reference' row below would pass on two empty files"
  return 1
}

# e_assert_shared — the claims that hold on EVERY row here, whatever the injection.
# A timeout is called out by name: rc 124 (GNU timeout) / 142 (the perl-alarm fallback in
# bin/run-with-timeout.sh) means the loop never terminated, which is a different failure
# from "terminated with the wrong code" and must not be reported as one.
e_assert_shared() { # <row> <prefix>
  local row="$1" p="$2" bytes
  case "$E_RC" in
    124 | 142)
      fail "$row[$GUARD_TARGET]: the process did NOT terminate within 30 s (rc $E_RC) -- the retry loop is unbounded"
      return 1 ;;
  esac
  pass "$row-term[$GUARD_TARGET]: the process terminated on its own within 30 s"
  check "$row-rc[$GUARD_TARGET]: exits $GUARD_EXIT_CODE whether or not the diagnostic was written" \
    "$GUARD_EXIT_CODE" "$E_RC"
  bytes="$(wc -c < "$p.out" | tr -d ' ')"
  check "$row-out[$GUARD_TARGET]: stdout is empty, so a \$( ) caller still cannot capture a value" \
    "0" "$bytes"
  return 0
}

# ---- E1: the control -- the preload attaches, and changes nothing on its own ----
e1_preload_is_transparent() {
  local p="$E_TMP/e1"
  e_invoke "$p" 0 EAGAIN
  e_assert_shared E1 "$p" || return 0
  if cmp -s "$p.err" "$E_REF.err"; then
    pass "E1err[$GUARD_TARGET]: with zero failures injected the diagnostic is byte-identical to the unpatched run"
  else
    fail "E1err[$GUARD_TARGET]: the preload changed the diagnostic even with nothing injected -- every row below would be measuring the preload, not the guard"
  fi
  # The load-bearing half of this control: the guard's write really went through the
  # replacement. Without it, a preload that silently failed to attach would make E1err
  # pass (identical output) and E2/E3 pass for the wrong reason (nothing intercepted).
  check "E1hook[$GUARD_TARGET]: the patched fs.writeSync observed exactly one write attempt (the preload IS attached)" \
    "1" "$E_COUNT"
}

# ---- E2: transient EAGAIN -- the retry branch, then a successful write ----------
# Two depths, because a loop that retried exactly once would satisfy N=1 and fail N=3.
e2_transient() { # <row> <n>
  # Separate `local` statements on purpose: bash expands every word of a `local` line
  # before the builtin runs, so a later assignment cannot read an earlier one on the
  # same line -- under `set -u` that is an unbound-variable abort, not a stale value.
  local row="$1" n="$2"
  local p="$E_TMP/e2-$n"
  e_invoke "$p" "$n" EAGAIN
  e_assert_shared "$row" "$p" || return 0
  if cmp -s "$p.err" "$E_REF.err"; then
    pass "$row-err[$GUARD_TARGET]: after $n EAGAIN failure(s) the diagnostic is written IN FULL and byte-identical to the unpatched run"
  else
    fail "$row-err[$GUARD_TARGET]: after $n EAGAIN failure(s) the diagnostic is missing or truncated -- the retry branch did not recover the write"
  fi
  check "$row-tries[$GUARD_TARGET]: the guard made exactly $((n + 1)) write attempts ($n rejected, then one that succeeded)" \
    "$((n + 1))" "$E_COUNT"
}

# ---- E3: persistent EAGAIN -- bounded give-up, exit code survives ---------------
# The contract N6 states for EPIPE, reached down the other branch: the message is
# best-effort, the exit code is not. 100 is the loop's literal bound in the envelope, and
# pinning the exact number is what makes "bounded" an assertion rather than a hope --
# an unbounded retry would time out above, and a re-tuned bound must be re-declared here.
e3_persistent() {
  local p="$E_TMP/e3" bytes
  e_invoke "$p" -1 EAGAIN
  e_assert_shared E3 "$p" || return 0
  bytes="$(wc -c < "$p.err" | tr -d ' ')"
  check "E3err[$GUARD_TARGET]: stderr is empty when every write attempt fails (the diagnostic is best-effort)" \
    "0" "$bytes"
  check "E3tries[$GUARD_TARGET]: the retry loop stopped after its declared bound of 100 attempts" \
    "100" "$E_COUNT"
}

# ---- E4: a NON-EAGAIN error -- give up at once, no retry -----------------------
# PIN OF OBSERVED BEHAVIOUR. The envelope retries only on EAGAIN and breaks on anything
# else, so a synthetic EPERM must cost exactly one attempt. This row is the reject side of
# E3: without it, a guard that retried on every error code would look identical to a
# correct one in every other row here.
e4_non_eagain() {
  local p="$E_TMP/e4" bytes
  e_invoke "$p" -1 EPERM
  e_assert_shared E4 "$p" || return 0
  check "E4tries[$GUARD_TARGET]: a non-EAGAIN error is NOT retried -- exactly one write attempt" \
    "1" "$E_COUNT"
  bytes="$(wc -c < "$p.err" | tr -d ' ')"
  check "E4err[$GUARD_TARGET]: stderr is empty after a non-EAGAIN write failure" "0" "$bytes"
}

# ---- E5: LEGAL SHORT WRITES -- fs.writeSync returns fewer bytes than asked ------
# PIN OF MEASURED BEHAVIOUR, NOT AN ASPIRATION (review round 3, codex C5).

# WHY THIS IS A DISTINCT FAILURE MODE. E2/E3/E4 all go through the try/catch: an
# injected error either recovers or gives up. A short write raises NOTHING. POSIX lets
# write(2) -- and therefore fs.writeSync -- consume only part of the buffer and report
# that smaller count, and a correct writer must loop on the remainder. The envelope's
# loop discards the return value and runs `break` unconditionally on the non-throwing
# path, so the guard does NOT resume a partial write: it writes once and stops.

# THE MEASURED CONTRACT PINNED BELOW IS THEREFORE TRUNCATION. On a short write the
# diagnostic is cut to exactly the bytes the call reported, the loop still terminates,
# and process.exitCode stays 70. The machine-readable half of the contract survives;
# the human-readable half can arrive incomplete. Repairing that would mean editing the
# envelope inside the five bin/ scripts, which this suite may not do -- these rows exist
# so a future envelope that ADDS a resume loop surfaces here as a deliberate re-pin.

# Every row runs inside run_with_timeout: "return 0 bytes forever" is the shape that
# would hang a naive resume loop, and a hang must be a named failure, not a stall.
e5_short_write() { # <row> <mode> <expected-bytes>
  local row="$1" mode="$2" want_bytes="$3"
  local p="$E_TMP/e5-$mode"
  local bytes
  e_invoke "$p" 0 EAGAIN "$mode"
  e_assert_shared "$row" "$p" || return 0
  # Non-vacuity: the patch reports what it returned. An empty value means the short-write
  # branch was never entered, and every row here would be re-measuring E1.
  check "$row-hook[$GUARD_TARGET]: the patched fs.writeSync actually returned a SHORT count of $want_bytes byte(s)" \
    "$want_bytes" "$E_SHORT_BYTES"
  check "$row-tries[$GUARD_TARGET]: a short return is not an error, so exactly one write attempt is made (the remainder is NOT resumed)" \
    "1" "$E_COUNT"
  bytes="$(wc -c < "$p.err" | tr -d ' ')"
  check "$row-bytes[$GUARD_TARGET]: stderr holds exactly the $want_bytes byte(s) the short write consumed -- TRUNCATED, pinned as today's contract" \
    "$want_bytes" "$bytes"
  # Truncated, but truncated from the RIGHT message: a prefix of the reference, never
  # some other text of the same length.
  if [ "$want_bytes" -eq 0 ]; then
    pass "$row-prefix[$GUARD_TARGET]: a zero-byte short write leaves stderr empty (nothing to compare)"
  elif head -c "$want_bytes" "$E_REF.err" | cmp -s - "$p.err"; then
    pass "$row-prefix[$GUARD_TARGET]: what survived is the leading $want_bytes byte(s) of the full diagnostic"
  else
    fail "$row-prefix[$GUARD_TARGET]: stderr is $want_bytes byte(s) but is NOT a prefix of the unpatched diagnostic"
  fi
}

# 1 byte per call, half the buffer, and 0 bytes repeatedly -- the three shapes a legal
# short write takes.
e5_main() {
  local ref_bytes
  ref_bytes="$(wc -c < "$E_REF.err" | tr -d ' ')"
  e5_short_write E5a one 1
  e5_short_write E5b half "$((ref_bytes / 2))"
  e5_short_write E5c zero 0
}

e_main() {
  require_node "E1-E5[$GUARD_TARGET]" || return 0
  e_reference || return 0
  e1_preload_is_transparent
  e2_transient E2a 1
  e2_transient E2b 3
  e3_persistent
  e4_non_eagain
  e5_main
}

e_main
