#!/usr/bin/env bash
# tests/hooks/feature-2513-plan-sync-lib.sh
# Tests: hooks/lib/plan-sync.js, hooks/lib/plans-artifact-registry.js
# Tags: plan-sync, plans, git, lib, registry, TL2, scope:issue-specific, flow, provision, non-ff, visibility, gh-stub, symlink, security, hardlink, toctou, stale-tip
# #2513 plan-sync lib unit tests (detail.md S1-6): URL helpers, allowlist, .gitignore,
# registry contract, checkProvisioned verdicts, syncPlanFile non-push statuses.
set -uo pipefail

# TL3 gap (what this test does NOT catch):
# - a real GitHub push/auth round trip (covered only through the ssh stub e2e)
# - developer-specific global git config beyond the insteadOf forms exercised here
# - the production allowlist on the flow provision path (deps is replaced there)
# - symlink.sh's skip branches (host without symlink / hard-link support) are not verified on any host here
# - a real concurrent lstat->open race (TOC-2 / TOC-3 simulate it by patching fs.lstatSync / fs.openSync in-process)
# Closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: hook-registration.
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
# shellcheck source=../lib/plan-sync-fixture.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/plan-sync-fixture.sh"

psf_setup || { fail "setup" "psf_setup failed"; exit 1; }
psf_tag_unimplemented_fails
trap psf_cleanup EXIT
PLANS="$WORKFLOW_PLANS_DIR"
URL_TABLE="$(psf_np "$SCRIPT_CHECKOUT_ROOT/tests/fixtures/session-sync-remote-url-table.txt")"

# expect_eq <name> <got> <want> — reports "not implemented" for a missing module.
expect_eq() {
  case "$2" in
    NOT_IMPLEMENTED:*) fail "$1" "not implemented (${2})"; return ;;
  esac
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "want=$(printf '%q' "$3") got=$(printf '%q' "$2")"; fi
}

if psf_git_version_ok; then pass "git-version>=2.32"; else fail "git-version>=2.32" "$(git version)"; fi

case_begin "allowlist-shared-fixture" "hooks/lib/plan-sync.js"
OUT="$(psf_node '
const rows = fs.readFileSync(process.argv[1], "utf8").split(/\r?\n/).filter((l) => l && !l.startsWith("#"));
const bad = rows.filter((l) => { const i = l.indexOf("\t"); const want = l.slice(0, i);
  return (ps.isAllowedRemoteUrl(l.slice(i + 1)) ? "ALLOW" : "DENY") !== want; });
process.stdout.write((rows.length >= 30 ? "rows-ok" : "rows-" + rows.length) + "|" + (bad.join(",") || "none"));' "$URL_TABLE")"
expect_eq "allowlist: every shared-fixture ALLOW/DENY row matches" "$OUT" "rows-ok|none"
while IFS='|' read -r name url want; do
  [ -z "$name" ] && continue
  OUT="$(psf_node 'process.stdout.write(ps.isAllowedRemoteUrl(process.argv[1]) ? "ALLOW" : "DENY");' "$url")"
  expect_eq "allowlist: $name" "$OUT" "$want"
done <<TABLE
scp-github|$PSF_ORIGIN_GH|ALLOW
ssh-github|$PSF_ORIGIN_E2E|ALLOW
ssh-dead-port|$PSF_ORIGIN_DEAD|ALLOW
local-abs-path|$PSF_ROOT/bare.git|DENY
local-relative|./rel/bare.git|DENY
file-scheme|file://$PSF_ROOT/bare.git|DENY
TABLE
OUT="$(psf_node 'process.stdout.write(ps.isAllowedRemoteUrl("") ? "ALLOW" : "DENY");')"
expect_eq "allowlist: empty string" "$OUT" "DENY"
OUT="$(psf_node 'process.stdout.write(ps.isAllowedRemoteUrl("C:\\plans\\bare.git") ? "ALLOW" : "DENY");')"
expect_eq "allowlist: windows backslash path" "$OUT" "DENY"
case_end

case_begin "parse-github-remote" "hooks/lib/plan-sync.js"
while IFS='|' read -r name url want; do
  [ -z "$name" ] && continue
  OUT="$(psf_node 'const r = ps.parseGitHubRemote(process.argv[1]);
process.stdout.write(r ? r.owner + "/" + r.repo : "null");' "$url")"
  expect_eq "parseGitHubRemote: $name" "$OUT" "$want"
done <<'TABLE'
scp-dotgit|git@github.com:test-owner/test-repo.git|test-owner/test-repo
scp-bare|git@github.com:test-owner/test-repo|test-owner/test-repo
ssh-dotgit|ssh://git@github.com/test-owner/test-repo.git|test-owner/test-repo
ssh-bare|ssh://git@github.com/test-owner/test-repo|test-owner/test-repo
https-dotgit|https://github.com/test-owner/test-repo.git|test-owner/test-repo
https-userinfo|https://test-user:s3cr3t@github.com/test-owner/test-repo.git|test-owner/test-repo
non-github-https|https://gitlab.example.com/test-owner/test-repo.git|null
non-github-scp|git@example.com:test-owner/test-repo.git|null
local-path|/tmp/plan-sync/bare.git|null
repo-dot|git@github.com:test-owner/.|null
repo-dotdot|git@github.com:test-owner/..|null
owner-underscore|git@github.com:test_owner/test-repo.git|null
owner-dot|https://github.com/test.owner/test-repo.git|null
deeper-path|git@github.com:test-owner/test-repo/x.git|null
lookalike-host|https://github.com.evil.com/test-owner/test-repo.git|null
ssh-port-22|ssh://git@github.com:22/test-owner/test-repo.git|test-owner/test-repo
TABLE
OUT="$(psf_node 'process.stdout.write(ps.redactUrl("https://test-user:s3cr3t@github.com/test-owner/test-repo.git"));')"
case "$OUT" in
  NOT_IMPLEMENTED:*) fail "redactUrl: userinfo hidden" "not implemented ($OUT)" ;;
  *s3cr3t*|*test-user*) fail "redactUrl: userinfo hidden" "got=$OUT" ;;
  *github.com/test-owner/test-repo.git*) pass "redactUrl: userinfo hidden, host/path kept" ;;
  *) fail "redactUrl: userinfo hidden" "host/path lost: $OUT" ;;
esac
OUT="$(psf_node 'process.stdout.write(ps.redactUrl(process.argv[1]));' "$PSF_ORIGIN_E2E")"
expect_eq "redactUrl: URL without userinfo unchanged" "$OUT" "$PSF_ORIGIN_E2E"
case_end

case_begin "blob-url-for" "hooks/lib/plan-sync.js"
OUT="$(psf_node 'process.stdout.write(ps.blobUrlFor({ owner: "test-owner", repo: "test-repo" }, "main", process.argv[1]));' 's 1#x-intent.md')"
expect_eq "blobUrlFor: space and hash encoded" "$OUT" "https://github.com/test-owner/test-repo/blob/main/s%201%23x-intent.md"
OUT="$(psf_node 'process.stdout.write(ps.blobUrlFor({ owner: "test-owner", repo: "test-repo" }, "main", process.argv[1]));' 'd ir/a?b.md')"
expect_eq "blobUrlFor: per-segment encoding keeps separators" "$OUT" "https://github.com/test-owner/test-repo/blob/main/d%20ir/a%3Fb.md"
case_end

case_begin "render-gitignore" "hooks/lib/plan-sync.js"
OUT="$(psf_node 'const l = ps.renderGitignore().split("\n").filter((x) => x !== "");
process.stdout.write((l[0].startsWith("#") ? "comment" : "no-comment") + "|" + l.slice(1).join(" "));')"
expect_eq "renderGitignore: comment line + allowlist patterns" "$OUT" \
  "comment|/* !/*-intent.md !/*-outline.md !/*-detail.md /.* !/.gitignore"
GI_REPO="$PSF_ROOT/gi-repo"
harness_git_init "$GI_REPO"
psf_node 'fs.writeFileSync(path.join(process.argv[1], ".gitignore"), ps.renderGitignore());' "$GI_REPO" >/dev/null
while IFS='|' read -r rel want; do
  [ -z "$rel" ] && continue
  if git -C "$GI_REPO" check-ignore -q --no-index -- "$rel"; then got=ignored; else got=tracked; fi
  [ -f "$GI_REPO/.gitignore" ] || got="NOT_IMPLEMENTED: renderGitignore wrote no .gitignore"
  expect_eq "check-ignore: $rel" "$got" "$want"
done <<'TABLE'
s2513-intent.md|tracked
s2513-outline.md|tracked
s2513-detail.md|tracked
.gitignore|tracked
s2513-context.md|ignored
drafts/x-intent.md|ignored
.foo-intent.md|ignored
s2513-terminal.log|ignored
s2513-plan.jsonl|ignored
TABLE
case_end

case_begin "is-sync-target" "hooks/lib/plan-sync.js"
while IFS='|' read -r name rel want; do
  [ -z "$name" ] && continue
  OUT="$(psf_node 'process.stdout.write(String(ps.isSyncTarget(process.argv[1], path.join(process.argv[1], process.argv[2]))));' "$PLANS" "$rel")"
  expect_eq "isSyncTarget: $name" "$OUT" "$want"
done <<'TABLE'
intent|s2513-intent.md|true
outline|s2513-outline.md|true
detail|s2513-detail.md|true
context|s2513-context.md|false
intermediate|s2513-outline-draft.md|false
drafts-child|drafts/s2513-intent.md|false
dot-entry|.foo-intent.md|false
outside|../elsewhere/s2513-intent.md|false
TABLE
case_end

case_begin "registry-synced-kinds-contract" "hooks/lib/plans-artifact-registry.js"
read -r -d '' REG_JS <<'JS'
const path = require("path"); const reg = require(process.env.PSF_REG); const { getSuffix } = require(process.env.PSF_PCF);
const synced = reg.SYNCED_PLAN_ARTIFACT_KINDS;
if (!Array.isArray(synced)) { process.stdout.write("NOT_IMPLEMENTED: SYNCED_PLAN_ARTIFACT_KINDS"); process.exit(0); }
const plans = process.env.WORKFLOW_PLANS_DIR; const out = [];
for (const k of ["intent", "outline", "detail", "context", "issue-prefill", "test-review"]) {
  const s = getSuffix(path.join(plans, "s2513-" + k + ".md"));
  if ((s === k) !== synced.includes(k)) out.push(k + ":" + s);
}
process.stdout.write([...synced].sort().join(",") + "|" + (out.join(",") || "agree"));
JS
OUT="$(PSF_REG="$(psf_np "$SCRIPT_CHECKOUT_ROOT/hooks/lib/plans-artifact-registry.js")" \
  PSF_PCF="$(psf_np "$SCRIPT_CHECKOUT_ROOT/hooks/lib/plan-confirm-flag.js")" psf_timeout 30 node -e "$REG_JS" 2>&1)"
expect_eq "SYNCED_PLAN_ARTIFACT_KINDS == getSuffix accepted set (both directions)" "$OUT" "detail,intent,outline|agree"
case_end

# check_prov <dir> <remote-url> — prints "ok:<pushUrl>" or the reason.
check_prov() {
  psf_node 'Promise.resolve(ps.checkProvisioned(process.argv[1], process.argv[2])).then((r) =>
  process.stdout.write(r.ok ? "ok:" + r.pushUrl : String(r.reason)));' "$1" "$2"
}

case_begin "check-provisioned-verdicts" "hooks/lib/plan-sync.js"
CP=0
while IFS='|' read -r name mutation want; do
  [ -z "$name" ] && continue
  CP=$((CP + 1)); d="$PSF_ROOT/cp-$CP"; arg="$PSF_ORIGIN_GH"
  if [ "$mutation" = "empty-dir" ] || [ "$mutation" = "git-file" ]; then
    mkdir -p "$d"; [ "$mutation" = "git-file" ] && printf 'gitdir: %s\n' "$PSF_ROOT/elsewhere" > "$d/.git"
  else
    psf_make_provisioned "$d" "$PSF_ORIGIN_GH" >/dev/null 2>&1 || { fail "checkProvisioned: $name" "not implemented (fixture needs renderGitignore/INIT_VERSION)"; continue; }
  fi
  case "$mutation" in
    version-0) git -C "$d" config plansync.version 0 ;;
    version-unset) git -C "$d" config --unset plansync.version ;;
    other-remote) arg="git@github.com:test-owner/other-repo.git" ;;
    local-insteadof) git -C "$d" config "url.ssh://git@127.0.0.1:1/.insteadOf" "git@github.com:" ;;
    push-insteadof) git -C "$d" config "url.ssh://git@127.0.0.1:1/.pushInsteadOf" "git@github.com:" ;;
    pushurl) git -C "$d" config remote.origin.pushurl "$PSF_ORIGIN_GH" ;;
    gitignore-drift) printf '!/*.log\n' >> "$d/.gitignore" ;;
  esac
  if [ "$mutation" = "global-insteadof" ]; then
    OUT="$(cp "$GIT_CONFIG_GLOBAL" "$d.gitconfig"
      git config --file "$d.gitconfig" "url.ssh://git@127.0.0.1:1/.insteadOf" "git@github.com:"
      GIT_CONFIG_GLOBAL="$d.gitconfig" check_prov "$d" "$arg")"
  else
    OUT="$(check_prov "$d" "$arg")"
  fi
  [ "$want" = "ok" ] && want="ok:$PSF_ORIGIN_GH"
  expect_eq "checkProvisioned: $name" "$OUT" "$want"
done <<'TABLE'
provisioned-ok|none|ok
no-repo|empty-dir|no-repo
dot-git-is-a-file|git-file|no-repo
version-mismatch|version-0|version-mismatch
version-unset|version-unset|version-mismatch
remote-mismatch|other-remote|remote-mismatch
rewrite-local-insteadof|local-insteadof|url-rewritten
rewrite-push-insteadof|push-insteadof|url-rewritten
rewrite-pushurl|pushurl|url-rewritten
rewrite-global-insteadof|global-insteadof|url-rewritten
gitignore-drift|gitignore-drift|gitignore-drift
TABLE
# deps seam: omitted deps keeps the production allowlist, so a local-path origin is refused.
LOCAL_BARE="$PSF_ROOT/seam-bare.git"; psf_make_bare "$LOCAL_BARE"
if psf_make_provisioned "$PSF_ROOT/seam" "$LOCAL_BARE" >/dev/null 2>&1; then
  OUT="$(psf_node 'const a = ps.checkProvisioned(process.argv[1], process.argv[2]);
const b = ps.checkProvisioned(process.argv[1], process.argv[2], allowLocal);
Promise.all([a, b]).then(([x, y]) => process.stdout.write(x.ok + "|" + y.ok));' "$PSF_ROOT/seam" "$LOCAL_BARE")"
else OUT="NOT_IMPLEMENTED: fixture"; fi
expect_eq "deps omitted: local-path origin refused by allowlist; allowLocal deps accepts" "$OUT" "false|true"
case_end

# sync_status <plansDir> <absPath> — prints "<status>|<reason>|<url>".
sync_status() {
  psf_node 'Promise.resolve(ps.syncPlanFile(process.argv[1], process.argv[2], { budgetMs: 20000 })).then((r) =>
  process.stdout.write([r.status, r.reason || "", r.url || ""].join("|")));' "$1" "$2"
}

case_begin "sync-plan-file-non-push-statuses" "hooks/lib/plan-sync.js"
printf 'plan\n' > "$PLANS/s2513-intent.md"
expect_eq "syncPlanFile: empty URL -> off" "$(PLAN_SYNC_REMOTE_URL="" sync_status "$PLANS" "$PLANS/s2513-intent.md")" "off||"
printf 'ctx\n' > "$PLANS/s2513-context.md"
OUT="$(PLAN_SYNC_REMOTE_URL="$PSF_ORIGIN_GH" sync_status "$PLANS" "$PLANS/s2513-context.md")"
expect_eq "syncPlanFile: non-target -> skipped" "${OUT%%|*}" "skipped"
expect_eq "syncPlanFile: unprovisioned -> not-provisioned/no-repo" \
  "$(PLAN_SYNC_REMOTE_URL="$PSF_ORIGIN_GH" sync_status "$PLANS" "$PLANS/s2513-intent.md")" "not-provisioned|no-repo|"
BR="$PSF_ROOT/branch-plans"
if psf_make_provisioned "$BR" "$PSF_ORIGIN_GH" >/dev/null 2>&1; then
  git -C "$BR" symbolic-ref HEAD refs/heads/other; printf 'p\n' > "$BR/s2513-intent.md"
  OUT="$(PLAN_SYNC_REMOTE_URL="$PSF_ORIGIN_GH" WORKFLOW_PLANS_DIR="$BR" sync_status "$BR" "$BR/s2513-intent.md")"
else OUT="NOT_IMPLEMENTED: fixture"; fi
expect_eq "syncPlanFile: HEAD not main -> not-provisioned/detached-or-branch" "$OUT" "not-provisioned|detached-or-branch|"
case_end

case_begin "overlay-preserves-base-entries" "hooks/lib/plan-sync.js"
OV="$PSF_ROOT/overlay-plans"
if psf_make_provisioned "$OV" "$PSF_ORIGIN_DEAD" >/dev/null 2>&1; then
  printf 'a\n' > "$OV/s2513a-intent.md"; psf_commit_file "$OV" s2513a-intent.md refs/remotes/origin/main
  rm -f "$OV/s2513a-intent.md"; printf 'b\n' > "$OV/s2513b-intent.md"
  OUT="$(PLAN_SYNC_REMOTE_URL="$PSF_ORIGIN_DEAD" GIT_SSH_COMMAND=false WORKFLOW_PLANS_DIR="$OV" sync_status "$OV" "$OV/s2513b-intent.md")"
  expect_eq "syncPlanFile: unreachable remote -> failed" "${OUT%%|*}" "failed"
  TREE="$(git -C "$OV" ls-tree -r --name-only refs/heads/main 2>&1 | tr '\n' ' ')"
  expect_eq "overlay: base-only entry kept, target added, nothing deleted" "$TREE" ".gitignore s2513a-intent.md s2513b-intent.md "
  if [ ! -e "$OV/.git/index" ] && [ ! -e "$OV/s2513a-intent.md" ]; then pass "overlay: no main index, no checkout"
  else fail "overlay: no main index, no checkout" "index or s2513a-intent.md appeared"; fi
else
  fail "overlay-preserves-base-entries" "not implemented (fixture needs renderGitignore/INIT_VERSION)"
fi
case_end

case_begin "no-ssh-layer-in-production" "hooks/lib/plan-sync.js"
SRCS=()
for f in "$SCRIPT_CHECKOUT_ROOT/hooks/lib/plan-sync.js" "$SCRIPT_CHECKOUT_ROOT/hooks/lib/plan-sync"; do
  [ -e "$f" ] && SRCS+=("$f")
done
if [ "${#SRCS[@]}" -ne 2 ]; then
  fail "no GIT_SSH/sshCommand in plan-sync sources" "not implemented (${#SRCS[@]}/2 sources present)"
elif HITS="$(grep -rnE 'GIT_SSH|sshCommand' "${SRCS[@]}")"; then
  fail "no GIT_SSH/sshCommand in plan-sync sources" "$HITS"
else
  pass "no GIT_SSH/sshCommand in plan-sync sources"
fi
case_end

# Flow sections share state in order: provision -> sync -> nonff.
LIB_DIR="$SCRIPT_CHECKOUT_ROOT/tests/hooks/feature-2513-plan-sync-lib"
. "$LIB_DIR/flow-helpers.sh"
case_begin "flow-provision-repo" "hooks/lib/plan-sync.js"
. "$LIB_DIR/provision.sh"
case_end
case_begin "flow-sync-plan-file" "hooks/lib/plan-sync.js"
. "$LIB_DIR/sync.sh"
case_end
case_begin "flow-non-ff-recovery" "hooks/lib/plan-sync.js"
. "$LIB_DIR/nonff.sh"
case_end
# Visibility sections: the real gh (network) is removed from PATH from here on.
psf_drop_gh_from_path
case_begin "flow-provision-visibility" "hooks/lib/plan-sync.js"
. "$LIB_DIR/provision-visibility.sh"
case_end
case_begin "flow-non-regular-targets" "hooks/lib/plan-sync.js"
. "$LIB_DIR/symlink.sh"
case_end
case_begin "flow-open-time-swap" "hooks/lib/plan-sync.js"
. "$LIB_DIR/toctou.sh"
case_end
case_begin "flow-stale-origin-main-no-op" "hooks/lib/plan-sync.js"
. "$LIB_DIR/stale-tip.sh"
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
