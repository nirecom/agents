# Non-regular plan targets (#2513 review_security F2): syncPlanFile / publishedBlobUrl act
# only on an lstat-regular, non-symlink file; carried local-only entries never publish a
# symlink (mode 120000) entry or its target's content. Sourced last by
# ../feature-2513-plan-sync-lib.sh (needs flow-helpers.sh). Symlinks are made with Node's
# fs.symlinkSync (Git Bash `ln -s` silently copies on Windows); cases needing a real
# symlink are skipped when the host cannot create one; mode-120000 entries are built by
# plumbing, so SL-4 / SL-4b / SL-6 (local-main part) and SL-0 / SL-3 / SL-5 always run.
# Also F1/F2: hard-linked plan names (HL), the verified-fd reader (RD), lstat->open swap (TOC), CRLF/UTF-8 (REG).

unset GIT_SSH_COMMAND GIT_SSH_VARIANT
SL_MARK="PLAN-SYNC-SL-SECRET-7f3a"
SL_SECRET="$PSF_ROOT/sl-secret/secret.txt"
mkdir -p "$PSF_ROOT/sl-secret"
printf '%s\n' "$SL_MARK" > "$SL_SECRET"

# sl_symlink <target> <link> [file|dir] — exit 0 only when <link> is a real symlink afterwards.
sl_symlink() {
  psf_timeout 30 node -e '
const fs = require("fs");
try { fs.symlinkSync(process.argv[1], process.argv[2], process.argv[3]); } catch (e) { process.exit(1); }
process.exit(fs.lstatSync(process.argv[2]).isSymbolicLink() ? 0 : 1);' "$1" "$2" "${3:-file}" 2>/dev/null
}

# sl_object_hits <git-dir> <needle> — count of object payloads (any type, packed or loose)
# holding <needle>; prints "git-error" (never 0) when git cannot list the objects.
sl_object_hits() {
  local dump="$PSF_ROOT/sl-dump.bin"
  git -C "$1" cat-file --batch-all-objects --batch > "$dump" 2>/dev/null || { echo "git-error"; return 1; }
  grep -caF -- "$2" "$dump" || true
}

# sl_mode_count <git-dir> <mode> — count of <mode> entries in the history of every ref; "git-error" on failure.
sl_mode_count() {
  local raw="$PSF_ROOT/sl-raw.txt"
  git -C "$1" log --all --format= --raw --no-abbrev > "$raw" 2>/dev/null || { echo "git-error"; return 1; }
  grep -cE "(^:| )$2 " "$raw" || true
}
sl_symlink_modes() { sl_mode_count "$1" 120000; }

# expect_pos <name> <count> — passes only for an integer >= 1 (positive control).
expect_pos() {
  if [[ "$2" =~ ^[0-9]+$ ]] && (( $2 >= 1 )); then pass "$1"; else fail "$1" "want>=1 got=$2"; fi
}

# sl_blob <repo> <content> — writes <content> (no trailing newline) as a blob, prints its sha.
sl_blob() { printf '%s' "$2" | git -C "$1" hash-object -w --stdin; }

# sl_entry_commit <repo> <mode> <rel> <sha> — commit <rel> with <mode> on top of refs/heads/main.
sl_entry_commit() {
  local d="$1" idx="$1/.git/sl-index" parent tree commit
  parent="$(git -C "$d" rev-parse refs/heads/main)" || return 1
  GIT_INDEX_FILE="$idx" git -C "$d" read-tree "$parent" || return 1
  GIT_INDEX_FILE="$idx" git -C "$d" update-index --add --cacheinfo "$2,$4,$3" || return 1
  tree="$(GIT_INDEX_FILE="$idx" git -C "$d" write-tree)" || return 1
  rm -f "$idx"
  commit="$(git -C "$d" commit-tree "$tree" -p "$parent" -m "local-only $2 entry $3")" || return 1
  git -C "$d" update-ref refs/heads/main "$commit"
}

# sl_link_commit <repo> <rel> <link-text> — commit <rel> as mode 120000 on top of refs/heads/main.
sl_link_commit() { sl_entry_commit "$1" 120000 "$2" "$(sl_blob "$1" "$3")"; }

# sl_mode_of <git-dir> <rel> — mode of <rel> on refs/heads/main ("absent" when missing).
sl_mode_of() { local m; m="$(git -C "$1" ls-tree refs/heads/main -- "$2" 2>/dev/null)"; printf '%s' "${m:0:6}"; [ -n "$m" ] || printf 'absent'; }

echo "=== SL-0: helper positive controls ==="
expect_eq "SL-0 sl_object_hits on a non-repo -> git-error" "$(sl_object_hits "$PSF_ROOT/sl-no-such-repo" x)" "git-error"
expect_eq "SL-0 sl_symlink_modes on a non-repo -> git-error" "$(sl_symlink_modes "$PSF_ROOT/sl-no-such-repo")" "git-error"

# blob_url <plansDir> <absPath> — publishedBlobUrl result as a string ("null" when none).
blob_url() {
  psf_node 'process.stdout.write(String(ps.publishedBlobUrl(process.argv[1], process.argv[2])));' "$1" "$2"
}

mkdir -p "$PSF_ROOT/sl-probe"
printf 'probe\n' > "$PSF_ROOT/sl-probe/t"
if sl_symlink "$PSF_ROOT/sl-probe/t" "$PSF_ROOT/sl-probe/l"; then SL_CAN=yes; else SL_CAN=no; fi
echo "=== SL: host can create symlinks: $SL_CAN ==="
SL_SKIP_MSG="host cannot create symlinks (Windows without Developer Mode?)"

SL_BARE="$PSF_ROOT/sl-bare.git"; psf_make_bare "$SL_BARE"
SLD="$PSF_ROOT/sl-plans"; mkdir -p "$SLD"
OUT="$(provision "$SLD" "$SL_BARE")"
expect_eq "SL precondition: provisionRepo ok" "${OUT%%|*}" "ok"

echo "=== SL-1: symlinked plan file -> skipped/not-regular-file, nothing leaks ==="
if [ "$SL_CAN" != yes ]; then
  skip "SL-1 symlinked plan file: $SL_SKIP_MSG"
elif sl_symlink "$SL_SECRET" "$SLD/sl1-intent.md"; then
  SL1_BEFORE="$(git -C "$SL_BARE" rev-parse --verify -q refs/heads/main || echo missing)"
  OUT="$(export PLAN_SYNC_REMOTE_URL="$SL_BARE"; sync_local "$SLD" sl1-intent.md)"
  expect_eq "SL-1 syncPlanFile(symlink) -> skipped|not-regular-file" "$OUT" "skipped|not-regular-file|"
  expect_eq "SL-1 bare main SHA unchanged" "$(git -C "$SL_BARE" rev-parse --verify -q refs/heads/main || echo missing)" "$SL1_BEFORE"
  expect_eq "SL-1 bare main tree has no sl1-intent.md" "$(tree_of "$SL_BARE")" ".gitignore "
  expect_eq "SL-1 no bare object holds the symlink target's content" "$(sl_object_hits "$SL_BARE" "$SL_MARK")" "0"
  expect_eq "SL-1 no local plans-repo object holds the target's content" "$(sl_object_hits "$SLD" "$SL_MARK")" "0"
  expect_eq "SL-1 symlink left in place" "$(test -L "$SLD/sl1-intent.md" && echo link)" "link"
else
  fail "SL-1 fixture" "could not create $SLD/sl1-intent.md as a symlink"
fi

echo "=== SL-3: directory / missing path named like a plan -> skipped/not-regular-file ==="
SL3_MARK="PLAN-SYNC-SL3-DIR-INNER-91c2"
SL3_TREE_BEFORE="$(tree_of "$SL_BARE")"
mkdir -p "$SLD/sl3-outline.md"
printf '%s\n' "$SL3_MARK" > "$SLD/sl3-outline.md/inner.txt"
OUT="$(export PLAN_SYNC_REMOTE_URL="$SL_BARE"; sync_local "$SLD" sl3-outline.md)"
expect_eq "SL-3 syncPlanFile(directory) -> skipped|not-regular-file" "$OUT" "skipped|not-regular-file|"
OUT="$(export PLAN_SYNC_REMOTE_URL="$SL_BARE"; sync_local "$SLD" sl3m-detail.md)"
expect_eq "SL-3 syncPlanFile(missing path) -> skipped|not-regular-file" "$OUT" "skipped|not-regular-file|"
if [ "$SL_CAN" != yes ]; then
  skip "SL-3 dangling symlink / symlink to a directory: $SL_SKIP_MSG"
else
  if sl_symlink "$PSF_ROOT/sl-secret/no-such-file" "$SLD/sl3g-intent.md"; then
    OUT="$(export PLAN_SYNC_REMOTE_URL="$SL_BARE"; sync_local "$SLD" sl3g-intent.md)"
    expect_eq "SL-3 syncPlanFile(dangling symlink) -> skipped|not-regular-file" "$OUT" "skipped|not-regular-file|"
  else fail "SL-3 fixture" "dangling symlink not created"; fi
  if sl_symlink "$PSF_ROOT/sl-secret" "$SLD/sl3d-detail.md" dir; then
    OUT="$(export PLAN_SYNC_REMOTE_URL="$SL_BARE"; sync_local "$SLD" sl3d-detail.md)"
    expect_eq "SL-3 syncPlanFile(symlink to a directory) -> skipped|not-regular-file" "$OUT" "skipped|not-regular-file|"
  else fail "SL-3 fixture" "directory symlink not created"; fi
fi
expect_eq "SL-3 bare main tree unchanged" "$(tree_of "$SL_BARE")" "$SL3_TREE_BEFORE"
expect_eq "SL-3 no bare object holds the directory's inner content" "$(sl_object_hits "$SL_BARE" "$SL3_MARK")" "0"

echo "=== SL-5: a regular plan file still pushes (regression) ==="
printf 'sl5 intent\n' > "$SLD/sl5-intent.md"
OUT="$(export PLAN_SYNC_REMOTE_URL="$SL_BARE"; sync_local "$SLD" sl5-intent.md)"
expect_eq "SL-5 syncPlanFile(regular) -> pushed|non-github" "$OUT" "pushed|non-github|"
expect_eq "SL-5 bare main:sl5-intent.md matches the file" "$(git -C "$SL_BARE" show refs/heads/main:sl5-intent.md 2>&1)" "sl5 intent"
expect_pos "SL-0 positive control: sl_object_hits finds pushed 'sl5 intent'" "$(sl_object_hits "$SL_BARE" "sl5 intent")"

echo "=== SL-2 / SL-5: publishedBlobUrl on a GitHub-provisioned repo (no network) ==="
G2="$PSF_ROOT/sl2-plans"
if psf_make_provisioned "$G2" "$PSF_ORIGIN_GH" >/dev/null 2>&1; then
  cp "$SL_SECRET" "$G2/sl2-intent.md"
  psf_commit_file "$G2" sl2-intent.md refs/remotes/origin/main
  expect_eq "SL-5 publishedBlobUrl(regular, content on origin/main) -> URL" \
    "$(PLAN_SYNC_REMOTE_URL="$PSF_ORIGIN_GH" blob_url "$G2" "$G2/sl2-intent.md")" \
    "https://github.com/test-owner/test-repo/blob/main/sl2-intent.md"
  rm -f "$G2/sl2-intent.md"
  if [ "$SL_CAN" != yes ]; then
    skip "SL-2 publishedBlobUrl(symlink): $SL_SKIP_MSG"
  elif sl_symlink "$SL_SECRET" "$G2/sl2-intent.md"; then
    expect_eq "SL-2 publishedBlobUrl(symlink whose target matches origin/main) -> null" \
      "$(PLAN_SYNC_REMOTE_URL="$PSF_ORIGIN_GH" blob_url "$G2" "$G2/sl2-intent.md")" "null"
  else
    fail "SL-2 fixture" "could not create $G2/sl2-intent.md as a symlink"
  fi
  mkdir -p "$G2/sl2d-outline.md"
  expect_eq "SL-3 publishedBlobUrl(directory) -> null" \
    "$(PLAN_SYNC_REMOTE_URL="$PSF_ORIGIN_GH" blob_url "$G2" "$G2/sl2d-outline.md")" "null"
  expect_eq "SL-3 publishedBlobUrl(nonexistent path) -> null" \
    "$(PLAN_SYNC_REMOTE_URL="$PSF_ORIGIN_GH" blob_url "$G2" "$G2/sl2m-detail.md")" "null"
else
  fail "SL-2 fixture" "psf_make_provisioned failed"
fi

echo "=== SL-4: a mode-120000 entry on local main is never carried to the remote ==="
S4_BARE="$PSF_ROOT/sl4-bare.git"; psf_make_bare "$S4_BARE"
S4="$PSF_ROOT/sl4-plans"; mkdir -p "$S4"
OUT="$(provision "$S4" "$S4_BARE")"
expect_eq "SL-4 precondition: provisionRepo ok" "${OUT%%|*}" "ok"
sl_link_commit "$S4" sl4b-detail.md "$SL_SECRET" || fail "SL-4 fixture" "sl_link_commit failed"
expect_pos "SL-0 positive control: sl_symlink_modes counts the local 120000 entry" "$(sl_symlink_modes "$S4")"
expect_eq "SL-4 precondition: local main holds sl4b-detail.md as mode 120000" \
  "$(git -C "$S4" ls-tree refs/heads/main sl4b-detail.md | cut -c1-6)" "120000"
sl_entry_commit "$S4" 100755 sl4x-outline.md "$(sl_blob "$S4" 'sl4 exec')" || fail "SL-4 fixture" "100755 entry"
sl_entry_commit "$S4" 160000 sl4g-intent.md "$(git -C "$S4" rev-parse refs/heads/main)" || fail "SL-4 fixture" "160000 entry"
expect_eq "SL-4 precondition: local main holds 100755 + 160000 entries" \
  "$(sl_mode_of "$S4" sl4x-outline.md)|$(sl_mode_of "$S4" sl4g-intent.md)" "100755|160000"
expect_pos "SL-0 positive control: sl_mode_count counts the local 160000 entry" "$(sl_mode_count "$S4" 160000)"
if [ "$SL_CAN" = yes ]; then
  sl_symlink "$SL_SECRET" "$S4/sl4b-detail.md" || fail "SL-4 fixture" "working-tree symlink not created"
else
  skip "SL-4 working-tree symlink beside the carried entry: $SL_SKIP_MSG"
fi
printf 'sl4 intent\n' > "$S4/sl4a-intent.md"
OUT="$(export PLAN_SYNC_REMOTE_URL="$S4_BARE"; sync_local "$S4" sl4a-intent.md)"
expect_eq "SL-4 regular file sync -> pushed|non-github" "$OUT" "pushed|non-github|"
expect_eq "SL-4 bare main:sl4a-intent.md matches the file" "$(git -C "$S4_BARE" show refs/heads/main:sl4a-intent.md 2>&1)" "sl4 intent"
expect_eq "SL-4 no mode-120000 entry anywhere in bare history" "$(sl_symlink_modes "$S4_BARE")" "0"
expect_eq "SL-4 no bare object holds the symlink target's content" "$(sl_object_hits "$S4_BARE" "$SL_MARK")" "0"
expect_eq "SL-4 120000 / 160000 not carried, 100755 carried" "$(tree_of "$S4_BARE")" ".gitignore sl4a-intent.md sl4x-outline.md "
expect_eq "SL-4 carried 100755 entry: same content, normalized to 100644 by overlayCommit" \
  "$(git -C "$S4_BARE" show refs/heads/main:sl4x-outline.md 2>&1)|$(sl_mode_of "$S4_BARE" sl4x-outline.md)" "sl4 exec|100644"
expect_eq "SL-4 no mode-160000 entry anywhere in bare history" "$(sl_mode_count "$S4_BARE" 160000)" "0"
expect_eq "SL-4 no bare object holds the link text (secret path)" "$(sl_object_hits "$S4_BARE" "sl-secret/secret.txt")" "0"
expect_pos "SL-0 positive control: sl_object_hits finds pushed 'sl4 intent'" "$(sl_object_hits "$S4_BARE" "sl4 intent")"

echo "=== SL-4b: no merge base (treeEntries path) -> mode-120000 entry still not carried ==="
S4N_BARE="$PSF_ROOT/sl4n-bare.git"; psf_make_bare "$S4N_BARE"
S4N="$PSF_ROOT/sl4n-plans"; mkdir -p "$S4N"
OUT="$(provision "$S4N" "$S4N_BARE")"
expect_eq "SL-4b precondition: provisionRepo ok" "${OUT%%|*}" "ok"
SEED4N="$PSF_ROOT/sl4n-seed"
harness_git_init "$SEED4N"
git -C "$SEED4N" symbolic-ref HEAD refs/heads/main
cp "$S4N/.gitignore" "$SEED4N/.gitignore"
printf 'sl4n remote\n' > "$SEED4N/sl4n-remote-intent.md"
git -C "$SEED4N" add .gitignore sl4n-remote-intent.md
git -C "$SEED4N" commit -q -m "unrelated remote root"
git -C "$SEED4N" push -q --force "$S4N_BARE" HEAD:refs/heads/main 2>/dev/null
git -C "$S4N" fetch -q origin +refs/heads/main:refs/remotes/origin/main 2>/dev/null
sl_link_commit "$S4N" sl4n-link-detail.md "$SL_SECRET" || fail "SL-4b fixture" "sl_link_commit failed"
sl_entry_commit "$S4N" 100644 sl4n-carry-outline.md "$(sl_blob "$S4N" 'sl4n carry')" || fail "SL-4b fixture" "100644 entry"
sl_entry_commit "$S4N" 100755 sl4nx-detail.md "$(sl_blob "$S4N" 'sl4n exec')" || fail "SL-4b fixture" "100755 entry"
sl_entry_commit "$S4N" 160000 sl4ng-intent.md "$(git -C "$S4N" rev-parse refs/heads/main)" || fail "SL-4b fixture" "160000 entry"
if git -C "$S4N" merge-base refs/remotes/origin/main refs/heads/main >/dev/null 2>&1; then S4N_MB=has-base; else S4N_MB=none; fi
expect_eq "SL-4b precondition: origin/main and local main share no merge base" "$S4N_MB" "none"
expect_eq "SL-4b precondition: local main holds the link as mode 120000" \
  "$(git -C "$S4N" ls-tree refs/heads/main sl4n-link-detail.md | cut -c1-6)" "120000"
printf 'sl4n intent\n' > "$S4N/sl4n-intent.md"
OUT="$(export PLAN_SYNC_REMOTE_URL="$S4N_BARE"; sync_local "$S4N" sl4n-intent.md)"
expect_eq "SL-4b regular file sync -> pushed|non-github" "$OUT" "pushed|non-github|"
expect_eq "SL-4b regular entries carried; 120000 link and 160000 gitlink absent" "$(tree_of "$S4N_BARE")" \
  ".gitignore sl4n-carry-outline.md sl4n-intent.md sl4n-remote-intent.md sl4nx-detail.md "
expect_eq "SL-4b carried 100644 entry: identical content, mode 100644" \
  "$(git -C "$S4N_BARE" show refs/heads/main:sl4n-carry-outline.md 2>&1)|$(sl_mode_of "$S4N_BARE" sl4n-carry-outline.md)" "sl4n carry|100644"
expect_eq "SL-4b carried 100755 entry: same content" "$(git -C "$S4N_BARE" show refs/heads/main:sl4nx-detail.md 2>&1)" "sl4n exec"
expect_eq "SL-4b no mode-160000 entry anywhere in bare history" "$(sl_mode_count "$S4N_BARE" 160000)" "0"
expect_eq "SL-4b no bare object holds the link text" "$(sl_object_hits "$S4N_BARE" "sl-secret/secret.txt")" "0"
expect_eq "SL-4b no mode-120000 entry anywhere in bare history" "$(sl_symlink_modes "$S4N_BARE")" "0"
expect_pos "SL-0 positive control: sl_object_hits finds pushed 'sl4n intent'" "$(sl_object_hits "$S4N_BARE" "sl4n intent")"

echo "=== SL-6: a name already on origin/main as a regular file, later a symlink locally ==="
S6_BARE="$PSF_ROOT/sl6-bare.git"; psf_make_bare "$S6_BARE"
S6="$PSF_ROOT/sl6-plans"; mkdir -p "$S6"
OUT="$(provision "$S6" "$S6_BARE")"
expect_eq "SL-6 precondition: provisionRepo ok" "${OUT%%|*}" "ok"
printf 's6 original\n' > "$S6/sl6x-intent.md"
OUT="$(export PLAN_SYNC_REMOTE_URL="$S6_BARE"; sync_local "$S6" sl6x-intent.md)"
expect_eq "SL-6 precondition: original regular file pushed" "$OUT" "pushed|non-github|"
if [ "$SL_CAN" != yes ]; then
  skip "SL-6 working-tree symlink replacing a published name: $SL_SKIP_MSG"
else
  rm -f "$S6/sl6x-intent.md"
  if sl_symlink "$SL_SECRET" "$S6/sl6x-intent.md"; then
    printf 'sl6 outline\n' > "$S6/sl6y-outline.md"
    OUT="$(export PLAN_SYNC_REMOTE_URL="$S6_BARE"; sync_local "$S6" sl6y-outline.md)"
    expect_eq "SL-6 sync of another file beside the working-tree symlink -> pushed|non-github" "$OUT" "pushed|non-github|"
  else fail "SL-6 fixture" "working-tree symlink not created"; fi
fi
sl_link_commit "$S6" sl6x-intent.md "$SL_SECRET" || fail "SL-6 fixture" "sl_link_commit failed"
printf 'sl6 detail\n' > "$S6/sl6z-detail.md"
OUT="$(export PLAN_SYNC_REMOTE_URL="$S6_BARE"; sync_local "$S6" sl6z-detail.md)"
expect_eq "SL-6 sync after local main type-changed the name to 120000 -> pushed|non-github" "$OUT" "pushed|non-github|"
expect_eq "SL-6 remote keeps the original content" "$(git -C "$S6_BARE" show refs/heads/main:sl6x-intent.md 2>&1)" "s6 original"
expect_eq "SL-6 remote entry is still mode 100644" "$(git -C "$S6_BARE" ls-tree refs/heads/main sl6x-intent.md | cut -c1-6)" "100644"
expect_eq "SL-6 no type change (T) anywhere in bare history" "$(git -C "$S6_BARE" log --all --diff-filter=T --format=%H 2>&1)" ""
expect_eq "SL-6 no mode-120000 entry anywhere in bare history" "$(sl_symlink_modes "$S6_BARE")" "0"
expect_eq "SL-6 no bare object holds the secret content" "$(sl_object_hits "$S6_BARE" "$SL_MARK")" "0"
expect_eq "SL-6 no bare object holds the link text" "$(sl_object_hits "$S6_BARE" "sl-secret/secret.txt")" "0"
expect_pos "SL-0 positive control: sl_object_hits finds pushed 's6 original'" "$(sl_object_hits "$S6_BARE" "s6 original")"

# --- Hard links / TOCTOU (#2513 review_security F1/F2): content is read once through a verified
# fd (readVerifiedRegularFile: lstat + O_NOFOLLOW open + fstat, nlink 1, same dev/ino) and hashed
# from those bytes; a hard-linked plan name (nlink > 1) is never published.

# hl_link <existing> <new> — exit 0 only when <new> is a hard link (nlink >= 2) afterwards.
hl_link() {
  psf_timeout 30 node -e '
const fs = require("fs");
try { fs.linkSync(process.argv[1], process.argv[2]); } catch (e) { process.exit(1); }
process.exit(fs.lstatSync(process.argv[2]).nlink >= 2 ? 0 : 1);' "$1" "$2" 2>/dev/null
}

# hl_nlink <path> — lstat nlink of <path> ("err" when lstat fails).
hl_nlink() {
  psf_timeout 30 node -e '
try { process.stdout.write(String(require("fs").lstatSync(process.argv[1]).nlink)); } catch (e) { process.stdout.write("err"); }' "$1"
}

# rd_read <path> — readVerifiedRegularFile verdict: buffer-equal | buffer-differs | null | NOT_IMPLEMENTED: ...
rd_read() {
  psf_node '
let cp;
try { cp = require(path.join(path.dirname(process.env.PSF_LIB_PATH), "plan-sync", "commit-push.js")); }
catch (e) { process.stdout.write("NOT_IMPLEMENTED: commit-push.js " + (e.code || e.message)); process.exit(0); }
if (typeof cp.readVerifiedRegularFile !== "function") {
  process.stdout.write("NOT_IMPLEMENTED: readVerifiedRegularFile not exported"); process.exit(0);
}
let r;
try { r = cp.readVerifiedRegularFile(process.argv[1]); } catch (e) { process.stdout.write("threw:" + (e.code || e.message)); process.exit(0); }
if (r === null) { process.stdout.write("null"); process.exit(0); }
if (!Buffer.isBuffer(r)) { process.stdout.write("non-buffer:" + typeof r); process.exit(0); }
let want = null;
try { want = fs.readFileSync(process.argv[1]); } catch (_) { want = null; }
process.stdout.write(want && r.equals(want) ? "buffer-equal" : "buffer-differs");' "$1"
}

# hl_patched <mode> <plansDir> <rel> [swap-src] — runs with git.js hashObjectWrite / hashObject
# (the path-reopening hashers) counted. mode sync: "<status>|<reason>|path-hashes=<n>";
# url: "<publishedBlobUrl>|path-hashes=<n>"; swap: the first fs.lstatSync of the target renames
# <swap-src> over it (an lstat->open race), prints "<status>|<reason>|swapped=<yes|no>".
hl_patched() {
  psf_node '
const G = require(path.join(path.dirname(process.env.PSF_LIB_PATH), "plan-sync", "git.js"));
const [mode, dir, rel, swapSrc] = process.argv.slice(1);
const target = path.resolve(dir, rel);
let pathHashes = 0;
for (const k of ["hashObjectWrite", "hashObject"]) {
  const orig = G[k];
  G[k] = function () { pathHashes++; return orig.apply(this, arguments); };
}
let swapped = "no";
if (mode === "swap") {
  const origLstat = fs.lstatSync;
  fs.lstatSync = function (p) {
    const st = origLstat.apply(fs, arguments);
    if (swapped === "no" && path.resolve(String(p)) === target) { swapped = "yes"; fs.renameSync(swapSrc, target); }
    return st;
  };
}
if (mode === "url") {
  process.stdout.write(String(ps.publishedBlobUrl(dir, target)) + "|path-hashes=" + pathHashes);
} else {
  Promise.resolve(ps.syncPlanFile(dir, target, { budgetMs: 20000, deps: allowLocal })).then((r) => {
    const tail = mode === "swap" ? "swapped=" + swapped : "path-hashes=" + pathHashes;
    process.stdout.write([r.status, r.reason || "", tail].join("|"));
  });
}' "$@"
}

mkdir -p "$PSF_ROOT/hl-probe"
printf 'probe\n' > "$PSF_ROOT/hl-probe/t"
if hl_link "$PSF_ROOT/hl-probe/t" "$PSF_ROOT/hl-probe/l"; then HL_CAN=yes; else HL_CAN=no; fi
echo "=== HL: host can create hard links (nlink visible): $HL_CAN ==="
HL_SKIP_MSG="host cannot create hard links (or does not report nlink)"
HL_MARK="PLAN-SYNC-HL-SECRET-c41e"
mkdir -p "$PSF_ROOT/hl-secret"
HL_SECRET="$PSF_ROOT/hl-secret/secret.txt"
printf '%s\n' "$HL_MARK" > "$HL_SECRET"

HL_BARE="$PSF_ROOT/hl-bare.git"; psf_make_bare "$HL_BARE"
HLD="$PSF_ROOT/hl-plans"; mkdir -p "$HLD"
OUT="$(provision "$HLD" "$HL_BARE")"
expect_eq "HL precondition: provisionRepo ok" "${OUT%%|*}" "ok"

echo "=== RD-1..RD-6: readVerifiedRegularFile verdicts ==="
mkdir -p "$PSF_ROOT/rd"
printf 'rd1 line\r\n\xe8\xa8\x88\xe7\x94\xbb\n' > "$PSF_ROOT/rd/regular.md"
expect_eq "RD-1 regular file -> Buffer equal to the file bytes" "$(rd_read "$PSF_ROOT/rd/regular.md")" "buffer-equal"
if [ "$SL_CAN" != yes ]; then
  skip "RD-2 symlink -> null: $SL_SKIP_MSG"
elif sl_symlink "$PSF_ROOT/rd/regular.md" "$PSF_ROOT/rd/link.md"; then
  expect_eq "RD-2 symlink to a regular file -> null" "$(rd_read "$PSF_ROOT/rd/link.md")" "null"
else
  fail "RD-2 fixture" "symlink not created"
fi
if [ "$HL_CAN" != yes ]; then
  skip "RD-3 hard link (nlink 2) -> null: $HL_SKIP_MSG"
else
  printf 'rd3\n' > "$PSF_ROOT/rd/hl-src.md"
  if hl_link "$PSF_ROOT/rd/hl-src.md" "$PSF_ROOT/rd/hl.md"; then
    expect_eq "RD-3 hard link (nlink 2) -> null" "$(rd_read "$PSF_ROOT/rd/hl.md")" "null"
  else fail "RD-3 fixture" "hard link not created"; fi
fi
mkdir -p "$PSF_ROOT/rd/dir.md"
expect_eq "RD-4 directory -> null" "$(rd_read "$PSF_ROOT/rd/dir.md")" "null"
expect_eq "RD-5 missing path -> null" "$(rd_read "$PSF_ROOT/rd/missing.md")" "null"
: > "$PSF_ROOT/rd/empty.md"
expect_eq "RD-6 empty regular file -> empty Buffer" "$(rd_read "$PSF_ROOT/rd/empty.md")" "buffer-equal"

echo "=== HL-1: plan name hard-linked to a secret outside plansDir -> skipped, nothing leaks ==="
if [ "$HL_CAN" != yes ]; then
  skip "HL-1 hard-linked plan file: $HL_SKIP_MSG"
  skip "HL-2 extra link removed -> syncs: $HL_SKIP_MSG"
elif hl_link "$HL_SECRET" "$HLD/hl1-intent.md"; then
  HL1_BEFORE="$(git -C "$HL_BARE" rev-parse --verify -q refs/heads/main || echo missing)"
  OUT="$(export PLAN_SYNC_REMOTE_URL="$HL_BARE"; sync_local "$HLD" hl1-intent.md)"
  expect_eq "HL-1 syncPlanFile(hard link, nlink 2) -> skipped|not-regular-file" "$OUT" "skipped|not-regular-file|"
  expect_eq "HL-1 bare main SHA unchanged" "$(git -C "$HL_BARE" rev-parse --verify -q refs/heads/main || echo missing)" "$HL1_BEFORE"
  expect_eq "HL-1 bare main tree has no hl1-intent.md" "$(tree_of "$HL_BARE")" ".gitignore "
  expect_eq "HL-1 no bare object holds the hard-linked secret" "$(sl_object_hits "$HL_BARE" "$HL_MARK")" "0"
  expect_eq "HL-1 no local plans-repo object holds the secret" "$(sl_object_hits "$HLD" "$HL_MARK")" "0"
  echo "=== HL-2: same file after the extra link is removed (nlink 1) -> pushed ==="
  rm -f "$HL_SECRET"
  expect_eq "HL-2 precondition: nlink back to 1" "$(hl_nlink "$HLD/hl1-intent.md")" "1"
  OUT="$(export PLAN_SYNC_REMOTE_URL="$HL_BARE"; sync_local "$HLD" hl1-intent.md)"
  expect_eq "HL-2 syncPlanFile(same name, nlink 1) -> pushed|non-github" "$OUT" "pushed|non-github|"
  expect_eq "HL-2 bare main:hl1-intent.md matches the file" "$(git -C "$HL_BARE" show refs/heads/main:hl1-intent.md 2>&1)" "$HL_MARK"
else
  fail "HL-1 fixture" "could not create $HLD/hl1-intent.md as a hard link"
fi

echo "=== HL-1 / HL-2: publishedBlobUrl on a GitHub-provisioned repo (no network) ==="
GHL="$PSF_ROOT/hl-gh-plans"
if psf_make_provisioned "$GHL" "$PSF_ORIGIN_GH" >/dev/null 2>&1; then
  HL_SECRET2="$PSF_ROOT/hl-secret/secret2.txt"
  printf '%s\n' "$HL_MARK" > "$HL_SECRET2"
  cp "$HL_SECRET2" "$GHL/hlu-intent.md"
  psf_commit_file "$GHL" hlu-intent.md refs/remotes/origin/main
  HLU_URL="https://github.com/test-owner/test-repo/blob/main/hlu-intent.md"
  expect_eq "HL positive control: publishedBlobUrl(regular, content on origin/main) -> URL" \
    "$(PLAN_SYNC_REMOTE_URL="$PSF_ORIGIN_GH" blob_url "$GHL" "$GHL/hlu-intent.md")" "$HLU_URL"
  expect_eq "TOC-1 publishedBlobUrl hashes verified bytes, never re-opens the path" \
    "$(PLAN_SYNC_REMOTE_URL="$PSF_ORIGIN_GH" hl_patched url "$GHL" hlu-intent.md)" "$HLU_URL|path-hashes=0"
  if [ "$HL_CAN" != yes ]; then
    skip "HL-1 publishedBlobUrl(hard link): $HL_SKIP_MSG"
  else
    rm -f "$GHL/hlu-intent.md"
    if hl_link "$HL_SECRET2" "$GHL/hlu-intent.md"; then
      expect_eq "HL-1 publishedBlobUrl(hard link whose content matches origin/main) -> null" \
        "$(PLAN_SYNC_REMOTE_URL="$PSF_ORIGIN_GH" blob_url "$GHL" "$GHL/hlu-intent.md")" "null"
      rm -f "$HL_SECRET2"
      expect_eq "HL-2 publishedBlobUrl after the extra link is removed -> URL" \
        "$(PLAN_SYNC_REMOTE_URL="$PSF_ORIGIN_GH" blob_url "$GHL" "$GHL/hlu-intent.md")" "$HLU_URL"
    else
      fail "HL-1 fixture" "could not create $GHL/hlu-intent.md as a hard link"
    fi
  fi
else
  fail "HL fixture" "psf_make_provisioned failed"
fi

echo "=== TOC-1: syncPlanFile hashes the verified bytes, never re-opens the path ==="
printf 'toc1 intent\n' > "$HLD/toc1-intent.md"
OUT="$(export PLAN_SYNC_REMOTE_URL="$HL_BARE"; hl_patched sync "$HLD" toc1-intent.md)"
expect_eq "TOC-1 syncPlanFile -> pushed with no path-based hash-object call" "$OUT" "pushed|non-github|path-hashes=0"
expect_eq "TOC-1 bare main:toc1-intent.md matches the file" "$(git -C "$HL_BARE" show refs/heads/main:toc1-intent.md 2>&1)" "toc1 intent"

echo "=== TOC-2: target swapped for a hard link to a secret right after lstat -> nothing leaks ==="
if [ "$HL_CAN" != yes ]; then
  skip "TOC-2 lstat->open swap: $HL_SKIP_MSG"
else
  TOC_MARK="PLAN-SYNC-TOC-SECRET-5d0b"
  mkdir -p "$PSF_ROOT/toc-secret"
  printf '%s\n' "$TOC_MARK" > "$PSF_ROOT/toc-secret/secret.txt"
  printf 'toc2 benign\n' > "$HLD/toc2-outline.md"
  if hl_link "$PSF_ROOT/toc-secret/secret.txt" "$PSF_ROOT/toc-secret/swap-in"; then
    TOC2_BEFORE="$(git -C "$HL_BARE" rev-parse --verify -q refs/heads/main || echo missing)"
    OUT="$(export PLAN_SYNC_REMOTE_URL="$HL_BARE"; hl_patched swap "$HLD" toc2-outline.md "$PSF_ROOT/toc-secret/swap-in")"
    expect_eq "TOC-2 syncPlanFile(swapped after lstat) -> skipped|not-regular-file" "$OUT" "skipped|not-regular-file|swapped=yes"
    expect_eq "TOC-2 bare main SHA unchanged" "$(git -C "$HL_BARE" rev-parse --verify -q refs/heads/main || echo missing)" "$TOC2_BEFORE"
    expect_eq "TOC-2 no bare object holds the swapped-in secret" "$(sl_object_hits "$HL_BARE" "$TOC_MARK")" "0"
    expect_eq "TOC-2 no local plans-repo object holds the secret" "$(sl_object_hits "$HLD" "$TOC_MARK")" "0"
  else
    fail "TOC-2 fixture" "swap-in hard link not created"
  fi
fi

echo "=== REG-1: CRLF + UTF-8 (Japanese) plan pushes byte-identical (regression) ==="
printf 'reg1 line one\r\n\xe6\x97\xa5\xe6\x9c\xac\xe8\xaa\x9e\xe3\x81\xae\xe8\xa8\x88\xe7\x94\xbb\r\nend\n' > "$HLD/reg1-intent.md"
OUT="$(export PLAN_SYNC_REMOTE_URL="$HL_BARE"; sync_local "$HLD" reg1-intent.md)"
expect_eq "REG-1 syncPlanFile(CRLF + UTF-8) -> pushed|non-github" "$OUT" "pushed|non-github|"
REG1_WANT="$(git -C "$HLD" hash-object --no-filters -- "$HLD/reg1-intent.md" 2>&1)"
expect_eq "REG-1 remote blob id == hash-object --no-filters of the file" \
  "$(git -C "$HL_BARE" rev-parse --verify -q refs/heads/main:reg1-intent.md || echo missing)" "$REG1_WANT"
git -C "$HL_BARE" cat-file blob refs/heads/main:reg1-intent.md > "$PSF_ROOT/reg1-remote.bin" 2>/dev/null
if cmp -s "$HLD/reg1-intent.md" "$PSF_ROOT/reg1-remote.bin"; then REG1_CMP=identical; else REG1_CMP=differs; fi
expect_eq "REG-1 remote blob bytes identical to the file (CRLF and UTF-8 kept)" "$REG1_CMP" "identical"
if [ -d "$GHL/.git" ]; then
  cp "$HLD/reg1-intent.md" "$GHL/reg1-outline.md"
  psf_commit_file "$GHL" reg1-outline.md refs/remotes/origin/main
  expect_eq "REG-1 publishedBlobUrl(CRLF + UTF-8 content on origin/main) -> URL" \
    "$(PLAN_SYNC_REMOTE_URL="$PSF_ORIGIN_GH" blob_url "$GHL" "$GHL/reg1-outline.md")" \
    "https://github.com/test-owner/test-repo/blob/main/reg1-outline.md"
else
  fail "REG-1 fixture" "GitHub-provisioned repo missing"
fi
