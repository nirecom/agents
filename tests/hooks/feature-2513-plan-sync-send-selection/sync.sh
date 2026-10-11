# Which plans syncPlanFile sends (hooks/lib/plan-sync/commit-push.js): the written plan and the
# plans it carries along from local main pass one predicate — the name condition AND a record
# whose host matches the destination; a carried plan must also hold on disk the bytes local main holds.
# Sourced by ../feature-2513-plan-sync-send-selection.sh after plan-sync-flow.sh. The destination is
# $PSF_ORIGIN_PLAIN through the ssh stub; sync_raw never touches a record, so each case sets its own.

SS_OTHER_HOST="other.example.com"
SS_BARE="$PSF_ROOT/ss-bare.git"; psf_make_bare "$SS_BARE"
setup_ssh_stub "$SS_BARE"
SS="$PSF_ROOT/ss-m"; mkdir -p "$SS"
expect_eq "send-selection precondition: machine provisioned" "$(provision "$SS" "$SS_BARE" | cut -d'|' -f1)" "ok"

# ss_remote <bare> <rel> — content of <rel> at the destination, or "absent".
ss_remote() { git -C "$1" show "refs/heads/main:$2" 2>/dev/null || printf 'absent'; }
ss_tip() { git -C "$1" rev-parse --verify -q refs/heads/main || printf 'missing'; }

echo "=== W1: written plan, record matches the destination -> sent ==="
printf 'w1\n' > "$SS/w1-intent.md"
psf_record "$SS" w1-intent.md "$PSF_HOST_PLAIN"
expect_eq "W1 record verdict against the destination" "$(psf_record_state "$SS" w1-intent.md "$PSF_ORIGIN_PLAIN")" "match"
expect_eq "W1 pushed" "$(sync_raw "$SS" w1-intent.md)" "pushed|unknown-forge|"
expect_eq "W1 at the destination" "$(ss_remote "$SS_BARE" w1-intent.md)" "w1"

echo "=== W2-W4: written plan without a matching record -> not sent, with the reason ==="
while IFS='|' read -r name rel record state status reason; do
  [ -z "$name" ] && continue
  want="$status|${reason#-}|"
  printf '%s\n' "$name" > "$SS/$rel"
  case "$record" in
    missing) psf_record_remove "$SS" "$rel" ;;
    *) psf_record "$SS" "$rel" "$record" ;;
  esac
  expect_eq "$name: record verdict" "$(psf_record_state "$SS" "$rel" "$PSF_ORIGIN_PLAIN")" "$state"
  SS_REMOTE_BEFORE="$(ss_tip "$SS_BARE")"; SS_LOCAL_BEFORE="$(ss_tip "$SS")"
  expect_eq "$name: result" "$(sync_raw "$SS" "$rel")" "$want"
  expect_eq "$name: absent from the destination" "$(ss_remote "$SS_BARE" "$rel")" "absent"
  expect_eq "$name: destination main did not move" "$(ss_tip "$SS_BARE")" "$SS_REMOTE_BEFORE"
  expect_eq "$name: local main did not move" "$(ss_tip "$SS")" "$SS_LOCAL_BEFORE"
  expect_eq "$name: the plan file stays on disk" "$(cat "$SS/$rel" 2>&1)" "$name"
done <<TABLE
W2 host differs|w2-intent.md|$SS_OTHER_HOST|host-mismatch|skipped|host-mismatch
W2 lookalike host|w2b-outline.md|sub.$PSF_HOST_PLAIN|host-mismatch|skipped|host-mismatch
W3 no-host record|w3-outline.md|none|no-project-host|skipped|no-project-host
W4 no record|w4-detail.md|missing|missing|skipped|-
TABLE

echo "=== W5: an unreadable record never counts as a match ==="
printf 'w5\n' > "$SS/w5-intent.md"
printf 'not json' > "$(psf_record_path "$SS" w5-intent.md)"
OUT="$(sync_raw "$SS" w5-intent.md)"
expect_eq "W5 skipped" "${OUT%%|*}" "skipped"
expect_eq "W5 absent from the destination" "$(ss_remote "$SS_BARE" w5-intent.md)" "absent"
PH_W5="$(psf_record_state "$SS" w5-intent.md "$PSF_ORIGIN_PLAIN")"
case "$PH_W5" in
  NOT_IMPLEMENTED:*|match) fail "W5 readProjectHostState never answers match for it" "state=$PH_W5" ;;
  *) pass "W5 readProjectHostState never answers match for it" ;;
esac

echo "=== W6: where the predicate sits — after off and the name check, before the provisioned check ==="
SS_RAW="$PSF_ROOT/ss-unprovisioned"; mkdir -p "$SS_RAW"
printf 'w6\n' > "$SS_RAW/w6-intent.md"; printf 'ctx\n' > "$SS_RAW/w6-context.md"
psf_record "$SS_RAW" w6-intent.md "$SS_OTHER_HOST"
expect_eq "W6 sync off wins over a mismatch" "$(PLAN_SYNC_REMOTE_URL="" sync_raw "$SS_RAW" w6-intent.md)" "off||"
expect_eq "W6 a name that is no plan -> skipped without a reason" "$(sync_raw "$SS_RAW" w6-context.md)" "skipped||"
expect_eq "W6 mismatch reported on an unprovisioned dir" "$(sync_raw "$SS_RAW" w6-intent.md)" "skipped|host-mismatch|"
psf_record "$SS_RAW" w6-intent.md none
expect_eq "W6 no-host reported on an unprovisioned dir" "$(sync_raw "$SS_RAW" w6-intent.md)" "skipped|no-project-host|"
psf_record_remove "$SS_RAW" w6-intent.md
expect_eq "W6 no record reported on an unprovisioned dir" "$(sync_raw "$SS_RAW" w6-intent.md)" "skipped||"
psf_record "$SS_RAW" w6-intent.md "$PSF_HOST_PLAIN"
expect_eq "W6 a match reaches the provisioned check" "$(sync_raw "$SS_RAW" w6-intent.md)" "not-provisioned|no-repo|"

# ss_orphan_main <dir> <rel...> — replaces local main by a root commit holding <rel...>, so
# local main and origin/main share no merge base.
ss_orphan_main() {
  local d="$1" idx="$1/.git/ss-index" rel blob tree
  shift
  for rel in "$@"; do
    blob="$(git -C "$d" hash-object -w -- "$rel")" || return 1
    GIT_INDEX_FILE="$idx" git -C "$d" update-index --add --cacheinfo "100644,$blob,$rel" || return 1
  done
  tree="$(GIT_INDEX_FILE="$idx" git -C "$d" write-tree)" || return 1
  rm -f "$idx"
  git -C "$d" update-ref refs/heads/main "$(git -C "$d" commit-tree "$tree" -m 'unrelated local history')"
}

SS_KEPT="k-match-intent.md"
SS_DROPPED="k-mismatch-intent.md k-nohost-outline.md k-norecord-detail.md k-stale-intent.md k-gone-outline.md"

# ss_scene <dir> <connected|unconnected> — six plans on local main only (what failed pushes
# leave behind): one a later sync may carry, five it may not.
ss_scene() {
  local d="$1" rel
  for rel in $SS_KEPT $SS_DROPPED; do printf '%s v1\n' "$rel" > "$d/$rel"; done
  if [ "$2" = connected ]; then
    for rel in $SS_KEPT $SS_DROPPED; do psf_commit_file "$d" "$rel" || return 1; done
  else
    # shellcheck disable=SC2086
    ss_orphan_main "$d" $SS_KEPT $SS_DROPPED || return 1
  fi
  psf_record "$d" k-match-intent.md "$PSF_HOST_PLAIN"
  psf_record "$d" k-mismatch-intent.md "$SS_OTHER_HOST"
  psf_record "$d" k-nohost-outline.md none
  psf_record_remove "$d" k-norecord-detail.md
  psf_record "$d" k-stale-intent.md "$PSF_HOST_PLAIN"
  psf_record "$d" k-gone-outline.md "$PSF_HOST_PLAIN"
  printf 'k-stale-intent.md v2\n' > "$d/k-stale-intent.md"
  rm -f "$d/k-gone-outline.md"
}

for ss_mode in connected unconnected; do
  echo "=== C ($ss_mode history): plans carried along with a sync pass the same predicate ==="
  SC_BARE="$PSF_ROOT/ss-$ss_mode-bare.git"; psf_make_bare "$SC_BARE"
  SC="$PSF_ROOT/ss-$ss_mode"; mkdir -p "$SC"
  expect_eq "C $ss_mode precondition: machine provisioned" "$(provision "$SC" "$SC_BARE" | cut -d'|' -f1)" "ok"
  if ss_scene "$SC" "$ss_mode"; then pass "C $ss_mode precondition: scene built"
  else fail "C $ss_mode precondition: scene built" "fixture step failed"; fi
  SC_TRACKED="$(tree_of "$SC")"
  case "$SC_TRACKED" in
    *k-gone-outline.md*k-match-intent.md*k-mismatch-intent.md*k-nohost-outline.md*k-norecord-detail.md*k-stale-intent.md*)
      pass "C $ss_mode precondition: local main tracks all six plans" ;;
    *) fail "C $ss_mode precondition: local main tracks all six plans" "tree=$SC_TRACKED" ;;
  esac
  if git -C "$SC" merge-base refs/heads/main refs/remotes/origin/main >/dev/null 2>&1; then got=connected; else got=unconnected; fi
  expect_eq "C $ss_mode precondition: history shape" "$got" "$ss_mode"
  printf 'new\n' > "$SC/k-new-detail.md"
  psf_record "$SC" k-new-detail.md "$PSF_HOST_PLAIN"
  OUT="$(flow_bare "$SC_BARE"; sync_raw "$SC" k-new-detail.md)"
  expect_eq "C $ss_mode sync of another plan pushed" "$OUT" "pushed|unknown-forge|"
  expect_eq "C $ss_mode destination holds the written plan and the one carried match only" \
    "$(tree_of "$SC_BARE")" ".gitignore k-match-intent.md k-new-detail.md "
  expect_eq "C $ss_mode carried plan arrives with the bytes on disk" \
    "$(ss_remote "$SC_BARE" k-match-intent.md)" "k-match-intent.md v1"
  SC_HIST="$(git -C "$SC_BARE" log --format= --name-only refs/heads/main 2>/dev/null | sort -u | tr '\n' ' ')"
  case "$SC_HIST" in
    "") fail "C $ss_mode no unsent plan anywhere in the destination history" "destination main has no history" ;;
    *k-mismatch*|*k-nohost*|*k-norecord*|*k-stale*|*k-gone*|*note-project-host*)
      fail "C $ss_mode no unsent plan anywhere in the destination history" "history paths: $SC_HIST" ;;
    *) pass "C $ss_mode no unsent plan anywhere in the destination history" ;;
  esac
  SC_LEFT=""
  for rel in k-mismatch-intent.md k-nohost-outline.md k-norecord-detail.md k-stale-intent.md; do
    [ -f "$SC/$rel" ] || SC_LEFT="$SC_LEFT $rel"
  done
  expect_eq "C $ss_mode unsent plan files stay on disk" "${SC_LEFT:-none}" "none"
  expect_eq "C $ss_mode the newer on-disk version is left as written" "$(cat "$SC/k-stale-intent.md" 2>&1)" "k-stale-intent.md v2"
  # The record decides again on the next sync: a plan whose record now matches is picked up.
  psf_record "$SC" k-mismatch-intent.md "$PSF_HOST_PLAIN"
  OUT="$(flow_bare "$SC_BARE"; sync_raw "$SC" k-mismatch-intent.md)"
  expect_eq "C $ss_mode a plan whose record now matches is sent on its own sync" "${OUT%%|*}" "pushed"
  expect_eq "C $ss_mode and only that plan joined the destination" \
    "$(tree_of "$SC_BARE")" ".gitignore k-match-intent.md k-mismatch-intent.md k-new-detail.md "
done

echo "=== U: a blob URL without a record only for content already at the destination ==="
SU_BARE="$PSF_ROOT/ss-url-bare.git"; psf_make_bare "$SU_BARE"
SU="$PSF_ROOT/ss-url"; mkdir -p "$SU"
SU_URL="$PSF_ORIGIN_E2E"
SU_BLOB="https://github.com/test-owner/test-repo/blob/main/u1-intent.md"
# su_node <js> — runs with the GitHub destination served by $SU_BARE.
su_node() { (flow_bare "$SU_BARE"; export PLAN_SYNC_REMOTE_URL="$SU_URL"; psf_node "$@"); }
OUT="$(su_node 'const deps = Object.assign({ listPrivateRepoNames: () => [], repoVisibility: () => "private" }, allowLocal);
Promise.resolve(ps.provisionRepo(process.argv[1], process.argv[2], deps)).then((r) => process.stdout.write(r.ok ? "ok" : "ng:" + r.reason));' "$SU" "$SU_URL")"
expect_eq "U precondition: machine provisioned against the GitHub destination" "$OUT" "ok"
su_sync() { su_node 'Promise.resolve(ps.syncPlanFile(process.argv[1], path.join(process.argv[1], process.argv[2]), { budgetMs: 20000 }))
  .then((r) => process.stdout.write([r.status, r.reason || "", r.url || ""].join("|")));' "$SU" "$1"; }
su_url() { su_node 'Promise.resolve(ps.publishedBlobUrl(process.argv[1], path.join(process.argv[1], process.argv[2])))
  .then((u) => process.stdout.write(u || "none"));' "$SU" "$1"; }
printf 'u1\n' > "$SU/u1-intent.md"
psf_record "$SU" u1-intent.md github.com
expect_eq "U precondition: sent with the blob URL" "$(su_sync u1-intent.md)" "pushed||$SU_BLOB"
expect_eq "U match record, same content: URL" "$(su_url u1-intent.md)" "$SU_BLOB"
psf_record_remove "$SU" u1-intent.md
expect_eq "U no record: the sync sends nothing" "$(su_sync u1-intent.md)" "skipped||"
expect_eq "U no record, content already at the destination: URL" "$(su_url u1-intent.md)" "$SU_BLOB"
printf 'u1 edited\n' > "$SU/u1-intent.md"
expect_eq "U no record, content differs from the destination: no URL" "$(su_url u1-intent.md)" "none"
expect_eq "U edited content was not sent" "$(su_sync u1-intent.md)|$(ss_remote "$SU_BARE" u1-intent.md)" "skipped|||u1"
printf 'u1\n' > "$SU/u1-intent.md"
psf_record "$SU" u1-intent.md gitlab.com
expect_eq "U mismatch record, content already at the destination: no URL" "$(su_url u1-intent.md)" "none"
psf_record "$SU" u1-intent.md none
expect_eq "U no-host record, content already at the destination: no URL" "$(su_url u1-intent.md)" "none"

echo "=== S: the carry site applies the full predicate, never the name-only one ==="
SS_SRC="$SCRIPT_CHECKOUT_ROOT/hooks/lib/plan-sync/commit-push.js"
if [ ! -f "$SS_SRC" ]; then fail "commit-push.js does not use the name-only predicate" "not implemented ($SS_SRC absent)"
elif HITS="$(grep -n 'isSyncTargetName' "$SS_SRC")"; then fail "commit-push.js does not use the name-only predicate" "$HITS"
else pass "commit-push.js does not use the name-only predicate"; fi
setup_ssh_stub "$BARE"
