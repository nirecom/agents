# Part of tests/bin-vscode-cc-repair-prune.sh (sourced, not standalone).
# Tests: bin/lib/vscode-cc-repair/prune.js
# Tags: bin, vscode, prune, scan, roots, session-files, scope:common, pwsh-not-required, TL2
#
# D — enumeration and root resolution: which files the tool is even allowed to
# consider, and what happens when part of the tree cannot be read.
#
# The enumeration filter is a safety boundary, not a convenience: ~/.claude/projects
# also holds agent-*.jsonl subagent transcripts and .history.jsonl, none of which this
# tool understands. Anything the pattern lets through becomes eligible for deletion.

list_files_json() { # <root> ; sets NODE_OUT
  L_ROOT="$(native_path "$1")" node_m 'const m=require("'"$REQUIRE_PATH"'");
const r=m.listSessionFiles(process.env.L_ROOT);
const names=r.entries.map(function(e){return String(e.file).replace(/\\/g,"/").split("/").pop();}).sort();
console.log("N="+r.entries.length+" E="+r.scanErrors.length+" F="+names.join(","));'
}

# ---- D1: the enumeration filter -------------------------------------------

run_d_pattern() {
  local root
  root="$(new_proj_root)"
  mkdir -p "$root"
  { title_line "$SID_A" "Alpha"; } | mk_session "$root" "$SID_A"
  # Every one of these must be structurally excluded.
  : > "$root/agent-$SID_B.jsonl"
  : > "$root/.history.jsonl"
  : > "$root/$SID_B.json"
  : > "$root/$SID_B.jsonl.bak"
  : > "$root/not-a-uuid.jsonl"
  : > "$root/$SID_B"
  list_files_json "$root"
  check "D01: only UUID-named .jsonl files are enumerated" \
    "N=1 E=0 F=$SID_A.jsonl" "$NODE_OUT"
}

# Depth 1, 2 and 3 under one root. intent.md says "somewhere under the scanned root",
# and --claude-projects-dir accepts a parent directory, so a depth-2-only walk (which
# would exactly fit today's observed layout) is not the general solution.
run_d_recursion() {
  local root
  root="$(new_proj_root)"
  { title_line "$SID_A" "Alpha"; } | mk_session "$root/one" "$SID_A"
  { title_line "$SID_B" "Alpha"; } | mk_session "$root/one/two" "$SID_B"
  { title_line "$SID_C" "Alpha"; } | mk_session "$root/one/two/three" "$SID_C"
  list_files_json "$root"
  check "D02: files at depth 1, 2 and 3 are all found" \
    "N=3 E=0 F=$SID_A.jsonl,$SID_B.jsonl,$SID_C.jsonl" "$NODE_OUT"
}

# SKIPPED (when the alias cannot be created): symlinked session file / symlinked
#          directory are never followed, and a directory symlink pointing at an
#          ancestor does not spin the walk.
# Because: on Windows_NT `ln -s` silently produces a real COPY under the MSYS default,
#          and a junction is not a symlink for dirent.isSymbolicLink() purposes, so the
#          branch under test cannot be reached at all.
# Needed:  a POSIX host, or Developer Mode + real symlink support on Windows.
# TL3 gap: a real ~/.claude/projects reached through a symlinked home (roaming
#          profile, dotfiles manager) is the realistic trigger.
run_d_symlinks() {
  local root real_target
  root="$(new_proj_root)"
  { title_line "$SID_A" "Alpha"; } | mk_session "$root/real" "$SID_A"
  real_target="$(session_path "$root/real" "$SID_A")"

  if ! make_file_alias "$root/real/$SID_B.jsonl" "$real_target"; then
    # ln -s can silently fall back to a real copy on this host even though the
    # symlink check failed; scrub any such leftover so it never leaks into D03b.
    rm -f "$root/real/$SID_B.jsonl"
    skip_case "D03a symlinked session file (this host cannot create a file symlink)"
  else
    list_files_json "$root"
    check "D03a: a symlinked session file is not enumerated" \
      "N=1 E=0 F=$SID_A.jsonl" "$NODE_OUT"
    rm -f "$root/real/$SID_B.jsonl"
  fi

  # A directory alias pointing back at the root: following it would recurse forever.
  if ! make_dir_alias "$root/loop" "$root"; then
    skip_case "D03b symlinked directory / walk loop (this host cannot create a directory alias)"
    return 0
  fi
  list_files_json "$root"
  check "D03b: a directory alias is not followed and the walk terminates" \
    "N=1 E=0 F=$SID_A.jsonl" "$NODE_OUT"
  rm -rf "$root/loop" 2>/dev/null || true
}

# ---- D2: root resolution ---------------------------------------------------

# --claude-projects-dir mirrors --extensions-dir: repeatable, order-preserving, and it
# REPLACES the default rather than adding to it. The replacement half is the safety
# half — a test that only checked "both roots were scanned" would still pass if the
# real ~/.claude/projects had been scanned as well.
run_d_multiple_roots() {
  local home ext p1 p2 roots
  home="$(new_home)"; ext="$(new_ext_root)"
  p1="$(new_proj_root)"; p2="$(new_proj_root)"
  { title_line "$SID_A" "Alpha"; } | mk_session "$p1/stub" "$SID_A"
  { content_line "$SID_A"; title_line "$SID_A" "Alpha"; } | mk_session "$p1/real" "$SID_A"
  { title_line "$SID_B" "Alpha"; } | mk_session "$p2/stub" "$SID_B"
  { content_line "$SID_B"; title_line "$SID_B" "Alpha"; } | mk_session "$p2/real" "$SID_B"
  # A default-location tree that must NOT be touched once overrides are supplied.
  { title_line "$SID_C" "Alpha"; } | mk_session "$home/.claude/projects/stub" "$SID_C"
  { content_line "$SID_C"; title_line "$SID_C" "Alpha"; } | mk_session "$home/.claude/projects/real" "$SID_C"

  run_iso "$home" "$ext" --prune-stub-sessions \
    --claude-projects-dir "$(native_path "$p2")" --claude-projects-dir "$(native_path "$p1")"
  check "D04a: exit 0" "0" "$CLI_RC"
  check_contains "D04b: both overrides became roots" "prune-roots=2" "$CLI_OUT"
  roots="$(prune_roots_lines "$CLI_OUT")"
  check "D04c: input order is preserved (p2 before p1)" \
    "prune-root: $(native_path "$p2")
prune-root: $(native_path "$p1")" "$roots"
  check_absent "D04d: the home default root was not scanned" \
    "$(native_path "$home/.claude/projects")" "$CLI_OUT"
  check_file "D04e: the default-location stub is untouched" \
    "$(session_path "$home/.claude/projects/stub" "$SID_C")"
  check_no_file "D04f: the override stubs were pruned" "$(session_path "$p1/stub" "$SID_A")"
  check_no_file "D04g: the second override stub was pruned too" "$(session_path "$p2/stub" "$SID_B")"
}

run_d_duplicate_root() {
  local home ext proj
  home="$(new_home)"; ext="$(new_ext_root)"; proj="$(new_proj_root)"
  { title_line "$SID_A" "Alpha"; } | mk_session "$proj/stub" "$SID_A"
  { content_line "$SID_A"; title_line "$SID_A" "Alpha"; } | mk_session "$proj/real" "$SID_A"
  run_iso "$home" "$ext" --prune-stub-sessions --dry-run \
    --claude-projects-dir "$(native_path "$proj")" --claude-projects-dir "$(native_path "$proj")"
  check "D05a: exit 0" "0" "$CLI_RC"
  check_contains "D05b: the same directory twice collapses to one root" "prune-roots=1" "$CLI_OUT"
  check "D05c: exactly one prune-root line" "1" "$(prune_roots_lines "$CLI_OUT" | wc -l | tr -d '[:space:]')"
}

# Two overlapping roots (a directory and its own parent) enumerate the SAME file
# twice. Without realpath dedup of the entries, that file would appear to have another
# copy of itself and could be pruned against itself — the single most dangerous
# failure mode this tool has.
run_d_overlapping_roots() {
  local home ext proj stub
  home="$(new_home)"; ext="$(new_ext_root)"; proj="$(new_proj_root)"
  { title_line "$SID_A" "Alpha"; } | mk_session "$proj/sub" "$SID_A"
  stub="$(session_path "$proj/sub" "$SID_A")"
  run_iso "$home" "$ext" --prune-stub-sessions \
    --claude-projects-dir "$(native_path "$proj")" --claude-projects-dir "$(native_path "$proj/sub")"
  check "D06a: exit 0" "0" "$CLI_RC"
  check_contains "D06b: nothing was pruned" "pruned=0" "$CLI_OUT"
  check_contains "D06c: nothing was even a candidate" "would-prune=0" "$CLI_OUT"
  check_file "D06d: a file seen through two overlapping roots is not its own counterpart" "$stub"
}

run_d_zero_roots() {
  local home ext
  home="$(new_home)"; ext="$(new_ext_root)"
  run_iso "$home" "$ext" --prune-stub-sessions
  check "D07a: exit 0" "0" "$CLI_RC"
  check_contains "D07b: the zero-root message is emitted" "nothing to prune" "$CLI_OUT"
  check_contains "D07c: the summary still reports zero roots" "prune-roots=0" "$CLI_OUT"
}

# ---- D3: partial observability --------------------------------------------

# SKIPPED (when deny_read cannot prove the denial): an unreadable DIRECTORY inside a
#          scanned root -> `scan-error <relpath> reason=EACCES`, sibling directories
#          still fully scanned and pruned, scan-errors=1, exit 1.
# Because: chmod is advisory on MSYS/Windows and ignored under root, and a Windows ACL
#          denial additionally blocks the fixture teardown. deny_read proves the denial
#          before asserting, so this degrades to a SKIP instead of a false PASS.
# Needed:  a POSIX host running as a non-root user.
# TL3 gap: a real ~/.claude/projects with a directory owned by another user, or a
#          roaming profile with restricted ACLs.
run_d_scan_error() {
  local home ext proj locked
  home="$(new_home)"; ext="$(new_ext_root)"; proj="$(new_proj_root)"
  # A healthy sibling pair that must still be pruned despite the unreadable neighbour.
  { title_line "$SID_A" "Alpha"; } | mk_session "$proj/stub" "$SID_A"
  { content_line "$SID_A"; title_line "$SID_A" "Alpha"; } | mk_session "$proj/real" "$SID_A"
  locked="$proj/locked"
  mkdir -p "$locked"
  { title_line "$SID_B" "Alpha"; } | mk_session "$locked" "$SID_B"

  if ! deny_read "$locked"; then
    skip_case "D08 unreadable directory (chmod is advisory on this host, or running as root)"
    return 0
  fi

  run_cli_prune "$home" "$ext" "$proj"
  allow_read "$proj"

  check "D08a: a partially scanned run exits 1" "1" "$CLI_RC"
  check_token "D08b: the unreadable directory is reported" "scan-error" "$CLI_OUT"
  check_contains "D08c: the scan-error line names the directory" "locked" "$CLI_OUT"
  check_contains "D08d: the scan-error line carries the errno" "reason=EACCES" "$CLI_OUT"
  check_contains "D08e: the summary counts one scan error" "scan-errors=1" "$CLI_OUT"
  check_no_file "D08f: the sibling stub was still pruned" "$(session_path "$proj/stub" "$SID_A")"
  check_file "D08g: the sibling counterpart survives" "$(session_path "$proj/real" "$SID_A")"
}

# SKIPPED (when deny_read cannot prove the denial): an unreadable FILE inside a
#          readable directory -> `unreadable <relpath> reason=EACCES scope=self`,
#          unrelated groups still pruned, unreadable=1, exit 1.
# Because / Needed / TL3 gap: identical to D08.
#
# Note the fixture shape: the unreadable file needs a same-basename sibling, because a
# group of size 1 is never classified at all (detail plan 3.7) and would therefore
# produce no line and no exit-code contribution.
run_d_unreadable_file() {
  local home ext proj victim
  home="$(new_home)"; ext="$(new_ext_root)"; proj="$(new_proj_root)"
  { title_line "$SID_A" "Alpha"; } | mk_session "$proj/stub" "$SID_A"
  { content_line "$SID_A"; title_line "$SID_A" "Alpha"; } | mk_session "$proj/real" "$SID_A"
  { content_line "$SID_B"; } | mk_session "$proj/other" "$SID_B"
  { title_line "$SID_B" "Alpha"; } | mk_session "$proj/locked" "$SID_B"
  victim="$(session_path "$proj/locked" "$SID_B")"

  if ! deny_read "$victim"; then
    skip_case "D09 unreadable file (chmod is advisory on this host, or running as root)"
    return 0
  fi

  run_cli_prune "$home" "$ext" "$proj"
  allow_read "$proj"

  check "D09a: an unreadable file makes the run exit 1" "1" "$CLI_RC"
  check_token "D09b: the unreadable file is reported" "unreadable" "$CLI_OUT"
  check_contains "D09c: the line carries the errno" "reason=EACCES" "$CLI_OUT"
  check_contains "D09d: the line attributes the fault to the file itself" "scope=self" "$CLI_OUT"
  check_contains "D09e: the summary counts one unreadable file" "unreadable=1" "$CLI_OUT"
  check_no_file "D09f: an unrelated group is still pruned normally" \
    "$(session_path "$proj/stub" "$SID_A")"
}

run_d_pattern
run_d_recursion
run_d_symlinks
run_d_multiple_roots
run_d_duplicate_root
run_d_overlapping_roots
run_d_zero_roots
run_d_scan_error
run_d_unreadable_file
