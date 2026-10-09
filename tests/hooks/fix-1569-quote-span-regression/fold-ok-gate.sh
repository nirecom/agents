# tests/hooks/fix-1569-quote-span-regression/fold-ok-gate.sh
# Tests: hooks/enforce-worktree/main-worktree-allows/worker-script.js, hooks/lib/quote-spans/fold.js
# Tags: worktree, enforce, hook, quote-spans, arg-tail, security, classifier, scope:issue-specific
# Sourced by tests/hooks/fix-1569-quote-span-regression.sh — uses its pass/fail,
# run_with_timeout, FAKE_SCRIPT_CHECKOUT_ROOT, DISPATCH, MAIN_WT, SCRIPT_CHECKOUT_ROOT.
# Defect pinned: worker-script.js must not consume foldNewlinesInSpans(...).out
# while ignoring `.ok` (`.ok:false` = unparseable, `out` untrustworthy; using it
# anyway is fail-OPEN). Behaviour rows: a fold-failing tail rejects. Structural
# row: the call site owns that decision instead of relying on
# rejectsUnsafeArgTail re-scanning and failing closed by accident.

run_fold_ok_gate_cases() {

# ── Behaviour: a fold-failing arg tail must reject ──────────────────────────
fold_probe() {
    run_with_timeout 30 env "AGENTS_MAIN_ROOT=$FAKE_SCRIPT_CHECKOUT_ROOT" node -e '
      const path = require("path");
      const root = process.argv[1];
      const op = process.argv[2], tail = process.argv[3];
      let qs, ws;
      try {
        qs = require(path.join(root, "hooks", "lib", "quote-spans.js"));
        ws = require(path.join(root, "hooks", "enforce-worktree",
                               "main-worktree-allows", "worker-script.js"));
      } catch (e) { console.log("ERROR: " + e.message); process.exit(0); }
      try {
        if (op === "foldok") {
          console.log(String(qs.foldNewlinesInSpans(tail, ["dq"]).ok));
        } else if (op === "allowed") {
          const f = ws.isAllowedWorkerScriptInvocation;
          if (typeof f !== "function") { console.log("ERROR: isAllowedWorkerScriptInvocation not exported"); process.exit(0); }
          console.log(String(f(tail, process.argv[4])));
        } else {
          console.log("ERROR: unknown op " + op);
        }
      } catch (e) { console.log("ERROR: threw " + e.message); }
    ' "$FAKE_SCRIPT_CHECKOUT_ROOT" "$1" "$2" "$MAIN_WT" 2>&1
}

assert_fold() {
    local label="$1" op="$2" input="$3" want="$4" got
    got="$(fold_probe "$op" "$input")"
    if [ "$got" = "$want" ]; then pass "$label"
    else fail "$label (want=$want got=$got)"; fi
}

# Step 1 — the fold really does fail on these tails (without this the verdict
# rows below would be pinning some unrelated rejection), and really does
# succeed on the control.
assert_fold "FOLDOK-fold unclosed dq -> ok:false"        foldok ' --title "a'      false
assert_fold "FOLDOK-fold unclosed sq -> ok:false"        foldok " --title 'a"      false
assert_fold "FOLDOK-fold unclosed cmdsubst -> ok:false"  foldok ' --title $(id'    false
assert_fold "FOLDOK-fold unclosed backtick -> ok:false"  foldok ' --title `id'     false
assert_fold "FOLDOK-fold balanced tail -> ok:true"       foldok ' --title "a|b"'   true

# Step 2 — each of those tails, attached to a genuinely sanctioned script, must
# resolve to the reject side; the balanced twin must still be accepted, so
# "reject every invocation" does not satisfy the block.
assert_fold "FOLDOK-verdict unclosed dq rejects"       allowed "bash \"$DISPATCH\" --title \"a"     false
assert_fold "FOLDOK-verdict unclosed sq rejects"       allowed "bash \"$DISPATCH\" --title 'a"      false
assert_fold "FOLDOK-verdict unclosed cmdsubst rejects" allowed "bash \"$DISPATCH\" --title \$(id"   false
assert_fold "FOLDOK-verdict unclosed backtick rejects" allowed "bash \"$DISPATCH\" --title \`id"    false
assert_fold "FOLDOK-verdict balanced twin accepted"    allowed "bash \"$DISPATCH\" --title \"a|b\"" true

# ── Structure: the call site must own its fail-closed decision ──────────────
# RED today: line 97 is `const scanTail = foldNewlinesInSpans(argTail, ["dq"]).out;`.
WORKER_SRC_FOLDOK="$SCRIPT_CHECKOUT_ROOT/hooks/enforce-worktree/main-worktree-allows/worker-script.js"

assert_foldok_src() {
    local label="$1" pattern="$2" want="$3" got=false
    if grep -Eq "$pattern" "$WORKER_SRC_FOLDOK" 2>/dev/null; then got=true; fi
    if [ "$got" = "$want" ]; then pass "$label"
    else fail "$label (want=$want got=$got for /$pattern/)"; fi
}

# Existence guard: a `want=false` grep row passes trivially against a missing or
# renamed file, so pin first that the call really is still here.
assert_foldok_src "FOLDOK-src worker-script still calls foldNewlinesInSpans" \
    'foldNewlinesInSpans\(' true
assert_foldok_src "FOLDOK-src the fold result is not consumed as a bare .out" \
    'foldNewlinesInSpans\([^;]*\)\.out' false
assert_foldok_src "FOLDOK-src the fold result's ok flag is consulted" \
    '\.ok' true

}
