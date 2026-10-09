# tests/hooks/fix-389-load-env-default-fallback/resolve-config-var-cases.sh
# Tests: hooks/lib/load-env.js
# Tags: hook, env, load-env, resolver, unit, scope:issue-specific
# CV-1..5 (#2100 Step 8a): RED until load-env.js exports resolveConfigVar.
# Sourced by the fix-389 dispatcher (its pass/fail/require_source/LOAD_ENV_NODE).
# Rule: exported env > (repoRoot ? effective .env : process.env) > default > "".

# _cv_node <cwd> <script> [VAR=val...] — neutral CWD that is also the agents main
# root (its .env is the global one); CLAUDE_PROJECT_DIR and session ids unset.
# Prints stdout; stderr lands in $_CV_ERR.
_CV_ERR=""
RWT_CV="$SCRIPT_CHECKOUT_ROOT/bin/run-with-timeout.sh"
_cv_node() {
    local cwd="$1" script="$2"; shift 2
    local errf out rc cwd_n
    cwd_n="$(_cv_n "$cwd")"
    errf="$(mktemp "$_ISOLATION_TMP_ROOT/cv-err.XXXXXX")"
    out=$(cd "$cwd" && env -u CLAUDE_PROJECT_DIR -u CLAUDE_CODE_SESSION_ID "AGENTS_MAIN_ROOT=$cwd_n" "$@" \
        bash "$RWT_CV" 5 node -e "$script" 2>"$errf")
    rc=$?
    _CV_ERR="$(cat "$errf")"
    rm -f "$errf"
    printf '%s' "$out"
    return $rc
}

# Prints NOFN when the function is absent, so the RED reason is explicit.
_cv_prelude() {
    printf '%s' "const le = require('$LOAD_ENV_NODE');
if (typeof le.resolveConfigVar !== 'function') { process.stdout.write('NOFN'); process.exit(0); }
const out = (r) => process.stdout.write(JSON.stringify(r));
"
}

# Every fixture dir lives under the dispatcher's readonly temp root, so the one EXIT trap
# removes it even when a case returns early.
_cv_tmp() { mktemp -d "$_ISOLATION_TMP_ROOT/cv.XXXXXX"; }

_cv_n() {
    if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi
}

# CV-1: non-empty exported env wins over .env; loadFailed false; value never on stderr.
run_cv_1() {
    local label="CV-1: non-empty process env beats .env (loadFailed=false, value not logged)"
    require_source "$LOAD_ENV" "$label" || return
    local tmp out rc
    tmp="$(_cv_tmp)"
    printf 'CV1_KEY=cv1_fromfile\n' > "$tmp/.env"
    out=$(_cv_node "$tmp" \
        "$(_cv_prelude)out(le.resolveConfigVar('CV1_KEY', 'cv1_dflt'));" \
        AGENTS_HOOK_DEBUG=1 CV1_KEY=cv1_fromenv)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -ne 0 ] || [ "$out" = "NOFN" ]; then fail "$label (rc=$rc out=$out — resolveConfigVar not exported yet?)"; return; fi
    if [ "$out" != '{"value":"cv1_fromenv","loadFailed":false}' ]; then fail "$label (out=$out)"; return; fi
    case "$_CV_ERR" in
        *cv1_fromenv*|*cv1_fromfile*) fail "$label (value leaked to stderr: $_CV_ERR)"; return ;;
    esac
    pass "$label"
}

# CV-2: empty exported env -> .env value; the local .env.local overlay applies.
run_cv_2() {
    local label="CV-2: empty process env falls to .env, local .env.local overlay wins over global"
    require_source "$LOAD_ENV" "$label" || return
    local tmp proj out rc
    tmp="$(_cv_tmp)"; proj="$(_cv_tmp)"
    printf 'CV2_KEY=cv2_fromfile\nCV2_OVL=cv2_global\n' > "$tmp/.env"
    printf 'CV2_OVL=cv2_local\n' > "$proj/.env.local"
    out=$(_cv_node "$tmp" \
        "$(_cv_prelude)out([le.resolveConfigVar('CV2_KEY', 'd'), le.resolveConfigVar('CV2_OVL', 'd')]);" \
        CLAUDE_PROJECT_DIR="$(_cv_n "$proj")" CV2_KEY=)
    rc=$?
    rm -rf "$tmp" "$proj"
    if [ $rc -ne 0 ] || [ "$out" = "NOFN" ]; then fail "$label (rc=$rc out=$out — resolveConfigVar not exported yet?)"; return; fi
    if [ "$out" = '[{"value":"cv2_fromfile","loadFailed":false},{"value":"cv2_local","loadFailed":false}]' ]; then
        pass "$label"
    else
        fail "$label (out=$out)"
    fi
}

# CV-3: opts.repoRoot reads readEffectiveEnvFile(repoRoot); without it the global
# value comes back (negative control); a non-empty exported value still wins.
run_cv_3() {
    local label="CV-3: opts.repoRoot reads that repo's effective .env; exported env still wins"
    require_source "$LOAD_ENV" "$label" || return
    local tmp repo repo_n out rc
    tmp="$(_cv_tmp)"; repo="$(_cv_tmp)"
    printf 'CV3_KEY=cv3_global\n' > "$tmp/.env"
    printf 'CV3_KEY=cv3_repo\n' > "$repo/.env.local"
    repo_n="$(_cv_n "$repo")"
    out=$(_cv_node "$tmp" "$(_cv_prelude)out([
  le.resolveConfigVar('CV3_KEY', 'd', { repoRoot: '$repo_n' }).value,
  le.resolveConfigVar('CV3_KEY', 'd').value,
]);")
    rc=$?
    if [ $rc -ne 0 ] || [ "$out" = "NOFN" ]; then rm -rf "$tmp" "$repo"; fail "$label (rc=$rc out=$out — resolveConfigVar not exported yet?)"; return; fi
    if [ "$out" != '["cv3_repo","cv3_global"]' ]; then rm -rf "$tmp" "$repo"; fail "$label (repoRoot branch: out=$out)"; return; fi
    out=$(_cv_node "$tmp" \
        "$(_cv_prelude)out(le.resolveConfigVar('CV3_KEY', 'd', { repoRoot: '$repo_n' }).value);" \
        CV3_KEY=cv3_env)
    rc=$?
    rm -rf "$tmp" "$repo"
    if [ $rc -eq 0 ] && [ "$out" = '"cv3_env"' ]; then
        pass "$label"
    else
        fail "$label (exported-wins-over-repoRoot: rc=$rc out=$out)"
    fi
}

# CV-4: nothing anywhere -> defaultValue; no default -> "".
run_cv_4() {
    local label="CV-4: unset everywhere returns defaultValue, or \"\" without one"
    require_source "$LOAD_ENV" "$label" || return
    local tmp out rc
    tmp="$(_cv_tmp)"
    printf 'CV4_OTHER=x\n' > "$tmp/.env"
    out=$(_cv_node "$tmp" \
        "$(_cv_prelude)out([le.resolveConfigVar('CV4_ABSENT', 'cv4_dflt'), le.resolveConfigVar('CV4_ABSENT'), le.resolveConfigVar('CV4_ABSENT', '')]);" \
        CV4_ABSENT=)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -ne 0 ] || [ "$out" = "NOFN" ]; then fail "$label (rc=$rc out=$out — resolveConfigVar not exported yet?)"; return; fi
    if [ "$out" = '[{"value":"cv4_dflt","loadFailed":false},{"value":"","loadFailed":false},{"value":"","loadFailed":false}]' ]; then
        pass "$label"
    else
        fail "$label (out=$out)"
    fi
}

# CV-5: loadDefaultEnv throws -> loadFailed=true; exported env or default is used
# and the .env value never appears. The throw is injected by replacing normDir — the
# first call loadDefaultEnv makes on every path, main root set or not — in the require
# cache before load-env.js destructures it.
run_cv_5() {
    local label="CV-5: loadDefaultEnv throwing sets loadFailed=true; exported env or default is used"
    require_source "$LOAD_ENV" "$label" || return
    local tmp script_checkout_root out rc
    tmp="$(_cv_tmp)"
    printf 'CV5_KEY=cv5_fromfile\nCV5_ENV=cv5_fromfile\n' > "$tmp/.env"
    script_checkout_root="${LOAD_ENV_NODE%/load-env.js}/script-checkout-root.js"
    out=$(_cv_node "$tmp" "require('$script_checkout_root').normDir = () => { throw new Error('cv5-injected'); };
$(_cv_prelude)out([le.resolveConfigVar('CV5_KEY', 'cv5_dflt'), le.resolveConfigVar('CV5_ENV', 'cv5_dflt')]);" \
        CV5_KEY= CV5_ENV=cv5_fromenv)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -ne 0 ] || [ "$out" = "NOFN" ]; then fail "$label (rc=$rc out=$out err=$_CV_ERR — resolveConfigVar not exported yet?)"; return; fi
    if [ "$out" = '[{"value":"cv5_dflt","loadFailed":true},{"value":"cv5_fromenv","loadFailed":true}]' ]; then
        pass "$label"
    else
        fail "$label (out=$out)"
    fi
}
