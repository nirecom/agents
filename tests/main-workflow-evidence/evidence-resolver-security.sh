# shellcheck shell=bash
# Tests: hooks/lib/workflow-state/evidence-resolver.js, hooks/lib/workflow-state/state-io.js
# Tags: workflow, hook, security, path-traversal
#
# Case group: hasCompletionEvidence sessionId validation (SESSION_ID_VALID_RE),
# WS-EV-23. Sourced by main-workflow-evidence.sh; relies on helpers from common.sh.

run_evidence_resolver_security_tests() {
    local RESOLVER EV23_TMP EV23_PLANS EV23_PLANS_N EV23_JS EV23_OUT tag name verdict detail

    echo ""
    echo "=== WS-EV-23: hasCompletionEvidence rejects malformed sessionId (path traversal / metachars) ==="

    if [ ! -f "$DOTFILES_DIR/hooks/lib/workflow-state/evidence-resolver.js" ]; then
      echo "SKIP: WS-EV-23 (evidence-resolver.js not yet implemented)"
      return 0
    fi

    RESOLVER="$(to_node_path "$DOTFILES_DIR/hooks/lib/workflow-state/evidence-resolver.js")"
    EV23_TMP=$(mktemp -d)
    # PLANS_DIR is rooted deep inside the sandbox so that a successful '../../'
    # traversal still lands inside $EV23_TMP — nothing is ever written to a real
    # system path such as /etc or C:\Windows.
    EV23_PLANS="$EV23_TMP/sandbox/lvl1/lvl2/plans"
    mkdir -p "$EV23_PLANS"
    EV23_PLANS_N="$(to_node_path "$EV23_PLANS")"
    EV23_JS="$EV23_TMP/ev23.js"

    # Written to a file (not `node -e`) so backslash-bearing attack strings
    # survive verbatim instead of being mangled by shell quoting.
    cat > "$EV23_JS" <<'EV23JS'
const path = require('path');
const fs = require('fs');
const r = require(process.argv[2]);
const plansDir = process.argv[3];
const sandboxRoot = process.argv[4];
const resolvedPlans = path.resolve(plansDir);

// Table-driven (skills/_shared/test-design/parser-regex-tests.md).
const badSids = [
  { name: 'posix-traversal',     sid: '../../etc/passwd' },
  { name: 'embedded-traversal',  sid: 'a/../../b' },
  { name: 'backslash-traversal', sid: '..\\..\\windows\\system32' },
  { name: 'shell-metachar',      sid: 'x;whoami' },
  { name: 'space',               sid: 'x y' },
];

function emit(name, ok, detail) {
  console.log('RESULT|' + name + '|' + (ok ? 'ok' : 'ng') + '|' + detail);
}

function escapesPlansDir(p) {
  const abs = path.resolve(String(p));
  return abs !== resolvedPlans && !abs.startsWith(resolvedPlans + path.sep);
}

// Warm-up under the real fs so env / plans-dir resolution is not recorded below.
r.hasCompletionEvidence('outline', 'warmup');

for (const step of ['outline', 'detail']) {
  for (const c of badSids) {
    const name = step + '/' + c.name;
    // Attack setup: create the artifact the traversal would resolve to, so the
    // case would return true if the SESSION_ID_VALID_RE guard were removed.
    const attackPath = path.join(plansDir, c.sid + '-' + step + '.md');
    // Never write outside the mktemp sandbox, whatever the traversal resolves to.
    if (!path.resolve(attackPath).startsWith(path.resolve(sandboxRoot) + path.sep)) {
      emit(name, false, 'attack path escapes the sandbox, refusing to write: ' + attackPath);
      continue;
    }
    try {
      fs.mkdirSync(path.dirname(attackPath), { recursive: true });
      fs.writeFileSync(attackPath, 'planted');
    } catch (e) {
      emit(name, false, 'attack setup failed (case would be vacuous): ' + e.message);
      continue;
    }

    // Record every path the resolver probes, then assert none escapes PLANS_DIR.
    const seen = [];
    const realExists = fs.existsSync;
    fs.existsSync = function (p) { seen.push(String(p)); return realExists(p); };
    let got, threw = null;
    try { got = r.hasCompletionEvidence(step, c.sid); }
    catch (e) { threw = e && e.message; }
    finally { fs.existsSync = realExists; }

    const escaped = seen.filter(escapesPlansDir);
    if (threw !== null) {
      emit(name, false, 'hasCompletionEvidence threw: ' + threw);
    } else if (got !== false) {
      emit(name, false, 'expected exactly false, got ' + JSON.stringify(got));
    } else if (escaped.length) {
      emit(name, false, 'probed path(s) outside PLANS_DIR: ' + escaped.join(', '));
    } else if (seen.length === 0) {
      emit(name, true, 'false; 0 fs probes (rejected before any path was built)');
    } else {
      emit(name, true, 'false; ' + seen.length + ' fs probe(s), all inside PLANS_DIR');
    }
  }

  // Mutation probe / control: a well-formed sid with the artifact present must
  // return true through the same harness. If this fails, the harness is broken
  // and the false-assertions above are vacuous.
  const goodSid = 'ev23-control-' + step;
  fs.writeFileSync(path.join(plansDir, goodSid + '-' + step + '.md'), 'planted');
  let ctl;
  try { ctl = r.hasCompletionEvidence(step, goodSid); }
  catch (e) { ctl = 'threw: ' + (e && e.message); }
  emit(step + '/control-wellformed-sid', ctl === true,
       'control expects true, got ' + JSON.stringify(ctl));
}
EV23JS

    EV23_OUT=$(WORKFLOW_PLANS_DIR="$EV23_PLANS_N" node "$EV23_JS" "$RESOLVER" "$EV23_PLANS_N" "$(to_node_path "$EV23_TMP")" 2>&1)

    if ! echo "$EV23_OUT" | grep -q '^RESULT|'; then
      fail "WS-EV-23. harness produced no RESULT lines, got: $EV23_OUT"
      rm -rf "$EV23_TMP"
      return 0
    fi

    while IFS='|' read -r tag name verdict detail; do
      [ "$tag" = "RESULT" ] || continue
      if [ "$verdict" = "ok" ]; then
        pass "WS-EV-23 [$name]. $detail"
      else
        fail "WS-EV-23 [$name]. $detail"
      fi
    done <<< "$(echo "$EV23_OUT" | grep '^RESULT|')"

    rm -rf "$EV23_TMP"
}
