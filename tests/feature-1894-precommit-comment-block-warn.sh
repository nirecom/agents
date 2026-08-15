#!/usr/bin/env bash
# tests/feature-1894-precommit-comment-block-warn.sh
# Tests: hooks/pre-commit, bin/review-comment-block-size
# Tags: comment-block-size, pre-commit, hook, git, block, guard, fail-open, scope:issue-specific, scope:feature-1894, layer:TL2

# Issue #1894 — the hooks/pre-commit comment-block section for
# review-comment-block-size, converted from advisory WARN to a hard BLOCK.
# Filename still says "warn" on purpose: the retire policy keys on the
# feature-<N> prefix and suite identity, not the verdict asserted; renaming
# would detach it from its own history for no behavioural gain.

# What changed: the section now OWNS an exit code. rc 1 means "staged
# content made a comment block worse" and must block the commit; every OTHER
# non-zero rc must fail OPEN (a broken Node install shouldn't brick every
# commit — detail plan S2-5). Tested separately (CPR-SC): (1) the
# two-condition AND guard gating the section; (2) placement BEFORE the
# hook's three unconditional early exits, or it never runs for repos that
# matter; (3) `exit 1` only on rc-1, with _cb_out/_cb_rc pre-initialised so
# `set -euo pipefail` can't abort the clean path; (3b) every SKIPPED result
# on stderr — a silent skip is how a blocking check quietly stops existing;
# (4) a real `git commit` with findings is REJECTED (part 3).

# Kill switch and threshold resolve from the config dir's .env ONLY —
# `COMMENT_BLOCK_ENFORCE=off` / `COMMENT_BLOCK_MAX_LINES=999999` on `git
# commit` are exactly the bypasses this issue closes, so run_precommit /
# run_commit write config into $cfg/.env and keep those names out of the
# child env; *_ambient does both, driving the hostile direction explicitly.
# Dispatcher: harness here, cases in
# tests/feature-1894-precommit-comment-block-warn/*.sh.

# TL3 gap: installer deployment into a real core.hooksPath (part 3 only
# proves git fires the hook for a self-pointed fixture repo); real `gh api`
# repo-visibility resolution (represented by its non-GitHub-remote sibling);
# interaction with the Claude Code PreToolUse chain (fixtures pin
# ENFORCE_WORKTREE=off); whether rules/coding/file-split.md renders as the
# installed rule a session loads. Mitigation: WORKFLOW_USER_VERIFIED
# preflight (bin/check-verification-gate.sh, category hook-registration).

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# The worktree copy is the state under test — never the deployed ~/.claude one.
PRECOMMIT="$AGENTS_DIR/hooks/pre-commit"
LOCAL_SCANNER="$AGENTS_DIR/bin/review-comment-block-size"
FILE_SPLIT_RULE="$AGENTS_DIR/rules/coding/file-split.md"
CASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/feature-1894-precommit-comment-block-warn"

PASS=0
FAIL=0
SKIP=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; [ -n "${2:-}" ] && echo "    detail: $2"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then pass "$name"
    else fail "$name" "want=$(printf '%q' "$want") got=$(printf '%q' "$got")"; fi
}
assert_contains() {
    local name="$1" needle="$2" hay="$3"
    if printf '%s\n' "$hay" | grep -qF -- "$needle"; then pass "$name"
    else fail "$name" "missing $(printf '%q' "$needle") in: $hay"; fi
}
assert_absent() {
    local name="$1" needle="$2" hay="$3"
    if printf '%s\n' "$hay" | grep -qF -- "$needle"; then
        fail "$name" "unexpected $(printf '%q' "$needle") in: $hay"
    else pass "$name"; fi
}

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

if [ ! -f "$PRECOMMIT" ]; then
    echo "FAIL: hooks/pre-commit not found at $PRECOMMIT"
    exit 1
fi

TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# Fixture isolation (rules/test/fixture-isolation.md): dual-pin both dirs and
# drop any inherited session id so the hook cannot touch real session state.
CLAUDE_WORKFLOW_DIR="$TMPDIR_BASE/workflow-state"
WORKFLOW_PLANS_DIR="$TMPDIR_BASE/plans"
mkdir -p "$CLAUDE_WORKFLOW_DIR" "$WORKFLOW_PLANS_DIR"
export CLAUDE_WORKFLOW_DIR WORKFLOW_PLANS_DIR
unset CLAUDE_SESSION_ID 2>/dev/null || true
unset CLAUDE_CODE_SESSION_ID 2>/dev/null || true

BLOCK_LINE='BLOCK: sample.js — longest comment run 10 → 23 lines (over-threshold runs 1 → 2)'
SCANNER_HEADER='## Comment-block Size Review: PERFORMED (staged mode)'
SKIPPED_HEADER='## Comment-block Size Review: SKIPPED (node runtime unavailable)'
ERR_LINE='ERROR: sample.js — baseline blob unreadable'
# The committer-facing verdict. Matched as a prefix, not verbatim: the exact
# sentence is the hook author's to word, but "Commit blocked" is the established
# shape every other blocking section in this hook already uses (CPR-ORTH).
BLOCK_NOTICE='Commit blocked'
# The fail-open diagnostic. Any non-zero rc that is NOT 1 keeps the commit, and
# must say so out loud.
FAILOPEN_NOTICE='pre-commit: review-comment-block-size rc='
# Retired with the conversion. Its survival anywhere would mean the section is
# still advertising itself as advisory while returning a blocking exit code.
ADVISORY_NOTICE='pre-commit: comment-block warnings are advisory — commit continues.'
# Planted in the comment body of a scanned file. The output contract reports
# paths, line ranges and counts only — never comment text — so this string must
# never surface on stdout or stderr.
SENTINEL='SENTINEL-DO-NOT-LEAK-abc123'

# Every stub records the argv it was called with, so a hook that invokes the
# scanner with the wrong mode (or not at all) cannot pass silently.
STUB_PROLOGUE='_argv_log="$(dirname "$0")/../.scanner-argv"; { printf "%s\n" "$#"; if [ $# -gt 0 ]; then printf "%s\n" "$@"; fi; } > "$_argv_log"'

# write_stub <path> <kind>: block -> ^BLOCK: output, rc 1 (the verdict);
# clean -> no finding line, rc 0; skipped -> SKIPPED header, rc 0 (node
# missing, kill switch, not a repo...); rc3 -> internal-error output, rc 3
# (fail-open); rc7 -> an rc the contract doesn't name (fail-open); real ->
# thin wrapper around the worktree's real scanner. rc is what the stubs
# exist to control: mapping scanner rc to commit rc is the hook's whole new
# job, and a real scanner can't be steered into every rc on demand.
write_stub() {
    local path="$1" kind="$2"
    case "$kind" in
        block)
            cat > "$path" <<EOF
#!/usr/bin/env bash
$STUB_PROLOGUE
echo "$SCANNER_HEADER"
echo ""
echo "Staged code files scanned: 1 (extensions: js;sh;py; threshold: > 10 consecutive comment lines)"
echo "$BLOCK_LINE"
echo "  L10-L32 (23 lines)"
echo ""
echo "  Compress to a one-line summary + a pointer to the authoritative doc (CPR-SSOT)."
exit 1
EOF
            ;;
        clean)
            cat > "$path" <<EOF
#!/usr/bin/env bash
$STUB_PROLOGUE
echo "$SCANNER_HEADER"
echo ""
echo "Staged code files scanned: 1 (extensions: js;sh;py; threshold: > 10 consecutive comment lines)"
exit 0
EOF
            ;;
        skipped)
            cat > "$path" <<EOF
#!/usr/bin/env bash
$STUB_PROLOGUE
echo "$SKIPPED_HEADER"
exit 0
EOF
            ;;
        rc3)
            cat > "$path" <<EOF
#!/usr/bin/env bash
$STUB_PROLOGUE
echo "$SCANNER_HEADER"
echo "$ERR_LINE"
exit 3
EOF
            ;;
        rc7)
            cat > "$path" <<EOF
#!/usr/bin/env bash
$STUB_PROLOGUE
echo "$SCANNER_HEADER"
exit 7
EOF
            ;;
        real)
            # Execs the fixture's OWN copied scanner (make_repo renames the
            # copy aside to .review-comment-block-size.real before calling
            # this), never the worktree's $LOCAL_SCANNER — the fixture must
            # stay self-contained now that hooks/pre-commit resolves every
            # path from its own $0, not from AGENTS_CONFIG_DIR.
            { printf '#!/usr/bin/env bash\n'
              printf '%s\n' "$STUB_PROLOGUE"
              printf 'exec bash "$(dirname "$0")/.review-comment-block-size.real" "$@"\n'
            } > "$path"
            ;;
    esac
    chmod +x "$path" 2>/dev/null || true
}

# scanner_argc / scanner_argv <config-repo> — what the hook actually passed.
scanner_argc() {
    local f="$1/.scanner-argv"
    if [ ! -f "$f" ]; then printf 'not-invoked'; return; fi
    head -1 "$f"
}
scanner_argv() {
    local f="$1/.scanner-argv"
    if [ ! -f "$f" ]; then printf 'not-invoked'; return; fi
    sed -n '2,$p' "$f" | tr '\n' ' ' | sed 's/ *$//'
}

# core.hooksPath=/dev/null neutralises the developer's installed hooks
# (rules/test/fixture-isolation.md). Cases that need git to fire the hook under
# test override it per command with `git -c core.hooksPath=<dir>` — see part 3.
# Written straight into .git/config: four `git config` spawns per fixture repo
# is a measurable share of this suite's runtime on Windows.
init_repo() {
    local dir="$1"
    mkdir -p "$dir"
    git -C "$dir" init -q -b main
    cat >> "$dir/.git/config" <<'CFG'
[user]
	email = test@example.com
	name = Test
[core]
	hooksPath = /dev/null
	autocrlf = false
CFG
}

# make_repo <name> <scanner-kind> [remote]
#   scanner-kind: block | clean | skipped | rc3 | rc7 | real | none | noexec
#   remote: "none" (default) or a URL
#
# hooks/pre-commit resolves _cfg_dir from its own $0 (issue #1894 item 1: the
# gate must ignore ambient AGENTS_CONFIG_DIR for identity + scanner-path
# resolution). A fixture invoked via the worktree's real $PRECOMMIT can never
# exercise that gate, so every fixture is its own self-contained mini-install:
# a copy of hooks/ + bin/, with bin/review-comment-block-size swapped for the
# kind under test.
make_repo() {
    local name="$1" kind="$2" remote="${3:-none}"
    local dir="$TMPDIR_BASE/$name"
    init_repo "$dir"
    cp -r "$AGENTS_DIR/hooks" "$dir/hooks"
    cp -r "$AGENTS_DIR/bin" "$dir/bin"
    # A self-contained fixture is now indistinguishable from a real agents
    # install to hooks/pre-commit's OTHER _cfg_dir-gated sections too (not
    # just the comment-block-size gate this file targets) — in particular the
    # on-demand rules-injection notation gate (hooks/pre-commit ~L325), which
    # unconditionally re-validates the whole rules/ tree on every commit once
    # it identifies the repo as itself. Without a copy it sees an empty
    # rules/ and hard-blocks every fixture commit on INVALID_ON_DEMAND_PATHS.
    cp -r "$AGENTS_DIR/rules" "$dir/rules"
    case "$kind" in
        none) rm -f "$dir/bin/review-comment-block-size" ;;
        noexec)
            printf '#!/usr/bin/env bash\nexit 0\n' > "$dir/bin/review-comment-block-size"
            chmod 000 "$dir/bin/review-comment-block-size" 2>/dev/null || true
            ;;
        real)
            mv "$dir/bin/review-comment-block-size" "$dir/bin/.review-comment-block-size.real"
            write_stub "$dir/bin/review-comment-block-size" real
            ;;
        *) write_stub "$dir/bin/review-comment-block-size" "$kind" ;;
    esac
    echo "init" > "$dir/README.md"
    # hooks/bin/rules are committed (not left as untracked filesystem writes)
    # so that a linked `git worktree add` fixture (P02b) sees them too — a
    # linked worktree only reflects the committed tree, never the main
    # worktree's untracked files.
    git -C "$dir" add README.md hooks bin rules
    git -C "$dir" commit -q -m "initial"
    [ "$remote" != "none" ] && git -C "$dir" remote add origin "$remote"
    printf '%s' "$dir"
}

# make_hooks_dir <name> <cfg> — a core.hooksPath directory whose pre-commit
# execs <cfg>'s OWN copied hook (from make_repo), never the worktree's real
# $PRECOMMIT — see make_repo's comment for why.
make_hooks_dir() {
    local dir="$TMPDIR_BASE/$1" cfg="$2"
    mkdir -p "$dir"
    printf '#!/usr/bin/env bash\nexec bash "%s/hooks/pre-commit"\n' "$cfg" > "$dir/pre-commit"
    chmod +x "$dir/pre-commit"
    printf '%s' "$dir"
}

# A staged .js file (not .sh: the hook's execute-bit check runs earlier and
# would block on a mode-100644 shell script before reaching the new section).
stage_sample() {
    local repo="$1" body="${2:-note}"
    { echo "var x = 1;"
      for i in $(seq 1 12); do echo "// $body $i"; done
    } > "$repo/sample.js"
    git -C "$repo" add sample.js
}

# The three variables that can steer a verdict: the kill switch, the threshold
# and the extension list. Every invocation starts from "all removed" — including
# the two obsolete COMMENT_BLOCK_WARN* names, which must not be honoured even
# when present — and then re-pins only what the case is about, in the .env.
CB_ENV_RESET=(
    -u COMMENT_BLOCK_ENFORCE
    -u COMMENT_BLOCK_MAX_LINES
    -u CODE_FILE_EXTENSIONS
    -u COMMENT_BLOCK_WARN
    -u COMMENT_BLOCK_WARN_LINES
)
# Names that must reach the code under test through $cfg/.env and nowhere else.
PC_DOTENV_KEYS=" COMMENT_BLOCK_MAX_LINES COMMENT_BLOCK_ENFORCE CODE_FILE_EXTENSIONS COMMENT_BLOCK_WARN COMMENT_BLOCK_WARN_LINES "
PC_BASE_ENV=(
    "COMMENT_BLOCK_MAX_LINES=10"
    "CODE_FILE_EXTENSIONS=js;sh;py"
)

# _pc_env <cfg> <ambient:0|1> [VAR=VAL ...] — writes $cfg/.env and echoes the
# `env` arguments for the child. PC_BASE_ENV always lands in .env — it is the
# repo's genuine config. Caller-supplied dotenv-scoped overrides are the two
# DISTINCT channels under test, kept independently controllable: with
# ambient=0 they represent an honest .env edit and are written there; with
# ambient=1 they represent the committer's hostile shell override and go ONLY
# into the ambient export, never touching .env — conflating the two would let
# an "ambient" case silently rewrite the very config value it is supposed to
# leave alone (the P05 ambient-cannot-disable premise). Everything else is a
# plain child env var either way.
PC_ENVS=()
_pc_env() {
    local cfg="$1" ambient="$2"; shift 2
    PC_ENVS=("${CB_ENV_RESET[@]}")
    local -a dot_keys=() dot_vals=()
    local kv key i found
    for kv in "${PC_BASE_ENV[@]}"; do
        key="${kv%%=*}"
        dot_keys+=("$key"); dot_vals+=("${kv#*=}")
    done
    for kv in ${@+"$@"}; do
        key="${kv%%=*}"
        if [ "${PC_DOTENV_KEYS#* "$key" }" != "$PC_DOTENV_KEYS" ]; then
            if [ "$ambient" = "1" ]; then
                PC_ENVS+=("$kv")
            else
                found=-1
                for ((i = 0; i < ${#dot_keys[@]}; i++)); do
                    [ "${dot_keys[$i]}" = "$key" ] && found=$i
                done
                if [ "$found" -ge 0 ]; then dot_vals[$found]="${kv#*=}"
                else dot_keys+=("$key"); dot_vals+=("${kv#*=}"); fi
            fi
        else
            PC_ENVS+=("$kv")
        fi
    done
    : > "$cfg/.env"
    for ((i = 0; i < ${#dot_keys[@]}; i++)); do
        printf '%s=%s\n' "${dot_keys[$i]}" "${dot_vals[$i]}" >> "$cfg/.env"
    done
    PC_ENVS+=("AGENTS_CONFIG_DIR=$cfg" "ENFORCE_WORKTREE=off")
}

OUT=""
ERR=""
RC=0
# run_precommit <repo> <agents-config-dir> [VAR=VAL ...]
run_precommit() { _pc_run "$1" "$2" 0 "${@:3}"; }
# Same, with the config keys ALSO in the child environment (hostile direction).
run_precommit_ambient() { _pc_run "$1" "$2" 1 "${@:3}"; }
_pc_run() {
    local repo="$1" cfg="$2" ambient="$3"; shift 3
    local errfile="$TMPDIR_BASE/pc.err"
    _pc_env "$cfg" "$ambient" "$@"
    RC=0
    OUT="$( (cd "$repo" \
        && unset CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID \
        && run_with_timeout 60 env "${PC_ENVS[@]}" \
            bash "$cfg/hooks/pre-commit") 2>"$errfile" )" || RC=$?
    ERR="$(cat "$errfile" 2>/dev/null || true)"
}

# run_commit <repo> <agents-config-dir> <hooks-dir> <message> [VAR=VAL ...]
# A real `git commit` — git decides whether to fire the hook and whether the
# hook's exit code blocks the commit.
run_commit() { _pc_commit "$1" "$2" "$3" "$4" 0 "${@:5}"; }
run_commit_ambient() { _pc_commit "$1" "$2" "$3" "$4" 1 "${@:5}"; }
_pc_commit() {
    local repo="$1" cfg="$2" hooks="$3" msg="$4" ambient="$5"; shift 5
    _pc_env "$cfg" "$ambient" "$@"
    RC=0
    OUT="$( (cd "$repo" \
        && unset CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID \
        && run_with_timeout 60 env "${PC_ENVS[@]}" \
            git -c "core.hooksPath=$hooks" commit -q -m "$msg") 2>&1 )" || RC=$?
    ERR=""
}

NON_GITHUB="https://git.example.com/acme/widgets.git"

# ============================================================================
# Cases
# ============================================================================
# shellcheck source=feature-1894-precommit-comment-block-warn/guard-and-killswitch.sh
. "$CASE_DIR/guard-and-killswitch.sh"
# shellcheck source=feature-1894-precommit-comment-block-warn/failopen-placement-static.sh
. "$CASE_DIR/failopen-placement-static.sh"
# shellcheck source=feature-1894-precommit-comment-block-warn/commit-integration.sh
. "$CASE_DIR/commit-integration.sh"
# shellcheck source=feature-1894-precommit-comment-block-warn/node-unavailable.sh
. "$CASE_DIR/node-unavailable.sh"

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
exit $((FAIL > 0 ? 1 : 0))
