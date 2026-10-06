# provisionRepo flow cases (detail.md S2-5). Sourced by ../feature-2513-plan-sync-lib.sh.
# Leaves M1 provisioned against $BARE for sync.sh / nonff.sh.

M1="$PSF_ROOT/m1"; mkdir -p "$M1"

echo "=== P1: first run against an empty bare remote ==="
OUT="$(provision "$M1")"
expect_eq "P1 provisionRepo ok" "${OUT%%|*}" "ok"
if [ "${OUT%%|*}" = "ok" ]; then
  case "$OUT" in
    *.private-info-blocklist*) pass "P1 notes recommend .private-info-blocklist (private-repo list empty)" ;;
    *) fail "P1 notes recommend .private-info-blocklist (private-repo list empty)" "notes=${OUT#*|}" ;;
  esac
  expect_eq "P1 bare main holds only .gitignore" "$(tree_of "$BARE")" ".gitignore "
  expect_eq "P1 checkProvisioned ok afterwards" "$(check_prov_local "$M1")" "ok:$BARE"
  expect_eq "P1 HEAD is refs/heads/main" "$(git -C "$M1" symbolic-ref HEAD)" "refs/heads/main"
  no_index_or_checkout "P1 no .git/index after init" "$M1"
else
  fail "P1 post-provision state" "provision did not succeed: $OUT"
fi

echo "=== P2: second run is idempotent ==="
BEFORE="$(git -C "$BARE" rev-parse --verify -q refs/heads/main)"
OUT="$(provision "$M1")"
expect_eq "P2 provisionRepo ok again" "${OUT%%|*}" "ok"
if [ -n "$BEFORE" ]; then
  expect_eq "P2 bare main unchanged" "$(git -C "$BARE" rev-parse refs/heads/main)" "$BEFORE"
else
  fail "P2 bare main unchanged" "bare main missing after P1"
fi

echo "=== P5: a pre-set remote.origin.pushurl is removed ==="
M5="$PSF_ROOT/m5"
harness_git_init "$M5"
git -C "$M5" remote add origin "$BARE"
git -C "$M5" config remote.origin.pushurl "$PSF_ROOT/other-push.git"
OUT="$(provision "$M5")"
expect_eq "P5 provisionRepo ok" "${OUT%%|*}" "ok"
expect_eq "P5 pushurl unset" "$(git -C "$M5" config --get-all remote.origin.pushurl)" ""
expect_eq "P5 checkProvisioned ok" "$(check_prov_local "$M5")" "ok:$BARE"

echo "=== P6: local insteadOf -> url-rewritten, version not written ==="
M6="$PSF_ROOT/m6"
harness_git_init "$M6"
# insteadOf is a prefix match, so the value must be a real prefix of the remote URL.
git -C "$M6" config "url.$PSF_ROOT/rewritten-.insteadOf" "${BARE%.git}"
P6_EFFECTIVE="$(git -C "$M6" ls-remote --get-url "$BARE" 2>/dev/null)"
if [ -n "$P6_EFFECTIVE" ] && [ "$P6_EFFECTIVE" != "$BARE" ]; then pass "P6 precondition: insteadOf rewrites the remote URL"
else fail "P6 precondition: insteadOf rewrites the remote URL" "effective=$P6_EFFECTIVE raw=$BARE"; fi
OUT="$(provision "$M6")"
expect_eq "P6 provisionRepo fails with url-rewritten" "${OUT%%|*}" "ng:url-rewritten"
case "$OUT" in
  NOT_IMPLEMENTED:*) fail "P6 plansync.version not written" "not implemented ($OUT)" ;;
  *) expect_eq "P6 plansync.version not written" "$(git -C "$M6" config --get plansync.version)" "" ;;
esac

echo "=== P7: pre-existing junk never enters the initial commit ==="
BARE7="$PSF_ROOT/bare7.git"; psf_make_bare "$BARE7"
M7="$PSF_ROOT/m7"; mkdir -p "$M7/drafts"
printf 'log\n' > "$M7/s7-terminal.log"; printf '{}\n' > "$M7/s7.json"
printf 'ctx\n' > "$M7/s7-context.md"; printf 'd\n' > "$M7/drafts/s7-intent.md"
printf 'dot\n' > "$M7/.foo-intent.md"
OUT="$(provision "$M7" "$BARE7")"
expect_eq "P7 provisionRepo ok" "${OUT%%|*}" "ok"
expect_eq "P7 bare7 main holds only .gitignore" "$(tree_of "$BARE7")" ".gitignore "
if [ "${OUT%%|*}" != "ok" ]; then fail "P7 junk files left untouched" "provision did not succeed: $OUT"
elif [ -f "$M7/s7-terminal.log" ] && [ -f "$M7/drafts/s7-intent.md" ]; then pass "P7 junk files left untouched"
else fail "P7 junk files left untouched" "working-tree files were removed"; fi

echo "=== P8: an existing repo already TRACKING junk never publishes it ==="
BARE8="$PSF_ROOT/bare8.git"; psf_make_bare "$BARE8"
M8="$PSF_ROOT/m8"
harness_git_init "$M8"
git -C "$M8" symbolic-ref HEAD refs/heads/main
printf 'log\n' > "$M8/s8-terminal.log"; printf '{}\n' > "$M8/s8-state.json"
printf 'n\n' > "$M8/notes.md"; printf 'ctx\n' > "$M8/s8-context.md"
git -C "$M8" add -A
git -C "$M8" commit -q -m "pre-existing junk"
expect_eq "P8 precondition: junk is tracked on local main" "$(tree_of "$M8")" \
  "notes.md s8-context.md s8-state.json s8-terminal.log "
OUT="$(provision "$M8" "$BARE8")"
expect_eq "P8 provisionRepo ok" "${OUT%%|*}" "ok"
printf 'intent 8\n' > "$M8/s8-intent.md"
OUT="$(export PLAN_SYNC_REMOTE_URL="$BARE8"; sync_local "$M8" s8-intent.md)"
expect_eq "P8 sync pushed" "${OUT%%|*}" "pushed"
expect_eq "P8 bare8 main holds only .gitignore + allowlisted plan" "$(tree_of "$BARE8")" ".gitignore s8-intent.md "
if [ -f "$M8/s8-terminal.log" ] && [ -f "$M8/notes.md" ]; then pass "P8 junk files left in the working tree"
else fail "P8 junk files left in the working tree" "working-tree files were removed"; fi

echo "=== P9: non-empty remote + local-only junk commit on top -> junk never published ==="
BARE9="$PSF_ROOT/bare9.git"; psf_make_bare "$BARE9"
SEED9="$PSF_ROOT/seed9"
harness_git_init "$SEED9"
git -C "$SEED9" symbolic-ref HEAD refs/heads/main
printf 'intent 9\n' > "$SEED9/s9-intent.md"
git -C "$SEED9" add s9-intent.md
git -C "$SEED9" commit -q -m "prior remote plan"
git -C "$SEED9" push -q "$BARE9" HEAD:refs/heads/main 2>/dev/null
P9_SEED="$(git -C "$BARE9" rev-parse --verify -q refs/heads/main)"
M9="$PSF_ROOT/m9"
harness_git_init "$M9"
git -C "$M9" symbolic-ref HEAD refs/heads/main
git -C "$M9" fetch -q "$BARE9" refs/heads/main 2>/dev/null
git -C "$M9" reset -q --hard FETCH_HEAD 2>/dev/null
printf 'log\n' > "$M9/s9-terminal.log"; printf '{}\n' > "$M9/s9-state.json"
printf 'n\n' > "$M9/notes.md"; printf 'ctx\n' > "$M9/s9-context.md"
git -C "$M9" add -A
git -C "$M9" commit -q -m "local-only junk"
P9_PRE="no"
if [ -n "$P9_SEED" ] && git -C "$M9" merge-base --is-ancestor "$P9_SEED" refs/heads/main 2>/dev/null \
  && [ "$(git -C "$M9" rev-parse refs/heads/main)" != "$P9_SEED" ]; then P9_PRE="yes"; fi
expect_eq "P9 precondition: local main = remote commit + local-only commit" "$P9_PRE" "yes"
expect_eq "P9 precondition: junk tracked on local main" "$(tree_of "$M9")" \
  "notes.md s9-context.md s9-intent.md s9-state.json s9-terminal.log "
OUT="$(provision "$M9" "$BARE9")"
expect_eq "P9 provisionRepo ok" "${OUT%%|*}" "ok"
printf 'outline 9\n' > "$M9/s9-outline.md"
OUT="$(export PLAN_SYNC_REMOTE_URL="$BARE9"; sync_local "$M9" s9-outline.md)"
expect_eq "P9 sync pushed" "${OUT%%|*}" "pushed"
expect_eq "P9 bare9 main holds only .gitignore + allowlisted plans" "$(tree_of "$BARE9")" \
  ".gitignore s9-intent.md s9-outline.md "
if git -C "$BARE9" merge-base --is-ancestor "$P9_SEED" refs/heads/main 2>/dev/null; then pass "P9 prior remote commit kept as ancestor"
else fail "P9 prior remote commit kept as ancestor" "seed=$P9_SEED main=$(git -C "$BARE9" rev-parse --verify -q refs/heads/main)"; fi
P9_HIST="$(git -C "$BARE9" log --format= --name-only refs/heads/main 2>/dev/null | sort -u | tr '\n' ' ')"
case "$P9_HIST" in
  "") fail "P9 junk absent from all remote history" "bare9 main has no history" ;;
  *s9-terminal.log*|*s9-state.json*|*notes.md*|*s9-context.md*) fail "P9 junk absent from all remote history" "history paths: $P9_HIST" ;;
  *) pass "P9 junk absent from all remote history" ;;
esac
if [ -f "$M9/s9-terminal.log" ] && [ -f "$M9/notes.md" ] && [ -f "$M9/s9-state.json" ]; then pass "P9 junk files left in the working tree"
else fail "P9 junk files left in the working tree" "working-tree files were removed"; fi

echo "=== P10: plans already on disk are published by the first init (empty remote) ==="
BARE10="$PSF_ROOT/bare10.git"; psf_make_bare "$BARE10"
M10="$PSF_ROOT/m10"; mkdir -p "$M10"
printf 'i\n' > "$M10/a10-intent.md"; printf 'o\n' > "$M10/a10-outline.md"; printf 'd\n' > "$M10/b10-detail.md"
printf 'log\n' > "$M10/a10-terminal.log"; printf 'src\n' > "$M10/src10.txt"
ln "$M10/src10.txt" "$M10/h10-intent.md" 2>/dev/null
OUT="$(provision "$M10" "$BARE10")"
expect_eq "P10 provisionRepo ok" "${OUT%%|*}" "ok"
expect_eq "P10 bare10 holds every on-disk plan, no junk, no hardlink" "$(tree_of "$BARE10")" \
  ".gitignore a10-intent.md a10-outline.md b10-detail.md "
expect_eq "P10 content published byte-for-byte" "$(git -C "$BARE10" show refs/heads/main:a10-outline.md)" "o"
no_index_or_checkout "P10 no .git/index after init" "$M10"
P10_BEFORE="$(git -C "$BARE10" rev-parse --verify -q refs/heads/main)"
OUT="$(provision "$M10" "$BARE10")"
expect_eq "P10 second run ok" "${OUT%%|*}" "ok"
expect_eq "P10 second run leaves bare10 main unchanged" "$(git -C "$BARE10" rev-parse --verify -q refs/heads/main)" "$P10_BEFORE"

echo "=== P11: re-init on a non-empty remote adds only names it lacks, never overwrites ==="
BARE11="$PSF_ROOT/bare11.git"; psf_make_bare "$BARE11"
SEED11="$PSF_ROOT/seed11"
harness_git_init "$SEED11"
git -C "$SEED11" symbolic-ref HEAD refs/heads/main
printf 'remote\n' > "$SEED11/s11-intent.md"
git -C "$SEED11" add s11-intent.md
git -C "$SEED11" commit -q -m "remote plan"
git -C "$SEED11" push -q "$BARE11" HEAD:refs/heads/main 2>/dev/null
M11="$PSF_ROOT/m11"; mkdir -p "$M11"
printf 'local\n' > "$M11/s11-intent.md"; printf 'new\n' > "$M11/t11-outline.md"
OUT="$(provision "$M11" "$BARE11")"
expect_eq "P11 provisionRepo ok" "${OUT%%|*}" "ok"
expect_eq "P11 bare11 gains the absent plan" "$(tree_of "$BARE11")" ".gitignore s11-intent.md t11-outline.md "
expect_eq "P11 remote copy of a shared name is not overwritten" "$(git -C "$BARE11" show refs/heads/main:s11-intent.md)" "remote"
expect_eq "P11 local file left as written" "$(cat "$M11/s11-intent.md")" "local"

echo "=== BL: .private-info-blocklist note only for a remote absent from listPrivateRepoNames ==="
# provision_bl <plansDir> <url> <mode> — deps.listPrivateRepoNames per mode; repoVisibility
# answers "private" so the real gh is never asked. Prints "ok|<notes>" or "ng:<reason>|<notes>".
provision_bl() {
  psf_node 'const mode = process.argv[3];
const lists = { empty: [], other: ["test-owner/other-repo"], prefix: ["test-owner/test-repo-2"],
  short: ["test-owner/test-rep", "test-owner", "other-owner/test-repo"],
  exact: ["test-owner/other-repo", "test-owner/test-repo"], case: ["Test-Owner/Test-Repo"],
  local: ["test-owner/test-repo", process.argv[2]] };
const deps = Object.assign({ repoVisibility: () => "private" }, allowLocal);
deps.listPrivateRepoNames = mode === "throws" ? () => { throw new Error("gh exploded"); }
  : mode === "nonarray" ? () => "test-owner/test-repo" : () => lists[mode];
Promise.resolve(ps.provisionRepo(process.argv[1], process.argv[2], deps)).then((r) =>
  process.stdout.write((r.ok ? "ok" : "ng:" + r.reason) + "|" + (r.notes || []).join(" ")));' "$1" "$2" "$3"
}
BL_BARE="$PSF_ROOT/bl-bare.git"; psf_make_bare "$BL_BARE"; setup_ssh_stub "$BL_BARE"
while IFS='|' read -r mode url want label; do
  [ -z "$mode" ] && continue
  [ "$url" = "gh" ] && url="$PSF_ORIGIN_E2E" || url="$BL_BARE"
  OUT="$(provision_bl "$PSF_ROOT/bl-$mode" "$url" "$mode")"
  expect_eq "BL $label: provisionRepo ok" "${OUT%%|*}" "ok"
  case "${OUT#*|}" in *.private-info-blocklist*) got=note ;; *) got=no-note ;; esac
  expect_eq "BL $label: blocklist note -> $want" "$got" "$want"
done <<'TABLE'
empty|gh|note|list empty
other|gh|note|list holds only another repo
prefix|gh|note|list holds a longer name sharing the prefix
short|gh|note|list holds only partial matches (shorter repo, owner alone, other owner)
exact|gh|no-note|list holds owner/repo
case|gh|no-note|list holds a case variant of owner/repo
throws|gh|note|list function throws
nonarray|gh|note|list function returns a non-array
local|local|note|non-GitHub remote, list holds owner/repo and the URL
TABLE
unset GIT_SSH_COMMAND GIT_SSH_VARIANT
