#!/usr/bin/env bash
# tests/feature-1643-worker-dispatch-backup-secrets.sh
# Tests: bin/worker-dispatch/workers/worktree-backup.js, bin/worker-dispatch/fsguard.js, bin/worker-dispatch.js
# Tags: worker-dispatch, worktree-backup, secrets, manifest, idempotency, protection-fix, TL2, scope:issue-specific
#
# Issue #1643 — worktree-backup inventories gitignored/untracked state and copies
# it aside. The files it handles are exactly the ones most likely to hold local
# credentials, so the worker hashes content instead of quoting it: a manifest
# that embedded the bytes of a local .env would turn the backup index into a
# secret of its own.
#
# This file is the protection-fix test for that property. The fixture worktree
# carries obviously-fake secret literals; after each mode every byte the worker
# produced — manifest, dry-run log, execute log, stdout, stderr — is scanned for
# those literals. The assertion is negative and made against the protected
# resource itself (protection-fix Pattern 1), not against an exit status.
#
# Real git runs here (inventory is `git ls-files --others`), so this is TL2.
#
# TL3 gap (what this TL2 test does NOT catch):
#   - A real worktree whose ignored set includes NTFS junctions, files locked by
#     another process, or paths beyond MAX_PATH — all of which change what
#     `git ls-files` returns and what readFileSync can open.
#   - Real `docker ps` bind-mount detection (docker_check is false throughout).
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED
# preflight via bin/check-verification-gate.sh category: skill-orchestration.
#
# Skipped-Because: "a payload naming a backup_dir other than the derived
# <main-root>/.worktree-backup/<branch> is rejected" is NOT re-asserted here.
# tests/feature-1643-worker-dispatch-capability.sh already drives that as rows
# `backup-dir-arbitrary` and `backup-dir-sibling` with all three protection
# properties. Duplicating it would add a second place to update.

set -u

if command -v timeout >/dev/null 2>&1 && [ -z "${_WD1643_BS_INNER:-}" ]; then
    _WD1643_BS_INNER=1 timeout 420 bash "$0" "$@"
    exit $?
fi

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DISPATCH_JS="$AGENTS_DIR/bin/worker-dispatch.js"
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

if [ ! -f "$DISPATCH_JS" ]; then
    fail "0: dispatcher missing" "$DISPATCH_JS"
    echo ""
    echo "Total: PASS=$PASS FAIL=$FAIL"
    exit 1
fi

TMPD="$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/wd-bs-$$")"
mkdir -p "$TMPD"
trap 'rm -rf "$TMPD"' EXIT

# ---------------------------------------------------------------------------
# Fixture — main repo, two linked worktrees, obviously-fake secret literals.
# ---------------------------------------------------------------------------
MAIN_RAW="$TMPD/mainrepo"
mkdir -p "$MAIN_RAW"
git -C "$MAIN_RAW" init -q -b main
git -C "$MAIN_RAW" config user.email "test@example.com"
git -C "$MAIN_RAW" config user.name "Test"
git -C "$MAIN_RAW" config core.hooksPath /dev/null
printf '.env\nlocal/\n' > "$MAIN_RAW/.gitignore"
echo init > "$MAIN_RAW/README.md"
git -C "$MAIN_RAW" add .gitignore README.md >/dev/null 2>&1
git -C "$MAIN_RAW" commit -q --no-verify -m initial >/dev/null 2>&1

BRANCH="feature/bk-probe"
LINKED_RAW="$TMPD/linked-wt"
git -C "$MAIN_RAW" worktree add -q -b "$BRANCH" "$LINKED_RAW" >/dev/null 2>&1
BRANCH_EMPTY="feature/bk-empty"
EMPTY_RAW="$TMPD/empty-wt"
git -C "$MAIN_RAW" worktree add -q -b "$BRANCH_EMPTY" "$EMPTY_RAW" >/dev/null 2>&1

# Fake credentials. Values are nonsense on purpose; the email domain is the
# RFC 2606 reserved example.com so no real address can ever be implied.
SECRET_KEY="sk-test-FAKE0000-not-a-real-key"
SECRET_PW="fake-password-do-not-use"
SECRET_MAIL="svc-account@example.com"
mkdir -p "$LINKED_RAW/local"
printf 'EXAMPLE_API_KEY=%s\nSMTP_USER=%s\n' "$SECRET_KEY" "$SECRET_MAIL" > "$LINKED_RAW/.env"
printf 'DB_PASSWORD=%s\n' "$SECRET_PW" > "$LINKED_RAW/local/creds.txt"
printf 'scratch\n' > "$LINKED_RAW/untracked-note.txt"

PLANS_RAW="$TMPD/plans"; mkdir -p "$PLANS_RAW"
BACKUP_RAW="$MAIN_RAW/.worktree-backup/$BRANCH"

MAIN="$(nodepath "$MAIN_RAW")"
LINKED="$(nodepath "$LINKED_RAW")"
EMPTY="$(nodepath "$EMPTY_RAW")"
PLANS="$(nodepath "$PLANS_RAW")"

DOUT=""; DERR=""; DRC=0
dispatch_backup() {
    local pfile="$1"
    DRC=0
    DERR="$TMPD/stderr.txt"
    DOUT="$(run_with_timeout 90 env "WORKFLOW_PLANS_DIR=$PLANS" \
        node "$(nodepath "$DISPATCH_JS")" worktree-backup "$MAIN" "$pfile" 2>"$DERR")" || DRC=$?
}
field_of() {
    local v
    v="$(printf '%s\n' "$DOUT" | sed -n "s/^$1: //p" | head -1)"
    v="${v%\"}"; v="${v#\"}"
    printf '%s' "$v"
}
write_payload() { printf '%s' "$2" > "$PLANS_RAW/$1.json"; nodepath "$PLANS_RAW/$1.json"; }

# Every byte the worker produced, EXCEPT the backup copies themselves — a copy of
# a secret file is supposed to contain the secret; the index describing it is not.
scan_targets() {
    find "$PLANS_RAW" -type f 2>/dev/null
    find "$MAIN_RAW/.worktree-backup" -type f -name 'manifest.json' 2>/dev/null
    [ -f "$DERR" ] && echo "$DERR"
    printf '%s\n' "$DOUT" > "$TMPD/stdout.txt"; echo "$TMPD/stdout.txt"
}

assert_no_secret_leak() {
    local label="$1" hits=""
    local f lit
    while IFS= read -r f; do
        [ -f "$f" ] || continue
        for lit in "$SECRET_KEY" "$SECRET_PW" "$SECRET_MAIL"; do
            if grep -qF "$lit" "$f" 2>/dev/null; then hits="$hits $f"; fi
        done
    done <<< "$(scan_targets)"
    if [ -z "$hits" ]; then pass "$label/no-secret-value-in-any-produced-byte"
    else fail "$label/no-secret-value-in-any-produced-byte" "leaked in:$hits"; fi
}

# ===========================================================================
# Group 1 — dry_run: inventory is reported, secrets are not
# ===========================================================================
group_dry_run() {
    local p log
    p="$(write_payload bk-dry "{\"mode\":\"dry_run\",\"worktree_path\":\"$LINKED\",\"branch\":\"$BRANCH\",\"docker_check\":false,\"artifact_dir\":\"$PLANS\"}")"
    dispatch_backup "$p"
    assert_eq "dry/exit0" "0" "$DRC"
    assert_eq "dry/status" "dry_run_complete" "$(field_of status)"

    log="$(field_of artifact_path)"
    if [ -f "$log" ]; then pass "dry/log-written"
    else fail "dry/log-written" "artifact_path='$log'"; fi

    # The log must name the files (that is its whole job) …
    if grep -qF '.env' "$log" 2>/dev/null; then pass "dry/log-lists-the-env-file"
    else fail "dry/log-lists-the-env-file" "$(cat "$log" 2>/dev/null)"; fi
    if grep -qF 'local/creds.txt' "$log" 2>/dev/null || grep -qF 'local\creds.txt' "$log" 2>/dev/null; then
        pass "dry/log-lists-the-nested-file"
    else fail "dry/log-lists-the-nested-file" "$(cat "$log" 2>/dev/null)"; fi

    # … and must not have copied anything.
    if [ -d "$BACKUP_RAW" ]; then fail "dry/no-copy-performed" "$BACKUP_RAW exists after a dry run"
    else pass "dry/no-copy-performed"; fi

    # … while never quoting their contents.
    assert_no_secret_leak "dry"
}

# ===========================================================================
# Group 2 — execute: real copy, hashed manifest, still no secret values
# ===========================================================================
group_execute() {
    local p manifest
    p="$(write_payload bk-exec "{\"mode\":\"execute\",\"worktree_path\":\"$LINKED\",\"branch\":\"$BRANCH\",\"docker_check\":false,\"artifact_dir\":\"$PLANS\"}")"
    dispatch_backup "$p"
    assert_eq "exec/exit0" "0" "$DRC"
    assert_eq "exec/status" "copied" "$(field_of status)"

    manifest="$(field_of artifact_path)"
    if [ -f "$manifest" ]; then pass "exec/manifest-written"
    else fail "exec/manifest-written" "artifact_path='$manifest'"; fi

    # The copy is byte-identical to the source — hashing must not have replaced
    # the real copy with a digest.
    if cmp -s "$LINKED_RAW/.env" "$BACKUP_RAW/.env"; then pass "exec/copy-is-byte-identical"
    else fail "exec/copy-is-byte-identical" "$BACKUP_RAW/.env differs from source"; fi
    if cmp -s "$LINKED_RAW/local/creds.txt" "$BACKUP_RAW/local/creds.txt"; then
        pass "exec/nested-copy-is-byte-identical"
    else fail "exec/nested-copy-is-byte-identical" "nested copy differs"; fi

    # The manifest names the file and carries a sha256 in place of the content.
    if grep -qF '"path": ".env"' "$manifest" 2>/dev/null; then pass "exec/manifest-names-the-file"
    else fail "exec/manifest-names-the-file" "$(head -40 "$manifest" 2>/dev/null)"; fi
    assert_eq "exec/manifest-hash-matches-content" \
        "$(node -e 'const c=require("crypto"),f=require("fs");process.stdout.write(c.createHash("sha256").update(f.readFileSync(process.argv[1])).digest("hex"))' "$(nodepath "$LINKED_RAW/.env")")" \
        "$(node -e 'const f=require("fs");const m=JSON.parse(f.readFileSync(process.argv[1],"utf8"));const e=m.files.find(x=>x.path===".env");process.stdout.write(e?e.sha256:"(missing)")' "$(nodepath "$BACKUP_RAW/manifest.json")")"

    assert_no_secret_leak "exec"
}

# ===========================================================================
# Group 3 — idempotency: a second execute neither duplicates nor corrupts
# ===========================================================================
group_idempotent() {
    local p before after
    before="$(node -e 'const m=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.stdout.write(m.files.length+"/"+m.files.map(f=>f.path).sort().join(","))' "$(nodepath "$BACKUP_RAW/manifest.json")")"
    p="$(write_payload bk-exec2 "{\"mode\":\"execute\",\"worktree_path\":\"$LINKED\",\"branch\":\"$BRANCH\",\"docker_check\":false,\"artifact_dir\":\"$PLANS\"}")"
    dispatch_backup "$p"
    assert_eq "idem/second-run-status" "copied" "$(field_of status)"
    after="$(node -e 'const m=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.stdout.write(m.files.length+"/"+m.files.map(f=>f.path).sort().join(","))' "$(nodepath "$BACKUP_RAW/manifest.json")")"
    assert_eq "idem/manifest-not-duplicated" "$before" "$after"
    if cmp -s "$LINKED_RAW/.env" "$BACKUP_RAW/.env"; then pass "idem/copy-not-corrupted"
    else fail "idem/copy-not-corrupted" "second execute damaged the copy"; fi
    assert_no_secret_leak "idem"
}

# ===========================================================================
# Group 4 — zero candidates: the caller's documented skip path is representable
# ===========================================================================
group_zero_files() {
    local p
    p="$(write_payload bk-dry0 "{\"mode\":\"dry_run\",\"worktree_path\":\"$EMPTY\",\"branch\":\"$BRANCH_EMPTY\",\"docker_check\":false,\"artifact_dir\":\"$PLANS\"}")"
    dispatch_backup "$p"
    assert_eq "zero/dry-status" "dry_run_complete" "$(field_of status)"
    case "$(field_of summary)" in
        "0 files"*) pass "zero/dry-reports-zero" ;;
        *) fail "zero/dry-reports-zero" "summary='$(field_of summary)'" ;;
    esac

    p="$(write_payload bk-exec0 "{\"mode\":\"execute\",\"worktree_path\":\"$EMPTY\",\"branch\":\"$BRANCH_EMPTY\",\"docker_check\":false,\"artifact_dir\":\"$PLANS\"}")"
    dispatch_backup "$p"
    assert_eq "zero/execute-status-is-skipped" "skipped" "$(field_of status)"
    assert_eq "zero/execute-artifact-null-form" "(none)" "$(field_of artifact_path)"
    if [ -d "$MAIN_RAW/.worktree-backup/$BRANCH_EMPTY" ]; then
        fail "zero/no-empty-backup-dir-created" "an empty backup directory was created anyway"
    else
        pass "zero/no-empty-backup-dir-created"
    fi
}

# ===========================================================================
# Group 5 — the backup root must be ignored by the TRACKED .gitignore
#
# Groups 1-4 prove the worker does not QUOTE a secret. This group covers the
# other way the same secret escapes: worktree-backup copies gitignored files —
# `.env` among them — into <main-root>/.worktree-backup/<branch>, verbatim and
# by design. If that directory is not ignored, the very next `git add -A` in the
# main worktree stages a copy of every local credential for commit.
#
# The rule has to live in the tracked `.gitignore`, not in `.git/info/exclude`:
# info/exclude is per-clone local state that no checkout inherits, so a machine
# that never ran the setup would stage the backups while this repo looked safe.
# Both halves are asserted — the file is tracked, AND it is the file git names
# as the source of the ignore decision.
# ===========================================================================
group_gitignore() {
    local gi="$AGENTS_DIR/.gitignore"
    if [ ! -f "$gi" ]; then
        fail "gitignore/file-exists" "$gi"
        return
    fi
    pass "gitignore/file-exists"

    if git -C "$AGENTS_DIR" ls-files --error-unmatch .gitignore >/dev/null 2>&1; then
        pass "gitignore/is-tracked"
    else
        fail "gitignore/is-tracked" ".gitignore is not tracked by git"
    fi

    if grep -qE '^\.worktree-backup/?$' "$gi"; then
        pass "gitignore/declares-worktree-backup"
    else
        fail "gitignore/declares-worktree-backup" "no '.worktree-backup/' line in $gi"
    fi

    # Which file git actually attributes the decision to. `git check-ignore -v`
    # prints `<source>:<line>:<pattern>\t<path>`; the source must be .gitignore,
    # never .git/info/exclude or a global core.excludesFile.
    local src
    src="$(git -C "$AGENTS_DIR" check-ignore -v ".worktree-backup/some-branch/.env" 2>/dev/null | head -1 | cut -d: -f1)"
    assert_eq "gitignore/ignore-source-is-the-tracked-file" ".gitignore" "$src"

    # Non-vacuity: check-ignore must be discriminating, not ignoring everything.
    if git -C "$AGENTS_DIR" check-ignore -q "README.md" 2>/dev/null; then
        fail "gitignore/check-ignore-is-discriminating" "README.md reported as ignored"
    else
        pass "gitignore/check-ignore-is-discriminating"
    fi
}

group_dry_run
group_execute
group_idempotent
group_zero_files
group_gitignore

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $((FAIL > 0 ? 1 : 0))
