#!/usr/bin/env bash
# tests/bin/feature-3142-board-resolve/_lib.sh — shared fixture helpers for the #3142 board tests (sourced).
# Tests: bin/github-issues/lib/resolve-project.sh
# Tags: scope:issue-specific, shared-lib, projects-v2, feature-3142
# The sourcing test pins HOME / WORKFLOW_STATE_DIR / WORKFLOW_PLANS_DIR at top level before sourcing this.
#   f3142_install_mock <dir>       gh wrapper in <dir>/mockbin, prepended to PATH (after the harness guard)
#   f3142_linked <file> <more> <spec...>  projectsV2 object; spec = id:number:owner:closed(true|false)
#   f3142_repo <dir> <owner/repo>  git fixture with origin on github.com, hooks off
#   f3142_cache_file               the resolver's project-resolve.tsv under the pinned state root
#   f3142_cache_row <key> <owner> <num> <pid>  11-column sid1 row text
#   f3142_path_without_gh <tools-dir>  PATH with no gh on it

F3142_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
F3142_ROOT="$(cd "$F3142_LIB_DIR/../../.." && pwd)"

f3142_install_mock() {
  mkdir -p "$1/mockbin"
  printf '#!/usr/bin/env bash\nexec bash %q "$@"\n' "$F3142_LIB_DIR/_gh-mock.sh" >"$1/mockbin/gh"
  chmod +x "$1/mockbin/gh"
  PATH="$1/mockbin:$PATH"
  export PATH
}

f3142_linked() {
  local file="$1" more="$2" spec id num own closed nodes="" sep=""
  shift 2
  for spec in "$@"; do
    IFS=':' read -r id num own closed <<<"$spec"
    nodes="$nodes$sep{\"id\":\"$id\",\"number\":$num,\"closed\":${closed:-false},\"owner\":{\"login\":\"$own\"}}"
    sep=","
  done
  printf '{"nodes":[%s],"pageInfo":{"hasNextPage":%s,"endCursor":null}}\n' "$nodes" "$more" >"$file"
}

f3142_repo() {
  mkdir -p "$1"
  harness_git_init "$1"
  git -C "$1" remote add origin "https://github.com/$2.git"
}

f3142_cache_file() {
  local root
  root="$(node "$F3142_ROOT/bin/workflow-state-dir" --global 2>/dev/null | tr -d '\r')"
  [ -n "$root" ] || root="$WORKFLOW_STATE_DIR"
  printf '%s/cache/project-resolve.tsv\n' "$root"
}

# f3142_path_without_gh <tools-dir> — PATH with every entry holding a gh (guard stub, mock, real CLI) removed,
# plus <tools-dir> of symlinks to each needed tool only a removed entry held (gh in /usr/bin takes bash too).
f3142_path_without_gh() {
  local d t src out="" rest="$PATH:" tools="$1"
  while [ -n "$rest" ]; do
    d="${rest%%:*}"; rest="${rest#*:}"
    [ -e "$d/gh" ] || [ -e "$d/gh.exe" ] || out="${out:+$out:}$d"
  done
  mkdir -p "$tools"
  for t in bash sh env sed awk grep tr cut head tail cat wc sort mkdir rm mv cp mktemp dirname basename \
    cksum date sleep timeout perl git jq node; do
    (PATH="$out"; command -v "$t" >/dev/null 2>&1) && continue
    src="$(command -v "$t" 2>/dev/null)" || continue
    ln -sf "$src" "$tools/$t"
  done
  printf '%s' "${out:+$out:}$tools"
}

f3142_cache_row() {
  printf '%s\t%s\t%s\t%s\tPVTF_cd\tPVTSSF_st\tOPT_todo\tOPT_ip\tOPT_done\tPVTF_sid\tsid1\n' "$1" "$2" "$3" "$4"
}
