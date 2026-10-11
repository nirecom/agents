#!/usr/bin/env bash
# tests/lib/plan-sync-flow.sh
# Tests: tests/lib/plan-sync-flow.sh
# Tags: scope:issue-specific, shared-lib, plan-sync, fixture, flow
# In-process provisionRepo -> syncPlanFile flow helpers (#2513). Sourced after plan-sync-fixture.sh
# and psf_setup by the plan-sync lib entrypoints, after their hook-driven cases (the exports below
# would otherwise leak into them). Defines no pass/fail of its own except no_index_or_checkout.

# The destination is always $PSF_ORIGIN_PLAIN (a host, no known forge): a local bare path has
# no host, so nothing would ever be sent to it. The ssh stub serves whichever bare repo
# flow_bare selected. deps.listPrivateRepoNames answers [] so provisioning never reaches gh.
BARE="$PSF_ROOT/flow-bare.git"
psf_make_bare "$BARE"
setup_ssh_stub "$BARE"
export PLAN_SYNC_REMOTE_URL="$PSF_ORIGIN_PLAIN"
FLOW_RECORD_HOST="$PSF_HOST_PLAIN"

# flow_bare <bare> — the bare repo behind the destination URL from here on (use in a subshell
# to scope it to one call).
flow_bare() { export GIT_SSH_STUB_BARE; GIT_SSH_STUB_BARE="$(psf_np "$1")"; }

# flow_match <plansDir> <rel...> — match records, as the hook writes them before a sync.
flow_match() {
  local d="$1" r
  shift
  for r in "$@"; do psf_record "$d" "$r" "$FLOW_RECORD_HOST"; done
}

# provision <plansDir> [bare] — prints "ok|<notes>" or "ng:<reason>|<notes>".
provision() {
  (flow_bare "${2:-$BARE}"
  psf_node 'const deps = Object.assign({ listPrivateRepoNames: () => [] }, allowLocal);
Promise.resolve(ps.provisionRepo(process.argv[1], process.argv[2], deps)).then((r) =>
  process.stdout.write((r.ok ? "ok" : "ng:" + r.reason) + "|" + (r.notes || []).join(" ")));' "$1" "$PSF_ORIGIN_PLAIN")
}

# sync_local <plansDir> <rel> — writes the match record, then prints "<status>|<reason>|<url>".
sync_local() {
  flow_match "$1" "$2"
  sync_raw "$1" "$2"
}

# sync_raw <plansDir> <rel> — sync_local without touching the record.
sync_raw() {
  psf_node 'Promise.resolve(ps.syncPlanFile(process.argv[1], path.join(process.argv[1], process.argv[2]),
  { budgetMs: 20000, deps: allowLocal })).then((r) => process.stdout.write([r.status, r.reason || "", r.url || ""].join("|")));' "$1" "$2"
}

check_prov_local() {
  psf_node 'Promise.resolve(ps.checkProvisioned(process.argv[1], process.argv[2], allowLocal)).then((r) =>
  process.stdout.write(r.ok ? "ok:" + r.pushUrl : String(r.reason)));' "$1" "$PSF_ORIGIN_PLAIN"
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
