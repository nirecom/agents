#!/usr/bin/env bash
# Tests: bin/check-verification-gate.sh
# Tags: verification-gate, base-is-head, scope:common

set -u

_TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENTS_DIR="$(git -C "$_TEST_DIR" rev-parse --show-toplevel 2>/dev/null)"
[ -n "$AGENTS_DIR" ] || AGENTS_DIR="$(cd "$_TEST_DIR/../.." && pwd)"

GATE_SRC="$AGENTS_DIR/bin/check-verification-gate.sh"
BIH_RWT="$AGENTS_DIR/bin/run-with-timeout.sh"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

run_to() { bash "$BIH_RWT" 120 "$@"; }

assert_eq() {
    local desc="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then pass "$desc"; else fail "$desc — want: [$want], got: [$got]"; fi
}
assert_contains() {
    local desc="$1" needle="$2" hay="$3"
    case "$hay" in *"$needle"*) pass "$desc" ;; *) fail "$desc — expected to contain [$needle], got: [$hay]" ;; esac
}
assert_not_contains() {
    local desc="$1" needle="$2" hay="$3"
    case "$hay" in *"$needle"*) fail "$desc — expected NOT to contain [$needle], got: [$hay]" ;; *) pass "$desc" ;; esac
}

# Fixture isolation (rules/test/fixture-isolation.md).
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export CLAUDE_WORKFLOW_DIR="$tmp/wf"; mkdir -p "$CLAUDE_WORKFLOW_DIR"
export WORKFLOW_PLANS_DIR="$tmp/plans"; mkdir -p "$WORKFLOW_PLANS_DIR"
unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID CLAUDE_ENV_FILE 2>/dev/null || true
unset AGENTS_CONFIG_DIR 2>/dev/null || true

# The gate resolves its sibling via BASH_SOURCE, so a copy (not symlink) is required.
make_gate_bin() {
    local bindir="$1"; shift
    mkdir -p "$bindir"
    cp "$GATE_SRC" "$bindir/check-verification-gate.sh"
    chmod +x "$bindir/check-verification-gate.sh"
    local stub="$bindir/resolve-merge-base.sh" kv
    {
        echo '#!/usr/bin/env bash'
        echo 'touch "$(dirname "$0")/stub-was-called"'
        for kv in "$@"; do
            printf 'echo %q\n' "$kv"
        done
    } > "$stub"
    chmod +x "$stub"
}

# Shared fixture repo for cases c_files, c_bih, d_existing_degraded.
repo="$tmp/repo"
git init -q "$repo"
git -C "$repo" config core.hooksPath /dev/null
git -C "$repo" config user.email test@example.invalid
git -C "$repo" config user.name test
printf 'seed\n' > "$repo/README.md"
git -C "$repo" add README.md
git -C "$repo" commit -q -m init
HEAD_SHA="$(git -C "$repo" rev-parse HEAD)"

# Case (c-files) — --files mode smoke / regression guard (GREEN both sides).
case_c_files() {
    local out rc
    rc=0
    out="$(run_to bash "$GATE_SRC" --files "skills/foo/SKILL.md" 2>/dev/null)" || rc=$?
    assert_eq "CF-1 --files mode exits 0" "0" "$rc"
    assert_contains "CF-2 --files classifies a SKILL.md as skill-orchestration" "skill-orchestration" "$out"
    assert_not_contains "CF-3 --files mode never raises merge-base-suspect" "merge-base-suspect" "$out"
}

# Case (c-bih) — base_is_head=true must trigger the degraded path (RED pre-fix).
case_c_bih() {
    local bindir="$tmp/bih_bin" out err rc
    make_gate_bin "$bindir" "state=RESOLVED" "base=$HEAD_SHA" "base_is_head=true"
    mkdir -p "$repo/skills/newskill"
    printf '# skill\n' > "$repo/skills/newskill/SKILL.md"
    rc=0
    ( cd "$repo" && run_to bash "$bindir/check-verification-gate.sh" ) \
        > "$tmp/bih.out" 2> "$tmp/bih.err" || rc=$?
    out="$(cat "$tmp/bih.out")"
    err="$(cat "$tmp/bih.err")"
    assert_eq "BIH-0 the stubbed resolver was actually invoked" \
        "yes" "$([ -f "$bindir/stub-was-called" ] && echo yes || echo no)"
    assert_eq "BIH-rc the gate still exits 0 (verdict produced)" "0" "$rc"
    assert_contains "BIH-1 base_is_head=true triggers the degraded merge-base notification" "merge-base" "$err"
    assert_contains "BIH-2 ... and raises the merge-base-suspect category" "merge-base-suspect" "$out"
    assert_contains "BIH-3 the untracked risky SKILL.md is no longer invisible" "skill-orchestration" "$out"
}

# Case (c-bih-tracked) — base_is_head=true WITH a tracked dirty file (CPR-ORTH counterpart).
# Uses a separate repo to avoid contamination from c_bih's untracked file.
case_c_bih_tracked() {
    local bindir="$tmp/bih_tracked_bin" repo3 tracked_sha out err rc
    repo3="$tmp/repo3"
    git init -q "$repo3"
    git -C "$repo3" config core.hooksPath /dev/null
    git -C "$repo3" config user.email test@example.invalid
    git -C "$repo3" config user.name test
    printf 'seed\n' > "$repo3/README.md"
    mkdir -p "$repo3/skills/foo"
    printf '# skill\n' > "$repo3/skills/foo/SKILL.md"
    git -C "$repo3" add README.md
    git -C "$repo3" add skills/foo/SKILL.md
    git -C "$repo3" commit -q -m init
    # Modify the tracked file without committing; git diff HEAD --name-only returns it.
    printf '# modified\n' >> "$repo3/skills/foo/SKILL.md"
    tracked_sha="$(git -C "$repo3" rev-parse HEAD)"
    make_gate_bin "$bindir" "state=RESOLVED" "base=$tracked_sha" "base_is_head=true"
    rc=0
    ( cd "$repo3" && run_to bash "$bindir/check-verification-gate.sh" ) \
        > "$tmp/bih_t.out" 2> "$tmp/bih_t.err" || rc=$?
    out="$(cat "$tmp/bih_t.out")"
    err="$(cat "$tmp/bih_t.err")"
    assert_eq "BIH-T-rc gate exits 0 with tracked dirty file" "0" "$rc"
    assert_contains "BIH-T-1 base_is_head=true + tracked dirty file raises degraded notification" "merge-base" "$err"
    assert_contains "BIH-T-2 degraded_scope_files picks up tracked dirty SKILL.md -> skill-orchestration" "skill-orchestration" "$out"
    assert_contains "BIH-T-3 tracked-dirty path raises merge-base-suspect (same as untracked path)" "merge-base-suspect" "$out"
}

# Case (c-bih-recorded) — state=RECORDED + base_is_head=true must ALSO trigger the
# degraded path (BIH-R-*: CPR-ORTH counterpart of case_c_bih which uses state=RESOLVED).
# The fix covers `RECORDED|RESOLVED` together; this case is RED pre-fix (silent pass) and
# GREEN post-fix (degraded notification in stderr).
case_c_bih_recorded() {
    local bindir="$tmp/bih_rec_bin" out err rc
    make_gate_bin "$bindir" "state=RECORDED" "base=$HEAD_SHA" "base_is_head=true"
    # The untracked skills/newskill/SKILL.md already exists in $repo from case_c_bih.
    rc=0
    ( cd "$repo" && run_to bash "$bindir/check-verification-gate.sh" ) \
        > "$tmp/bih_r.out" 2> "$tmp/bih_r.err" || rc=$?
    out="$(cat "$tmp/bih_r.out")"
    err="$(cat "$tmp/bih_r.err")"
    assert_eq "BIH-R-0 the stubbed resolver was actually invoked" \
        "yes" "$([ -f "$bindir/stub-was-called" ] && echo yes || echo no)"
    assert_eq "BIH-R-rc the gate still exits 0 (verdict produced)" "0" "$rc"
    assert_contains "BIH-R-1 state=RECORDED + base_is_head=true triggers the degraded merge-base notification" "merge-base" "$err"
    assert_contains "BIH-R-2 ... and raises the merge-base-suspect category" "merge-base-suspect" "$out"
    assert_contains "BIH-R-3 the untracked risky SKILL.md is no longer invisible" "skill-orchestration" "$out"
}

# Case (d) — existing degraded path (empty mb_base) still notifies (GREEN both sides).
case_d_existing_degraded() {
    local bindir="$tmp/deg_bin" err rc
    make_gate_bin "$bindir" "state=RECORDED" "base="
    rc=0
    ( cd "$repo" && run_to bash "$bindir/check-verification-gate.sh" ) \
        > "$tmp/deg.out" 2> "$tmp/deg.err" || rc=$?
    err="$(cat "$tmp/deg.err")"
    assert_eq "D-0 the stubbed resolver was invoked" \
        "yes" "$([ -f "$bindir/stub-was-called" ] && echo yes || echo no)"
    assert_contains "D-1 an empty merge-base still narrows scope and notifies" "merge-base" "$err"
}

# Case (e-bnh) — base_is_head=false NORMAL path regression guard (CPR-ORTH, GREEN both sides).
case_e_base_not_head() {
    local bindir="$tmp/bnh_bin" repo2 base_sha out rc
    repo2="$tmp/repo2"
    git init -q "$repo2"
    git -C "$repo2" config core.hooksPath /dev/null
    git -C "$repo2" config user.email test@example.invalid
    git -C "$repo2" config user.name test
    printf 'seed\n' > "$repo2/README.md"
    git -C "$repo2" add README.md
    git -C "$repo2" commit -q -m init
    base_sha="$(git -C "$repo2" rev-parse HEAD)"
    mkdir -p "$repo2/skills/normalskill"
    printf '# skill\n' > "$repo2/skills/normalskill/SKILL.md"
    git -C "$repo2" add skills/normalskill/SKILL.md
    git -C "$repo2" commit -q -m add-skill
    make_gate_bin "$bindir" "state=RESOLVED" "base=$base_sha" "base_is_head=false"
    rc=0
    ( cd "$repo2" && run_to bash "$bindir/check-verification-gate.sh" ) \
        > "$tmp/bnh.out" 2> "$tmp/bnh.err" || rc=$?
    out="$(cat "$tmp/bnh.out")"
    assert_eq "BNH-0 the stubbed resolver was invoked" \
        "yes" "$([ -f "$bindir/stub-was-called" ] && echo yes || echo no)"
    assert_eq "BNH-rc the gate exits 0 (verdict produced)" "0" "$rc"
    assert_contains "BNH-1 the committed-range diff surfaces the risk file (normal classification)" \
        "skill-orchestration" "$out"
    assert_not_contains "BNH-2 base_is_head=false is NOT the degraded path (no merge-base-suspect)" \
        "merge-base-suspect" "$out"
}

case_c_files
case_c_bih
case_c_bih_tracked
case_c_bih_recorded
case_d_existing_degraded
case_e_base_not_head

echo ""
echo "Results: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
