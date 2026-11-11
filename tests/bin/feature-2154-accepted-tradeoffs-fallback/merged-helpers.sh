# Tests: bin/resolve-accepted-tradeoffs-file
# Tags: codex, review, accepted-tradeoffs, scope:issue-specific
# Shared helpers (no cases) for the #2924 merged-file contract: the resolver prints ONE
# control-dir file, so "which candidate was used" is read from the stage sections that
# file holds, not from the printed path.
# Sourced by tests/bin/feature-2154-accepted-tradeoffs-fallback.sh before every case file.

# merged_path <sid> <chain head> → the path the resolver is expected to print.
merged_path() { printf '%s/%s.control/accepted-tradeoffs.%s.md' "$WORKFLOW_STATE_DIR" "$1" "$2"; }

# make_staged <name> <suffix>... — make_plans with a staged `(<suffix>)` heading and a
# per-file body marker, so each stage read is visible in the merged file.
make_staged() {
  local d s
  d="$(make_plans "$@")"
  shift
  for s in "$@"; do printf '# %s\n\n## Accepted Tradeoffs (%s)\n\nkeep-%s\n' "$s" "$s" "$s" > "$d/SID-$s.md"; done
  printf '%s' "$d"
}

# tool_path_dir <dir> → prints <dir> (native spelling, for PATH) holding one exec wrapper per
# tool the #2924 resolver runs — node and the coreutils it needs, but NO realpath / readlink,
# so a PATH built from it (plus at most one canonicalizer) still reaches the merge path.
tool_path_dir() {
  local d="$1" t bin
  mkdir -p "$d"
  for t in bash node awk dirname tail tr mv rm; do
    bin="$(command -v "$t" 2>/dev/null)" || continue
    printf '#!/bin/bash\nexec "%s" "$@"\n' "$bin" > "$d/$t"
    chmod +x "$d/$t"
  done
  if command -v cygpath >/dev/null 2>&1; then cygpath -u "$d" 2>/dev/null || printf '%s' "$d"; else printf '%s' "$d"; fi
}

# stage_set <file> → the stage sections present, space-joined in file order ("" if none).
stage_set() {
  grep -oE '^## Accepted Tradeoffs \((intent|outline|detail)\)' "$1" 2>/dev/null \
    | sed -E 's/.*\((.*)\)/\1/' | tr '\n' ' ' | sed 's/ $//'
}
