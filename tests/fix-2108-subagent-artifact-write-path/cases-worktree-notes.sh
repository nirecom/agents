#!/usr/bin/env bash
# Tests: hooks/lib/worktree-notes-session-ids.js, hooks/workflow-state/session-id.js, hooks/lib/resolve-workflow-session-id.js
# Tags: worktree-notes, session-id, parser, table-driven, git-worktree, ssot, fail-closed, security, scope:issue-specific, pwsh-not-required
# Part of tests/fix-2108-subagent-artifact-write-path.sh (rules/coding/file-split.md).

# Section C10 plus the shared fixtures for C11/C14 (cases-notes-enumerate.sh), all
# against the NEW shared module hooks/lib/worktree-notes-session-ids.js.
# WHY: `Session-ID:` in WORKTREE_NOTES.md is agent-writable, and a clearance READER in
# another process honours it at priority 6/6b/6c — while observeActiveSessionIds() never
# sees it (resolveSessionId() returns at priority 1 on any stdin sid).
WT_NOTES_NODE="$AGENTS_NODE/hooks/lib/worktree-notes-session-ids.js"

# C10 covers the two helpers currently DUPLICATED as `_readSessionIdFromWorktreeNotes`
# and `_findOwnWorktreeDir` in BOTH resolvers, which the fix extracts verbatim into one
# shared module (CPR-SSOT) — parser rows, boundary rows, and a grep that the copies are
# actually GONE rather than merely shadowed by a require.
WTN_BASE=""

# TEST-FIRST: the module does not exist yet; until /write-code lands it the expected
# failure signature here is "module not found". Git worktrees created below live in a
# fixture repo under $TMPBASE_SH and are removed by this file AND by the aggregator's
# rm -rf trap, so no global state is touched and no `# Serial:` lane is needed.
WTN_REPO=""
WTN_REPO_OK=no
WTN_PLATFORM=""

_wtn_write_probes() {
    cat > "$PROBE_DIR/wtn-read-probe.js" <<'PROBE_EOF'
"use strict";
// argv: <module> <notesPath> -> the parsed Session-ID, or the literal "null"
const m = require(process.argv[2]);
process.stdout.write(String(m.readSessionIdFromWorktreeNotes(process.argv[3])));
PROBE_EOF
    cat > "$PROBE_DIR/wtn-own-probe.js" <<'PROBE_EOF'
"use strict";
// argv: <module> <cwd> [dir...] -> the ORIGINAL matching dir string, or "null".
// Empty argv entries are forwarded on purpose: a falsy dir must be skipped, not throw.
const m = require(process.argv[2]);
process.stdout.write(String(m.findOwnWorktreeDir(process.argv.slice(4), process.argv[3])));
PROBE_EOF
    cat > "$PROBE_DIR/wtn-enum-probe.js" <<'PROBE_EOF'
"use strict";
// argv: <module> -> "<complete>|<sids, sorted, comma-joined>" for process.cwd().
// Sorted so the assertion pins the SET, not the traversal order (unspecified).
const m = require(process.argv[2]);
const r = m.enumerateWorktreeNotesSessionIds();
const ok = r && Array.isArray(r.sids) && typeof r.complete === "boolean";
process.stdout.write(ok ? String(r.complete) + "|" + r.sids.slice().sort().join(",") : "BAD-SHAPE|");
PROBE_EOF
    cat > "$PROBE_DIR/wtn-resolver-probe.js" <<'PROBE_EOF'
"use strict";
// argv: <session-id.js> <resolve-workflow-session-id.js> <sid|wsid> [ctx-json]
const mode = process.argv[4];
let ctx = {};
try { ctx = JSON.parse(process.argv[5] || "{}"); } catch (_) {}
const mod = mode === "sid" ? require(process.argv[2]) : require(process.argv[3]);
process.stdout.write(String(mode === "sid" ? mod.resolveSessionId(ctx) : mod.resolveWorkflowSessionId(ctx)));
PROBE_EOF
}

# _wtn_notes <dir> <content-key> — plants WORKTREE_NOTES.md in <dir>
_wtn_notes() {
    mkdir -p "$1" 2>/dev/null || true
    case "$2" in
        plain)      printf 'Session-ID: canon-sid-1\n' > "$1/WORKTREE_NOTES.md" ;;
        crlf)       printf 'Session-ID: canon-sid-1\r\n' > "$1/WORKTREE_NOTES.md" ;;
        midfile)    printf '# Worktree Notes\n\nSession-ID: canon-sid-1\nBranch: main\n' > "$1/WORKTREE_NOTES.md" ;;
        tabsep)     printf 'Session-ID:\tcanon-sid-1\n' > "$1/WORKTREE_NOTES.md" ;;
        trailws)    printf 'Session-ID: canon-sid-1   \n' > "$1/WORKTREE_NOTES.md" ;;
        uuid)       printf 'Session-ID: 0f3d9a21-4b6c-4d7e-8f90-a1b2c3d4e5f6\n' > "$1/WORKTREE_NOTES.md" ;;
        underscore) printf 'Session-ID: canon_sid_1\n' > "$1/WORKTREE_NOTES.md" ;;
        dotted)     printf 'Session-ID: canon.sid.1\n' > "$1/WORKTREE_NOTES.md" ;;
        slashed)    printf 'Session-ID: ../../etc/passwd\n' > "$1/WORKTREE_NOTES.md" ;;
        backslashed) printf 'Session-ID: C:\\wf\\sid\n' > "$1/WORKTREE_NOTES.md" ;;
        spaced)     printf 'Session-ID: canon sid 1\n' > "$1/WORKTREE_NOTES.md" ;;
        emptyval)   printf 'Session-ID:\n' > "$1/WORKTREE_NOTES.md" ;;
        noline)     printf '# Worktree Notes\nBranch: main\n' > "$1/WORKTREE_NOTES.md" ;;
        emptyfile)  printf '' > "$1/WORKTREE_NOTES.md" ;;
        unanchored) printf 'see Session-ID: canon-sid-1\n' > "$1/WORKTREE_NOTES.md" ;;
        twolines)   printf 'Session-ID: first-sid\nSession-ID: second-sid\n' > "$1/WORKTREE_NOTES.md" ;;
        lowerkey)   printf 'session-id: canon-sid-1\n' > "$1/WORKTREE_NOTES.md" ;;
        ghost)      printf 'Session-ID: ghost-planted-sid\n' > "$1/WORKTREE_NOTES.md" ;;
        sibone)     printf 'Session-ID: sib-one-sid\n' > "$1/WORKTREE_NOTES.md" ;;
        sibtwo)     printf 'Session-ID: sib-two-sid\n' > "$1/WORKTREE_NOTES.md" ;;
        isdir)      rm -f "$1/WORKTREE_NOTES.md" 2>/dev/null; mkdir -p "$1/WORKTREE_NOTES.md" ;;
        none)       rm -rf "$1/WORKTREE_NOTES.md" 2>/dev/null || true ;;
    esac
}

# _wtn_setup — one fixture base + a git repo with two linked worktrees.
_wtn_setup() {
    WTN_BASE="$TMPBASE_SH/wtnotes"
    rm -rf "$WTN_BASE" 2>/dev/null || true
    mkdir -p "$WTN_BASE"
    WTN_PLATFORM="$(run_probe -e "process.stdout.write(process.platform)")"
    _wtn_write_probes

    WTN_REPO="$WTN_BASE/repo"
    WTN_REPO_OK=no
    command -v git >/dev/null 2>&1 || return 0
    mkdir -p "$WTN_REPO"
    git -C "$WTN_REPO" init -q -b main >/dev/null 2>&1
    git -C "$WTN_REPO" config core.hooksPath /dev/null >/dev/null 2>&1
    git -C "$WTN_REPO" config user.email test@example.com >/dev/null 2>&1
    git -C "$WTN_REPO" config user.name Test >/dev/null 2>&1
    printf 'x\n' > "$WTN_REPO/README.md"
    git -C "$WTN_REPO" add README.md >/dev/null 2>&1
    git -C "$WTN_REPO" -c commit.gpgsign=false commit -q --no-verify -m init >/dev/null 2>&1
    git -C "$WTN_REPO" worktree add -q -b wt-one "$WTN_BASE/wt-one" >/dev/null 2>&1
    git -C "$WTN_REPO" worktree add -q -b wt-two "$WTN_BASE/wt-two" >/dev/null 2>&1
    [ -d "$WTN_BASE/wt-one" ] && [ -d "$WTN_BASE/wt-two" ] && WTN_REPO_OK=yes
    return 0
}

# _wtn_teardown — explicit worktree removal (the aggregator's rm -rf is the backstop).
_wtn_teardown() {
    [ "$WTN_REPO_OK" = yes ] || return 0
    git -C "$WTN_REPO" worktree remove --force "$WTN_BASE/wt-one" >/dev/null 2>&1 || true
    git -C "$WTN_REPO" worktree remove --force "$WTN_BASE/wt-two" >/dev/null 2>&1 || true
    git -C "$WTN_REPO" worktree prune >/dev/null 2>&1 || true
    return 0
}

# _wtn_in <cwd> <probe-args...> -> probe stdout with session env stripped
_wtn_in() {
    local dir="$1"; shift
    (
        cd "$dir" || exit 1
        unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID CLAUDE_ENV_FILE CLAUDE_PROJECT_DIR
        run_probe "$@"
    )
}

run_C10_notes_helpers() {
    local d label key want got dirs_base a cwd

    _wtn_setup

    # C10-0 — the module and its three exports. Without them every row below is
    # vacuous, so this is asserted before anything reads a fixture.
    assert_eq "C10-0 worktree-notes-session-ids.js exports the three helpers" \
        "function,function,function" \
        "$(run_probe -e "const m=require(process.argv[1]);process.stdout.write([typeof m.readSessionIdFromWorktreeNotes,typeof m.findOwnWorktreeDir,typeof m.enumerateWorktreeNotesSessionIds].join(','))" "$WT_NOTES_NODE")"

    # C10-1 — readSessionIdFromWorktreeNotes, table-driven over the PARSER contract
    # (skills/_shared/test-design/parser-regex-tests.md). The value is agent-written,
    # so the charset gate is a security boundary: anything carrying a path separator,
    # a dot or whitespace must come back null rather than reaching a path join.
    d="$WTN_BASE/read"
    while IFS='|' read -r label key want; do
        [[ -z "$label" || "$label" =~ ^[[:space:]]*# ]] && continue
        label="${label//[[:space:]]/}"; key="${key//[[:space:]]/}"; want="${want//[[:space:]]/}"
        _wtn_notes "$d" "$key"
        got="$(run_probe "$PROBE_DIR/wtn-read-probe.js" "$WT_NOTES_NODE" "$(node_path "$d/WORKTREE_NOTES.md")")"
        assert_eq "C10-1 $label" "$want" "$got"
    done <<'READ_TABLE'
# label                     | content key  | want
# --- ACCEPTED: the shapes /worktree-start actually writes
C10-1-plain-value           | plain        | canon-sid-1
C10-1-crlf-line-ending      | crlf         | canon-sid-1
C10-1-line-mid-file         | midfile      | canon-sid-1
C10-1-tab-after-colon       | tabsep       | canon-sid-1
C10-1-trailing-whitespace   | trailws      | canon-sid-1
C10-1-uuid-value            | uuid         | 0f3d9a21-4b6c-4d7e-8f90-a1b2c3d4e5f6
C10-1-underscore-value      | underscore   | canon_sid_1
C10-1-first-of-two-wins     | twolines     | first-sid
# --- REJECTED by the charset gate: these would otherwise reach path.join()
C10-1-dot-rejected          | dotted       | null
C10-1-separator-rejected    | slashed      | null
C10-1-backslash-rejected    | backslashed  | null
C10-1-inner-space-rejected  | spaced       | null
# --- NO VALUE PRESENT: absence is an answer, never a throw
C10-1-empty-value           | emptyval     | null
C10-1-no-session-id-line    | noline       | null
C10-1-empty-file            | emptyfile    | null
C10-1-not-line-anchored     | unanchored   | null
C10-1-key-is-case-sensitive | lowerkey     | null
READ_TABLE

    # C10-1b — read FAULTS. Both must be null (the read is best-effort by contract),
    # and neither may propagate an exception out of the helper.
    _wtn_notes "$d" none
    assert_eq "C10-1b missing file -> null" "null" \
        "$(run_probe "$PROBE_DIR/wtn-read-probe.js" "$WT_NOTES_NODE" "$(node_path "$d/WORKTREE_NOTES.md")")"
    _wtn_notes "$d" isdir
    assert_eq "C10-1b unreadable (path is a directory) -> null" "null" \
        "$(run_probe "$PROBE_DIR/wtn-read-probe.js" "$WT_NOTES_NODE" "$(node_path "$d/WORKTREE_NOTES.md")")"

    # C10-2 — findOwnWorktreeDir. Real directories, not hardcoded drive letters, so
    # the same rows run on POSIX and win32.
    dirs_base="$WTN_BASE/own"
    mkdir -p "$dirs_base/wt1/inner/deep" "$dirs_base/wt1-other" "$dirs_base/elsewhere"
    a="$(node_path "$dirs_base/wt1")"

    assert_eq "C10-2a cwd IS the worktree root -> that root" "$a" \
        "$(run_probe "$PROBE_DIR/wtn-own-probe.js" "$WT_NOTES_NODE" "$a" "$a")"
    assert_eq "C10-2b cwd is a subdir of the worktree -> that root" "$a" \
        "$(run_probe "$PROBE_DIR/wtn-own-probe.js" "$WT_NOTES_NODE" "$(node_path "$dirs_base/wt1/inner/deep")" "$a")"

    # The separator-boundary case the docstring names: a sibling whose name merely
    # STARTS with the worktree's name is not inside it.
    assert_eq "C10-2c wt1 must not match cwd wt1-other (separator boundary)" "null" \
        "$(run_probe "$PROBE_DIR/wtn-own-probe.js" "$WT_NOTES_NODE" "$(node_path "$dirs_base/wt1-other")" "$a")"

    # Nested worktrees: deepest ancestor wins, and the answer must not depend on the
    # order git happened to list them in.
    assert_eq "C10-2d nested worktrees: deepest ancestor wins" "$(node_path "$dirs_base/wt1/inner")" \
        "$(run_probe "$PROBE_DIR/wtn-own-probe.js" "$WT_NOTES_NODE" "$(node_path "$dirs_base/wt1/inner/deep")" "$a" "$(node_path "$dirs_base/wt1/inner")")"
    assert_eq "C10-2e deepest still wins when listed first" "$(node_path "$dirs_base/wt1/inner")" \
        "$(run_probe "$PROBE_DIR/wtn-own-probe.js" "$WT_NOTES_NODE" "$(node_path "$dirs_base/wt1/inner/deep")" "$(node_path "$dirs_base/wt1/inner")" "$a")"
    assert_eq "C10-2f no ancestor among the dirs -> null" "null" \
        "$(run_probe "$PROBE_DIR/wtn-own-probe.js" "$WT_NOTES_NODE" "$(node_path "$dirs_base/elsewhere")" "$a")"
    assert_eq "C10-2g empty dir list -> null" "null" \
        "$(run_probe "$PROBE_DIR/wtn-own-probe.js" "$WT_NOTES_NODE" "$a")"
    assert_eq "C10-2h falsy entries are skipped, not thrown on" "$a" \
        "$(run_probe "$PROBE_DIR/wtn-own-probe.js" "$WT_NOTES_NODE" "$a" "" "$a")"

    # The ORIGINAL string is what comes back — callers join WORKTREE_NOTES.md onto it,
    # and a normalized return would silently change which file they open.
    assert_eq "C10-2i returns the ORIGINAL dir string, not the resolved form" "$a/./" \
        "$(run_probe "$PROBE_DIR/wtn-own-probe.js" "$WT_NOTES_NODE" "$a" "$a/./")"

    # win32 folds case; POSIX does not. Both directions are asserted, so a helper that
    # hardcoded either one is caught on the platform where it is wrong.
    cwd="$(node_path "$dirs_base/wt1/inner")"
    if [ "$WTN_PLATFORM" = "win32" ]; then
        assert_eq "C10-2j win32: case-insensitive match, original casing returned" \
            "$(printf '%s' "$a" | tr '[:lower:]' '[:upper:]')" \
            "$(run_probe "$PROBE_DIR/wtn-own-probe.js" "$WT_NOTES_NODE" "$cwd" "$(printf '%s' "$a" | tr '[:lower:]' '[:upper:]')")"
    else
        assert_eq "C10-2j posix: case-SENSITIVE, an uppercased dir does not match" "null" \
            "$(run_probe "$PROBE_DIR/wtn-own-probe.js" "$WT_NOTES_NODE" "$cwd" "$(printf '%s' "$a" | tr '[:lower:]' '[:upper:]')")"
    fi

    # C10-3 — CPR-SSOT: the copies must be GONE, not merely shadowed. A resolver that
    # kept its private helper alongside a require of the shared one would pass every
    # behavioural row above and still drift on the next edit.
    local dup req f
    dup=0; req=0
    for f in "$AGENTS_DIR/hooks/workflow-state/session-id.js" "$AGENTS_DIR/hooks/lib/resolve-workflow-session-id.js"; do
        grep -qE '^function _(readSessionIdFromWorktreeNotes|findOwnWorktreeDir)' "$f" 2>/dev/null && dup=$((dup + 1))
        grep -qE "require\(.*worktree-notes-session-ids" "$f" 2>/dev/null && req=$((req + 1))
    done
    assert_eq "C10-3 neither resolver still defines a private copy of the helpers" "0" "$dup"
    assert_eq "C10-3 both resolvers require the shared module" "2" "$req"

    _wtn_teardown
}
