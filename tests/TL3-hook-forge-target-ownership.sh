#!/usr/bin/env bash
# Tests: hooks/confirm-forge-target-ownership.js
# Tags: forge-ownership, gh, github, pre-tool-use, hook, security, TL3, run-e2e, scope:issue-specific
#
# Real-wiring seam test (TL3, live claude -p) for confirm-forge-target-ownership.js:
# proves a live session actually routes `gh issue create` to the hook, unlike the
# synthetic-stdin suite tests/feature-2053-forge-target-ownership.sh which proves
# only the DECISION. Fixture design, reachability preflight, and the layered safety
# mitigations that keep this from ever attempting a real network write are
# documented in tests/TL3-hook-forge-target-ownership/rationale.md.

set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# --- skip gates (claude-e2e.md acceptance criteria) --------------------------
if [ ! -x "$AGENTS_DIR/bin/get-config-var" ]; then
    echo "SKIP: bin/get-config-var not found or not executable" >&2; exit 77
fi
if "$AGENTS_DIR/bin/get-config-var" --is-off RUN_TL3 off; then
    echo "SKIP: requires RUN_TL3=on in .env" >&2; exit 77
fi
if ! command -v claude >/dev/null 2>&1; then
    echo "SKIP: claude CLI not found" >&2; exit 77
fi

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1 — $2"; FAIL=$((FAIL + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    elif command -v perl >/dev/null 2>&1; then perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    else "$@"; fi
}
node_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

# C3: every PATH entry that carries a real `gh`, dropped. Prepending the stub
# leaves the authenticated binary one `PATH=` edit away from being reachable;
# removing its directory removes the route itself.
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

MAIN="$BASE/main"; REPO="$BASE/wt"; WFDIR="$BASE/workflow"; PLANSDIR="$BASE/plans"
MOCKBIN="$BASE/bin"; GHCONFIG="$BASE/ghconfig"
mkdir -p "$MAIN" "$WFDIR" "$PLANSDIR" "$MOCKBIN" "$GHCONFIG"
GH_LOG="$BASE/gh-invocations.log"; : > "$GH_LOG"
GH_ENV_LOG="$BASE/gh-env.log"; : > "$GH_ENV_LOG"
GUARD="confirm-forge-target-ownership.js"

OWNER="tl3-owner"
# Mitigation (a): a repo name that cannot exist under any real login.
OWNED_REPO="tl3-nonexistent-repo-2053"
FOREIGN="tl3-foreign-org"
BRANCH="fix/2053-tl3-probe"

# --- C1 preflight: the production registration itself ------------------------
# These run against the REAL settings.json, before any process is spawned. Every
# live assertion below is downstream of them: an unregistered guard cannot be
# dispatched, so reporting the registration first names the actual defect.
SETTINGS_REAL="$AGENTS_DIR/settings.json"
REG_MATCHER="$(node -e '
    const s = require(process.argv[1]);
    const hit = (s.hooks && s.hooks.PreToolUse || []).filter(e =>
        (e.hooks || []).some(h => String(h.command).includes("confirm-forge-target-ownership")));
    process.stdout.write(hit.map(e => e.matcher).join(";"));
' "$(node_path "$SETTINGS_REAL")" 2>/dev/null)"

if [ -n "$REG_MATCHER" ]; then
    pass "C1-1 settings.json registers the guard on PreToolUse"
else
    fail "C1-1 settings.json registers the guard on PreToolUse" \
         "no PreToolUse entry in $SETTINGS_REAL runs $GUARD"
fi
MISSING_TOOLS=""
for t in Bash runInTerminal runCommands; do
    case "$REG_MATCHER" in *"$t"*) ;; *) MISSING_TOOLS="$MISSING_TOOLS $t" ;; esac
done
if [ -n "$REG_MATCHER" ] && [ -z "$MISSING_TOOLS" ]; then
    pass "C1-2 the registered matcher covers Bash, runInTerminal and runCommands"
else
    fail "C1-2 the registered matcher covers Bash, runInTerminal and runCommands" \
         "matcher='$REG_MATCHER' missing:${MISSING_TOOLS:- (not registered)}"
fi

# --- fixture: a MANAGED LINKED WORKTREE (round-2 C1) -------------------------
# `git init` alone produces a main checkout, which handle-bash-write.js refuses a
# bare `gh issue create` from. A linked worktree is the sanctioned shape, so the
# guard gets its turn to decide instead of never being reached.
git -C "$MAIN" init -q
git -C "$MAIN" config user.email "test@example.com"
git -C "$MAIN" config user.name "Test"
git -C "$MAIN" config core.hooksPath /dev/null
git -C "$MAIN" config commit.gpgsign false
git -C "$MAIN" symbolic-ref HEAD refs/heads/main >/dev/null 2>&1
git -C "$MAIN" commit -q --allow-empty --no-verify -m init >/dev/null 2>&1
git -C "$MAIN" remote add origin "https://github.com/$OWNER/$OWNED_REPO.git"
git -C "$MAIN" worktree add -q -b "$BRANCH" "$REPO" >/dev/null 2>&1

if [ ! -d "$REPO" ]; then
    echo "SKIP: git worktree add failed — the sanctioned fixture shape is unavailable here" >&2
    exit 77
fi
mkdir -p "$REPO/.claude"
git -C "$REPO" config core.hooksPath /dev/null

# The fixture's shape is the premise of C1-P1/P2, so assert it directly rather
# than trusting `worktree add` to have done what it says.
FX_GITDIR="$(git -C "$REPO" rev-parse --git-dir 2>/dev/null)"
FX_BRANCH="$(git -C "$REPO" rev-parse --abbrev-ref HEAD 2>/dev/null)"
case "$FX_GITDIR" in
    */worktrees/*)
        if [ "$FX_BRANCH" = "$BRANCH" ]; then
            pass "C1-9 the fixture is a linked worktree on $BRANCH (the sanctioned shape)"
        else
            fail "C1-9 the fixture is a linked worktree on $BRANCH" "branch is '$FX_BRANCH'"
        fi ;;
    *)  fail "C1-9 the fixture is a linked worktree on $BRANCH" \
             "git-dir='$FX_GITDIR' — still a main checkout, the worktree gate preempts every turn" ;;
esac

# --- C3: the turn's PATH, and the proof that it carries exactly one gh --------
NOGH_PATH="$(path_without_gh)"
TURN_PATH="$MOCKBIN:$NOGH_PATH"
for _need in claude node git bash; do
    if ! PATH="$TURN_PATH" command -v "$_need" >/dev/null 2>&1; then
        echo "SKIP: '$_need' shares a directory with gh — cannot isolate gh without breaking the harness" >&2
        exit 77
    fi
done
# The two C3 resolution proofs are asserted BELOW, immediately after the stub
# file exists — `command -v` cannot resolve a stub that has not been written yet.

# --- mock gh (round-2 C4): the SAME argv/output contract as the TL2 stub ------
# TL2 models `gh api user --jq .login` as PLAIN LOGIN TEXT and `gh api
# repos/<o>/<r>` as a permissions object. The old TL3 stub answered `api user`
# with {"login":...} and served `repo view`, so the two layers demanded
# contradictory parsing from one implementation. This stub reproduces the TL2
# contract verbatim; C4-1..C4-3 pin that it still does.
cat > "$MOCKBIN/gh" <<GHMOCK
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$GH_LOG"
# C3: record what the credential environment actually looked like AT the point a
# real gh would have used it. Assertions read this instead of trusting the setup.
printf 'GH_TOKEN=%s|GITHUB_TOKEN=%s|GH_ENTERPRISE_TOKEN=%s|GITHUB_ENTERPRISE_TOKEN=%s|GH_HOST=%s|GH_CONFIG_DIR=%s\n' \\
    "\${GH_TOKEN-<unset>}" "\${GITHUB_TOKEN-<unset>}" "\${GH_ENTERPRISE_TOKEN-<unset>}" \\
    "\${GITHUB_ENTERPRISE_TOKEN-<unset>}" "\${GH_HOST-<unset>}" "\${GH_CONFIG_DIR-<unset>}" >> "$GH_ENV_LOG"
case "\$*" in
    *"api user"*)   printf '%s\n' "$OWNER" ;;
    *"api repos/"*) printf '{"permissions":{"admin":false},"fork":false,"parent":{"full_name":"up/stream"}}\n' ;;
    *"issue create"*) echo "STUB: refusing to file an issue (TL3 safety)" >&2; exit 1 ;;
    *) exit 0 ;;
esac
exit 0
GHMOCK
chmod +x "$MOCKBIN/gh"

# C3: with the stub in place, prove the turn PATH carries exactly one gh — the
# stub — and that the authenticated real gh is not reachable behind it.
GH_RESOLVED="$(PATH="$TURN_PATH" command -v gh 2>/dev/null)"
if [ "$GH_RESOLVED" = "$MOCKBIN/gh" ]; then
    pass "C3-1 gh resolves to the stub on the turn PATH"
else
    fail "C3-1 gh resolves to the stub on the turn PATH" "resolved to '$GH_RESOLVED'"
fi
OTHER_GH=""
_oldifs="$IFS"; IFS=:
for _d in $TURN_PATH; do
    [ "$_d" = "$MOCKBIN" ] && continue
    { [ -x "$_d/gh" ] || [ -x "$_d/gh.exe" ]; } && OTHER_GH="$OTHER_GH $_d"
done
IFS="$_oldifs"
if [ -z "$OTHER_GH" ]; then
    pass "C3-2 no other gh executable is reachable from the turn PATH"
else
    fail "C3-2 no other gh executable is reachable from the turn PATH" \
         "an authenticated gh remains at:$OTHER_GH"
fi

# C4: the contract itself, checked both ways — against the running stub and
# against the TL2 file that defines it, so a change to either side is visible.
STUB_USER="$("$MOCKBIN/gh" api user --jq .login 2>/dev/null)"
if [ "$STUB_USER" = "$OWNER" ]; then
    pass "C4-1 the stub answers 'api user --jq .login' with the bare login (TL2 contract)"
else
    fail "C4-1 the stub answers 'api user --jq .login' with the bare login (TL2 contract)" \
         "got [$STUB_USER], want [$OWNER]"
fi
case "$STUB_USER" in
    *"{"*|*'login":'*)
        fail "C4-2 the stub does not emit a JSON object where TL2 models plain text" \
             "got JSON: $STUB_USER" ;;
    *)  pass "C4-2 the stub does not emit a JSON object where TL2 models plain text" ;;
esac
TL2_FILE="$AGENTS_DIR/tests/feature-2053-forge-target-ownership.sh"
if grep -q '\*"api user"\*).*GH_STUB_LOGIN' "$TL2_FILE" 2>/dev/null \
   && ! grep -q '\*"api user"\*).*{"login"' "$TL2_FILE" 2>/dev/null; then
    pass "C4-3 the TL2 stub still models the same plain-login contract"
else
    fail "C4-3 the TL2 stub still models the same plain-login contract" \
         "the two layers have diverged again — see the api-user arm in $TL2_FILE"
fi
: > "$GH_LOG"; : > "$GH_ENV_LOG"

# The shim records (hook, rc, payload, output) for every dispatch and passes the
# hook's stdout and exit code through untouched, so the chain behaves exactly as
# it does in production — including a deny, which is one of the things under test.
# TL3_HOOK_LOG is set per turn by run_turn, which makes a dispatch attributable
# to the turn that caused it.
cat > "$MOCKBIN/hookwrap.sh" <<'WRAP_EOF'
#!/usr/bin/env bash
name="$1"; shift
payload="$(cat)"
out="$(printf '%s' "$payload" | eval "$@" 2>/dev/null)"
rc=$?
printf '%s\t%s\t%s\t%s\n' "$name" "$rc" \
    "$(printf '%s' "$payload" | tr '\n\t' '  ')" \
    "$(printf '%s' "$out" | tr '\n\t' '  ')" >> "${TL3_HOOK_LOG:-/dev/null}"
printf '%s' "$out"
exit $rc
WRAP_EOF
chmod +x "$MOCKBIN/hookwrap.sh"

# Generate the fixture chain from production. Only Bash-matching entries are kept
# (the others cannot fire for a Bash tool call anyway), in production order, each
# command rewritten to run under the shim with $AGENTS_CONFIG_DIR already resolved.
node -e '
    const fs = require("fs");
    const [settingsPath, agentsDir, wrapSh, outPath] = process.argv.slice(1);
    const s = require(settingsPath);
    const entries = (s.hooks && s.hooks.PreToolUse || []).filter(e =>
        /(^|\|)Bash(\||$)/.test(String(e.matcher || "")));
    const q = (v) => JSON.stringify(String(v));
    const wrapped = entries.map(e => ({
        matcher: e.matcher,
        hooks: (e.hooks || []).map(h => {
            const real = String(h.command).split("$AGENTS_CONFIG_DIR").join(agentsDir);
            const name = (real.match(/([\w.-]+\.js)/) || [, real])[1];
            return { type: "command", timeout: h.timeout || 20,
                     command: "bash " + q(wrapSh) + " " + q(name) + " " + q(real) };
        })
    }));
    fs.writeFileSync(outPath, JSON.stringify({ hooks: { PreToolUse: wrapped } }, null, 2));
' "$(node_path "$SETTINGS_REAL")" "$(node_path "$AGENTS_DIR")" \
  "$(node_path "$MOCKBIN/hookwrap.sh")" "$REPO/.claude/settings.json"

if grep -qF "$GUARD" "$REPO/.claude/settings.json" 2>/dev/null; then
    pass "C1-4 the generated fixture chain carries the guard from production"
else
    fail "C1-4 the generated fixture chain carries the guard from production" \
         "the guard's production entry does not match Bash, so no live turn can reach it"
fi

unset CLAUDECODE
unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID

CMD_FOREIGN="gh issue create --repo $FOREIGN/some-repo --title TOKEN --body TOKEN"
CMD_OWNED="gh issue create --title TOKEN --body TOKEN"

# --- C1-P: the EXISTING gate permits the fixture -----------------------------
# Run enforce-worktree.js itself over the two exact payloads, from the fixture's
# cwd, before any agent exists. A block here means the live turns could never
# reach the guard and every ask/allow verdict below would be vacuous — which is
# exactly the defect round-2 C1 reported. Note the gate signals a block through
# stdout JSON while still exiting 0, so rc alone would miss it.
EW_HOOK="$AGENTS_DIR/hooks/enforce-worktree.js"
gate_verdict() { # <command> -> "block" | "permit" | "crash:<rc>" | "absent"
    [ -f "$EW_HOOK" ] || { printf 'absent'; return; }
    local out rc
    out="$(cd "$REPO" && printf '{"tool_name":"Bash","session_id":"tl3gate","cwd":"%s","tool_input":{"command":"%s"}}' \
             "$(node_path "$REPO")" "$1" \
           | CLAUDE_WORKFLOW_DIR="$WFDIR" WORKFLOW_PLANS_DIR="$PLANSDIR" \
             AGENTS_CONFIG_DIR="$(node_path "$AGENTS_DIR")" PATH="$TURN_PATH" \
             run_with_timeout 20 node "$EW_HOOK" 2>/dev/null)"
    rc=$?
    [ "$rc" -ne 0 ] && { printf 'crash:%s' "$rc"; return; }
    case "$out" in *'"decision"'*'"block"'*) printf 'block'; return ;; esac
    printf 'permit'
}
GATE_F="$(gate_verdict "$CMD_FOREIGN")"
GATE_O="$(gate_verdict "$CMD_OWNED")"
if [ "$GATE_F" = "permit" ]; then
    pass "C1-P1 enforce-worktree.js permits the foreign-target fixture command"
else
    fail "C1-P1 enforce-worktree.js permits the foreign-target fixture command" \
         "gate verdict=$GATE_F — the guard would never be reached, so turn A proves nothing"
fi
if [ "$GATE_O" = "permit" ]; then
    pass "C1-P2 enforce-worktree.js permits the owned-target fixture command"
else
    fail "C1-P2 enforce-worktree.js permits the owned-target fixture command" \
         "gate verdict=$GATE_O — turn B (the control) would prove nothing"
fi

HOOK="$AGENTS_DIR/hooks/$GUARD"
if [ -f "$HOOK" ] && [ -n "$REG_MATCHER" ]; then
    pass "C1-3 the guard exists and is registered, so the live turns can run"
else
    fail "C1-3 the guard exists and is registered, so the live turns can run" \
         "RED-EXPECTED — hook file present=$([ -f "$HOOK" ] && echo yes || echo no), registered=$([ -n "$REG_MATCHER" ] && echo yes || echo no)"
    echo ""
    echo "Results: $PASS passed, $FAIL failed (live turns skipped: nothing to dispatch)"
    exit 1
fi

# run_turn <session-id> <token> <prompt> — sets TURN_RC and TURN_LOG.
# C3: `env -u` strips every credential variable the developer's shell may export,
# and GH_CONFIG_DIR points at an empty temp dir, so no hosts.yml is readable.
run_turn() {
    TURN_LOG="$BASE/hooks-$2.log"; : > "$TURN_LOG"
    ( cd "$REPO" && \
      env -u GH_TOKEN -u GITHUB_TOKEN -u GH_ENTERPRISE_TOKEN -u GITHUB_ENTERPRISE_TOKEN \
          -u GH_HOST -u GH_REPO -u GH_PATH -u GH_FORCE_TTY \
      PATH="$TURN_PATH" \
      GH_CONFIG_DIR="$GHCONFIG" \
      CLAUDE_WORKFLOW_DIR="$WFDIR" \
      WORKFLOW_PLANS_DIR="$PLANSDIR" \
      TL3_HOOK_LOG="$TURN_LOG" \
      AGENTS_CONFIG_DIR="$(node_path "$AGENTS_DIR")" \
      run_with_timeout 180 claude -p "$3" \
        --session-id "$1" \
        --setting-sources project \
        --dangerously-skip-permissions \
        --output-format json \
      >"$BASE/$2.out" 2>&1 )
    TURN_RC=$?
}

# Each turn carries its own token, in the command itself, so a dispatch found in
# the log can be attributed to exactly one turn. Without it, one turn retrying
# twice and one turn never running look the same in aggregate.
TOK_A="tl3probeA$$"
TOK_B="tl3probeB$$"

echo "=== A: a foreign target the session cannot prove it owns ==="
run_turn "bbbbbbbb-0000-4000-8000-000000000001" "$TOK_A" \
  "Using the Bash tool, run exactly this one command and report its output verbatim: ${CMD_FOREIGN//TOKEN/$TOK_A}"
RC_A=$TURN_RC; LOG_A="$TURN_LOG"

echo "=== B: the control — the fixture's own origin, provably owned ==="
run_turn "bbbbbbbb-0000-4000-8000-000000000002" "$TOK_B" \
  "Using the Bash tool, run exactly this one command in the current repository and report its output verbatim: ${CMD_OWNED//TOKEN/$TOK_B}"
RC_B=$TURN_RC; LOG_B="$TURN_LOG"

echo ""
echo "=== assertions ==="

ASSERTIONS="$(dirname "$0")/TL3-hook-forge-target-ownership/assertions.sh"
if [ -f "$ASSERTIONS" ]; then
    # shellcheck source=/dev/null
    . "$ASSERTIONS"
else
    fail "assertion part file present" "missing: $ASSERTIONS — the turns ran but nothing read them"
fi

git -C "$MAIN" worktree remove --force "$REPO" >/dev/null 2>&1 || true

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
