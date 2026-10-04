# Open-time swap (#2513 review_security F1/F2): the path is swapped after every lstat
# pre-check passed on a sole regular file, right before fs.openSync, so only the post-open
# fstat re-verification (isFile, nlink 1, dev/ino == lstat) can refuse it. Sourced after
# symlink.sh by ../feature-2513-plan-sync-lib.sh (reuses HLD / HL_BARE / HL_CAN / SL_CAN,
# hl_link, hl_nlink, sl_object_hits).

# toc3_patched <read|sync> <rename|symlink|none> <plansDir> <rel> [src] — the first fs.openSync of
# the target (after every lstat pre-check passed on a sole regular file) first swaps the path:
# rename moves <src> over it, symlink replaces it by a symlink to <src>. Only the post-open fstat
# can catch it. Prints "<read verdict>|swapped=<y/n>" or "<status>|<reason>|swapped=<y/n>".
toc3_patched() {
  psf_node '
const cp = require(path.join(path.dirname(process.env.PSF_LIB_PATH), "plan-sync", "commit-push.js"));
const [mode, kind, dir, rel, src] = process.argv.slice(1);
const target = path.resolve(dir, rel);
let swapped = "no";
const origOpen = fs.openSync;
fs.openSync = function (p) {
  if (kind !== "none" && swapped === "no" && path.resolve(String(p)) === target) {
    swapped = "yes";
    if (kind === "rename") fs.renameSync(src, target);
    else { fs.unlinkSync(target); fs.symlinkSync(src, target, "file"); }
  }
  return origOpen.apply(fs, arguments);
};
const done = (s) => { fs.openSync = origOpen; process.stdout.write(s + "|swapped=" + swapped); };
if (mode === "read") {
  let r;
  try { r = cp.readVerifiedRegularFile(target); } catch (e) { r = "threw:" + (e.code || e.message); }
  done(r === null ? "null" : Buffer.isBuffer(r) ? "buffer:" + r.toString("utf8").trim() : String(r));
} else {
  Promise.resolve(ps.syncPlanFile(dir, target, { budgetMs: 20000, deps: allowLocal }))
    .then((r) => done([r.status, r.reason || ""].join("|")), (e) => done("threw|" + (e && e.message)));
}' "$@"
}

echo "=== TOC-3: lstat passes on a sole regular file, path swapped right before open -> fstat refuses ==="
TOC3_MARK="PLAN-SYNC-TOC3-SECRET-e6a1"
TOC3_SEC="$PSF_ROOT/toc3-secret"
mkdir -p "$TOC3_SEC"
printf '%s\n' "$TOC3_MARK" > "$TOC3_SEC/secret.txt"
TOC3_REL="toc3-detail.md"
# toc3_reset — benign nlink-1 target; precondition asserted so the lstat pre-check genuinely passes.
toc3_reset() {
  rm -f "$HLD/$TOC3_REL"
  printf 'toc3 benign\n' > "$HLD/$TOC3_REL"
  expect_eq "TOC-3 $1 precondition: target is a sole regular file (nlink 1)" "$(hl_nlink "$HLD/$TOC3_REL")" "1"
}
toc3_reset "control"
expect_eq "TOC-3 control: no swap -> readVerifiedRegularFile returns the benign bytes" \
  "$(toc3_patched read none "$HLD" "$TOC3_REL")" "buffer:toc3 benign|swapped=no"
TOC3_BEFORE="$(git -C "$HL_BARE" rev-parse --verify -q refs/heads/main || echo missing)"

echo "=== TOC-3a: swapped for a hard link (nlink 2) to a secret ==="
if [ "$HL_CAN" != yes ]; then
  skip "TOC-3a open-time hard-link swap: $HL_SKIP_MSG"
else
  for toc3_mode in read sync; do
    toc3_reset "3a-$toc3_mode"
    rm -f "$TOC3_SEC/swap-hl"
    if hl_link "$TOC3_SEC/secret.txt" "$TOC3_SEC/swap-hl"; then
      OUT="$(export PLAN_SYNC_REMOTE_URL="$HL_BARE"; toc3_patched "$toc3_mode" rename "$HLD" "$TOC3_REL" "$TOC3_SEC/swap-hl")"
      if [ "$toc3_mode" = read ]; then
        expect_eq "TOC-3a readVerifiedRegularFile(hard link swapped in at open) -> null" "$OUT" "null|swapped=yes"
      else
        expect_eq "TOC-3a syncPlanFile(hard link swapped in at open) -> skipped|not-regular-file" "$OUT" "skipped|not-regular-file|swapped=yes"
      fi
    else
      fail "TOC-3a fixture" "swap-in hard link not created"
    fi
  done
fi

echo "=== TOC-3b: swapped for a different sole regular file (dev/ino differ) ==="
for toc3_mode in read sync; do
  toc3_reset "3b-$toc3_mode"
  rm -f "$TOC3_SEC/swap-other"
  cp "$TOC3_SEC/secret.txt" "$TOC3_SEC/swap-other"
  OUT="$(export PLAN_SYNC_REMOTE_URL="$HL_BARE"; toc3_patched "$toc3_mode" rename "$HLD" "$TOC3_REL" "$TOC3_SEC/swap-other")"
  if [ "$toc3_mode" = read ]; then
    expect_eq "TOC-3b readVerifiedRegularFile(other nlink-1 file swapped in at open) -> null" "$OUT" "null|swapped=yes"
  else
    expect_eq "TOC-3b syncPlanFile(other nlink-1 file swapped in at open) -> skipped|not-regular-file" "$OUT" "skipped|not-regular-file|swapped=yes"
  fi
done

echo "=== TOC-3c: swapped for a symlink to a secret ==="
if [ "$SL_CAN" != yes ]; then
  skip "TOC-3c open-time symlink swap: $SL_SKIP_MSG"
else
  for toc3_mode in read sync; do
    toc3_reset "3c-$toc3_mode"
    OUT="$(export PLAN_SYNC_REMOTE_URL="$HL_BARE"; toc3_patched "$toc3_mode" symlink "$HLD" "$TOC3_REL" "$TOC3_SEC/secret.txt")"
    if [ "$toc3_mode" = read ]; then
      expect_eq "TOC-3c readVerifiedRegularFile(symlink swapped in at open) -> null" "$OUT" "null|swapped=yes"
    else
      expect_eq "TOC-3c syncPlanFile(symlink swapped in at open) -> skipped|not-regular-file" "$OUT" "skipped|not-regular-file|swapped=yes"
    fi
  done
fi
rm -f "$HLD/$TOC3_REL"

expect_eq "TOC-3 bare main SHA unchanged" "$(git -C "$HL_BARE" rev-parse --verify -q refs/heads/main || echo missing)" "$TOC3_BEFORE"
expect_eq "TOC-3 no bare object holds the swapped-in secret" "$(sl_object_hits "$HL_BARE" "$TOC3_MARK")" "0"
expect_eq "TOC-3 no local plans-repo object holds the secret" "$(sl_object_hits "$HLD" "$TOC3_MARK")" "0"
