#!/usr/bin/env bash
# tests/feature-2256-input-version-full-hash/content-kinds.sh
# Tests: hooks/lib/diff-fingerprint.js, hooks/lib/branch-diff.js
# Tags: supervisor, input-version, content-hash, binary, symlink, gitlink, TL2, scope:issue-specific
# #2256 round-2 C2: the version hashes file CONTENT, so every change git diff renders as
# "Binary files differ" (or not at all) still moves it.
# Parent: tests/feature-2256-input-version-full-hash.sh

set -uo pipefail
# shellcheck source=./_common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

# --- 1: 5MB identical prefix, identical length, different tail ---
repo="$(mk_repo big)"
node -e "
const fs = require('fs');
const head = Buffer.alloc(5 * 1024 * 1024, 0x41);
fs.writeFileSync('$WORK_NODE/big/large.bin', Buffer.concat([head, Buffer.from('TAIL-A')]));
" 2>&1
a="$(fp computeInputVersion "$repo")"
node -e "
const fs = require('fs');
const head = Buffer.alloc(5 * 1024 * 1024, 0x41);
fs.writeFileSync('$WORK_NODE/big/large.bin', Buffer.concat([head, Buffer.from('TAIL-B')]));
" 2>&1
b="$(fp computeInputVersion "$repo")"
assert_ne "1: a tail-only difference past 5MB changes the input version" "$a" "$b"
assert_match "2: the tail-different version is still a full digest" "$b" '^[0-9a-f]{64}$'

# --- 3-5: binary content, in each of the three change states ---
bin_probe() {
    local label="$1" state="$2"
    local r; r="$(mk_repo "bin-$state")"
    local dir="$WORK/bin-$state"
    node -e "const fs=require('fs');fs.writeFileSync('$WORK_NODE/bin-$state/b.dat', Buffer.from([0,1,2,3,255,0,9]));" 2>&1
    case "$state" in
        committed) git -C "$dir" add -A; git -C "$dir" commit -q -m b1 ;;
        staged) git -C "$dir" add -A ;;
        untracked) : ;;
    esac
    local v1; v1="$(fp computeInputVersion "$r")"
    node -e "const fs=require('fs');fs.writeFileSync('$WORK_NODE/bin-$state/b.dat', Buffer.from([0,1,2,3,254,0,9]));" 2>&1
    case "$state" in
        committed) git -C "$dir" add -A; git -C "$dir" commit -q -m b2 ;;
        staged) git -C "$dir" add -A ;;
        untracked) : ;;
    esac
    local v2; v2="$(fp computeInputVersion "$r")"
    assert_ne "$label" "$v1" "$v2"
}
bin_probe "3: a committed binary's content change moves the version" committed
bin_probe "4: a staged binary's content change moves the version" staged
bin_probe "5: an untracked binary's content change moves the version" untracked

# --- 6: a text file marked -diff in .gitattributes ---
repo="$(mk_repo attr)"
printf 'nodiff.txt -diff\n' > "$WORK/attr/.gitattributes"
printf 'first\n' > "$WORK/attr/nodiff.txt"
git -C "$WORK/attr" add -A
git -C "$WORK/attr" commit -q -m attr
v1="$(fp computeInputVersion "$repo")"
printf 'second\n' > "$WORK/attr/nodiff.txt"
v2="$(fp computeInputVersion "$repo")"
assert_ne "6: a -diff text file's content change moves the version" "$v1" "$v2"

# --- 7-9: delete, rename, and the executable mode bit ---
repo="$(mk_repo meta)"
printf 'x\n' > "$WORK/meta/a.txt"
printf 'y\n' > "$WORK/meta/b.txt"
git -C "$WORK/meta" add -A
git -C "$WORK/meta" commit -q -m meta
base="$(fp computeInputVersion "$repo")"
rm -f "$WORK/meta/a.txt"
v_del="$(fp computeInputVersion "$repo")"
assert_ne "7: deleting a tracked file moves the version" "$base" "$v_del"

git -C "$WORK/meta" checkout -q -- a.txt
git -C "$WORK/meta" mv b.txt c.txt
v_ren="$(fp computeInputVersion "$repo")"
assert_ne "8: renaming a tracked file moves the version" "$base" "$v_ren"

git -C "$WORK/meta" mv c.txt b.txt
git -C "$WORK/meta" update-index --chmod=+x b.txt
v_mode="$(fp computeInputVersion "$repo")"
assert_ne "9: flipping the executable mode bit moves the version" "$base" "$v_mode"

# --- 10: a symlink's target change ---
repo="$(mk_repo link)"
printf 'target-one\n' > "$WORK/link/t1.txt"
printf 'target-two\n' > "$WORK/link/t2.txt"
if ln -s t1.txt "$WORK/link/ptr" 2>/dev/null; then
    v1="$(fp computeInputVersion "$repo")"
    rm -f "$WORK/link/ptr"
    ln -s t2.txt "$WORK/link/ptr"
    v2="$(fp computeInputVersion "$repo")"
    assert_ne "10: a symlink retargeted to another file moves the version" "$v1" "$v2"
else
    fail "10: a symlink retargeted to another file moves the version" \
        "this host cannot create symlinks — the symlink kind is untested here, not skipped"
fi

# --- 11: a gitlink (submodule) pointer change ---
repo="$(mk_repo super)"
sub="$(mk_repo subm)"
printf 'sub-change\n' > "$WORK/subm/seed.txt"
git -C "$WORK/subm" add -A
git -C "$WORK/subm" commit -q -m s1
if git -C "$WORK/super" -c protocol.file.allow=always submodule add -q "$WORK/subm" sub 2>/dev/null; then
    git -C "$WORK/super" commit -q -m addsub
    v1="$(fp computeInputVersion "$repo")"
    printf 'sub-change-2\n' > "$WORK/super/sub/seed.txt"
    git -C "$WORK/super/sub" add -A
    git -C "$WORK/super/sub" commit -q -m s2
    v2="$(fp computeInputVersion "$repo")"
    assert_ne "11: a gitlink pointing at a new submodule sha moves the version" "$v1" "$v2"
else
    fail "11: a gitlink pointing at a new submodule sha moves the version" \
        "the submodule fixture could not be created — the gitlink kind is untested here, not skipped"
fi

# --- 12-16: computeWorkingTreeDiff reports the union of every change state ---
repo="$(mk_repo union)"
printf 'committed\n' > "$WORK/union/c.txt"
git -C "$WORK/union" add -A
git -C "$WORK/union" commit -q -m c
printf 'staged\n' > "$WORK/union/s.txt"
git -C "$WORK/union" add s.txt
printf 'unstaged\n' >> "$WORK/union/c.txt"
printf 'untracked\n' > "$WORK/union/u.txt"
js="$WORK/wtd.js"
{
    printf '%s\n' "const bd = require('$BD_NODE');"
    printf '%s\n' "const r = bd.computeWorkingTreeDiff('$repo') || {};"
    printf '%s\n' "const files = (r.changedFiles || []).slice().sort().join(',');"
    printf '%s\n' "const untracked = (r.untrackedFiles || []).slice().sort().join(',');"
    printf '%s\n' "process.stdout.write([String(r.mergeBase || ''), files, untracked, Array.isArray(r.rawRecords) ? 'records' : 'no-records'].join('|'));"
} > "$js"
wtd="$(bash "$RWT" 60 node "$js" 2>&1)"
assert_match "12: computeWorkingTreeDiff resolves a merge base" "$wtd" '^[0-9a-f]{7,}\|'
assert_match "13: changedFiles includes the committed file" "$wtd" 'c\.txt'
assert_match "14: changedFiles includes the staged file" "$wtd" 's\.txt'
assert_match "15: changedFiles includes the untracked file" "$wtd" 'u\.txt'
assert_match "16: untrackedFiles lists the untracked file separately" "$wtd" '\|u\.txt\|'
assert_match "17: computeWorkingTreeDiff exposes rawRecords" "$wtd" '\|records$'

# --- 18: an untracked file's content change alone moves the version ---
repo="$(mk_repo untr)"
printf 'v1\n' > "$WORK/untr/note.txt"
v1="$(fp computeInputVersion "$repo")"
printf 'v2\n' > "$WORK/untr/note.txt"
v2="$(fp computeInputVersion "$repo")"
assert_ne "18: rewriting an untracked file's content moves the version" "$v1" "$v2"

# --- 19: an unreadable path degrades to a recorded kind instead of throwing ---
repo="$(mk_repo unread)"
mkdir -p "$WORK/unread/locked"
printf 'x\n' > "$WORK/unread/locked/secret.txt"
chmod 000 "$WORK/unread/locked/secret.txt" 2>/dev/null || true
v="$(fp computeInputVersion "$repo")"
chmod 644 "$WORK/unread/locked/secret.txt" 2>/dev/null || true
assert_match "19: an unreadable file yields a digest rather than an exception" "$v" '^[0-9a-f]{64}$'

# --- 20-24: parseRawZ decodes every `git diff --raw -z` record kind. A pathCount=2
# regression on R/C would silently drop the rename/copy paths from changedFiles and
# blind scope-drift, so each kind's path count and contents are pinned directly.
# parseRawZ is module-private, so it is lifted out of branch-diff.js via vm with a
# createRequire-bound require (no source edit) and driven with synthetic -z records.
prz="$WORK/parseraw.js"
{
    printf '%s\n' "const fs = require('fs');"
    printf '%s\n' "const vm = require('vm');"
    printf '%s\n' "const path = require('path');"
    printf '%s\n' "const { createRequire } = require('module');"
    printf '%s\n' "const BD = '$BD_NODE';"
    printf '%s\n' "const src = fs.readFileSync(BD, 'utf8');"
    printf '%s\n' "const sandbox = { require: createRequire(BD), module: { exports: {} }, exports: {}, process, console, Buffer, __filename: BD, __dirname: path.dirname(BD) };"
    printf '%s\n' "vm.createContext(sandbox);"
    printf '%s\n' "vm.runInContext(src, sandbox, { filename: BD });"
    printf '%s\n' "const parseRawZ = sandbox.parseRawZ;"
    printf '%s\n' "const NUL = String.fromCharCode(0);"
    printf '%s\n' "const H = '100644', Z = '000000';"
    printf '%s\n' "const S0 = '0000000000000000000000000000000000000000';"
    printf '%s\n' "const S1 = '1111111111111111111111111111111111111111';"
    printf '%s\n' "const S2 = '2222222222222222222222222222222222222222';"
    printf '%s\n' "const cases = ["
    printf '%s\n' "  { name: 'A', input: ':' + Z + ' ' + H + ' ' + S0 + ' ' + S1 + ' A' + NUL + 'added.txt' + NUL },"
    printf '%s\n' "  { name: 'D', input: ':' + H + ' ' + Z + ' ' + S1 + ' ' + S0 + ' D' + NUL + 'deleted.txt' + NUL },"
    printf '%s\n' "  { name: 'R', input: ':' + H + ' ' + H + ' ' + S1 + ' ' + S2 + ' R100' + NUL + 'old/name.txt' + NUL + 'new/name.txt' + NUL },"
    printf '%s\n' "  { name: 'C', input: ':' + H + ' ' + H + ' ' + S1 + ' ' + S2 + ' C100' + NUL + 'src.txt' + NUL + 'copy.txt' + NUL },"
    printf '%s\n' "  { name: 'MAL', input: 'no-leading-colon' + NUL + 'stray.txt' + NUL },"
    printf '%s\n' "];"
    printf '%s\n' "const lines = [];"
    printf '%s\n' "cases.forEach((c) => {"
    printf '%s\n' "  const recs = parseRawZ(c.input);"
    printf '%s\n' "  const paths = [].concat.apply([], recs.map((r) => r.paths));"
    printf '%s\n' "  lines.push(c.name + '|' + paths.length + '|' + paths.join(','));"
    printf '%s\n' "});"
    printf '%s\n' "process.stdout.write(lines.join(String.fromCharCode(10)) + String.fromCharCode(10));"
} > "$prz"
prz_out="$(bash "$RWT" 60 node "$prz" 2>&1)"
assert_match "20: parseRawZ decodes an add (A) as one path" "$prz_out" '^A\|1\|added\.txt$'
assert_match "21: parseRawZ decodes a delete (D) as one path" "$prz_out" '^D\|1\|deleted\.txt$'
assert_match "22: parseRawZ decodes a rename (R) as two paths, old then new" \
    "$prz_out" '^R\|2\|old/name\.txt,new/name\.txt$'
assert_match "23: parseRawZ decodes a copy (C) as two paths, source then dest" \
    "$prz_out" '^C\|2\|src\.txt,copy\.txt$'
assert_match "24: parseRawZ yields no record for a malformed line (missing leading colon)" \
    "$prz_out" '^MAL\|0\|$'

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
