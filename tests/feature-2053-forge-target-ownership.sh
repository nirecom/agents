#!/usr/bin/env bash
# Tests: hooks/confirm-forge-target-ownership.js, hooks/confirm-forge-target-ownership/
# Tags: hook, pre-tool-use, github, gh, ownership, security, scope:issue-specific
# Serial: spawns a real hook process per case against PATH-stubbed gh/git fixtures

# Guard under test (#2053): before a `gh` command writes to a GitHub repo, the
# hook asks the user unless EVERY in-scope target is actively proven owned.
# Silent allow is the narrow case; everything else asks. Cases live in
# tests/feature-2053-forge-target-ownership/ (rules/coding/file-split.md).

# Layer TL2: real hook process, real JSON stdin, real git fixtures, `gh` stubbed
# on PATH — no network. TL3 gap (category hook-registration) — that Claude Code
# dispatches it and honours `ask`: tests/TL3-hook-forge-target-ownership.sh.

set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PARTS_DIR="$AGENTS_DIR/tests/feature-2053-forge-target-ownership"
HOOK="$AGENTS_DIR/hooks/confirm-forge-target-ownership.js"
RWT="$AGENTS_DIR/bin/run-with-timeout.sh"

PASS=0; FAIL=0; SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1 — $2"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

npath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

# Round-2 C11: "gh is missing" must mean gh and ONLY gh is missing. Replacing
# PATH with an empty directory also removes bash (the `#!/usr/bin/env bash`
# timeout wrapper) and node, so the hook cannot start and the harness reports a
# crash where it meant to report a verdict. This keeps every PATH entry that
# carries no gh, so the interpreter chain survives and only gh disappears.
path_without_gh() {
    local out="" d
    local OLDIFS="$IFS"; IFS=:
    for d in $PATH; do
        [ -z "$d" ] && continue
        if [ -x "$d/gh" ] || [ -x "$d/gh.exe" ]; then continue; fi
        out="${out:+$out:}$d"
    done
    IFS="$OLDIFS"
    printf '%s' "$out"
}

BASE="$(mktemp -d)"
trap 'rm -rf "$BASE"' EXIT

# Fixture isolation (rules/test/fixture-isolation.md): both dirs are pinned into
# the temp tree and the inherited session ids are dropped, so nothing the hook
# writes can reach the developer's real workflow state.
export CLAUDE_WORKFLOW_DIR="$BASE/workflow"
export WORKFLOW_PLANS_DIR="$BASE/plans"
unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID
mkdir -p "$CLAUDE_WORKFLOW_DIR" "$WORKFLOW_PLANS_DIR"

# C4 (config-dependent branches, skills/_shared/test-design.md): every variable
# the guard branches on is a variable the DEVELOPER's shell may already export.
# An ambient GH_REPO or GH_TOKEN would silently flip a verdict here, so the
# baseline is pinned to "none of them set" and each case sets only its own.
# GH_AMBIENT is the SSOT for that list; _dispatch strips it on every invocation
# so a leak cannot survive even inside a case that forgot reset_env.
GH_AMBIENT=(GH_REPO GH_HOST GH_TOKEN GITHUB_TOKEN GH_CONFIG_DIR
            GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN GH_PATH GH_FORCE_TTY)
unset "${GH_AMBIENT[@]}"
ENV_UNSET=()
for _v in "${GH_AMBIENT[@]}"; do ENV_UNSET+=(-u "$_v"); done
unset _v

MOCKBIN="$BASE/bin"; mkdir -p "$MOCKBIN"
GH_LOG="$BASE/gh.log"
OWNER="testowner"          # the authenticated login the gh stub reports
FOREIGN="someoneelse"

# --- gh stub -----------------------------------------------------------------
# Records every invocation, then answers `api user` / `api repos/<o>/<r>` from
# env knobs. It never performs network I/O, so no case can reach GitHub.
#
# Round-2 C8: GH_STUB_USER_RAW / GH_STUB_REPO_RAW override the response BODY
# verbatim while keeping exit 0, which is the shape a hostile-but-successful
# probe answer takes. `+x` (not `:-`) is deliberate: the empty string is itself
# one of the values under test, so "set to empty" must differ from "unset".
cat > "$MOCKBIN/gh" <<'GHSTUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${GH_STUB_LOG:-/dev/null}"
[ -n "${GH_STUB_SLEEP:-}" ] && sleep "$GH_STUB_SLEEP"
[ -n "${GH_STUB_EXIT:-}" ] && exit "$GH_STUB_EXIT"
case "$*" in
    *"api user"*)   if [ -n "${GH_STUB_USER_RAW+x}" ]; then printf '%s' "$GH_STUB_USER_RAW"; else printf '%s\n' "${GH_STUB_LOGIN:-testowner}"; fi ;;
    *"api repos/"*) if [ -n "${GH_STUB_REPO_RAW+x}" ]; then printf '%s' "$GH_STUB_REPO_RAW"; else \
                        printf '{"permissions":{"admin":%s},"fork":%s,"parent":{"full_name":"%s"}}\n' \
                        "${GH_STUB_ADMIN:-false}" "${GH_STUB_FORK:-false}" "${GH_STUB_PARENT:-up/stream}"; fi ;;
    *)              exit 0 ;;
esac
GHSTUB
chmod +x "$MOCKBIN/gh"

# --- git fixture repos -------------------------------------------------------
# The path is normalized once through npath (rules/test/fixture-isolation.md):
# MSYS declines to translate an argument carrying `;` or a shell metacharacter,
# so `git -C /tmp/.../meta$&;x` reaches git.exe verbatim and cannot resolve.
# Normalizing here covers every `git -C` below AND the cwd the hook receives.
mkfixture() { # <name> <origin-url> [extra git config key] [value]
    local raw="$BASE/repos/$1" dir
    mkdir -p "$raw"
    dir="$(npath "$raw")"
    git -C "$dir" init -q 2>/dev/null
    git -C "$dir" config core.hooksPath /dev/null
    git -C "$dir" config user.email test@example.com
    git -C "$dir" config user.name Test
    [ -n "${2:-}" ] && git -C "$dir" remote add origin "$2"
    [ -n "${3:-}" ] && git -C "$dir" config "$3" "$4"
    printf '%s' "$dir"
}

FX_OWNED="$(mkfixture owned "git@github.com:$OWNER/agents.git")"
FX_FOREIGN="$(mkfixture foreign "git@github.com:$FOREIGN/repo.git")"
FX_FORK="$(mkfixture fork "git@github.com:$OWNER/forked.git")"
FX_RESOLVED="$(mkfixture resolved "git@github.com:$OWNER/agents.git" "remote.origin.gh-resolved" "$FOREIGN/other")"
FX_NOREMOTE="$(mkfixture noremote "")"
FX_TWO="$(mkfixture tworemote "git@github.com:$OWNER/agents.git")"
git -C "$FX_TWO" remote add upstream "git@github.com:$FOREIGN/agents.git"
export FX_OWNED FX_FOREIGN FX_FORK FX_RESOLVED FX_NOREMOTE FX_TWO OWNER FOREIGN

# --- stdin payload builder ---------------------------------------------------
cat > "$BASE/mkjson.js" <<'MKJSON'
"use strict";
// argv: <sid> <tool> <cwd|-> <command...>.
//   C3: the real runCommands tool ALWAYS sends tool_input.commands[] — a
//   one-element array is not the same payload as tool_input.command, and a
//   builder that collapses it hides every array-shape defect. So the shape is
//   chosen by the TOOL, never by the element count: runCommands always emits
//   commands[], every other tool emits command.
//   Raw shape: pass "--commands-json" then one JSON array literal to send an
//   array verbatim (empty, null elements, non-strings) with no bash quoting.
//   Session id: "-" omits session_id entirely, "@null" sends JSON null.
const [sid, tool, cwd, ...cmds] = process.argv.slice(2);
const input = {};
if (cmds[0] === "--commands-json") {
  input.commands = JSON.parse(cmds[1]);
} else if (tool === "runCommands") {
  input.commands = cmds;
} else if (cmds.length === 1) {
  input.command = cmds[0];
} else if (cmds.length > 1) {
  input.commands = cmds;
}
if (cwd !== "-") input.cwd = cwd;
const payload = { tool_name: tool, tool_input: input };
if (sid === "@null") payload.session_id = null;
else if (sid !== "-") payload.session_id = sid;
process.stdout.write(JSON.stringify(payload));
MKJSON

cat > "$BASE/decide.js" <<'DECIDE'
"use strict";
// Reads the hook's stdout and prints "<decision>\t<reason>". An empty body or a
// bare {} is the silent path; anything else must be a well-formed ask.
const fs = require("fs");
const raw = fs.readFileSync(process.argv[2], "utf8").trim();
if (raw === "" || raw === "{}") { process.stdout.write("silent\t"); process.exit(0); }
let j;
try { j = JSON.parse(raw); } catch (e) { process.stdout.write("unparsable\t" + raw.slice(0, 200)); process.exit(0); }
const h = j.hookSpecificOutput || {};
if (h.hookEventName !== "PreToolUse") { process.stdout.write("wrong-event\t" + String(h.hookEventName)); process.exit(0); }
if (!h.permissionDecision) { process.stdout.write("silent\t"); process.exit(0); }
process.stdout.write(String(h.permissionDecision) + "\t" + String(h.permissionDecisionReason || ""));
DECIDE

SID_SEQ=0
# run_case <cwd|-> <command...>  — extra env via the CASE_ENV array.
# Sets DECISION, REASON, HOOK_RC, ELAPSED_MS and truncates the gh stub log.
run_case() {
    local cwd="$1"; shift
    _run_payload "Bash" "$cwd" "$@"
}
run_tool_case() { # run_tool_case <tool> <cwd|-> <command...>
    local tool="$1" cwd="$2"; shift 2
    _run_payload "$tool" "$cwd" "$@"
}
_run_payload() {
    local tool="$1" cwd="$2"; shift 2
    SID_SEQ=$((SID_SEQ + 1))
    SID="$(printf 'aaaaaaaa-0000-4000-8000-%012d' "$SID_SEQ")"
    node "$BASE/mkjson.js" "$SID" "$tool" "$cwd" "$@" > "$BASE/in.json"
    : > "$GH_LOG"
    _dispatch
}
# C3: a runCommands payload whose commands[] is given verbatim as JSON.
run_commands_json() { # <cwd|-> <json-array-literal>
    _run_payload "runCommands" "$1" "--commands-json" "$2"
}
# C9: the session id is state-store input, so it needs its own hostile-value
# entry point. SID is set to the literal passed so cache-path assertions can use it.
run_sid_case() { # <session-id|-|@null> <cwd|-> <command...>
    local sid="$1" cwd="$2"; shift 2
    SID="$sid"
    node "$BASE/mkjson.js" "$sid" "Bash" "$cwd" "$@" > "$BASE/in.json"
    : > "$GH_LOG"
    _dispatch
}
# _resume_case reuses the previous session id — the cross-invocation shape that
# Q-13 and the cache cases need (a second hook PROCESS, one session).
resume_case() {
    local cwd="$1"; shift
    node "$BASE/mkjson.js" "$SID" "Bash" "$cwd" "$@" > "$BASE/in.json"
    : > "$GH_LOG"
    _dispatch
}
_dispatch() {
    local t0 t1
    if [ ! -f "$HOOK" ]; then DECISION="hook-absent"; REASON=""; HOOK_RC=127; ELAPSED_MS=0; return; fi
    t0=$(date +%s%3N 2>/dev/null || echo 0)
    # C4: -u strips every ambient gh variable first; CASE_ENV then sets back only
    # what THIS case declared, so the branch under test is the only one armed.
    env "${ENV_UNSET[@]}" PATH="$MOCKBIN:$PATH" GH_STUB_LOG="$GH_LOG" ${CASE_ENV[@]+"${CASE_ENV[@]}"} \
        "$RWT" 20 node "$HOOK" < "$BASE/in.json" > "$BASE/out.txt" 2> "$BASE/err.txt"
    HOOK_RC=$?
    t1=$(date +%s%3N 2>/dev/null || echo 0)
    ELAPSED_MS=$((t1 - t0))
    local d
    d="$(node "$BASE/decide.js" "$BASE/out.txt" 2>/dev/null)"
    DECISION="${d%%	*}"; REASON="${d#*	}"
    [ "$HOOK_RC" -ne 0 ] && DECISION="crash-rc$HOOK_RC"
    return 0
}

CASE_ENV=()
reset_env() { CASE_ENV=(); }
add_env() { CASE_ENV+=("$1"); }

probe_count() { local n; n="$(grep -c -- "$1" "$GH_LOG" 2>/dev/null)"; [ -n "$n" ] || n=0; printf '%s' "$n"; }

# The assertion vocabulary and the unit-probe seam live beside the case blocks.
if [ -f "$PARTS_DIR/harness-asserts.sh" ]; then
    # shellcheck source=/dev/null
    . "$PARTS_DIR/harness-asserts.sh"
else
    echo "FATAL: missing $PARTS_DIR/harness-asserts.sh — no assertions are defined" >&2
    exit 1
fi

if [ ! -f "$HOOK" ]; then
    echo "RED-EXPECTED: $HOOK does not exist yet — every case below reports hook-absent."
fi

# <case-file>:<entry function>. One list, sourced then called in order, so a new
# block is registered in exactly one place.
PARTS=(
    "cases-a-c:run_block_a_c"
    "cases-d-f:run_block_d_f"
    "cases-g-i:run_block_g_i"
    "cases-j:run_block_j"
    "cases-o2-p:run_block_o2_p"
    "cases-q:run_block_q"
    "cases-r-k-l:run_block_r_k_l"
    "cases-m-n:run_block_m_n"
    "cases-c3-array-payloads:run_block_c3"
    "cases-c5-symmetry:run_block_c5"
    "cases-c6-sequencing:run_block_c6"
    "cases-c7-hosts:run_block_c7"
    "cases-c8-api-methods:run_block_c8"
    "cases-c9-session-state:run_block_c9"
    "cases-c10-secrets:run_block_c10"
    "cases-c13-mutation:run_block_c13"
    "cases-c12-c14-static:run_block_c12_c14"
    "cases-c15-edges:run_block_c15"
    "cases-r2-idempotency:run_block_r2_idempotency"
    "cases-r2-auth-cache:run_block_r2_auth_cache"
    "cases-r2-probe-responses:run_block_r2_probe_responses"
    "cases-r2-graphql:run_block_r2_graphql"
)
for _p in "${PARTS[@]}"; do
    if [ -f "$PARTS_DIR/${_p%%:*}.sh" ]; then
        # shellcheck source=/dev/null
        . "$PARTS_DIR/${_p%%:*}.sh"
    else
        fail "part-${_p%%:*}" "missing case file $PARTS_DIR/${_p%%:*}.sh"
    fi
done
for _p in "${PARTS[@]}"; do
    if declare -F "${_p##*:}" >/dev/null 2>&1; then
        "${_p##*:}"
    else
        fail "part-${_p%%:*}" "case file defines no ${_p##*:}"
    fi
done

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
