#!/usr/bin/env bash
# tests/hooks/feature-1937-worker-dispatch-dir-expand-capability.sh
# Tests: hooks/lib/worker-dispatch-registry.js, bin/worker-dispatch/capability.js
# Tags: worker-dispatch, worktree-backup, dir_expand, capability, type-validation, TL2, dup-group-keep:size-hard-limit, scope:issue-specific
#
# Issue #1937: worktree-backup gains payload `dir_expand: bool`. This pins its
# TYPE contract — a non-boolean must be refused at the capability wall.
# Separate file (not a row in feature-1643-worker-dispatch-capability.sh) only
# because that suite exceeds the 500-line HARD split limit; see dup-group-keep tag.

set -u

if command -v timeout >/dev/null 2>&1 && [ -z "${_WD1937_CAP_INNER:-}" ]; then
    _WD1937_CAP_INNER=1 timeout 300 bash "$0" "$@"
    exit $?
fi

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
. "$AGENTS_DIR/tests/lib/harness.sh"
DISPATCH_JS="$AGENTS_DIR/bin/worker-dispatch.js"
REGISTRY_JS="$AGENTS_DIR/hooks/lib/worker-dispatch-registry.js"
nodepath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi; }

if [ ! -f "$DISPATCH_JS" ] || [ ! -f "$REGISTRY_JS" ]; then
    fail "0: prerequisites missing" "dispatcher=$DISPATCH_JS registry=$REGISTRY_JS"
    echo ""
    echo "Total: PASS=$PASS FAIL=$FAIL"
    exit 1
fi

TMPD="$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/wd-1937cap-$$")"
mkdir -p "$TMPD"
trap 'rm -rf "$TMPD"' EXIT

# Fixture: main repo + one registered linked worktree, so every probe-payload
# field EXCEPT dir_expand is valid. That isolation makes any capability error
# unambiguously about dir_expand.
MAIN_RAW="$TMPD/mainrepo"
mkdir -p "$MAIN_RAW"
git -C "$MAIN_RAW" init -q -b main
git -C "$MAIN_RAW" config user.email "test@example.com"
git -C "$MAIN_RAW" config user.name "Test"
git -C "$MAIN_RAW" config core.hooksPath /dev/null
printf '.env\n' > "$MAIN_RAW/.gitignore"
echo init > "$MAIN_RAW/README.md"
git -C "$MAIN_RAW" add .gitignore README.md >/dev/null 2>&1
git -C "$MAIN_RAW" commit -q --no-verify -m initial >/dev/null 2>&1

BRANCH="feature/de-cap-probe"
LINKED_RAW="$TMPD/linked-wt"
git -C "$MAIN_RAW" worktree add -q -b "$BRANCH" "$LINKED_RAW" >/dev/null 2>&1
PLANS_RAW="$TMPD/plans"; mkdir -p "$PLANS_RAW"

MAIN="$(nodepath "$MAIN_RAW")"
LINKED="$(nodepath "$LINKED_RAW")"
PLANS="$(nodepath "$PLANS_RAW")"

DOUT=""; DRC=0
dispatch_backup() {
    DRC=0
    printf '%s' "$2" > "$PLANS_RAW/$1.json"
    DOUT="$(run_with_timeout 90 env "WORKFLOW_PLANS_DIR=$PLANS" \
        node "$(nodepath "$DISPATCH_JS")" worktree-backup "$MAIN" "$PLANS/$1.json" 2>/dev/null)" || DRC=$?
}
field_of() {
    local v
    v="$(printf '%s\n' "$DOUT" | sed -n "s/^$1: //p" | head -1)"
    v="${v%\"}"; v="${v#\"}"
    printf '%s' "$v"
}

# 1 — registry declares dir_expand as a boolean (Step 1 contract)
case_begin "registry-shape" "hooks/lib/worker-dispatch-registry.js"
group_registry_shape() {
    local got
    got="$(node -e '
const reg = require(process.argv[1]);
const e = (reg.workers || {})["worktree-backup"];
const spec = e && e.payloadSpec ? e.payloadSpec : {};
const f = spec.dir_expand;
process.stdout.write(f ? String(f.type) : "(absent)");
' "$(nodepath "$REGISTRY_JS")" 2>/dev/null)"
    assert_eq "registry/dir_expand-declared-as-bool" "bool" "$got"
}
group_registry_shape
case_end

# 2 — a non-boolean dir_expand is refused with the boolean type message
case_begin "reject-non-bool" "bin/worker-dispatch/capability.js"
group_reject_non_bool() {
    dispatch_backup "de-yes" \
        "{\"mode\":\"execute\",\"worktree_path\":\"$LINKED\",\"branch\":\"$BRANCH\",\"docker_check\":false,\"dir_expand\":\"yes\",\"artifact_dir\":\"$PLANS\"}"
    assert_eq "reject/exit0" "0" "$DRC"
    assert_eq "reject/status-failed" "failed" "$(field_of status)"
    case "$(field_of summary)" in
        *"field 'dir_expand' must be a boolean"*) pass "reject/summary-names-the-boolean-type" ;;
        *) fail "reject/summary-names-the-boolean-type" "summary='$(field_of summary)'" ;;
    esac
}
group_reject_non_bool
case_end

# 3 — dir_expand omitted must never itself be a rejection (optional field)
case_begin "omitted-accepted" "bin/worker-dispatch/capability.js"
group_omitted_is_accepted() {
    dispatch_backup "de-omit" \
        "{\"mode\":\"dry_run\",\"worktree_path\":\"$LINKED\",\"branch\":\"$BRANCH\",\"docker_check\":false,\"artifact_dir\":\"$PLANS\"}"
    assert_eq "omit/exit0" "0" "$DRC"
    case "$(field_of summary)" in
        *"dir_expand"*) fail "omit/no-dir_expand-complaint" "summary='$(field_of summary)'" ;;
        *) pass "omit/no-dir_expand-complaint" ;;
    esac
}
group_omitted_is_accepted
case_end

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $((FAIL > 0 ? 1 : 0))
