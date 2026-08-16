# f-security.sh — F1-F2: hostile session ids reaching the pause marker (#1624).
# Sourced by tests/feature-1624-next-step-pause-scope.sh.
# Tests: hooks/lib/next-step-pause-marker.js, hooks/lib/session-markers.js
# Tags: next-step-pause, security, path-traversal, session-id, regression-1624, scope:issue-specific, pwsh-not-required, TL1

# The session id becomes a FILENAME. Every id below is one of the standard ways
# a filename-shaped input escapes its directory, and the contract is the same for
# all of them: refuse (or sanitize), never throw, and above all never create a
# file anywhere except as a direct child of CLAUDE_WORKFLOW_DIR. The fixture root
# therefore contains a sibling `outside/` directory: a traversal that "worked"
# lands there, and the walk below sees it.

# _sid_probe <js-call-body> — run one probe over the hostile id set with a
# fixture root containing wf/ and outside/. The JS body is evaluated with `sid`
# bound to each hostile id and must not throw. Prints OK or BAD:<problems>.
_sid_probe() {
    local body="$1" tmp root out
    tmp="$(make_tmp)"
    root="$(node_path "$tmp")"
    mkdir -p "$tmp/wf" "$tmp/outside"
    out=$(ROOT="$root" BODY="$body" \
        CLAUDE_WORKFLOW_DIR="$root/wf" WORKFLOW_PLANS_DIR="$root/wf" "$RWT" 25 node -e "
const fs = require('fs'), path = require('path');
const M = require('$PAUSE_NODE');
const SM = require('$MARKERS_NODE');
const root = process.env.ROOT, wf = path.join(root, 'wf');
const problems = [];
const walk = (d) => {
  let out = [];
  for (const n of fs.readdirSync(d)) {
    const p = path.join(d, n);
    let st; try { st = fs.lstatSync(p); } catch (e) { continue; }
    if (st.isDirectory()) out = out.concat(walk(p)); else out.push(p);
  }
  return out;
};
const hostile = [
  ['empty', ''],
  ['whitespace', '   '],
  ['traversal-rel', '../../../etc/passwd'],
  ['traversal-dotdot', '..'],
  ['traversal-mixed', 'ok/../../evil'],
  ['separator-fwd', 'a/b'],
  ['separator-back', 'a\\\\b'],
  ['colon', 'a:b'],
  ['absolute-posix', '/etc/passwd'],
  ['absolute-win', 'C:\\\\Windows\\\\evil'],
  ['nul-byte', 'a\\u0000b'],
  ['glob', '*'],
  ['tilde', '~'],
  ['very-long', 'z'.repeat(1200)],
];
const probe = new Function('M', 'SM', 'sid', process.env.BODY);
for (const [label, sid] of hostile) {
  try { probe(M, SM, sid); }
  catch (e) { problems.push(label + ':threw(' + e.message + ')'); }
  for (const f of walk(root)) {
    const parent = path.resolve(path.dirname(f));
    if (parent !== path.resolve(wf)) {
      problems.push(label + ':escaped(' + path.relative(root, f) + ')');
    } else if (path.basename(f) !== sid + '.next-step-paused') {
      problems.push(label + ':unexpected-name(' + path.basename(f) + ')');
    }
    try { fs.unlinkSync(f); } catch (e) {}
  }
}
process.stdout.write(problems.length ? 'BAD:' + problems.join(' | ') : 'OK');" 2>/dev/null)
    rm -rf "$tmp" 2>/dev/null || true
    # An empty capture means the probe never ran (module missing or a syntax
    # error). Name that explicitly — silence must not read as OK.
    printf '%s' "${out:-BAD:probe-did-not-run(module-load-or-eval-error)}"
}

# ---------------------------------------------------------------------------
# F1: the WRITE side. writePauseMarker is reached from a sentinel the model
#     itself emits, so the id it carries is not trustworthy input. A traversal
#     that lands a `.next-step-paused` file outside the workflow directory is
#     both an escape and a forged suppression: the file authorises silence.
# ---------------------------------------------------------------------------
run_F1() {
    local out
    out="$(_sid_probe 'M.writePauseMarker(sid, { reason: "[for=any] probe" });')"
    if [ "$out" = "OK" ]; then
        pass "F1: writePauseMarker refuses or sanitizes every hostile session id (empty, whitespace, traversal, separators, colon, absolute, NUL, glob, tilde, 1200 chars) without throwing and without writing outside the workflow dir"
    else
        fail "F1: hostile session id reached the pause-marker writer; got '${out:-<err>}'"
    fi
}

# ---------------------------------------------------------------------------
# F2: the READ side. isPauseActive is a suppression predicate — a hostile id that
#     resolves to some file OUTSIDE the workflow dir would let an attacker-chosen
#     path decide whether the guards speak. It must stay total (never throw) and
#     answer false, which is also the fail-CLOSED direction.
# ---------------------------------------------------------------------------
run_F2() {
    local out
    out="$(_sid_probe 'if (M.isPauseActive(sid, "research") !== false) throw new Error("active-for-hostile-sid"); if (SM.isNextStepPaused(sid, "research") !== false) throw new Error("facade-active-for-hostile-sid");')"
    if [ "$out" = "OK" ]; then
        pass "F2: isPauseActive and the session-markers facade answer false for every hostile session id, without throwing and without touching anything outside the workflow dir"
    else
        fail "F2: hostile session id reached the pause-marker reader; got '${out:-<err>}'"
    fi
}

# ---------------------------------------------------------------------------
# F2b: the read-side counterpart C5 calls out — F2 only proves isPauseActive
#     answers false and never throws for hostile ids; it does not prove the
#     answer is untouched by a file an attacker managed to plant at a
#     traversal target. Plant a decoy marker that LOOKS like a live pause and
#     assert the answer is still false.
# ---------------------------------------------------------------------------
run_F2b() {
    local tmp root out
    tmp="$(make_tmp)"; root="$(node_path "$tmp")"
    mkdir -p "$tmp/wf" "$tmp/outside"
    cat > "$tmp/outside/evil.next-step-paused" <<'EOF'
{"reason":"[for=research] PLANTED-DECOY","createdAt":"2000-01-01T00:00:00.000Z"}
EOF
    cp "$tmp/outside/evil.next-step-paused" "$tmp/evil.next-step-paused"
    out=$(ROOT="$root" CLAUDE_WORKFLOW_DIR="$root/wf" WORKFLOW_PLANS_DIR="$root/wf" "$RWT" 25 node -e "
const M = require('$PAUSE_NODE');
const SM = require('$MARKERS_NODE');
const ids = [
  ['traversal-rel', '../../../etc/passwd'],
  ['traversal-mixed', 'ok/../../evil'],
  ['absolute-posix', '/etc/passwd'],
];
const problems = [];
for (const [label, sid] of ids) {
  try {
    if (M.isPauseActive(sid, 'research') !== false) problems.push(label + '=influenced-by-decoy(pause)');
    if (SM.isNextStepPaused(sid, 'research') !== false) problems.push(label + '=influenced-by-decoy(facade)');
  } catch (e) { problems.push(label + '=threw(' + e.message + ')'); }
}
process.stdout.write(problems.length ? 'BAD:' + problems.join(' ') : 'OK');" 2>/dev/null)
    rm -rf "$tmp" 2>/dev/null || true
    if [ "$out" = "OK" ]; then
        pass "F2b: isPauseActive/isNextStepPaused ignore decoy markers planted at traversal targets"
    else
        fail "F2b: a hostile session id caused the pause reader to be influenced by a planted decoy — ${out:-<probe-did-not-run>}"
    fi
}

# ---------------------------------------------------------------------------
# F3: the positive anchor for F1/F2. A well-formed id must still work — without
#     this row, a module that rejected every id whatsoever would pass the whole
#     security file while having removed the feature.
# ---------------------------------------------------------------------------
run_F3() {
    local tmp tn problems=""
    tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
    write_pause "$tn" "sess-ok_123" "[for=research] legitimate pause"
    [ -f "$(marker_path "$tmp" "sess-ok_123")" ] ||
        problems="$problems [a well-formed session id produced no marker]"
    [ "$(pause_active "$tn" "sess-ok_123" research)" = "true/true" ] ||
        problems="$problems [a well-formed session id's pause is not active]"
    rm -rf "$tmp" 2>/dev/null || true
    if [ -z "$problems" ]; then
        pass "F3: a well-formed session id still writes and resolves a working pause (the anchor for F1/F2)"
    else
        fail "F3: hostile-id hardening broke the legitimate path;$problems"
    fi
}
