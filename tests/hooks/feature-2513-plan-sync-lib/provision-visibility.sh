# provisionRepo visibility gate (detail.md S2 step 3a, S2-5) through the single-argument
# seam deps.repoVisibility(url) -> "public"|"private"|"internal"|null.
# Sourced by ../feature-2513-plan-sync-lib.sh with the real gh removed from PATH.
# The GitHub-form URL is served by the ssh stub, so a wrongly-allowed provision really pushes.
# Warning notes are matched on the case-insensitive word "visibility": every wording of
# "visibility could not be verified" must carry it; the exact sentence is not pinned.
# The descriptor side (gh/glab argv, timeout, unknown output) lives in
# feature-2307-forge-router.sh and feature-2308-gitlab-forge.sh.

VIS_URL="$PSF_ORIGIN_E2E"

# provision_vis <plansDir> <url> <public|private|internal|null|default> —
# prints "<ok|ng:reason>|<repoVisibility calls>|<notes>". allowLocal admits local bare paths.
# "default" leaves deps.repoVisibility unset so the codehost descriptor answers.
provision_vis() {
  psf_node 'const calls = []; const mode = process.argv[3];
const deps = Object.assign({ listPrivateRepoNames: () => [] }, allowLocal);
if (mode !== "default") deps.repoVisibility = (url) => { calls.push(url); return mode === "null" ? null : mode; };
Promise.resolve(ps.provisionRepo(process.argv[1], process.argv[2], deps)).then((r) =>
  process.stdout.write((r.ok ? "ok" : "ng:" + r.reason) + "|" + calls.join(",") + "|" + (r.notes || []).join(" ")));' "$1" "$2" "$3"
}

# split_vis <out> — sets VS (status), VC (calls), VN (notes).
split_vis() { VS="${1%%|*}"; local rest="${1#*|}"; VC="${rest%%|*}"; VN="${rest#*|}"; }

has_vis_note() { printf '%s' "$1" | grep -qi 'visibility'; }

echo "=== V3: public remote -> remote-public, nothing written ==="
VB="$PSF_ROOT/vis-public-bare.git"; psf_make_bare "$VB"; setup_ssh_stub "$VB"
VD="$PSF_ROOT/vis-public"; mkdir -p "$VD"
split_vis "$(provision_vis "$VD" "$VIS_URL" public)"
expect_eq "V3 provisionRepo fails with remote-public" "$VS" "ng:remote-public"
expect_eq "V3 repoVisibility called once with the remote URL" "$VC" "$VIS_URL"
if [ ! -e "$VD/.git" ] && [ ! -e "$VD/.gitignore" ]; then pass "V3 no .git, no .gitignore"
else fail "V3 no .git, no .gitignore" "plansDir: $(ls -A "$VD" | tr '\n' ' ')"; fi
expect_eq "V3 bare remote stays empty" "$(git -C "$VB" for-each-ref --format='%(refname)')" ""
if [ ! -s "$GIT_SSH_STUB_LOG" ]; then pass "V3 remote never contacted"
else fail "V3 remote never contacted" "ssh stub log: $(tr '\n' ' ' < "$GIT_SSH_STUB_LOG")"; fi

echo "=== V4: private / internal -> provisioned, no visibility note ==="
for mode in private internal; do
  VB="$PSF_ROOT/vis-$mode-bare.git"; psf_make_bare "$VB"; setup_ssh_stub "$VB"
  VD="$PSF_ROOT/vis-$mode"; mkdir -p "$VD"
  split_vis "$(provision_vis "$VD" "$VIS_URL" "$mode")"
  expect_eq "V4 $mode: provisionRepo ok" "$VS" "ok"
  expect_eq "V4 $mode: repoVisibility called once with the remote URL" "$VC" "$VIS_URL"
  if has_vis_note "$VN"; then fail "V4 $mode: no visibility warning note" "notes=$VN"
  else pass "V4 $mode: no visibility warning note"; fi
  expect_eq "V4 $mode: bare main holds only .gitignore" "$(tree_of "$VB")" ".gitignore "
  expect_eq "V4 $mode: checkProvisioned ok" "$(check_prov "$VD" "$VIS_URL")" "ok:$VIS_URL"
done

echo "=== V5: undetermined visibility (null) -> provisioned with a warning note ==="
VB="$PSF_ROOT/vis-null-bare.git"; psf_make_bare "$VB"; setup_ssh_stub "$VB"
VD="$PSF_ROOT/vis-null"; mkdir -p "$VD"
split_vis "$(provision_vis "$VD" "$VIS_URL" null)"
expect_eq "V5 provisionRepo ok (not refused)" "$VS" "ok"
expect_eq "V5 repoVisibility called once with the remote URL" "$VC" "$VIS_URL"
if has_vis_note "$VN"; then pass "V5 notes warn that visibility was not verified"
else fail "V5 notes warn that visibility was not verified" "notes=$VN"; fi
expect_eq "V5 bare main holds only .gitignore" "$(tree_of "$VB")" ".gitignore "

echo "=== V6: non-GitHub remote answering null -> provisioned with a warning note ==="
VB="$PSF_ROOT/vis-local-bare.git"; psf_make_bare "$VB"
VD="$PSF_ROOT/vis-local"; mkdir -p "$VD"
split_vis "$(provision_vis "$VD" "$VB" null)"
expect_eq "V6 provisionRepo ok" "$VS" "ok"
if has_vis_note "$VN"; then pass "V6 notes say visibility cannot be verified"
else fail "V6 notes say visibility cannot be verified" "notes=$VN"; fi

echo "=== V7: allowlist / placeholder refusals come before the visibility check ==="
while IFS='|' read -r name url want; do
  [ -z "$name" ] && continue
  VD="$PSF_ROOT/vis-order-$name"; mkdir -p "$VD"
  split_vis "$(provision_vis "$VD" "$url" private)"
  expect_eq "V7 $name: refused with $want" "$VS" "ng:$want"
  expect_eq "V7 $name: repoVisibility not called" "${VC:-none}" "none"
done <<'TABLE'
placeholder|ssh://git@github.com/YOUR_USERNAME/test-repo.git|url-placeholder
denied-relative|./rel/bare.git|url-denied
TABLE

echo "=== V8: checkProvisioned / syncPlanFile never check visibility ==="
VD="$PSF_ROOT/vis-private"; setup_ssh_stub "$PSF_ROOT/vis-private-bare.git"
printf 'vis intent\n' > "$VD/svis-intent.md"
OUT="$(PLAN_SYNC_REMOTE_URL="$VIS_URL" psf_node 'const calls = [];
const deps = { repoVisibility: (url) => { calls.push(url); return "public"; } };
Promise.resolve(ps.checkProvisioned(process.argv[1], process.argv[2], deps)).then((cp) =>
  Promise.resolve(ps.syncPlanFile(process.argv[1], path.join(process.argv[1], "svis-intent.md"), { budgetMs: 20000, deps }))
    .then((s) => process.stdout.write([cp.ok, s.status, s.url || s.reason || "", calls.length].join("|"))));' "$VD" "$VIS_URL")"
expect_eq "V8 check ok, sync pushed with URL, repoVisibility called 0 times" "$OUT" \
  "true|pushed|https://github.com/test-owner/test-repo/blob/main/svis-intent.md|0"

echo "=== V9: default seam (descriptor) — gh absent / stub codehost -> null -> warning note ==="
# gh is off PATH here, so the github descriptor cannot answer and must yield null, not throw.
VB="$PSF_ROOT/vis-default-gh-bare.git"; psf_make_bare "$VB"; setup_ssh_stub "$VB"
VD="$PSF_ROOT/vis-default-gh"; mkdir -p "$VD"
split_vis "$(provision_vis "$VD" "$VIS_URL" default)"
expect_eq "V9 github URL, gh absent: provisionRepo ok" "$VS" "ok"
if has_vis_note "$VN"; then pass "V9 github URL, gh absent: visibility warning note"
else fail "V9 github URL, gh absent: visibility warning note" "notes=$VN"; fi
VB="$PSF_ROOT/vis-default-local-bare.git"; psf_make_bare "$VB"
VD="$PSF_ROOT/vis-default-local"; mkdir -p "$VD"
split_vis "$(provision_vis "$VD" "$VB" default)"
expect_eq "V9 local bare (stub codehost): provisionRepo ok" "$VS" "ok"
if has_vis_note "$VN"; then pass "V9 local bare (stub codehost): visibility warning note"
else fail "V9 local bare (stub codehost): visibility warning note" "notes=$VN"; fi
