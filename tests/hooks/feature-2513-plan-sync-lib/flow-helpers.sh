# In-process provisionRepo -> syncPlanFile flow helpers (detail.md S1-7, S2-5), merged from
# the former feature-2513-plan-sync-flow.sh. Sourced by ../feature-2513-plan-sync-lib.sh
# after its own cases (the export below would otherwise leak into them). deps.isAllowedRemoteUrl
# is replaced (allowLocal) so a local bare repo is a valid remote; deps.listPrivateRepoNames
# answers [] so provisioning never reaches the real gh.

BARE="$PSF_ROOT/flow-bare.git"
psf_make_bare "$BARE"
export PLAN_SYNC_REMOTE_URL="$BARE"

# provision <plansDir> [remote] — prints "ok|<notes>" or "ng:<reason>|<notes>".
provision() {
  psf_node 'const deps = Object.assign({ listPrivateRepoNames: () => [] }, allowLocal);
Promise.resolve(ps.provisionRepo(process.argv[1], process.argv[2], deps)).then((r) =>
  process.stdout.write((r.ok ? "ok" : "ng:" + r.reason) + "|" + (r.notes || []).join(" ")));' "$1" "${2:-$BARE}"
}

# sync_local <plansDir> <rel> — prints "<status>|<reason>|<url>".
sync_local() {
  psf_node 'Promise.resolve(ps.syncPlanFile(process.argv[1], path.join(process.argv[1], process.argv[2]),
  { budgetMs: 20000, deps: allowLocal })).then((r) => process.stdout.write([r.status, r.reason || "", r.url || ""].join("|")));' "$1" "$2"
}

check_prov_local() {
  psf_node 'Promise.resolve(ps.checkProvisioned(process.argv[1], process.argv[2], allowLocal)).then((r) =>
  process.stdout.write(r.ok ? "ok:" + r.pushUrl : String(r.reason)));' "$1" "${2:-$BARE}"
}

# tree_of <git-dir-or-repo> [ref] — space-joined sorted path list of <ref>.
tree_of() { git -C "$1" ls-tree -r --name-only "${2:-refs/heads/main}" 2>/dev/null | tr '\n' ' '; }

# no_index_or_checkout <name> <plansDir> <rel...> — no .git/index, none of <rel> in the working tree.
no_index_or_checkout() {
  local name="$1" d="$2" r
  shift 2
  if [ -e "$d/.git/index" ]; then fail "$name" ".git/index exists"; return; fi
  for r in "$@"; do
    if [ -e "$d/$r" ]; then fail "$name" "$r checked out into the working tree"; return; fi
  done
  pass "$name"
}
