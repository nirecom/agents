# tests/fix-389-load-env-default-fallback/config-dir-cases.sh
# Tests: hooks/lib/load-env.js, hooks/lib/agents-config-dir.js
# Tags: hook, config-dir, env, resolver, unit, scope:issue-specific
#
# STATUS: T389-7 GREEN (the short-circuit already holds); T389-8 RED until C4
# routes candidates through configDirCandidates(). Sourced by
# tests/fix-389-load-env-default-fallback.sh.
#
# The two #1630 cases: load-env.js must NOT adopt the resolver fall-through
# policy, and it must normalize a Windows-POSIX AGENTS_CONFIG_DIR value.

# T389-7 (#1630 / C4): loadDefaultEnv MUST NOT fall through to the module /
# realpath candidates when an explicit AGENTS_CONFIG_DIR env candidate exists.
#
# This is the machine pin for the deliberate asymmetry recorded in the #1630
# plan: `hooks/lib/agents-config-dir.js` shares configDirCandidates() with
# load-env.js but NOT the selection policy —
#   resolveAgentsConfigDir : env -> module -> realpath   (falls through)
#   loadDefaultEnv         : env only                    (short-circuits)
# Rationale: load-env decides where SETTINGS come from, the resolver decides
# WHO is executing (CPR-SC). Letting load-env fall through would inject the real
# repository's .env into a child process that deliberately pointed at an
# alternate/test config dir.
#
# The module candidate is made non-vacuous by copying load-env.js into a
# throwaway module root that DOES carry a .env with a canary key. If the
# short-circuit is ever removed, the canary lands in process.env and this fails.
#
# Two fixture requirements that only become visible after C4:
#  1. Dependency closure. C4 gives load-env.js a `require("./agents-config-dir")`.
#     Copying the single file would make the copy unloadable, and the case would
#     fail on a require error BEFORE it ever exercised the short-circuit — a
#     failure that looks identical to the real regression. The whole hooks/lib
#     directory is copied instead, so any sibling dependency comes along.
#  2. Marker-valid env candidate. C4's resolver validates a candidate by
#     <d>/hooks/enforce-worktree.js + <d>/bin. If $envdir carried no markers the
#     env candidate would be REJECTED and fall-through would be legitimate,
#     making the assertion vacuous. Both roots therefore carry the markers, and
#     only the module root carries a .env.
run_t389_7() {
    local label="T389-7: explicit AGENTS_CONFIG_DIR does NOT fall through to the module/realpath .env"
    require_source "$LOAD_ENV" "$label" || return
    local root envdir out rc copied_node envdir_node
    root="$(mktemp -d)"
    envdir="$(mktemp -d)"
    mkdir -p "$root/hooks/lib" "$root/bin" "$envdir/hooks" "$envdir/bin"
    cp -r "$(dirname "$LOAD_ENV")/." "$root/hooks/lib/"
    : > "$root/hooks/enforce-worktree.js"
    : > "$envdir/hooks/enforce-worktree.js"
    # Module candidate (path.resolve(__dirname,"..","..")) = $root, and it HAS a .env.
    printf 'T389_7_MODULE_CANARY=from_module_root\n' > "$root/.env"
    # Env candidate = $envdir: marker-valid, deliberately WITHOUT a .env.
    if command -v cygpath >/dev/null 2>&1; then
        copied_node="$(cygpath -m "$root")/hooks/lib/load-env.js"
        envdir_node="$(cygpath -m "$envdir")"
    else
        copied_node="$root/hooks/lib/load-env.js"
        envdir_node="$envdir"
    fi
    out=$(AGENTS_CONFIG_DIR="$envdir_node" run_with_timeout 5 node -e "
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

# T389-8 (#1630 / C4): a Windows-POSIX AGENTS_CONFIG_DIR value (`/c/git/agents`,
# the form Git Bash / MSYS2 hand to Node) must be normalized via normalizeCwd +
# path.resolve before path.join / fs access. RED until C4 routes candidates
# through configDirCandidates(). Guarded win32-only — on POSIX `/c/...` is a
# legitimate absolute path and there is nothing to normalize.
run_t389_8() {
    local label="T389-8: Windows-POSIX AGENTS_CONFIG_DIR value is normalized before the .env read"
    case "$(uname -s 2>/dev/null)" in
        MINGW*|MSYS*|CYGWIN*) ;;
        *) skip "$label (win32-only path form)"; return ;;
    esac
    require_source "$LOAD_ENV" "$label" || return
    command -v cygpath >/dev/null 2>&1 || { skip "$label (cygpath unavailable)"; return; }
    local tmp win out rc
    tmp="$(mktemp -d)"
    printf 'T389_8_KEY=posix_form_ok\n' > "$tmp/.env"
    win="$(cygpath -m "$tmp")"          # C:/Users/.../Temp/tmp.XXXX
    # The POSIX form is derived INSIDE node and assigned to process.env there.
    # Exporting it from bash would be a false green: MSYS2/Git Bash rewrites
    # POSIX-looking env values (and argv) back to Windows form when it spawns a
    # native node.exe, so the very input class under test would never arrive.
    out=$(run_with_timeout 5 node -e "
const win = process.argv[1];                        // C:/Users/.../tmp.XXXX
process.env.AGENTS_CONFIG_DIR = '/' + win[0].toLowerCase() + win.slice(2);
const {loadDefaultEnv} = require('$LOAD_ENV_NODE');
const ok = loadDefaultEnv();
process.stdout.write(JSON.stringify({ok, seen: process.env.AGENTS_CONFIG_DIR, val: process.env.T389_8_KEY || ''}));
" "$win" 2>/dev/null)
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && echo "$out" | grep -q '"val":"posix_form_ok"'; then
        pass "$label"
    else
        fail "$label (rc=$rc, out=$out)"
    fi
}
