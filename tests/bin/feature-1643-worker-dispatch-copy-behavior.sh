#!/usr/bin/env bash
# tests/feature-1643-worker-dispatch-copy-behavior.sh
# Tests: bin/worker-dispatch/workers/worktree-copy.js, bin/worker-dispatch.js, bin/worktree-write-notes.js
# Tags: worker-dispatch, worktree-copy, status-derivation, table-driven, TL2, scope:issue-specific
# Issue #1643 — worktree-copy derives ONE status from three sequential CLIs;
#   this pins which combined outcome maps to which status. Group 1 uses the real
#   CLIs; groups 2-4 stub the process seam (feature-1643-worker-dispatch-lib/
#   spawn-stub.js); group 5 (#1937) pins the shared copy engine's opaque-directory
#   handling. TL3 gap: real /worktree-start argv + a real .worktreeinclude
#   allowlist, checked at WORKFLOW_USER_VERIFIED preflight via
#   bin/check-verification-gate.sh (category: skill-orchestration).

set -u

if command -v timeout >/dev/null 2>&1 && [ -z "${_WD1643_CB_INNER:-}" ]; then
    _WD1643_CB_INNER=1 timeout 420 bash "$0" "$@"
    exit $?
fi

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DISPATCH_JS="$AGENTS_DIR/bin/worker-dispatch.js"
PRELOAD="$AGENTS_DIR/tests/feature-1643-worker-dispatch-lib/spawn-stub.js"
nodepath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi; }

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; [ -n "${2:-}" ] && echo "    detail: $2"; FAIL=$((FAIL + 1)); }
assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then pass "$name"
    else fail "$name" "want=$(printf '%q' "$want") got=$(printf '%q' "$got")"; fi
}
run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

if [ ! -f "$DISPATCH_JS" ] || [ ! -f "$PRELOAD" ]; then
    fail "0: fixture prerequisites missing" "dispatcher=$DISPATCH_JS stub=$PRELOAD"
    echo ""
    echo "Total: PASS=$PASS FAIL=$FAIL"
    exit 1
fi

TMPD="$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/wd-cb-$$")"
mkdir -p "$TMPD"
trap 'rm -rf "$TMPD"' EXIT

MAIN_RAW="$TMPD/mainrepo"
mkdir -p "$MAIN_RAW"
git -C "$MAIN_RAW" init -q -b main
git -C "$MAIN_RAW" config user.email "test@example.com"
git -C "$MAIN_RAW" config user.name "Test"
git -C "$MAIN_RAW" config core.hooksPath /dev/null
printf '.env\n' > "$MAIN_RAW/.gitignore"
printf '.env\n' > "$MAIN_RAW/.worktreeinclude"
echo init > "$MAIN_RAW/README.md"
git -C "$MAIN_RAW" add .gitignore .worktreeinclude README.md >/dev/null 2>&1
git -C "$MAIN_RAW" commit -q --no-verify -m initial >/dev/null 2>&1
printf 'LOCAL_FLAG=1\n' > "$MAIN_RAW/.env"

BRANCH="feature/wc-probe"
LINKED_RAW="$TMPD/linked-wt"
git -C "$MAIN_RAW" worktree add -q -b "$BRANCH" "$LINKED_RAW" >/dev/null 2>&1
PLANS_RAW="$TMPD/plans"; mkdir -p "$PLANS_RAW"

MAIN="$(nodepath "$MAIN_RAW")"
LINKED="$(nodepath "$LINKED_RAW")"
PLANS="$(nodepath "$PLANS_RAW")"
CANNED="$TMPD/canned.json"
CALLLOG="$TMPD/calls.jsonl"

DOUT=""; DRC=0
write_payload() { printf '%s' "$2" > "$PLANS_RAW/$1.json"; nodepath "$PLANS_RAW/$1.json"; }
field_of() { printf '%s\n' "$DOUT" | sed -n "s/^$1: //p" | head -1; }

# Real child CLIs — no preload.
dispatch_real() {
    DRC=0
    DOUT="$(run_with_timeout 90 env "WORKFLOW_PLANS_DIR=$PLANS" \
        node "$(nodepath "$DISPATCH_JS")" worktree-copy "$MAIN" "$1" 2>/dev/null)" || DRC=$?
}
# Canned child CLIs — $1 is the rules JSON array, $2 the payload path.
dispatch_stubbed() {
    printf '%s' "$1" > "$CANNED"
    : > "$CALLLOG"
    DRC=0
    DOUT="$(run_with_timeout 90 env "WORKFLOW_PLANS_DIR=$PLANS" \
        "WD_SPAWN_MODULE=$(nodepath "$AGENTS_DIR/bin/worker-dispatch/spawn.js")" \
        "WD_CANNED=$(nodepath "$CANNED")" \
        "WD_CALL_LOG=$(nodepath "$CALLLOG")" \
        node -r "$(nodepath "$PRELOAD")" "$(nodepath "$DISPATCH_JS")" worktree-copy "$MAIN" "$2" 2>/dev/null)" || DRC=$?
}
# Field of the logged spawn whose script matches $1.
call_field() {
    node -e '
const fs=require("fs");
const rows=fs.readFileSync(process.argv[1],"utf8").trim().split("\n").filter(Boolean).map(JSON.parse);
const row=rows.find(r=>r.script===process.argv[2]);
if(!row){process.stdout.write("(no-such-call)");process.exit(0);}
const f=process.argv[3];
process.stdout.write(f==="args"?row.args.join(" "):String(row[f]===null||row[f]===undefined?"(null)":typeof row[f]==="object"?JSON.stringify(row[f]):row[f]));
' "$(nodepath "$CALLLOG")" "$1" "$2"
}

# JSON-escaped so it can be embedded inside a rule's "stdout" string value.
OK_COPY='{\"copied\":[\"a.txt\",\"b.txt\"],\"denied\":[],\"errors\":[]}'
OK_COPY_RAW='{"copied":["a.txt","b.txt"],"denied":[],"errors":[]}'

# args[$2] of the logged spawn whose script is $1.
call_arg() {
    node -e '
const fs=require("fs");
const rows=fs.readFileSync(process.argv[1],"utf8").trim().split("\n").filter(Boolean).map(JSON.parse);
const row=rows.find(r=>r.script===process.argv[2]);
process.stdout.write(row?String(row.args[Number(process.argv[3])]):"(no-such-call)");
' "$(nodepath "$CALLLOG")" "$1" "$2"
}
# extraEnv[$2] of the logged spawn whose script is $1.
call_env() {
    node -e '
const fs=require("fs");
const rows=fs.readFileSync(process.argv[1],"utf8").trim().split("\n").filter(Boolean).map(JSON.parse);
const row=rows.find(r=>r.script===process.argv[2]);
process.stdout.write(row&&row.extraEnv?String(row.extraEnv[process.argv[3]]):"(no-such-call)");
' "$(nodepath "$CALLLOG")" "$1" "$2"
}

# ===========================================================================
# Group 1 — the real chain: WORKTREE_NOTES.md must actually exist afterwards
# ===========================================================================
group_real_chain() {
    local p
    p="$(write_payload wc-real "{\"worktree_path\":\"$LINKED\",\"branch\":\"$BRANCH\",\"artifact_dir\":\"$PLANS\"}")"
    dispatch_real "$p"
    assert_eq "real/exit0" "0" "$DRC"
    case "$(field_of status)" in
        complete|partial) pass "real/status-is-a-success-variant" ;;
        *) fail "real/status-is-a-success-variant" "status='$(field_of status)' summary='$(field_of summary)'" ;;
    esac
    if [ -f "$LINKED_RAW/WORKTREE_NOTES.md" ]; then pass "real/notes-file-created"
    else fail "real/notes-file-created" "no WORKTREE_NOTES.md in $LINKED_RAW"; fi
    if grep -qF "$BRANCH" "$LINKED_RAW/WORKTREE_NOTES.md" 2>/dev/null; then pass "real/notes-name-the-branch"
    else fail "real/notes-name-the-branch" "$(head -20 "$LINKED_RAW/WORKTREE_NOTES.md" 2>/dev/null)"; fi
    case "$(field_of summary)" in
        *"WORKTREE_NOTES.md written"*) pass "real/summary-reports-the-notes-write" ;;
        *) fail "real/summary-reports-the-notes-write" "summary='$(field_of summary)'" ;;
    esac
}

# ===========================================================================
# Group 2 — status derivation table over the three CLI outcomes
# ===========================================================================
group_status_table() {
    local name rules want_status want_sub p got
    while IFS='|' read -r name rules want_status want_sub; do
        [ -z "${name// /}" ] && continue
        name="$(echo "$name" | xargs)"; want_status="$(echo "$want_status" | xargs)"
        want_sub="${want_sub#"${want_sub%%[![:space:]]*}"}"; want_sub="${want_sub%"${want_sub##*[![:space:]]}"}"
        rules="${rules#"${rules%%[![:space:]]*}"}"; rules="${rules%"${rules##*[![:space:]]}"}"
        p="$(write_payload "wc-$name" "{\"worktree_path\":\"$LINKED\",\"branch\":\"$BRANCH\",\"artifact_dir\":\"$PLANS\"}")"
        dispatch_stubbed "$rules" "$p"
        assert_eq "derive/$name/exit0" "0" "$DRC"
        assert_eq "derive/$name/status" "$want_status" "$(field_of status)"
        got="$(field_of summary)"
        case "$got" in
            *"$want_sub"*) pass "derive/$name/summary" ;;
            *) fail "derive/$name/summary" "want substring '$want_sub' in '$got'" ;;
        esac
    done <<TABLE
clean-copy       | [{"match":"includeFilter","stdout":"$OK_COPY"},{}] | complete | 2 files copied
inventory-fails  | [{"match":"ls-files","status":128,"stderr":"fatal: not a git repository"},{}] | failed | inventory failed
copy-nonjson     | [{"match":"includeFilter","status":1,"stdout":"boom","stderr":"copy blew up"},{}] | partial | copy issue(s)
copy-denied      | [{"match":"includeFilter","stdout":"{\\"copied\\":[\\"a\\"],\\"denied\\":[\\"secret.key\\"],\\"errors\\":[]}"},{}] | partial | 1 files copied
copy-errors      | [{"match":"includeFilter","stdout":"{\\"copied\\":[],\\"denied\\":[],\\"errors\\":[\\"EPERM x\\"]}"},{}] | partial | 0 files copied
notes-fails      | [{"match":"includeFilter","stdout":"$OK_COPY"},{"match":"writeNotes","status":1,"stderr":"notes CLI refused"},{}] | failed | WORKTREE_NOTES.md write failed
TABLE
}

# ===========================================================================
# Group 3 — the copied list has to reach the notes CLI, not just the summary
# ===========================================================================
group_copied_reaches_notes() {
    local p
    p="$(write_payload wc-env "{\"worktree_path\":\"$LINKED\",\"branch\":\"$BRANCH\",\"session_id\":\"sess-copy-1\",\"artifact_dir\":\"$PLANS\"}")"
    dispatch_stubbed "[{\"match\":\"includeFilter\",\"stdout\":\"$OK_COPY\"},{}]" "$p"
    assert_eq "wire/notes-cli-invoked" "node" "$(call_field writeNotes command)"
    assert_eq "wire/copied-json-passed-through" "$OK_COPY_RAW" "$(call_env writeNotes COPIED_JSON)"
    assert_eq "wire/branch-reaches-the-notes-cli" "$BRANCH" "$(call_arg writeNotes 2)"
    assert_eq "wire/session-reaches-the-notes-cli" "sess-copy-1" "$(call_arg writeNotes 4)"
    assert_eq "wire/sibling-parse-uses-the-session-intent" "1" \
        "$(grep -c '"script":"parseWorktrees"' "$CALLLOG" | tr -d ' ')"
}

# ===========================================================================
# Group 4 — a lost log must not downgrade a completed copy
# ===========================================================================
group_log_failure_non_fatal() {
    local p blocker
    blocker="$PLANS_RAW/blocked-artifacts"
    printf 'not a directory\n' > "$blocker"
    p="$(write_payload wc-logfail "{\"worktree_path\":\"$LINKED\",\"branch\":\"$BRANCH\",\"artifact_dir\":\"$(nodepath "$blocker")\"}")"
    dispatch_stubbed "[{\"match\":\"includeFilter\",\"stdout\":\"$OK_COPY\"},{}]" "$p"
    # artifact_dir is a regular file, so the log write throws inside the worker.
    # The worktree is already correctly populated at that point, so the caller
    # must still be told `complete` — only artifact_path degrades.
    assert_eq "logfail/status-still-complete" "complete" "$(field_of status)"
    assert_eq "logfail/artifact-path-degrades-to-none" "(none)" "$(field_of artifact_path)"
    case "$(field_of summary)" in
        *"2 files copied"*) pass "logfail/summary-unchanged" ;;
        *) fail "logfail/summary-unchanged" "summary='$(field_of summary)'" ;;
    esac
}

# ===========================================================================
# Group 5 (#1937, CPR-ORTH) — a gitignored DIRECTORY candidate must not crash
#   the copy. copyInclude is the shared copy engine, so the opaque-directory
#   skip that loses worktree-backup content afflicts it too: an opaque dir (a
#   gitignored dir made a single ls-files entry by an embedded repo) reaches
#   fs.copyFileSync today and fails with a raw "Failed to copy <dir>". The fix
#   must report the directory candidate cleanly while the sibling plain
#   gitignored file still copies.
# ===========================================================================
group_copyinclude_directory_candidate() {
    local WC_ROOT="$TMPD/wc-dir"
    local WC_MAIN="$WC_ROOT/main"
    local WC_LINKED="$WC_ROOT/linked"
    mkdir -p "$WC_MAIN" "$WC_LINKED"
    git -C "$WC_MAIN" init -q -b main
    git -C "$WC_MAIN" config user.email "test@example.com"
    git -C "$WC_MAIN" config user.name "Test"
    git -C "$WC_MAIN" config core.hooksPath /dev/null
    printf 'statedir/\nkeep.txt\n' > "$WC_MAIN/.gitignore"
    printf 'statedir/\nkeep.txt\n' > "$WC_MAIN/.worktreeinclude"
    echo init > "$WC_MAIN/README.md"
    git -C "$WC_MAIN" add .gitignore .worktreeinclude README.md >/dev/null 2>&1
    git -C "$WC_MAIN" commit -q --no-verify -m init >/dev/null 2>&1
    printf 'KEEP\n' > "$WC_MAIN/keep.txt"
    mkdir -p "$WC_MAIN/statedir"
    git -C "$WC_MAIN/statedir" init -q -b main
    git -C "$WC_MAIN/statedir" config core.hooksPath /dev/null
    printf 'INNER\n' > "$WC_MAIN/statedir/inner.txt"

    local WC_LIB="$AGENTS_DIR/hooks/lib/worktree-copy.js"
    if [ ! -f "$WC_LIB" ]; then fail "wc-dir/lib-present" "missing $WC_LIB"; return; fi
    local RES="$WC_ROOT/result.json"
    node -e '
const {copyInclude}=require(process.argv[1]);
const fs=require("fs");
const r=copyInclude({mainRoot:process.argv[2], worktreePath:process.argv[3]});
fs.writeFileSync(process.argv[4], JSON.stringify(r||{}));
' "$(nodepath "$WC_LIB")" "$(nodepath "$WC_MAIN")" "$(nodepath "$WC_LINKED")" "$(nodepath "$RES")" 2>/dev/null

    if [ -f "$WC_LINKED/keep.txt" ]; then pass "wc-dir/plain-file-still-copied"
    else fail "wc-dir/plain-file-still-copied" "keep.txt absent in $WC_LINKED"; fi

    local errs
    errs="$(node -e 'const r=require(process.argv[1]);process.stdout.write(JSON.stringify(r.errors||[]))' "$(nodepath "$RES")" 2>/dev/null)"
    case "$errs" in
        *"Failed to copy statedir"*) fail "wc-dir/no-raw-copyfile-failure" "errors=$errs" ;;
        *) pass "wc-dir/no-raw-copyfile-failure" ;;
    esac
    case "$errs" in
        *"directory candidate not copied"*) pass "wc-dir/directory-reported-cleanly" ;;
        *) fail "wc-dir/directory-reported-cleanly" "errors=$errs" ;;
    esac
}

case_begin() { echo "--- case: $1 ($2) ---"; }
case_end() { :; }

case_begin "real-chain" "bin/worker-dispatch.js"
group_real_chain
case_end

case_begin "status-table" "bin/worker-dispatch/workers/worktree-copy.js"
group_status_table
case_end

case_begin "copied-reaches-notes" "bin/worker-dispatch/workers/worktree-copy.js"
group_copied_reaches_notes
case_end

case_begin "log-failure-non-fatal" "bin/worker-dispatch.js"
group_log_failure_non_fatal
case_end

case_begin "copyinclude-directory-candidate" "bin/worker-dispatch/workers/worktree-copy.js"
group_copyinclude_directory_candidate
case_end

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $((FAIL > 0 ? 1 : 0))
