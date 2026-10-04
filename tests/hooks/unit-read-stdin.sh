#!/usr/bin/env bash
# tests/hooks/unit-read-stdin.sh
# Tests: hooks/lib/read-stdin.js, hooks/lib/pretool-lang-gate.js
# Tags: TL1, TL2, hook, stdin, scope:common, lint, static-check, read-stdin, bin, ssot, pwsh-not-required
# Shared EOF-safe hook stdin reader (#2479): real fd 0 (file redirect + pipe) at
# sizes around the 4096 / 65536 buffer edges, injected readSyncImpl for the
# EAGAIN / EINTR / EOF / alias paths, the fail-open diagnostic format, the
# unchanged readStdinJson contract of pretool-lang-gate after it delegates, and
# the #1810 static lint that no hook / bin file reads stdin privately.

set -uo pipefail
AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
. "$AGENTS_DIR/tests/lib/harness.sh"

command -v node >/dev/null 2>&1 || { echo "SKIP: node not found"; exit 77; }

TMPD="$(make_tmp)"
trap 'rm -rf "$TMPD"' EXIT
harness_isolate "$TMPD"
unset CLAUDE_CODE_SESSION_ID 2>/dev/null || true

AGENTS_WIN="$(np "$AGENTS_DIR")"
TMPW="$(np "$TMPD")"
READ_STDIN_JS="$AGENTS_WIN/hooks/lib/read-stdin.js"
GATE_JS="$AGENTS_WIN/hooks/lib/pretool-lang-gate.js"

# relay <group> <runner-output> — turn runner PASS:/FAIL: lines into verdicts.
relay() {
    local _seen=0 _ln
    while IFS= read -r _ln; do
        case "$_ln" in
            MODULE_MISSING:*) fail "$1/module-exists" "${_ln#MODULE_MISSING:}"; _seen=1 ;;
            PASS:*) pass "$1/${_ln#PASS:}"; _seen=1 ;;
            FAIL:*) fail "$1/${_ln#FAIL:}"; _seen=1 ;;
        esac
    done <<< "$2"
    [ "$_seen" -eq 1 ] || fail "$1/runner-produced-verdicts" "output=$2"
}

check() { # check <name> <want> <got>
    if [ "$3" = "$2" ]; then pass "$1"; else fail "$1" "want=$2 got=$3"; fi
}

# gen-input.js <size> <out>: ASCII filler with multibyte chars straddling every
# 4096 / 65536-multiple boundary; prints the sha256 of the bytes written.
cat > "$TMPD/gen-input.js" << 'JSEOF'
"use strict";
const fs = require("fs"), crypto = require("crypto");
const size = Number(process.argv[2]);
const b = Buffer.alloc(size);
for (let i = 0; i < size; i++) b[i] = (i % 64 === 63) ? 0x0a : 0x61 + (i % 26);
const A3 = Buffer.from("あ", "utf8"), E2 = Buffer.from("é", "utf8");
function straddle(B) {
  if (B + 2 <= size) A3.copy(b, B - 1);
  else if (B + 1 <= size) E2.copy(b, B - 1);
}
if (size >= 40) E2.copy(b, 20);
straddle(4096);
for (let B = 65536; B < size; B += 65536) straddle(B);
fs.writeFileSync(process.argv[3], b);
process.stdout.write(crypto.createHash("sha256").update(b).digest("hex"));
JSEOF

# stdin-runner.js <read-stdin.js> <text|hook|hookdiag>: exercises fd 0.
cat > "$TMPD/stdin-runner.js" << 'JSEOF'
"use strict";
const crypto = require("crypto");
let m;
try { m = require(process.argv[2]); }
catch (e) { process.stdout.write("MODULE_MISSING:" + String(e.message).split("\n")[0] + "\n"); process.exit(0); }
const mode = process.argv[3];
if (mode === "text") {
  const r = m.readStdinText();
  if (r.kind !== "ok") { process.stdout.write("KIND:" + r.kind + " CODE:" + (r.error && r.error.code)); process.exit(0); }
  const buf = Buffer.from(r.text, "utf8");
  process.stdout.write("KIND:ok SHA:" + crypto.createHash("sha256").update(buf).digest("hex") + " BYTES:" + buf.length);
} else if (mode === "hook") {
  const r = m.readHookInput();
  process.stdout.write(JSON.stringify({ kind: r.kind, text: r.text, input: r.input,
    err: r.error ? r.error.name : null }));
} else if (mode === "hookdiag") {
  const r = m.readHookInput();
  process.stdout.write(String(m.readFailOpenDiagnostic("hookx", r, "eff")));
}
JSEOF

# unit-runner.js <read-stdin.js> <group> <tmpdir>: in-process cases.
cat > "$TMPD/unit-runner.js" << 'JSEOF'
"use strict";
const fs = require("fs"), path = require("path");
let m;
try { m = require(process.argv[2]); }
catch (e) { process.stdout.write("MODULE_MISSING:" + String(e.message).split("\n")[0] + "\n"); process.exit(0); }
const group = process.argv[3], tmp = process.argv[4];
function ok(name, cond, detail) {
  process.stdout.write((cond ? "PASS:" : "FAIL:") + name + (!cond && detail ? " -- " + detail : "") + "\n");
}
function errOf(code, msg) { const e = new Error(msg || "mock " + code); e.code = code; return e; }
const show = (r) => JSON.stringify({ kind: r && r.kind, text: r && r.text, code: r && r.error && r.error.code });
// steps: {t: code} throws, {d: Buffer|string} writes at buf[off], {z: 1} returns 0.
function scripted(steps) {
  const st = { calls: 0, fds: [], lens: [] };
  const impl = (fd, buf, off, len) => {
    st.calls++; st.fds.push(fd); st.lens.push(len);
    const s = steps[st.calls - 1];
    if (!s || s.z) return 0;
    if (s.t) throw errOf(s.t);
    const b = Buffer.isBuffer(s.d) ? s.d : Buffer.from(s.d, "utf8");
    b.copy(buf, off);
    return b.length;
  };
  return { impl, st };
}
const isOk = (r, text) => r && r.kind === "ok" && r.text === text;
const isErr = (r, code) => r && r.kind === "read-error" && r.error && r.error.code === code;

if (group === "exports") {
  ["readAll", "readStdinText", "readHookInput", "readFailureReason", "readFailOpenDiagnostic"]
    .forEach((n) => ok("export-" + n, typeof m[n] === "function", "typeof=" + typeof m[n]));
}

if (group === "fd") {
  const wo = path.join(tmp, "wo-unit.txt");
  const fd = fs.openSync(wo, "w");
  let r; try { r = m.readAll(fd); } finally { fs.closeSync(fd); }
  ok("write-only-fd-read-error-EBADF", isErr(r, "EBADF"), show(r));
  const rf = path.join(tmp, "ro-unit.txt");
  fs.writeFileSync(rf, "hello あ\n");
  const fd2 = fs.openSync(rf, "r");
  let r2; try { r2 = m.readAll(fd2); } finally { fs.closeSync(fd2); }
  ok("readable-fd-ok", isOk(r2, "hello あ\n"), show(r2));
}

if (group === "inject") {
  let s = scripted([{ t: "EAGAIN" }, { d: "abc" }, { t: "EAGAIN" }, { d: "def" }, { t: "EOF" }]);
  let r = m.readAll(42, s.impl, {});
  ok("eagain-data-eof-ok", isOk(r, "abcdef"), show(r));
  ok("fd-passed-through", s.st.fds.every((f) => f === 42), "fds=" + s.st.fds);
  ok("buffer-at-least-64KiB", s.st.lens.length > 0 && s.st.lens.every((l) => l >= 65536), "lens=" + s.st.lens);

  const t0 = process.hrtime.bigint();
  let calls = 0;
  const stuck = () => {
    calls++;
    if (Number(process.hrtime.bigint() - t0) / 1e6 > 5000) throw errOf("GUARD-NO-BUDGET");
    throw errOf("EAGAIN");
  };
  r = m.readAll(0, stuck, { eagainBudgetMs: 50 });
  const ms = Number(process.hrtime.bigint() - t0) / 1e6;
  ok("persistent-eagain-read-error-EAGAIN", isErr(r, "EAGAIN"), show(r));
  ok("persistent-eagain-honours-50ms-budget", ms >= 50 && ms < 2000, "elapsed=" + ms.toFixed(1) + "ms calls=" + calls);

  s = scripted([{ t: "EINTR" }, { d: "xyz" }, { z: 1 }]);
  r = m.readAll(0, s.impl, {});
  ok("eintr-retried-ok", isOk(r, "xyz") && s.st.calls === 3, show(r) + " calls=" + s.st.calls);

  s = scripted([{ t: "EOF" }]);
  r = m.readAll(0, s.impl, {});
  ok("eof-only-ok-empty", isOk(r, ""), show(r));

  s = scripted([{ d: "abc" }, { t: "EIO" }]);
  r = m.readAll(0, s.impl, {});
  ok("eio-read-error-EIO", isErr(r, "EIO"), show(r));

  s = scripted([{ d: "a" }, { z: 1 }, { d: "b" }]);
  r = m.readAll(0, s.impl, {});
  ok("zero-read-terminates", isOk(r, "a") && s.st.calls === 2, show(r) + " calls=" + s.st.calls);

  s = scripted([{ d: "AAA" }, { d: "BBB" }, { d: "CCC" }, { z: 1 }]);
  r = m.readAll(0, s.impl, {});
  ok("reused-buffer-chunks-copied-in-order", isOk(r, "AAABBBCCC"), show(r));

  const a = Buffer.from("あ", "utf8");
  s = scripted([{ d: Buffer.concat([Buffer.from("x"), a.subarray(0, 2)]) },
    { d: Buffer.concat([a.subarray(2), Buffer.from("y")]) }, { z: 1 }]);
  r = m.readAll(0, s.impl, {});
  ok("multibyte-split-across-reads", isOk(r, "xあy"), show(r));

  // The budget is consecutive unreadable time: 5 stalls of ~40 ms each exceed a
  // 100 ms total but never 100 ms in a row, so a successful read resets it.
  let last = process.hrtime.bigint(), rounds = 0;
  const bursty = (fd, buf, off) => {
    if (rounds >= 5) return 0;
    if (Number(process.hrtime.bigint() - last) / 1e6 < 40) throw errOf("EAGAIN");
    rounds++; last = process.hrtime.bigint();
    buf[off] = 0x61; return 1;
  };
  const tb = process.hrtime.bigint();
  r = m.readAll(0, bursty, { eagainBudgetMs: 100 });
  const tot = Number(process.hrtime.bigint() - tb) / 1e6;
  ok("eagain-budget-resets-after-successful-read", isOk(r, "aaaaa") && tot > 100, show(r) + " total=" + tot.toFixed(1) + "ms");
}

if (group === "defaults") {
  const s = scripted([{ d: "abc" }, { t: "EAGAIN" }, { d: "def" }, { z: 1 }]);
  const r = m.readAll(0, s.impl);
  ok("opts-omitted-ok", isOk(r, "abcdef"), show(r));
  const t0 = process.hrtime.bigint();
  let calls = 0;
  const stuck = () => {
    calls++;
    if (Number(process.hrtime.bigint() - t0) / 1e6 > 1500) throw errOf("GUARD-BUDGET-ZERO-IGNORED");
    throw errOf("EAGAIN");
  };
  const r0 = m.readAll(0, stuck, { eagainBudgetMs: 0 });
  const ms = Number(process.hrtime.bigint() - t0) / 1e6;
  ok("budget-zero-read-error-EAGAIN", isErr(r0, "EAGAIN"), show(r0) + " calls=" + calls);
  ok("budget-zero-not-replaced-by-default", ms < 1000, "elapsed=" + ms.toFixed(1) + "ms calls=" + calls);
}

if (group === "diag") {
  const D = m.readFailOpenDiagnostic, R = m.readFailureReason;
  const ebadf = errOf("EBADF", "SECRET-TOKEN-xyz in message");
  ok("read-error-exact", D("hookx", { kind: "read-error", error: ebadf }, "eff") ===
    "[hookx] stdin read-error (EBADF): eff (fail-open)", D("hookx", { kind: "read-error", error: ebadf }, "eff"));
  ok("read-error-default-effect", D("hookx", { kind: "read-error", error: ebadf }) ===
    "[hookx] stdin read-error (EBADF): hook skipped (fail-open)", D("hookx", { kind: "read-error", error: ebadf }));
  const noCode = D("hookx", { kind: "read-error", error: new TypeError("boom") }, "eff");
  ok("read-error-code-falls-back-to-name", noCode === "[hookx] stdin read-error (TypeError): eff (fail-open)", noCode);
  const unk = D("hookx", { kind: "read-error", error: {} }, "eff");
  ok("read-error-code-falls-back-to-unknown", unk === "[hookx] stdin read-error (unknown): eff (fail-open)", unk);
  const mb = '{"a":"あいう';
  let pe; try { JSON.parse(mb); } catch (e) { pe = e; }
  const ji = D("hookx", { kind: "json-invalid", text: mb, error: pe }, "eff");
  ok("json-invalid-utf8-byte-count", ji === "[hookx] stdin json-invalid (15 bytes, SyntaxError): eff (fail-open)", ji);
  const em = D("hookx", { kind: "json-invalid", text: "", error: new Error("empty stdin") }, "eff");
  ok("empty-exact", em === "[hookx] stdin json-invalid (0 bytes, empty): eff (fail-open)", em);
  ok("ok-returns-null", D("hookx", { kind: "ok", input: {}, text: "{}" }, "eff") === null);
  const secret = '{"tool":"SECRET-TOKEN-xyz';
  let se; try { JSON.parse(secret); } catch (e) { se = e; }
  const sd = D("hookx", { kind: "json-invalid", text: secret, error: se }, "eff");
  ok("json-invalid-no-payload-no-message", !sd.includes("SECRET-TOKEN") && !sd.includes(se.message), sd);
  const rd = D("hookx", { kind: "read-error", error: ebadf }, "eff");
  ok("read-error-no-error-message", !rd.includes("SECRET-TOKEN"), rd);
  const fr = R("hookx", ebadf);
  ok("failure-reason-exact", fr === "[hookx] stdin read-error (EBADF): hook input unreadable; blocking (fail-close)", fr);
  ok("failure-reason-no-error-message", typeof fr === "string" && !fr.includes("SECRET-TOKEN"), fr);
}
JSEOF

# gate-runner.js <pretool-lang-gate.js> [plain|stub-eagain|stub-ok]: prints
# THROW:<code> | NULL | JSON:<value>. stub-* replaces the shared reader's
# readStdinText in the require cache to prove readStdinJson delegates to it.
cat > "$TMPD/gate-runner.js" << 'JSEOF'
"use strict";
const path = require("path");
const gate = process.argv[2], mode = process.argv[3] || "plain";
const out = (s) => process.stdout.write(s);
if (mode !== "plain") {
  let lib;
  try { lib = require.resolve(path.join(path.dirname(gate), "read-stdin.js")); }
  catch (e) { out("STUB_UNAVAILABLE:" + e.code); process.exit(0); }
  const real = require(lib);
  const readStdinText = () => {
    if (mode === "stub-ok") return { kind: "ok", text: '{"stub":true}' };
    const e = new Error("stalled"); e.code = "EAGAIN";
    return { kind: "read-error", error: e };
  };
  require.cache[lib].exports = Object.assign({}, real, { readStdinText });
}
let g;
try { g = require(gate); } catch (e) { out("GATE_LOAD_ERROR:" + e.code); process.exit(0); }
try {
  const v = g.readStdinJson();
  out(v === null ? "NULL" : "JSON:" + JSON.stringify(v));
} catch (e) { out("THROW:" + ((e && (e.code || e.name)) || "unknown")); }
JSEOF

# ============================================================================
case_begin "readstdintext-size-matrix" "hooks/lib/read-stdin.js"
# ============================================================================
for _sz in 0 100 4097 5000 65537 70000 1048576; do
    _f="$TMPD/in-$_sz.bin"
    _sha=$(run_with_timeout 30 node "$TMPD/gen-input.js" "$_sz" "$TMPW/in-$_sz.bin" 2>/dev/null || echo "gen-failed")
    _want="KIND:ok SHA:$_sha BYTES:$_sz"
    _got=$(run_with_timeout 60 node "$TMPD/stdin-runner.js" "$READ_STDIN_JS" text < "$_f" 2>"$TMPD/err-f" || echo "ERR:crashed")
    check "size-$_sz/file-redirect" "$_want" "$_got"
    check "size-$_sz/file-redirect-stderr-empty" "" "$(cat "$TMPD/err-f")"
    # shellcheck disable=SC2002  # the pipe is the stdin kind under test
    _got=$(cat "$_f" | run_with_timeout 60 node "$TMPD/stdin-runner.js" "$READ_STDIN_JS" text 2>"$TMPD/err-p" || echo "ERR:crashed")
    check "size-$_sz/pipe" "$_want" "$_got"
    check "size-$_sz/pipe-stderr-empty" "" "$(cat "$TMPD/err-p")"
done
case_end

# ============================================================================
case_begin "readhookinput-kinds-from-fd0" "hooks/lib/read-stdin.js"
# ============================================================================
_hk() { run_with_timeout 30 node "$TMPD/stdin-runner.js" "$READ_STDIN_JS" hook 2>"$TMPD/err-h" || echo "ERR:crashed"; }
check "hook-input/empty" '{"kind":"json-invalid","text":"","err":"Error"}' "$(_hk < /dev/null)"
check "hook-input/whitespace-only" '{"kind":"json-invalid","text":"","err":"Error"}' "$(printf '  \n\t \n' | _hk)"
check "hook-input/broken-json-keeps-text" '{"kind":"json-invalid","text":"{\"a\":","err":"SyntaxError"}' "$(printf '{"a":' | _hk)"
check "hook-input/valid-json" '{"kind":"ok","text":"{\"x\":[1,\"あ\"]}","input":{"x":[1,"あ"]},"err":null}' "$(printf '{"x":[1,"あ"]}' | _hk)"
check "hook-input/helper-writes-no-stderr" "" "$(cat "$TMPD/err-h")"
_dg() { run_with_timeout 30 node "$TMPD/stdin-runner.js" "$READ_STDIN_JS" hookdiag 2>/dev/null || echo "ERR:crashed"; }
_sec='{"tool_name":"Bash","x":"SECRET-TOKEN-xyz'
_dgo="$(printf '%s' "$_sec" | _dg)"
check "hook-input/diagnostic-from-real-result" "[hookx] stdin json-invalid (${#_sec} bytes, SyntaxError): eff (fail-open)" "$_dgo"
case "$_dgo" in *SECRET-TOKEN*) fail "hook-input/diagnostic-hides-payload" "$_dgo" ;; *) pass "hook-input/diagnostic-hides-payload" ;; esac
check "hook-input/diagnostic-empty-from-real-result" "[hookx] stdin json-invalid (0 bytes, empty): eff (fail-open)" "$(printf ' \n' | _dg)"
case_end

# ============================================================================
case_begin "readall-fd-and-injected-reads" "hooks/lib/read-stdin.js"
# ============================================================================
for _grp in exports fd inject; do
    relay "$_grp" "$(run_with_timeout 60 node "$TMPD/unit-runner.js" "$READ_STDIN_JS" "$_grp" "$TMPW" 2>&1 || echo "FAIL:runner-crashed")"
done
case_end

# ============================================================================
case_begin "fail-open-diagnostic-format" "hooks/lib/read-stdin.js"
# ============================================================================
relay "diag" "$(run_with_timeout 60 node "$TMPD/unit-runner.js" "$READ_STDIN_JS" diag "$TMPW" 2>&1 || echo "FAIL:runner-crashed")"
case_end

# ============================================================================
case_begin "readstdinjson-contract" "hooks/lib/pretool-lang-gate.js"
# ============================================================================
_gr() { run_with_timeout 30 node "$TMPD/gate-runner.js" "$GATE_JS" "$@" 2>/dev/null || echo "ERR:crashed"; }
check "RJ1/read-error-throws" "THROW:EBADF" "$(_gr plain 0>"$TMPD/wo.txt")"
check "RJ2/empty-returns-null" "NULL" "$(_gr plain < /dev/null)"
check "RJ3/broken-json-returns-null" "NULL" "$(printf '{"a":' | _gr plain)"
check "RJ4/valid-json-returned" 'JSON:{"tool_name":"Write"}' "$(printf '{"tool_name":"Write"}' | _gr plain)"
check "RJ5/shared-reader-error-is-thrown" "THROW:EAGAIN" "$(printf '{"tool_name":"Write"}' | _gr stub-eagain)"
check "RJ6/text-comes-from-shared-reader" 'JSON:{"stub":true}' "$(printf '{"tool_name":"Write"}' | _gr stub-ok)"
case_end

# ============================================================================
case_begin "readhookinput-fd0-read-error-diagnostic" "hooks/lib/read-stdin.js"
# ============================================================================
check "fd0-read-error/diagnostic-exact" "[hookx] stdin read-error (EBADF): eff (fail-open)" "$(_dg 0>"$TMPD/wo-fd0.txt")"
case_end

# ============================================================================
case_begin "readall-default-and-zero-budget" "hooks/lib/read-stdin.js"
# ============================================================================
relay "defaults" "$(run_with_timeout 60 node "$TMPD/unit-runner.js" "$READ_STDIN_JS" defaults "$TMPW" 2>&1 || echo "FAIL:runner-crashed")"
case_end

# --- #1810 S9 static lint: every hooks/**/*.js and every bin file (any
# extension) reads stdin via hooks/lib/read-stdin, never a private fd-0 read.
# Comments are scanned too. Detector + fixtures: tests/hooks/lint-shared-stdin-reader/.
LINT_DIR="$AGENTS_WIN/tests/hooks/lint-shared-stdin-reader"
LINT_SCAN="$LINT_DIR/scan.js"
LINT_FIX="$LINT_DIR/fixtures"
# Out of scope for #1810 (outline "Out of scope"): bin stdin readers that are
# not hook-input readers. Reason for every row: out-of-scope stdin read.
BIN_EXCLUDED=(
    bin/is-docs-only
    bin/lib/cli-exec-guard.sh
    bin/lib/last-json-object.js
    bin/lib/prompt-extraction/cli.js
    bin/sweep-branches/summary.sh
    bin/sweep-worktrees/summary.sh
    bin/sweep-plans.sh
    bin/sweep-issues.sh
    bin/worktree-copy-include.js
    bin/sweep-issues/scan-stale-paths.js
    bin/sweep-issues/meta-parent-scan.sh
    bin/sweep-issues/list-band.sh
)
# S8 fallback only: "<path>|<reason>" per row. Empty by design.
HOOKS_EXCEPTED=()

# ============================================================================
case_begin "lint-detector-self-check" "hooks/lib/read-stdin.js"
# ============================================================================
# The detector really detects; otherwise a green tree scan is vacuous.
for _lf in violation-extensionless violation-comment-only.js violation-dev-stdin.js violation-readsync-fd0.js violation-readfilesync-stdin-fd.js; do
    check "lint-self-check/detects-$_lf" "$LINT_FIX/$_lf" "$(run_with_timeout 30 node "$LINT_SCAN" files "$LINT_FIX/$_lf" 2>&1)"
done
check "lint-self-check/file-fd-read-not-flagged" "" "$(run_with_timeout 30 node "$LINT_SCAN" files "$LINT_FIX/clean-file-fd.js" 2>&1)"
check "lint-self-check/near-miss-fd-not-flagged" "" "$(run_with_timeout 30 node "$LINT_SCAN" files "$LINT_FIX/clean-near-miss-fd.js" 2>&1)"
case_end

# ============================================================================
case_begin "lint-no-private-stdin-reader" "hooks/lib/read-stdin.js"
# ============================================================================
_lint_hits="$(run_with_timeout 60 node "$LINT_SCAN" tree "$AGENTS_WIN" 2>"$TMPD/scan-err.txt")"
_lint_rc=$?
[ "$_lint_rc" -eq 0 ] || fail "lint-tree-scan/runs" "rc=$_lint_rc err=$(cat "$TMPD/scan-err.txt")"
_lint_excused() {
    local p="$1" row
    for row in "${BIN_EXCLUDED[@]}"; do [[ "$p" == "$row" ]] && return 0; done
    for row in "${HOOKS_EXCEPTED[@]+"${HOOKS_EXCEPTED[@]}"}"; do [[ "$p" == "${row%%|*}" ]] && return 0; done
    return 1
}
_lint_viol=0
while IFS= read -r _lp; do
    [[ -z "$_lp" ]] && continue
    _lint_excused "$_lp" && continue
    _lint_viol=$((_lint_viol + 1))
    fail "no-private-stdin-reader/$_lp" "reads stdin outside hooks/lib/read-stdin"
done <<< "$_lint_hits"
if [[ "$_lint_viol" -eq 0 && "$_lint_rc" -eq 0 ]]; then
    pass "no-private-stdin-reader/all-in-scope-files"
fi
# The shared reader itself is the one sanctioned site; it must stay out of scope.
if grep -qx "hooks/lib/read-stdin.js" <<< "$_lint_hits"; then
    fail "lint-shared-reader-excluded-from-scope" "hooks/lib/read-stdin.js was reported"
else
    pass "lint-shared-reader-excluded-from-scope"
fi
case_end

# ============================================================================
case_begin "lint-bin-exclusion-rows-live" "hooks/lib/read-stdin.js"
# ============================================================================
# A row that stops matching (or whose file is gone) is a stale exception -> red.
for _row in "${BIN_EXCLUDED[@]}"; do
    if [[ ! -f "$AGENTS_DIR/$_row" ]]; then
        fail "bin-exclusion-live/$_row" "file no longer exists; drop the row"
    elif grep -qx "$_row" <<< "$_lint_hits"; then
        pass "bin-exclusion-live/$_row"
    else
        fail "bin-exclusion-live/$_row" "no longer matches a forbidden pattern; drop the row"
    fi
done
case_end

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
