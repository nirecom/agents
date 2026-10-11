# Which plans the bulk publish of provisionRepo sends (hooks/lib/plan-sync/provision.js). Its
# three sources — plan files on disk, local main's tree (empty remote), local-only entries on
# top of the remote tip — pass the same predicate as a sync: the name condition AND a record
# matching the destination; an entry taken from local main must also be the bytes on disk.
# Sourced by ../feature-2513-plan-sync-send-selection.sh after sync.sh (ss_orphan_main,
# ss_remote, ss_tip, SS_OTHER_HOST). The destination is $PSF_ORIGIN_PLAIN through the ssh stub.

PP_PLANS="match-intent.md mismatch-intent.md nohost-outline.md norecord-detail.md stale-intent.md gone-outline.md"

# pp_write <dir> <prefix> — the six plan files, first version.
pp_write() {
  local rel
  for rel in $PP_PLANS; do printf '%s v1\n' "$2-$rel" > "$1/$2-$rel"; done
}

# pp_mark <dir> <prefix> — the records, then the later edits: "stale" gets a newer version on
# disk, "gone" leaves the disk. Only "match" and "stale" (as now on disk) may be published.
pp_mark() {
  psf_record "$1" "$2-match-intent.md" "$PSF_HOST_PLAIN"
  psf_record "$1" "$2-mismatch-intent.md" "$SS_OTHER_HOST"
  psf_record "$1" "$2-nohost-outline.md" none
  psf_record_remove "$1" "$2-norecord-detail.md"
  psf_record "$1" "$2-stale-intent.md" "$PSF_HOST_PLAIN"
  psf_record "$1" "$2-gone-outline.md" "$PSF_HOST_PLAIN"
  printf '%s v2\n' "$2-stale-intent.md" > "$1/$2-stale-intent.md"
  rm -f "$1/$2-gone-outline.md"
}

# pp_track <dir> <prefix> — commits the six plans on top of the current HEAD.
pp_track() {
  local rel
  for rel in $PP_PLANS; do git -C "$1" add -f -- "$2-$rel" || return 1; done
  git -C "$1" commit -q -m "local plans"
}

# pp_seed <bare> — a remote that already holds seed-intent.md.
pp_seed() {
  local s="$1.seed"
  harness_git_init "$s"
  git -C "$s" symbolic-ref HEAD refs/heads/main
  printf 'seed\n' > "$s/seed-intent.md"
  git -C "$s" add seed-intent.md
  git -C "$s" commit -q -m "remote plan"
  git -C "$s" push -q "$1" HEAD:refs/heads/main 2>/dev/null
}

# pp_check <label> <dir> <bare> <prefix> <want-tree> — provisions, then judges the destination.
pp_check() {
  local label="$1" d="$2" bare="$3" p="$4" want="$5" out hist left rel tip
  out="$(provision "$d" "$bare")"
  expect_eq "$label provisionRepo ok" "${out%%|*}" "ok"
  expect_eq "$label destination holds the matching plans only" "$(tree_of "$bare")" "$want"
  expect_eq "$label matching plan published byte-for-byte" "$(ss_remote "$bare" "$p-match-intent.md")" "$p-match-intent.md v1"
  expect_eq "$label a plan edited after its local commit is published as on disk" \
    "$(ss_remote "$bare" "$p-stale-intent.md")" "$p-stale-intent.md v2"
  hist="$(git -C "$bare" log --format= --name-only refs/heads/main 2>/dev/null | sort -u | tr '\n' ' ')"
  case "$hist" in
    "") fail "$label no unsent plan and no record anywhere in the destination history" "destination main has no history" ;;
    *-mismatch-*|*-nohost-*|*-norecord-*|*-gone-*|*note-project-host*)
      fail "$label no unsent plan and no record anywhere in the destination history" "history paths: $hist" ;;
    *) pass "$label no unsent plan and no record anywhere in the destination history" ;;
  esac
  left=""
  for rel in mismatch-intent.md nohost-outline.md norecord-detail.md; do
    [ "$(cat "$d/$p-$rel" 2>/dev/null)" = "$p-$rel v1" ] || left="$left $rel"
  done
  expect_eq "$label unsent plan files stay on disk unchanged" "${left:-none}" "none"
  expect_eq "$label the record of a published plan stays on disk" \
    "$(psf_record_state "$d" "$p-match-intent.md" "$PSF_ORIGIN_PLAIN")" "match"
  tip="$(ss_tip "$bare")"
  out="$(provision "$d" "$bare")"
  expect_eq "$label second run ok" "${out%%|*}" "ok"
  expect_eq "$label second run publishes nothing more" "$(ss_tip "$bare")" "$tip"
}

echo "=== PA: plan files on disk, empty remote, no local repo ==="
PA_BARE="$PSF_ROOT/pp-a-bare.git"; psf_make_bare "$PA_BARE"
PA="$PSF_ROOT/pp-a"; mkdir -p "$PA"
pp_write "$PA" pa
pp_mark "$PA" pa
pp_check "PA" "$PA" "$PA_BARE" pa ".gitignore pa-match-intent.md pa-stale-intent.md "

echo "=== PB: plans tracked on local main, empty remote ==="
PB_BARE="$PSF_ROOT/pp-b-bare.git"; psf_make_bare "$PB_BARE"
PB="$PSF_ROOT/pp-b"
harness_git_init "$PB"
git -C "$PB" symbolic-ref HEAD refs/heads/main
pp_write "$PB" pb
if pp_track "$PB" pb; then pass "PB precondition: six plans tracked on local main"
else fail "PB precondition: six plans tracked on local main" "tree=$(tree_of "$PB")"; fi
pp_mark "$PB" pb
pp_check "PB" "$PB" "$PB_BARE" pb ".gitignore pb-match-intent.md pb-stale-intent.md "

echo "=== PC: local-only plans on top of the remote tip (connected history) ==="
PC_BARE="$PSF_ROOT/pp-c-bare.git"; psf_make_bare "$PC_BARE"
pp_seed "$PC_BARE"
PC_SEED="$(ss_tip "$PC_BARE")"
PC="$PSF_ROOT/pp-c"
harness_git_init "$PC"
git -C "$PC" symbolic-ref HEAD refs/heads/main
git -C "$PC" fetch -q "$PC_BARE" refs/heads/main 2>/dev/null
git -C "$PC" reset -q --hard FETCH_HEAD 2>/dev/null
pp_write "$PC" pc
pp_track "$PC" pc
if [ "$PC_SEED" != missing ] && [ "$(ss_tip "$PC")" != "$PC_SEED" ] \
  && git -C "$PC" merge-base --is-ancestor "$PC_SEED" refs/heads/main 2>/dev/null; then
  pass "PC precondition: local main = remote commit + local-only plans"
else fail "PC precondition: local main = remote commit + local-only plans" "seed=$PC_SEED main=$(ss_tip "$PC")"; fi
pp_mark "$PC" pc
pp_check "PC" "$PC" "$PC_BARE" pc ".gitignore pc-match-intent.md pc-stale-intent.md seed-intent.md "
expect_eq "PC the plan the remote already held is untouched" "$(ss_remote "$PC_BARE" seed-intent.md)" "seed"

echo "=== PD: local plans on a history unrelated to a non-empty remote ==="
PD_BARE="$PSF_ROOT/pp-d-bare.git"; psf_make_bare "$PD_BARE"
pp_seed "$PD_BARE"
PD_SEED="$(ss_tip "$PD_BARE")"
PD="$PSF_ROOT/pp-d"
harness_git_init "$PD"
git -C "$PD" symbolic-ref HEAD refs/heads/main
pp_write "$PD" pd
# shellcheck disable=SC2046
ss_orphan_main "$PD" $(for rel in $PP_PLANS; do printf 'pd-%s ' "$rel"; done)
expect_eq "PD precondition: six plans tracked on local main" "$(git -C "$PD" ls-tree -r --name-only refs/heads/main 2>/dev/null | grep -c '^pd-')" "6"
pp_mark "$PD" pd
pp_check "PD" "$PD" "$PD_BARE" pd ".gitignore pd-match-intent.md pd-stale-intent.md seed-intent.md "
if [ "$PD_SEED" != missing ] && git -C "$PD_BARE" merge-base --is-ancestor "$PD_SEED" refs/heads/main 2>/dev/null; then
  pass "PD the remote's earlier commit is kept as an ancestor"
else fail "PD the remote's earlier commit is kept as an ancestor" "seed=$PD_SEED main=$(ss_tip "$PD_BARE")"; fi

echo "=== PS: the bulk publish applies the full predicate, never the name-only one ==="
PP_SRC="$SCRIPT_CHECKOUT_ROOT/hooks/lib/plan-sync/provision.js"
if [ ! -f "$PP_SRC" ]; then fail "provision.js does not use the name-only predicate" "not implemented ($PP_SRC absent)"
elif HITS="$(grep -n 'isSyncTargetName' "$PP_SRC")"; then fail "provision.js does not use the name-only predicate" "$HITS"
else pass "provision.js does not use the name-only predicate"; fi
PP_USERS=""; PP_COUNT=0
for f in "$SCRIPT_CHECKOUT_ROOT"/hooks/lib/plan-sync/*.js; do
  grep -q 'isSyncTargetName' "$f" 2>/dev/null || continue
  PP_USERS="$PP_USERS ${f##*/}"; PP_COUNT=$((PP_COUNT + 1))
done
PP_LABEL="the name-only predicate is named in allowlist.js and at most one predicate module"
case "$PP_USERS" in
  *commit-push.js*|*provision.js*|*" git.js"*|*remote-url.js*|*local-file.js*) fail "$PP_LABEL" "users:$PP_USERS" ;;
  *allowlist.js*)
    if [ "$PP_COUNT" -le 2 ]; then pass "$PP_LABEL"; else fail "$PP_LABEL" "users:$PP_USERS"; fi ;;
  *) fail "$PP_LABEL" "users:${PP_USERS:- none}" ;;
esac
