# A no-op re-sync is trusted only against a freshly fetched origin/main (#2513 stale-tip).
# Sourced by ../feature-2513-plan-sync-lib.sh. The GitHub-form URL is served by the ssh stub,
# so syncPlanFile can return a blob URL and the URL claim is checked against the real remote.

ST_URL="$PSF_ORIGIN_E2E"
ST_REL="sST-intent.md"

# st_provision <plansDir> — provisionRepo against $ST_URL; visibility answered "private" (no gh).
st_provision() {
  psf_node 'const deps = Object.assign({ listPrivateRepoNames: () => [], repoVisibility: () => "private" }, allowLocal);
Promise.resolve(ps.provisionRepo(process.argv[1], process.argv[2], deps)).then((r) =>
  process.stdout.write(r.ok ? "ok" : "ng:" + r.reason));' "$1" "$ST_URL"
}

st_sync() { (export PLAN_SYNC_REMOTE_URL="$ST_URL"; sync_local "$1" "$2"); }

# st_pair <tag> — fresh bare served by the ssh stub + two provisioned machines A and B.
st_pair() {
  ST_BARE="$PSF_ROOT/st-$1-bare.git"; psf_make_bare "$ST_BARE"; setup_ssh_stub "$ST_BARE"
  ST_A="$PSF_ROOT/st-$1-a"; ST_B="$PSF_ROOT/st-$1-b"; mkdir -p "$ST_A" "$ST_B"
  expect_eq "ST-$1 precondition: machine A provisioned" "$(st_provision "$ST_A")" "ok"
  expect_eq "ST-$1 precondition: machine B provisioned" "$(st_provision "$ST_B")" "ok"
}

ST_BLOB_URL="https://github.com/test-owner/test-repo/blob/main/$ST_REL"

echo "=== ST-P1: stale local origin/main, remote holds B's v2 -> A's unchanged v1 is republished ==="
st_pair P1
printf 'st v1\n' > "$ST_A/$ST_REL"
expect_eq "ST-P1 precondition: A pushes v1 with URL" "$(st_sync "$ST_A" "$ST_REL")" "pushed||$ST_BLOB_URL"
printf 'st v2\n' > "$ST_B/$ST_REL"
expect_eq "ST-P1 precondition: B pushes v2" "$(st_sync "$ST_B" "$ST_REL" | cut -d'|' -f1)" "pushed"
ST_B_TIP="$(git -C "$ST_BARE" rev-parse --verify -q refs/heads/main || echo missing-b)"
expect_eq "ST-P1 precondition: remote main:X is v2" "$(git -C "$ST_BARE" show "refs/heads/main:$ST_REL" 2>&1)" "st v2"
ST_A_REF="$(git -C "$ST_A" rev-parse --verify -q refs/remotes/origin/main || echo missing-a)"
if [ "$ST_A_REF" != "$ST_B_TIP" ]; then pass "ST-P1 precondition: A's origin/main is stale (not fetched)"
else fail "ST-P1 precondition: A's origin/main is stale (not fetched)" "A ref == B tip $ST_B_TIP"; fi
OUT="$(st_sync "$ST_A" "$ST_REL")"
expect_eq "ST-P1 re-sync of unchanged v1 reports pushed" "${OUT%%|*}" "pushed"
ST_REMOTE_X="$(git -C "$ST_BARE" show "refs/heads/main:$ST_REL" 2>&1)"
expect_eq "ST-P1 remote main:X equals A's local bytes v1" "$ST_REMOTE_X" "st v1"
ST_TIP="$(git -C "$ST_BARE" rev-parse --verify -q refs/heads/main || echo missing)"
if [ "$ST_TIP" != "$ST_B_TIP" ] && git -C "$ST_BARE" merge-base --is-ancestor "$ST_B_TIP" "$ST_TIP" 2>/dev/null; then
  pass "ST-P1 remote main is a new descendant of B's commit"
else fail "ST-P1 remote main is a new descendant of B's commit" "b=$ST_B_TIP main=$ST_TIP"; fi
# Result and remote judged together: an exact "pushed||<blob URL>" is honest only while the
# remote really holds v1, so a stale-ref no-op claiming the URL over v2 fails here.
expect_eq "ST-P1 result is pushed with the exact blob URL, and the remote behind it holds v1" \
  "$OUT|$ST_REMOTE_X" "pushed||$ST_BLOB_URL|st v1"

echo "=== ST-P2: genuine no-op (remote not advanced) -> pushed, remote ref unchanged ==="
st_pair P2
printf 'st2 x\n' > "$ST_A/$ST_REL"
expect_eq "ST-P2 precondition: A pushes X" "$(st_sync "$ST_A" "$ST_REL" | cut -d'|' -f1)" "pushed"
ST_BEFORE="$(git -C "$ST_BARE" rev-parse --verify -q refs/heads/main || echo missing)"
ST_COUNT="$(git -C "$ST_BARE" rev-list --count refs/heads/main 2>/dev/null || echo 0)"
OUT="$(st_sync "$ST_A" "$ST_REL")"
expect_eq "ST-P2 re-sync reports pushed with URL" "$OUT" "pushed||$ST_BLOB_URL"
expect_eq "ST-P2 bare main SHA unchanged" "$(git -C "$ST_BARE" rev-parse --verify -q refs/heads/main || echo missing)" "$ST_BEFORE"
expect_eq "ST-P2 no new commit on bare main" "$(git -C "$ST_BARE" rev-list --count refs/heads/main 2>/dev/null || echo 0)" "$ST_COUNT"
expect_eq "ST-P2 A's origin/main == bare main" "$(git -C "$ST_A" rev-parse --verify -q refs/remotes/origin/main || echo missing-a)" "$ST_BEFORE"

echo "=== ST-P3: stale ref, B advanced main with a DIFFERENT plan Y -> X stays, Y kept ==="
st_pair P3
printf 'st3 x\n' > "$ST_A/$ST_REL"
expect_eq "ST-P3 precondition: A pushes X" "$(st_sync "$ST_A" "$ST_REL" | cut -d'|' -f1)" "pushed"
printf 'st3 y\n' > "$ST_B/sSTY-intent.md"
expect_eq "ST-P3 precondition: B pushes Y" "$(st_sync "$ST_B" sSTY-intent.md | cut -d'|' -f1)" "pushed"
ST_B_TIP="$(git -C "$ST_BARE" rev-parse --verify -q refs/heads/main || echo missing-b)"
OUT="$(st_sync "$ST_A" "$ST_REL")"
expect_eq "ST-P3 re-sync of unchanged X reports pushed with URL" "$OUT" "pushed||$ST_BLOB_URL"
expect_eq "ST-P3 remote tree keeps Y and X" "$(tree_of "$ST_BARE")" ".gitignore sST-intent.md sSTY-intent.md "
expect_eq "ST-P3 remote main:Y is B's content" "$(git -C "$ST_BARE" show refs/heads/main:sSTY-intent.md 2>&1)" "st3 y"
expect_eq "ST-P3 remote main:X is A's content" "$(git -C "$ST_BARE" show "refs/heads/main:$ST_REL" 2>&1)" "st3 x"
expect_eq "ST-P3 A's origin/main refreshed to the remote tip" \
  "$(git -C "$ST_A" rev-parse --verify -q refs/remotes/origin/main || echo missing-a)" "$ST_B_TIP"

echo "=== ST-P4: stale ref, remote advanced, fetch fails -> failed, stale no-op never trusted ==="
st_pair P4
printf 'st4 v1\n' > "$ST_A/$ST_REL"
expect_eq "ST-P4 precondition: A pushes v1" "$(st_sync "$ST_A" "$ST_REL" | cut -d'|' -f1)" "pushed"
printf 'st4 v2\n' > "$ST_B/$ST_REL"
expect_eq "ST-P4 precondition: B pushes v2" "$(st_sync "$ST_B" "$ST_REL" | cut -d'|' -f1)" "pushed"
ST_B_TIP="$(git -C "$ST_BARE" rev-parse --verify -q refs/heads/main || echo missing-b)"
ST_A_REF="$(git -C "$ST_A" rev-parse --verify -q refs/remotes/origin/main || echo missing-a)"
if [ "$ST_A_REF" != "$ST_B_TIP" ]; then pass "ST-P4 precondition: A's origin/main is stale"
else fail "ST-P4 precondition: A's origin/main is stale" "A ref == B tip $ST_B_TIP"; fi
# An empty GIT_SSH_STUB_BARE makes the stub exit 128, so the in-attempt fetch fails.
OUT="$(export GIT_SSH_STUB_BARE=""; st_sync "$ST_A" "$ST_REL")"
expect_eq "ST-P4 fetch failure -> failed/push-failed, no URL" "$OUT" "failed|push-failed|"
expect_eq "ST-P4 remote main untouched (B's tip)" \
  "$(git -C "$ST_BARE" rev-parse --verify -q refs/heads/main || echo missing)" "$ST_B_TIP"
expect_eq "ST-P4 remote main:X still v2" "$(git -C "$ST_BARE" show "refs/heads/main:$ST_REL" 2>&1)" "st4 v2"
expect_eq "ST-P4 A's origin/main not advanced by the failed attempt" \
  "$(git -C "$ST_A" rev-parse --verify -q refs/remotes/origin/main || echo missing-a)" "$ST_A_REF"
unset GIT_SSH_COMMAND GIT_SSH_VARIANT
