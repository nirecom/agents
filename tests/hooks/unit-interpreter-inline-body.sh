#!/usr/bin/env bash
# tests/hooks/unit-interpreter-inline-body.sh
# Tests: hooks/lib/interpreter-inline-body.js, hooks/lib/bash-write-patterns/classify.js
# Tags: TL1, hook, classifier, system-ops, interpreter-inline-body, table-driven, security, scope:common, pwsh-not-required
# Inline-body extraction shared by enforce-system-ops (#1861): the isInlineBodyFlag
# truth table, every-argv-position scan, eval recursion, the depth cap, logical
# line splitting only outside quotes, line-continuation joining, closed-heredoc
# body removal, parse failures surfaced as unparsedLines, option skipping after
# -c, and the body count / byte caps that raise `overflow`.

set -uo pipefail
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

command -v node >/dev/null 2>&1 || { echo "SKIP: node not found"; exit 77; }

TMPD="$(make_tmp)"
trap 'rm -rf "$TMPD"' EXIT
harness_isolate "$TMPD"
unset CLAUDE_CODE_SESSION_ID SYSTEM_OPS_APPROVED 2>/dev/null || true
cd "$TMPD" || exit 1

LIB_JS="$(np "$SCRIPT_CHECKOUT_ROOT")/hooks/lib/interpreter-inline-body.js"

relay() { # relay <group> <runner-output>
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

cat > "$TMPD/runner.js" << 'JSEOF'
"use strict";
let m;
try { m = require(process.argv[2]); }
catch (e) { process.stdout.write("MODULE_MISSING:" + String(e.message).split("\n")[0] + "\n"); process.exit(0); }
const group = process.argv[3];
const out = (name, cond, detail) =>
  process.stdout.write((cond ? "PASS:" : "FAIL:") + name + (cond ? "" : " -- " + detail) + "\n");
const run = (text) => {
  try { return m.inlineBodiesOf(text); } catch (e) { return { threw: String(e && e.message) }; }
};
const shape = (r) => r && Array.isArray(r.bodies) && Array.isArray(r.unparsedLines) &&
  r.bodies.every((b) => typeof b === "string") && r.unparsedLines.every((l) => typeof l === "string");
const show = (r) => JSON.stringify(r);

if (group === "flag") {
  if (typeof m.isInlineBodyFlag !== "function") { out("export-isInlineBodyFlag", false, typeof m.isInlineBodyFlag); process.exit(0); }
  [
    ["posix-c", "-c", "bash", true], ["posix-lc", "-lc", "bash", true], ["posix-xc", "-xc", "bash", true],
    ["posix-ic-sh", "-ic", "sh", true], ["posix-c-zsh", "-c", "zsh", true], ["posix-c-fish", "-c", "fish", true],
    ["posix-l", "-l", "bash", false], ["posix-e", "-e", "bash", false],
    ["posix-long-login", "--login", "bash", false], ["posix-long-rcfile-has-c", "--rcfile", "bash", false],
    ["posix-no-dash", "c", "bash", false], ["posix-command-word", "-Command", "bash", false],
    ["pwsh-c", "-c", "pwsh", true], ["pwsh-command", "-Command", "pwsh", true],
    ["pwsh-command-lower", "-command", "pwsh", true], ["powershell-command-upper", "-COMMAND", "powershell", true],
    ["pwsh-noprofile", "-NoProfile", "pwsh", false], ["pwsh-lc-not-pwsh-flag", "-lc", "pwsh", false],
    ["pwsh-encodedcommand", "-EncodedCommand", "pwsh", false],
    ["fish-long-command", "--command", "fish", true], ["fish-long-command-eq", "--command=x", "fish", true],
    ["bash-long-command-not-flag", "--command", "bash", false], ["ksh-c", "-c", "ksh", true],
  ].forEach(([name, arg, base, want]) => {
    let got; try { got = m.isInlineBodyFlag(arg, base); } catch (e) { got = "threw:" + e.message; }
    out(name, got === want, "isInlineBodyFlag(" + arg + "," + base + ")=" + got);
  });
}

// [name, text, mustInclude[], mustExclude[], unparsedEmpty]
const BODY_CASES = [
  ["bash-c-sq", "bash -c 'x'", ["x"], [], true],
  ["sudo-u-root-every-position", "sudo -u root bash -c 'x'", ["x"], [], true],
  ["path-exe-uppercase-powershell", "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe -Command x", ["x"], [], true],
  ["pwsh-unquoted-rest-joined", "PowerShell -COMMAND winget install jq", ["winget install jq"], [], true],
  ["later-segment-quoted-interp", "cd /tmp && \"bash\" -lc \"shutdown -h now\"", ["shutdown -h now"], [], true],
  ["eval-plain", "eval echo hi", ["echo hi"], [], true],
  ["eval-recursion", "eval \"sudo bash -c 'winget install jq'\"", ["winget install jq"], [], true],
  ["newline-outside-quotes-splits", "ls\nbash -c 'y'", ["y"], [], true],
  ["newline-inside-quotes-one-body", "bash -c 'a\nb'", ["a\nb"], ["b"], true],
  ["odd-backslash-continuation-joins", "bash \\\n-c 'x'", ["x"], [], true],
  ["even-backslash-no-join", "bash \\\\\n-c 'x'", [], ["x"], null],
  ["heredoc-body-removed-apostrophe", "git commit -F - <<'EOF'\ndon't touch it\nEOF\nbash -c 'z'", ["z"], [], true],
  ["quoted-arg-not-a-position", "echo \"bash -c x\"", [], ["x"], true],
  ["no-flag-no-body", "bash script.sh", [], ["script.sh"], true],
  ["flag-without-body", "bash -c", [], [], true],
  ["posix-c-dashdash-skipped", "bash -c -- 'x'", ["x"], ["--"], true],
  ["posix-c-option-skipped", "bash -c -x 'x'", ["x"], ["-x"], true],
  ["posix-c-plus-o-name-skipped", "bash -c +o pipefail 'x'", ["x"], ["+o", "pipefail"], true],
  ["posix-c-options-only-no-body", "bash -c -- ", [], [], true],
  ["two-posix-bodies-one-segment", "find . -exec bash -c 'a' \\; -exec bash -c 'b' \\;", ["a", "b"], [], true],
  ["eval-then-posix-flat-body", "eval bash -c 'x'", ["x"], [], true],
  ["posix-c-shopt-O-name-skipped", "bash -c -O extglob 'x'", ["x"], ["-O", "extglob"], true],
  ["posix-c-shopt-plus-O-name-skipped", "bash -c +O extglob 'x'", ["x"], ["+O", "extglob"], true],
  ["fish-long-command", "fish --command 'x'", ["x"], [], true],
  ["fish-long-command-eq", "fish --command='x'", ["x"], ["--command=x"], true],
  ["ksh-c", "ksh -c 'x'", ["x"], [], true],
  ["ksh93-c", "ksh93 -c 'x'", ["x"], [], true],
  ["mksh-c", "mksh -c 'x'", ["x"], [], true],
  ["ash-c", "ash -c 'x'", ["x"], [], true],
];

if (group === "bodies") {
  for (const [name, text, inc, exc, unparsedEmpty] of BODY_CASES) {
    const r = run(text);
    if (!shape(r)) { out(name + "/shape", false, show(r)); continue; }
    inc.forEach((b) => out(name + "/includes-" + JSON.stringify(b), r.bodies.includes(b), show(r)));
    exc.forEach((b) => out(name + "/excludes-" + JSON.stringify(b), !r.bodies.includes(b), show(r)));
    if (inc.length === 0 && exc.length === 0) out(name + "/no-bodies", r.bodies.length === 0, show(r));
    if (unparsedEmpty) out(name + "/unparsed-empty", r.unparsedLines.length === 0, show(r));
  }
  const h = run("git commit -F - <<'EOF'\ndon't touch it\nEOF\nbash -c 'z'");
  out("heredoc-body-text-absent", shape(h) && !h.bodies.concat(h.unparsedLines).some((s) => s.includes("don't")), show(h));
  const e = run("");
  out("empty-input-empty-result", shape(e) && e.bodies.length === 0 && e.unparsedLines.length === 0, show(e));
}

if (group === "unparsed") {
  const r = run("echo 'unterminated");
  out("unclosed-quote-line-is-unparsed", shape(r) && r.unparsedLines.some((l) => l.includes("unterminated")), show(r));
  out("unclosed-quote-yields-no-body", shape(r) && r.bodies.length === 0, show(r));
  const ok = run("ls -la");
  out("parsed-line-not-unparsed", shape(ok) && ok.unparsedLines.length === 0, show(ok));
}

if (group === "depth") {
  // Each level is ONE double-quoted token of the level above, so only recursion
  // (never the flat every-position scan) can reach it. levels[k] = k wrappers.
  const N = 10;
  const dq = (s) => "\"" + s.replace(/\\/g, "\\\\").replace(/"/g, "\\\"") + "\"";
  const levels = ["echo deep"];
  for (let k = 1; k <= N; k++) levels.push("bash -c " + dq(levels[k - 1]));
  const r = run(levels[N]);
  out("deep-chain-returns", shape(r), show(r));
  if (shape(r)) {
    [1, 2, 3].forEach((k) => out("level-" + k + "-extracted", r.bodies.includes(levels[N - k]), show(r.bodies)));
    out("innermost-beyond-cap-absent", !r.bodies.includes("echo deep"), show(r.bodies));
    out("bodies-bounded-by-cap", r.bodies.length <= 5, "len=" + r.bodies.length);
    out("interpreter-beyond-cap-overflows", r.overflow === true, "overflow=" + r.overflow);
  }
  const atCap = run(levels[3]);
  out("three-levels-no-overflow", shape(atCap) && atCap.overflow === false && atCap.bodies.includes("echo deep"), show(atCap));
  const pastCap = run(levels[4]);
  out("four-levels-overflow", shape(pastCap) && pastCap.overflow === true, show(pastCap));
}

if (group === "classify") {
  // The allow side must not demote a body reached by skipping options after -c.
  const ro = m.isReadOnlyInterpreterC;
  if (typeof ro !== "function") { out("export-isReadOnlyInterpreterC", false, typeof ro); process.exit(0); }
  [
    ["shopt-O-write-not-read", "bash -c -O extglob 'rm -rf x'", false],
    ["shopt-O-read-still-not-read", "bash -c -O extglob 'ls'", false],
    ["dashdash-skipped-not-read", "bash -c -- 'ls'", false],
    ["fish-command-eq-not-read", "fish --command='rm -rf x' ls", false],
    ["plain-read-is-read", "bash -c 'ls'", true],
  ].forEach(([name, cmd, want]) => {
    let got; try { got = ro(cmd); } catch (e) { got = "threw:" + e.message; }
    out(name, got === want, "isReadOnlyInterpreterC(" + cmd + ")=" + got);
  });
}

if (group === "overflow") {
  // eval x400 once yielded O(N^3) bodies (OOM); it must now stay linear.
  const evals = "eval ".repeat(400);
  const t0 = Date.now();
  const r = run(evals + "winget install jq");
  const ms = Date.now() - t0;
  const bytes = shape(r) ? r.bodies.reduce((n, b) => n + b.length, 0) : -1;
  out("eval-x400-returns-quickly", shape(r) && ms < 5000, "ms=" + ms + " " + show(r).slice(0, 200));
  out("eval-x400-no-overflow", shape(r) && r.overflow === false, String(r.overflow));
  out("eval-x400-bounded", shape(r) && r.bodies.length <= 5 && bytes <= 4 * (evals.length + 20), "len=" + (r.bodies || []).length + " bytes=" + bytes);
  out("eval-x400-inner-reached", shape(r) && r.bodies.some((b) => b.endsWith("winget install jq")), show(r).slice(0, 200));
  out("caps-exported", Number.isInteger(m.MAX_BODIES) && Number.isInteger(m.MAX_TOTAL_BYTES), m.MAX_BODIES + "/" + m.MAX_TOTAL_BYTES);
  const many = Array(m.MAX_BODIES + 100).fill("bash -c x").join(" && ");
  const t1 = Date.now();
  const o = run(many);
  out("too-many-bodies-overflow", shape(o) && o.overflow === true && Date.now() - t1 < 10000, "overflow=" + o.overflow);
  out("too-many-bodies-capped", shape(o) && o.bodies.length <= m.MAX_BODIES, "len=" + (o.bodies || []).length);
  const big = run("bash -c '" + "x".repeat(m.MAX_TOTAL_BYTES + 1) + "'");
  out("too-many-bytes-overflow", shape(big) && big.overflow === true, "overflow=" + big.overflow);
  ["bash", "pwsh"].forEach((w) => {
    const t2 = Date.now();
    const q = run((w + " ").repeat(50000) + "x");
    const qms = Date.now() - t2;
    out(w + "-x50000-flag-search-linear", shape(q) && q.bodies.length === 0 && qms < 3000, "ms=" + qms);
  });
  const plain = run("bash -c 'x'");
  out("normal-input-no-overflow", shape(plain) && plain.overflow === false, String(plain.overflow));
}
JSEOF

# ============================================================================
case_begin "inline-body-flag-truth-table" "hooks/lib/interpreter-inline-body.js"
# ============================================================================
relay "flag" "$(run_with_timeout 60 node "$TMPD/runner.js" "$LIB_JS" flag 2>&1 || echo "FAIL:runner-crashed")"
case_end

# ============================================================================
case_begin "inline-bodies-extraction" "hooks/lib/interpreter-inline-body.js"
# ============================================================================
relay "bodies" "$(run_with_timeout 60 node "$TMPD/runner.js" "$LIB_JS" bodies 2>&1 || echo "FAIL:runner-crashed")"
case_end

# ============================================================================
case_begin "parse-failure-goes-to-unparsed-lines" "hooks/lib/interpreter-inline-body.js"
# ============================================================================
relay "unparsed" "$(run_with_timeout 60 node "$TMPD/runner.js" "$LIB_JS" unparsed 2>&1 || echo "FAIL:runner-crashed")"
case_end

# ============================================================================
case_begin "recursion-depth-cap" "hooks/lib/interpreter-inline-body.js"
# ============================================================================
relay "depth" "$(run_with_timeout 60 node "$TMPD/runner.js" "$LIB_JS" depth 2>&1 || echo "FAIL:runner-crashed")"
case_end

# ============================================================================
case_begin "body-count-and-size-caps" "hooks/lib/interpreter-inline-body.js"
# ============================================================================
# A 256 MB heap makes an unbounded blow-up crash (runner-crashed) instead of swapping.
relay "overflow" "$(run_with_timeout 60 node --max-old-space-size=256 "$TMPD/runner.js" "$LIB_JS" overflow 2>&1 || echo "FAIL:runner-crashed")"
case_end

# ============================================================================
case_begin "allow-side-skipped-options-fail-closed" "hooks/lib/bash-write-patterns/classify.js"
# ============================================================================
CLASSIFY_JS="$(np "$SCRIPT_CHECKOUT_ROOT")/hooks/lib/bash-write-patterns/classify.js"
relay "classify" "$(run_with_timeout 60 node "$TMPD/runner.js" "$CLASSIFY_JS" classify 2>&1 || echo "FAIL:runner-crashed")"
case_end

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
