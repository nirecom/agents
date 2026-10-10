# tests/hooks/fix-389-load-env-default-fallback/agents-main-root-cases.sh
# Tests: hooks/lib/load-env.js, hooks/lib/script-checkout-root.js
# Tags: hook, agents-main-root, env, resolver, unit, scope:issue-specific
# Sourced by tests/hooks/fix-389-load-env-default-fallback.sh. load-env reads AGENTS_MAIN_ROOT
# itself (settings); the resolver has no environment candidate — see both modules' headers.

# T389-7: a set AGENTS_MAIN_ROOT is the ONLY settings source. load-env.js runs from a
# throwaway copy of hooks/lib (the whole directory, so its requires resolve) whose own
# root carries a canary .env; the variable names a second root without one.
run_t389_7() {
    local label="T389-7: explicit AGENTS_MAIN_ROOT does NOT fall through to the module/realpath .env"
    require_source "$LOAD_ENV" "$label" || return
    local root envdir out rc copied_node envdir_node
    root="$(mktemp -d "$_ISOLATION_TMP_ROOT/t389-7-module.XXXXXX")"
    envdir="$(mktemp -d "$_ISOLATION_TMP_ROOT/t389-7-main-root.XXXXXX")"
    mkdir -p "$root/hooks/lib" "$root/bin" "$envdir/hooks" "$envdir/bin"
    cp -r "$(dirname "$LOAD_ENV")/." "$root/hooks/lib/"
    : > "$root/hooks/enforce-worktree.js"
    : > "$envdir/hooks/enforce-worktree.js"
    # The copy's own checkout is $root (both markers, so it would be adopted), and it HAS a .env.
    printf 'T389_7_MODULE_CANARY=from_module_root\n' > "$root/.env"
    # AGENTS_MAIN_ROOT = $envdir: an existing directory, deliberately WITHOUT a .env.
    if command -v cygpath >/dev/null 2>&1; then
        copied_node="$(cygpath -m "$root")/hooks/lib/load-env.js"
        envdir_node="$(cygpath -m "$envdir")"
    else
        copied_node="$root/hooks/lib/load-env.js"
        envdir_node="$envdir"
    fi
    out=$(AGENTS_MAIN_ROOT="$envdir_node" run_with_timeout 5 node -e "
const {loadDefaultEnv} = require('$copied_node');
const ok = loadDefaultEnv();
process.stdout.write(JSON.stringify({ok, canary: process.env.T389_7_MODULE_CANARY || ''}));
" 2>/dev/null)
    rc=$?
    rm -rf "$root" "$envdir"
    if [ $rc -ne 0 ]; then
        fail "$label (node exited rc=$rc, out=$out)"
        return
    fi
    if ! echo "$out" | grep -q '"ok":false'; then
        fail "$label (expected ok=false — loadDefaultEnv fell through to another candidate; out=$out)"
        return
    fi
    if ! echo "$out" | grep -q '"canary":""'; then
        fail "$label (module-root .env leaked into process.env; out=$out)"
        return
    fi
    pass "$label"
}

# T389-8: a Windows-POSIX AGENTS_MAIN_ROOT value (`/c/git/agents`, the form Git Bash /
# MSYS2 hand to Node) is normalized by loadDefaultEnv before the .env read. Guarded
# win32-only — on POSIX `/c/...` is a legitimate absolute path with nothing to normalize.
run_t389_8() {
    local label="T389-8: Windows-POSIX AGENTS_MAIN_ROOT value is normalized before the .env read"
    case "$(uname -s 2>/dev/null)" in
        MINGW*|MSYS*|CYGWIN*) ;;
        *) skip "$label (win32-only path form)"; return ;;
    esac
    require_source "$LOAD_ENV" "$label" || return
    command -v cygpath >/dev/null 2>&1 || { skip "$label (cygpath unavailable)"; return; }
    local tmp win out rc
    tmp="$(mktemp -d "$_ISOLATION_TMP_ROOT/t389-8.XXXXXX")"
    printf 'T389_8_KEY=posix_form_ok\n' > "$tmp/.env"
    win="$(cygpath -m "$tmp")"          # C:/Users/.../Temp/tmp.XXXX
    # The POSIX form is derived INSIDE node and assigned to process.env there.
    # Exporting it from bash would be a false green: MSYS2/Git Bash rewrites
    # POSIX-looking env values (and argv) back to Windows form when it spawns a
    # native node.exe, so the very input class under test would never arrive.
    out=$(run_with_timeout 5 node -e "
const win = process.argv[1];                        // C:/Users/.../tmp.XXXX
process.env.AGENTS_MAIN_ROOT = '/' + win[0].toLowerCase() + win.slice(2);
const {loadDefaultEnv} = require('$LOAD_ENV_NODE');
const ok = loadDefaultEnv();
process.stdout.write(JSON.stringify({ok, seen: process.env.AGENTS_MAIN_ROOT, val: process.env.T389_8_KEY || ''}));
" "$win" 2>/dev/null)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && echo "$out" | grep -q '"val":"posix_form_ok"'; then
        pass "$label"
    else
        fail "$label (rc=$rc, out=$out)"
    fi
}
