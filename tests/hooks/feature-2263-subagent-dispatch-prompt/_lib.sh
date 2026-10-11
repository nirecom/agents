# shellcheck shell=bash
# tests/hooks/feature-2263-subagent-dispatch-prompt/_lib.sh
# Tests: hooks/subagent-dispatch-prompt.js
# Tags: TL2, hooks, subagent-dispatch, library, scope:issue-specific, pwsh-not-required
# Shared fixture + probe helpers for the #2263 fragments; each fragment sources this after
# setting SCRIPT_CHECKOUT_ROOT. A missing hook is reported as a value (HOOK-MISSING), never a crash.

set -uo pipefail
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

TMPROOT="$(make_tmp)"
readonly TMPROOT
trap 'rm -rf "$TMPROOT"' EXIT
harness_isolate "$TMPROOT/iso"
unset CLAUDE_CODE_SESSION_ID

HOOK_JS="$SCRIPT_CHECKOUT_ROOT/hooks/subagent-dispatch-prompt.js"
HOOK_N="$(np "$HOOK_JS")"
REPO_N="$(np "$SCRIPT_CHECKOUT_ROOT")"
RULES_FILE="$SCRIPT_CHECKOUT_ROOT/rules/shell-commands.md"

# The canonical line, split at its rule-path slot; the SSOT is the rule's own line, which
# line-sync.sh compares against this split and against the hook's output.
CANON_PRE='Read `'
CANON_POST='` before the first Bash command and before writing a file, follow its Subagent Dispatch Prompts section, and end the final report with a `Command-form deviations` section counting every blocked or rejected command (write `0` when none) unless your own output contract fixes the exact shape of your reply.'
export SDP_CANON_PRE="$CANON_PRE" SDP_CANON_POST="$CANON_POST" SDP_RULE_PATH="$REPO_N/rules/shell-commands.md"

check() { if [ "$3" = "$2" ]; then pass "$1"; else fail "$1" "expected [$2] got [$3]"; fi; }

finish() {
  echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
  [ "$FAIL" -eq 0 ]
}

PROBE_N=0
# sdp_probe <check-expr> <input-expr> [opts-expr]
# Evaluates decide(<input>, <opts>) in-process and prints <check-expr>. In scope for every
# expression: canon (the line carrying THIS checkout's absolute rule path), canonFor(path),
# env (process.env). In <check-expr> also: out (decide's return), inp, P (updatedInput.prompt).
# Expressions travel through files, so Git Bash never rewrites a path-looking argument.
sdp_probe() {
  local d
  PROBE_N=$((PROBE_N + 1))
  d="$TMPROOT/probe-$PROBE_N"
  mkdir -p "$d"
  printf '%s' "$1" > "$d/check.js"
  printf '%s' "$2" > "$d/input.js"
  printf '%s' "${3:-undefined}" > "$d/opts.js"
  run_with_timeout 30 node -e '
    const fs = require("fs"), path = require("path");
    const [hook, dir] = process.argv.slice(1);
    const rd = (n) => fs.readFileSync(path.join(dir, n), "utf8");
    const canonFor = (p) => process.env.SDP_CANON_PRE + p + process.env.SDP_CANON_POST;
    const canon = canonFor(process.env.SDP_RULE_PATH);
    const env = process.env;
    const ev = (src, extra) => new Function("canon", "canonFor", "env", ...Object.keys(extra), "return (" + src + ");")(canon, canonFor, env, ...Object.values(extra));
    if (!fs.existsSync(hook)) { process.stdout.write("HOOK-MISSING"); process.exit(0); }
    let m;
    try { m = require(hook); } catch (e) { process.stdout.write("REQUIRE-THREW:" + e.message); process.exit(0); }
    if (!m || typeof m.decide !== "function") { process.stdout.write("NO-DECIDE-EXPORT"); process.exit(0); }
    const inp = ev(rd("input.js"), {});
    const opts = ev(rd("opts.js"), {});
    let out;
    try { out = m.decide(inp, opts); } catch (e) { process.stdout.write("DECIDE-THREW:" + e.message); process.exit(0); }
    const hso = out && out.hookSpecificOutput;
    const P = hso && hso.updatedInput ? hso.updatedInput.prompt : undefined;
    let v;
    try { v = ev(rd("check.js"), { out, inp, P }); } catch (e) { v = "CHECK-THREW:" + e.message; }
    process.stdout.write(typeof v === "string" ? v : JSON.stringify(v));
  ' "$HOOK_N" "$(np "$d")" 2>/dev/null
}

# sdp_main <stdin-file> -> "<rc>|<stdout>" from running the hook as a process.
sdp_main() {
  local out rc
  out="$(run_with_timeout 30 node "$HOOK_N" < "$1" 2>/dev/null)"
  rc=$?
  printf '%s|%s' "$rc" "$(printf '%s' "$out" | tr -d '\r\n')"
}

# Expression shorthands shared by the fragments.
# shellcheck disable=SC2016  # JS source, not shell expansion.
APPENDED_ONCE='typeof P === "string" && P.split(/\r?\n/).filter((l) => l.trim() === canon).length === 1'
PASSTHROUGH='JSON.stringify(out)'
