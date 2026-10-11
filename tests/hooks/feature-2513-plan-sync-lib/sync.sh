# syncPlanFile fast-forward cases + second machine (detail.md S1-7, S2-5).
# Sourced by ../feature-2513-plan-sync-lib.sh after provision.sh (needs M1, BARE).

echo "=== F1: fast-forward push to a remote on no known forge ==="
printf 'intent body 1\n' > "$M1/s1-intent.md"
OUT="$(sync_local "$M1" s1-intent.md)"
expect_eq "F1 pushed without URL (unknown-forge)" "$OUT" "pushed|unknown-forge|"
expect_eq "F1 bare main:s1-intent.md matches the written file" \
  "$(git -C "$BARE" show refs/heads/main:s1-intent.md 2>&1)" "intent body 1"
BARE_MAIN="$(git -C "$BARE" rev-parse --verify -q refs/heads/main)"
expect_eq "F1 local refs/remotes/origin/main == bare main" \
  "$(git -C "$M1" rev-parse --verify -q refs/remotes/origin/main)" "${BARE_MAIN:-missing}"

echo "=== F2: junk next to the plan never enters the commit ==="
mkdir -p "$M1/drafts"
printf 'log\n' > "$M1/s2-terminal.log"; printf '{}\n' > "$M1/s2.json"
printf 'ctx\n' > "$M1/s2-context.md"; printf 'd\n' > "$M1/drafts/s2-intent.md"
printf 'outline 2\n' > "$M1/s2-outline.md"
OUT="$(sync_local "$M1" s2-outline.md)"
expect_eq "F2 pushed" "${OUT%%|*}" "pushed"
expect_eq "F2 bare tree has only allowlisted plan files" "$(tree_of "$BARE")" ".gitignore s1-intent.md s2-outline.md "

echo "=== F7: re-syncing an unchanged plan makes no commit and moves no remote ref ==="
L_BEFORE="$(git -C "$M1" rev-parse --verify -q refs/heads/main || echo missing-local)"
R_BEFORE="$(git -C "$BARE" rev-parse --verify -q refs/heads/main || echo missing-remote)"
OUT="$(sync_local "$M1" s2-outline.md)"
expect_eq "F7 second sync still reports pushed" "${OUT%%|*}" "pushed"
if [ "${OUT%%|*}" = "pushed" ]; then
  expect_eq "F7 local main SHA unchanged" "$(git -C "$M1" rev-parse --verify -q refs/heads/main || echo missing-local)" "$L_BEFORE"
  expect_eq "F7 bare main SHA unchanged" "$(git -C "$BARE" rev-parse --verify -q refs/heads/main || echo missing-remote)" "$R_BEFORE"
else
  fail "F7 local/bare main SHAs unchanged" "second sync did not succeed: $OUT"
fi
# init commit + F1 + F2 = 3; a no-op re-sync must not add a 4th.
expect_eq "F7 commit count on bare main is still 3" "$(git -C "$BARE" rev-list --count refs/heads/main 2>/dev/null || echo 0)" "3"

echo "=== P3: second machine converges on origin/main without checkout ==="
M2="$PSF_ROOT/m2"; mkdir -p "$M2"
OUT="$(provision "$M2")"
expect_eq "P3 provisionRepo ok" "${OUT%%|*}" "ok"
BARE_MAIN="$(git -C "$BARE" rev-parse --verify -q refs/heads/main)"
expect_eq "P3 local main == bare main" "$(git -C "$M2" rev-parse --verify -q refs/heads/main)" "${BARE_MAIN:-missing}"
expect_eq "P3 local main == origin/main" "$(git -C "$M2" rev-parse --verify -q refs/heads/main)" \
  "$(git -C "$M2" rev-parse --verify -q refs/remotes/origin/main || echo missing-origin-main)"
if [ "${OUT%%|*}" = "ok" ]; then
  no_index_or_checkout "P3 no index, remote plans not checked out" "$M2" s1-intent.md s2-outline.md
else
  fail "P3 no index, remote plans not checked out" "provision did not succeed: $OUT"
fi

echo "=== F6: a working-tree deletion (sweep) never propagates ==="
rm -f "$M1/s1-intent.md"
printf 'detail 3\n' > "$M1/s3-detail.md"
OUT="$(sync_local "$M1" s3-detail.md)"
expect_eq "F6 pushed" "${OUT%%|*}" "pushed"
expect_eq "F6 deleted s1-intent.md stays in the remote" "$(tree_of "$BARE")" \
  ".gitignore s1-intent.md s2-outline.md s3-detail.md "

echo "=== F8: a destination on GitHub's alternate ssh host gets the github.com blob URL ==="
F8_URL="ssh://git@ssh.github.com:443/test-owner/test-repo.git"
F8_BARE="$PSF_ROOT/f8-bare.git"; psf_make_bare "$F8_BARE"
MF8="$PSF_ROOT/mf8"; mkdir -p "$MF8"
OUT="$(flow_bare "$F8_BARE"; psf_node 'const deps = Object.assign({ listPrivateRepoNames: () => [], repoVisibility: () => "private" }, allowLocal);
Promise.resolve(ps.provisionRepo(process.argv[1], process.argv[2], deps)).then((r) =>
  process.stdout.write(r.ok ? "ok" : "ng:" + r.reason));' "$MF8" "$F8_URL")"
expect_eq "F8 precondition: provisioned against the alternate ssh host" "$OUT" "ok"
printf 'intent 8\n' > "$MF8/sf8-intent.md"
psf_record "$MF8" sf8-intent.md github.com
OUT="$(flow_bare "$F8_BARE"; export PLAN_SYNC_REMOTE_URL="$F8_URL"; sync_raw "$MF8" sf8-intent.md)"
expect_eq "F8 pushed with the github.com blob URL" "$OUT" \
  "pushed||https://github.com/test-owner/test-repo/blob/main/sf8-intent.md"
expect_eq "F8 the destination holds the written file" \
  "$(git -C "$F8_BARE" show refs/heads/main:sf8-intent.md 2>&1)" "intent 8"

echo "=== F9: a plan with no project-host record is skipped, never sent ==="
printf 'intent 9\n' > "$M1/s9n-intent.md"
psf_record_remove "$M1" s9n-intent.md
F9_BEFORE="$(git -C "$BARE" rev-parse --verify -q refs/heads/main || echo missing)"
expect_eq "F9 syncPlanFile without a record -> skipped, no reason" "$(sync_raw "$M1" s9n-intent.md)" "skipped||"
expect_eq "F9 bare main SHA unchanged" "$(git -C "$BARE" rev-parse --verify -q refs/heads/main || echo missing)" "$F9_BEFORE"
