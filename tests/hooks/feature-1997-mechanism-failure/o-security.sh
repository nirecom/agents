# o-security.sh — O1-O3: hostile session ids (#1997).
# Sourced by tests/feature-1997-mechanism-failure.sh.
# Tests: hooks/lib/mechanism-failure.js
# Tags: mechanism-failure, security, path-traversal, session-id, regression-1997, scope:issue-specific, pwsh-not-required, TL1

# The session id reaches this module from hook stdin, so it is untrusted input
# that is then used to BUILD A PATH (`<sid>.stall-reported`, `<sid>.json`,
# `<sid>-supervisor-state.json`). A traversal or a separator inside it would let
# a crafted id write the ledger anywhere the process can reach — and the ledger
# is a suppression token, so a forged one silences future reports.

# _sid_probe <js-call-body> — run <body> once per hostile id under a temp root,
# then walk the whole root and flag any file that landed outside the pinned
# workflow dir. Prints OK, or BAD:<id>=<what-escaped> lines.
#
# The workflow dir is nested FOUR levels below the root on purpose: with a
# shallow `root/wf`, a `../../../` id would climb clean out of the root and the
# walk would never see the file it created — the escape would read as a pass.
_sid_probe() {
    local root tn out
    root="$(make_tmp)"
    mkdir -p "$root/n1/n2/n3/n4/wf" "$root/outside"
    tn="$(node_path "$root/n1/n2/n3/n4/wf")"
    out=$(ROOT="$(node_path "$root")" CLAUDE_WORKFLOW_DIR="$tn" WORKFLOW_PLANS_DIR="$tn" \
        BODY="$1" "$RWT" 40 node -e "
const fs = require('fs'), path = require('path');
const MF = require('$MF_NODE');
const root = process.env.ROOT;
const wf = path.join(root, 'n1', 'n2', 'n3', 'n4', 'wf');
const ids = [
  ['empty', ''],
  ['whitespace', '   '],
  ['traversal-rel', '../../../etc/passwd'],
  ['traversal-dotdot', '..'],
  ['traversal-mixed', 'ok/../../../../../outside/evil'],
  ['separator-fwd', 'a/b'],
  ['separator-back', 'a\\\\b'],
  ['colon', 'a:b'],
  ['absolute-posix', '/etc/passwd'],
  ['absolute-win', 'C:\\\\Windows\\\\evil'],
  ['nul-byte', 'a\u0000b'],
  ['glob', '*'],
  ['tilde', '~'],
  ['very-long', 'z'.repeat(1200)],
];
const call = new Function('MF', 'sid', process.env.BODY);
const problems = [];
for (const [label, sid] of ids) {
  try { call(MF, sid); } catch (e) { problems.push(label + '=threw(' + e.message + ')'); }
}
// Every file anywhere under the root must sit directly in wf/ and be named for
// a session marker or state file — anything else is an escape.
const walk = (d) => fs.readdirSync(d, { withFileTypes: true }).flatMap((e) => {
  const p = path.join(d, e.name);
  return e.isDirectory() ? walk(p) : [p];
});
for (const f of walk(root)) {
  if (path.dirname(f) !== wf) problems.push('escaped=' + path.relative(root, f));
}
process.stdout.write(problems.length ? 'BAD:' + problems.join(' ') : 'OK');" 2>/dev/null)
    rm -rf "$root" 2>/dev/null || true
    printf '%s' "${out:-BAD:probe-did-not-run(module-load-or-eval-error)}"
}

# ---------------------------------------------------------------------------
# O1: the write side. reportMechanismFailureOnce is the only call here that
#     creates files, so it is where a hostile id turns into a hostile path.
# ---------------------------------------------------------------------------
run_O1() {
    local out
    out="$(_sid_probe "MF.reportMechanismFailureOnce(sid, { step: 'write_tests', kind: 'in-flight-expired' });")"
    if [ "$out" = "OK" ]; then
        pass "O1: reportMechanismFailureOnce writes nothing outside CLAUDE_WORKFLOW_DIR for 14 hostile session ids, and never throws"
    else
        fail "O1: hostile session ids reach the reporter's path construction — $out"
    fi
}

# ---------------------------------------------------------------------------
# O2: the read side. detectStalledSteps only reads, but it reads a path built
#     the same way, so a traversal there is an arbitrary-file read — and it must
#     stay total: a throw inside a UserPromptSubmit hook costs the user a prompt.
# ---------------------------------------------------------------------------
run_O2() {
    local out
    out="$(_sid_probe "MF.detectStalledSteps(sid);")"
    if [ "$out" = "OK" ]; then
        pass "O2: detectStalledSteps stays inside CLAUDE_WORKFLOW_DIR and never throws for the same 14 hostile session ids"
    else
        fail "O2: hostile session ids reach the detector's path construction — $out"
    fi
}

# ---------------------------------------------------------------------------
# O2b: the read-side counterpart C5 calls out — O2 only proves detectStalledSteps
#     does not CREATE files outside the workflow dir. Since it is read-only, the
#     real risk is a traversal id causing it to READ a pre-planted file and be
#     influenced by attacker-controlled content. Plant a decoy at each traversal
#     target and assert the findings never reflect it.
# ---------------------------------------------------------------------------
run_O2b() {
    local root tn out
    root="$(make_tmp)"
    mkdir -p "$root/n1/n2/n3/n4/wf" "$root/outside"
    tn="$(node_path "$root/n1/n2/n3/n4/wf")"
    # Decoy state files at plausible traversal landing spots: a session state
    # shaped exactly like a genuine stall, so any influence would be visible.
    cat > "$root/outside/evil.json" <<'EOF'
{"version":1,"session_id":"evil","steps":{"write_tests":{"status":"in_progress","updated_at":"2000-01-01T00:00:00.000Z"}},"events":[{"step":"write_tests","status":"in_progress","at":"2000-01-01T00:00:00.000Z"}]}
EOF
    cp "$root/outside/evil.json" "$root/evil.json"
    out=$(ROOT="$(node_path "$root")" CLAUDE_WORKFLOW_DIR="$tn" WORKFLOW_PLANS_DIR="$tn" "$RWT" 40 node -e "
const MF = require('$MF_NODE');
const ids = [
  ['traversal-rel', '../../../etc/passwd'],
  ['traversal-dotdot', '..'],
  ['traversal-mixed', 'ok/../../../../../outside/evil'],
  ['absolute-posix', '/etc/passwd'],
];
const problems = [];
for (const [label, sid] of ids) {
  let r;
  try { r = MF.detectStalledSteps(sid); } catch (e) { problems.push(label + '=threw(' + e.message + ')'); continue; }
  const s = JSON.stringify(r || []);
  if (s.includes('write_tests') || s.includes('evil')) problems.push(label + '=influenced-by-decoy:' + s);
}
process.stdout.write(problems.length ? 'BAD:' + problems.join(' ') : 'OK');" 2>/dev/null)
    rm -rf "$root" 2>/dev/null || true
    if [ "$out" = "OK" ]; then
        pass "O2b: detectStalledSteps ignores decoy state files planted at traversal targets"
    else
        fail "O2b: a hostile session id caused detectStalledSteps to be influenced by a planted decoy — ${out:-<probe-did-not-run>}"
    fi
}

# ---------------------------------------------------------------------------
# O3: the positive anchor. O1/O2 are satisfied by a module that rejects every
#     id, including good ones — which would be a broken reporter that happens to
#     be safe. A normal id must still produce its ledger, in the pinned dir.
# ---------------------------------------------------------------------------
run_O3() {
    local tmp tn out problems=""
    tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
    out="$(report_once "$tn" sess-ok_123 write_tests in-flight-expired)"
    case "$out" in
        true\|*) : ;;
        *) problems="$problems [an ordinary session id returned '${out:-<module-load-error>}', expected reported=true]" ;;
    esac
    [ -f "$tmp/sess-ok_123.stall-reported" ] ||
        problems="$problems [no ledger at <workflow-dir>/sess-ok_123.stall-reported]"
    rm -rf "$tmp" 2>/dev/null || true
    if [ -z "$problems" ]; then
        pass "O3: an ordinary session id still writes its ledger inside the pinned workflow dir"
    else
        fail "O3: hostile-id rejection has swallowed the legitimate path;$problems"
    fi
}
