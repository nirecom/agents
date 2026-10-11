# tests/hooks/feature-1226-load-env-os-blocks/default-env-file-path-cases.sh
# Tests: hooks/lib/load-env.js
# Tags: load-env, resolver, unit, scope:issue-specific, plan-sync
# CV-6, DP-1..3 (#2513): resolveConfigVar reports where its value came from, and
# defaultEnvFilePath() names the one .env that readDefaultEnvFile reads and plan-sync-init
# writes. RED until load-env.js gains both. Sourced by ../feature-1226-load-env-os-blocks.sh
# (its pass/fail/run_with_timeout/LOAD_ENV/LOAD_ENV_NODE and the readonly $_DP_TMP_ROOT).

# The dispatcher pins nothing, so this file pins both state dirs itself (fixture-isolation.md).
export WORKFLOW_STATE_DIR="$_DP_TMP_ROOT/state" WORKFLOW_PLANS_DIR="$_DP_TMP_ROOT/plans"
RWT_DP="$SCRIPT_CHECKOUT_ROOT/bin/run-with-timeout.sh"

# Every fixture dir lives under the dispatcher's readonly temp root (one EXIT trap).
_dp_tmp() { mktemp -d "$_DP_TMP_ROOT/dp.XXXXXX"; }

_dp_n() {
    if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi
}

# _dp_node <cwd> <script> [VAR=val...] — neutral CWD that is also the agents main root
# (its .env is the global one); CLAUDE_PROJECT_DIR and session ids unset. Prints stdout.
_dp_node() {
    local cwd="$1" script="$2"; shift 2
    (cd "$cwd" || exit 1
     env -u CLAUDE_PROJECT_DIR -u CLAUDE_CODE_SESSION_ID "AGENTS_MAIN_ROOT=$(_dp_n "$cwd")" "$@" \
         bash "$RWT_DP" 5 node -e "$script" 2>/dev/null)
}

# _dp_probe <cwd> <load-env.js node path> <script> — AGENTS_MAIN_ROOT unset; prints stdout.
_dp_probe() {
    local cwd="$1" module="$2" script="$3"
    (cd "$cwd" || exit 1
     run_with_timeout 5 env -u AGENTS_MAIN_ROOT -u CLAUDE_PROJECT_DIR -u CLAUDE_CODE_SESSION_ID \
         node -e "const le = require('$module');
if (typeof le.defaultEnvFilePath !== 'function') { process.stdout.write('NOFN'); process.exit(0); }
const path = require('path'); const fs = require('fs');
$script" 2>/dev/null)
}

# _dp_copy_lib — a throwaway checkout root holding a copy of hooks/lib and no .env;
# prints the root (same technique as fix-389 T389-3).
_dp_copy_lib() {
    local root
    root="$(mktemp -d "$_DP_TMP_ROOT/dp-module.XXXXXX")"
    mkdir -p "$root/hooks/lib"
    cp -r "$(dirname "$LOAD_ENV")/." "$root/hooks/lib/" || return 1
    printf '%s' "$root"
}

# CV-6: source is "export" for a non-empty export (with or without repoRoot), "env-file"
# for a .env or repoRoot .env.local value, "default" otherwise (an empty export included).
run_cv_6() {
    local label="CV-6: resolveConfigVar returns source export / env-file / default"
    local tmp repo repo_n out rc
    tmp="$(_dp_tmp)"; repo="$(_dp_tmp)"
    printf 'CV6_FILE=cv6_fromfile\nCV6_EXP=cv6_fromfile\n' > "$tmp/.env"
    printf 'CV6_LOCAL=cv6_local\n' > "$repo/.env.local"
    repo_n="$(_dp_n "$repo")"
    out=$(_dp_node "$tmp" "const le = require('$LOAD_ENV_NODE');
if (typeof le.resolveConfigVar !== 'function') { process.stdout.write('NOFN'); process.exit(0); }
const s = (r) => r.value + '@' + (r.source === undefined ? 'NOSOURCE' : r.source);
process.stdout.write([
  s(le.resolveConfigVar('CV6_EXP', 'd')),
  s(le.resolveConfigVar('CV6_EXP', 'd', { repoRoot: '$repo_n' })),
  s(le.resolveConfigVar('CV6_FILE', 'd')),
  s(le.resolveConfigVar('CV6_LOCAL', 'd', { repoRoot: '$repo_n' })),
  s(le.resolveConfigVar('CV6_ABSENT', 'cv6_dflt')),
  s(le.resolveConfigVar('CV6_ABSENT')),
  s(le.resolveConfigVar('CV6_EMPTY', 'cv6_dflt')),
].join(','));" CV6_EXP=cv6_fromenv CV6_FILE= CV6_LOCAL= CV6_ABSENT= CV6_EMPTY=)
    rc=$?
    rm -rf "$tmp" "$repo"
    local want="cv6_fromenv@export,cv6_fromenv@export,cv6_fromfile@env-file,cv6_local@env-file,cv6_dflt@default,@default,cv6_dflt@default"
    if [ $rc -eq 0 ] && [ "$out" = "$want" ]; then pass "$label"
    else fail "$label (rc=$rc want=$want out=$out — source not implemented yet?)"; fi
}

# DP-1: AGENTS_MAIN_ROOT set → <root>/.env, also when the file does not exist yet (the
# write target is the first read candidate).
run_dp_1() {
    local label="DP-1: defaultEnvFilePath() is AGENTS_MAIN_ROOT/.env, present or absent"
    local tmp out rc
    tmp="$(_dp_tmp)"
    out=$(_dp_node "$tmp" "const le = require('$LOAD_ENV_NODE');
if (typeof le.defaultEnvFilePath !== 'function') { process.stdout.write('NOFN'); process.exit(0); }
const path = require('path'); const fs = require('fs');
const want = path.resolve(process.env.AGENTS_MAIN_ROOT, '.env');
const a = path.resolve(le.defaultEnvFilePath());
fs.writeFileSync(want, 'DP1=x\n');
const b = path.resolve(le.defaultEnvFilePath());
process.stdout.write(a === want && b === want ? 'OK' : 'absent=' + a + ' present=' + b);")
    rc=$?
    rm -rf "$tmp"
    if [ $rc -eq 0 ] && [ "$out" = "OK" ]; then pass "$label"
    else fail "$label (rc=$rc out=$out — defaultEnvFilePath not exported yet?)"; fi
}

# DP-2: AGENTS_MAIN_ROOT unset and no .env anywhere → the module-relative root (two
# levels above hooks/lib), the first read candidate.
run_dp_2() {
    local label="DP-2: defaultEnvFilePath() falls back to the checkout root two levels above hooks/lib"
    local root cwd out rc
    root="$(_dp_copy_lib)" || { fail "$label (fixture: could not copy hooks/lib)"; return; }
    cwd="$(_dp_tmp)"
    out=$(_dp_probe "$cwd" "$(_dp_n "$root")/hooks/lib/load-env.js" "
const want = path.resolve('$(_dp_n "$root")', '.env');
const got = path.resolve(le.defaultEnvFilePath());
process.stdout.write(got === want ? 'OK' : 'got=' + got);")
    rc=$?
    rm -rf "$root" "$cwd"
    if [ $rc -eq 0 ] && [ "$out" = "OK" ]; then pass "$label"
    else fail "$label (rc=$rc out=$out — defaultEnvFilePath not exported yet?)"; fi
}

# DP-3: a value written to defaultEnvFilePath() is what readDefaultEnvFile() reads back,
# with AGENTS_MAIN_ROOT set and with it unset (the plan-sync-init write/read pairing).
run_dp_3() {
    local label="DP-3: a value written to defaultEnvFilePath() is read back by readDefaultEnvFile()"
    local tmp root cwd rw out1 out2 rc1 rc2
    rw="const p = le.defaultEnvFilePath();
const before = le.readDefaultEnvFile().DP3_KEY || '';
fs.writeFileSync(p, 'DP3_KEY=dp3_written\n');
process.stdout.write(before + '|' + (le.readDefaultEnvFile().DP3_KEY || ''));"
    tmp="$(_dp_tmp)"
    out1=$(_dp_node "$tmp" "const le = require('$LOAD_ENV_NODE');
if (typeof le.defaultEnvFilePath !== 'function') { process.stdout.write('NOFN'); process.exit(0); }
const fs = require('fs');
$rw")
    rc1=$?
    rm -rf "$tmp"
    root="$(_dp_copy_lib)" || { fail "$label (fixture: could not copy hooks/lib)"; return; }
    cwd="$(_dp_tmp)"
    out2=$(_dp_probe "$cwd" "$(_dp_n "$root")/hooks/lib/load-env.js" "$rw")
    rc2=$?
    rm -rf "$root" "$cwd"
    if [ $rc1 -eq 0 ] && [ $rc2 -eq 0 ] && [ "$out1" = "|dp3_written" ] && [ "$out2" = "|dp3_written" ]; then
        pass "$label"
    else
        fail "$label (agents-dir: rc=$rc1 out=$out1; unset: rc=$rc2 out=$out2 — defaultEnvFilePath not exported yet?)"
    fi
}
