#!/usr/bin/env bash
# Tests: bin/check-root-names.sh, bin/check-root-names/main.js
# Tags: root-names, staged, index, cli-contract, gate, static-check, bin, scope:issue-specific, TL2
# #2561: the gate's command line — with the staged flag it judges what the index
# holds (content, paths and its own input data), never the working tree.
# TL3 gap (what this test does NOT catch):
# - the installed pre-commit hook calling the gate; a real commit proves that wiring.
set -euo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RWT="$SCRIPT_CHECKOUT_ROOT/bin/run-with-timeout.sh"
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
T="$(np "$(make_tmp)")"
readonly T
harness_isolate "$T/iso"
trap 'rm -rf "$T"' EXIT
REAL_GATE="$SCRIPT_CHECKOUT_ROOT/bin/check-root-names.sh"
RETIRED_LIST="$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-2561-root-names-residue.sh"
. "$(dirname "$0")/feature-2561-root-names/common.sh"

# A retired spelling and a retired path word, split so this file carries neither.
OLD_ENV="AGENTS_CON""FIG_D""IR"
OLD_LINE="echo \"\$$OLD_ENV\""
OLD_PATH="hooks/lib/agents-con""fig-d""ir.js"
LIST_REL="tests/bin/feature-2561-root-names-residue.sh"
TABLE_REL="bin/check-root-names/classification.json"

# staged_kit <name> — the gate copy is itself the repository under test, so the
# index it reads and the checkout it lives in are the same tree; sets KIT.
staged_kit() {
  make_kit "$1"
  write_table "$KIT"
  init_repo "$KIT"
  fx "$KIT/bin/base.sh" 'echo base'
  commit_all "$KIT"
}

# staged <args...> — run the gate on the index, from inside the repository.
staged() { run_gate_at "$KIT" "$KIT" --staged "$@"; }

# msg_of <kind> — the residue message of a retired entry of that kind.
msg_of() { printf 'retired %s "' "$1"; }

c_index_blob_is_read() {
  staged_kit blob
  fx "$KIT/bin/s-a.sh" "$OLD_LINE"
  git -C "$KIT" add bin/s-a.sh
  fx "$KIT/bin/s-a.sh" 'echo clean'
  staged --only residue
  expect "blob: the staged content is judged, not the cleaned working file" reports "bin/s-a.sh" residue 1
  fx "$KIT/bin/s-a2.sh" "$OLD_LINE"
  git -C "$KIT" add bin/s-a2.sh
  rm -f "$KIT/bin/s-a2.sh"
  staged --only residue
  expect "blob: a staged file missing from the working tree is still judged" reports "bin/s-a2.sh" residue 1
}

c_worktree_only_is_ignored() {
  staged_kit worktree
  fx "$KIT/bin/s-b.sh" 'echo clean'
  commit_all "$KIT"
  fx "$KIT/bin/s-b.sh" "$OLD_LINE"
  fx "$KIT/bin/s-b-untracked.sh" "$OLD_LINE"
  fx "$KIT/bin/s-b-staged.sh" 'echo clean'
  git -C "$KIT" add bin/s-b-staged.sh
  staged --only residue
  expect "worktree: an unstaged edit and an untracked file exit 0" rc_is 0
  expect "worktree: the unstaged edit is not reported" clean_for "bin/s-b.sh"
}

c_staged_deletion_is_ignored() {
  staged_kit deletion
  fx "$KIT/bin/s-c.sh" "$OLD_LINE"
  commit_all "$KIT"
  git -C "$KIT" rm -q bin/s-c.sh
  staged --only residue
  expect "deletion: removing a file that carried an old name exits 0" rc_is 0
  expect "deletion: the removed path is not reported" clean_for "bin/s-c.sh"
}

c_staged_rename_path() {
  staged_kit moved
  fx "$KIT/hooks/lib/s-d.js" 'module.exports = {};'
  commit_all "$KIT"
  git -C "$KIT" mv hooks/lib/s-d.js "$OLD_PATH"
  staged --only residue
  expect "rename: a path that gains a retired word is reported" reports "$OLD_PATH" residue 0 'the path carries'
  git -C "$KIT" mv "$OLD_PATH" hooks/lib/s-d-renamed.js
  staged --only residue
  expect "rename: a rename to a clean path exits 0" rc_is 0
}

c_staged_excludes_other_inputs() {
  staged_kit exclusive
  mkdir -p "$T/other-root"
  fx "$KIT/bin/s-e.sh" 'echo clean'
  git -C "$KIT" add bin/s-e.sh
  staged --root "$T/other-root"
  expect "exclusive: the staged flag with a root exits 2" rc_is 2
  staged bin/s-e.sh
  expect "exclusive: the staged flag with a file argument exits 2" rc_is 2
  run_gate_at "$KIT" "$KIT" --root "$KIT" bin/s-e.sh
  expect "exclusive: a root with a file argument exits 2" rc_is 2
}

c_staged_list_is_read() {
  local kept="$T/list-kept.sh"
  staged_kit list
  cp "$KIT/$LIST_REL" "$kept"
  awk '/^# retired-names:end$/ { print "# name zzqstaged" } { print }' "$kept" > "$KIT/$LIST_REL"
  git -C "$KIT" add "$LIST_REL"
  cp "$kept" "$KIT/$LIST_REL"
  fx "$KIT/bin/s-f.sh" 'echo zzqstaged'
  git -C "$KIT" add bin/s-f.sh
  staged --only residue
  expect "list: an entry staged into the list is applied" reports "bin/s-f.sh" residue 1 'retired name "zzqstaged"'
  git -C "$KIT" add "$LIST_REL"
  awk '/^# retired-names:end$/ { print "# name zzqstaged" } { print }' "$kept" > "$KIT/$LIST_REL"
  staged --only residue
  expect "list: an entry that exists only in the working tree is not applied" rc_is 0
}

c_staged_table_is_read() {
  local kept="$T/table-kept.json"
  staged_kit table
  cp "$KIT/$TABLE_REL" "$kept"
  fx "$KIT/$TABLE_REL" '{"rules": [], "exceptions": []}'
  git -C "$KIT" add "$TABLE_REL"
  cp "$kept" "$KIT/$TABLE_REL"
  fx "$KIT/bin/s-h.sh" "echo \"$V_SCR\""
  git -C "$KIT" add bin/s-h.sh
  staged --only table-match
  expect "table: the staged table decides (no rule left for the file)" reports "bin/s-h.sh" table-match 0 'no classification rule'
  git -C "$KIT" add "$TABLE_REL"
  fx "$KIT/$TABLE_REL" '{"rules": [], "exceptions": []}'
  staged --only table-match
  expect "table: a table edit that is not staged is not applied" clean_for "bin/s-h.sh"
}

c_nothing_staged() {
  staged_kit nothing
  fx "$KIT/bin/s-g-old.sh" "$OLD_LINE"
  commit_all "$KIT"
  staged --only residue
  expect "nothing: an empty index exits 0" rc_is 0
  fx "$KIT/bin/s-g-new.sh" 'echo clean'
  git -C "$KIT" add bin/s-g-new.sh
  staged --only residue
  expect "nothing: only the staged paths are judged (exit 0)" rc_is 0
  expect "nothing: a committed file outside the index change is not reported" clean_for "bin/s-g-old.sh"
}

c_staged_rerun() {
  local before out1
  staged_kit rerun
  fx "$KIT/bin/s-i.sh" "$OLD_LINE"
  git -C "$KIT" add bin/s-i.sh
  fx "$KIT/bin/s-i.sh" 'echo edited later'
  before="$(git -C "$KIT" status --porcelain)$(tree_sum "$KIT")"
  staged --only residue
  expect "rerun: first run exits 1" rc_is 1
  out1="$GATE_OUT"
  staged --only residue
  expect "rerun: second run exits 1" rc_is 1
  expect "rerun: the report is identical" test "$GATE_OUT" = "$out1"
  expect "rerun: index and working tree are untouched" test "$(git -C "$KIT" status --porcelain)$(tree_sum "$KIT")" = "$before"
}

c_usage_errors() {
  make_kit usage
  write_table "$KIT"
  new_repo usage
  fx "$REPO/bin/u.sh" 'echo clean'
  commit_all "$REPO"
  run_gate "$KIT" --root "$REPO" --only residue --repo agents --scope bin
  expect "usage: a clean tree with valid flags exits 0" rc_is 0
  run_gate "$KIT" --root "$REPO" --no-such-flag
  expect "usage: an unknown flag exits 2" rc_is 2
  run_gate "$KIT" --root
  expect "usage: a root without a value exits 2" rc_is 2
  run_gate "$KIT" --root "$T/repos/absent-root"
  expect "usage: a root that does not exist exits 2" rc_is 2
  run_gate "$KIT" --root "$REPO/bin/u.sh"
  expect "usage: a root that is a file exits 2" rc_is 2
  run_gate "$KIT" --root "$REPO" --repo bogus
  expect "usage: an unknown repo exits 2" rc_is 2
  run_gate "$KIT" --root "$REPO" --only bogus
  expect "usage: an unknown check name exits 2" rc_is 2
  run_gate "$KIT" --root "$REPO" --only
  expect "usage: a check name without a value exits 2" rc_is 2
  run_gate "$KIT" --root "$REPO" --scope
  expect "usage: a scope without a value exits 2" rc_is 2
  run_gate "$KIT" --scope "" --root "$REPO"
  expect "usage: an empty scope exits 2" rc_is 2
  expect "usage: the empty scope itself is what is refused" test "${GATE_OUT/--scope needs a value/}" != "$GATE_OUT"
}

case_begin "staged-blob-is-judged-not-the-working-file" "bin/check-root-names/main.js"
c_index_blob_is_read
case_end

case_begin "working-tree-only-change-is-ignored" "bin/check-root-names/main.js"
c_worktree_only_is_ignored
case_end

case_begin "staged-deletion-is-ignored" "bin/check-root-names/main.js"
c_staged_deletion_is_ignored
case_end

case_begin "staged-rename-to-a-retired-path-is-reported" "bin/check-root-names/main.js"
c_staged_rename_path
case_end

case_begin "staged-flag-excludes-root-and-files" "bin/check-root-names/main.js"
c_staged_excludes_other_inputs
case_end

case_begin "retired-list-is-read-from-the-index" "bin/check-root-names/main.js"
c_staged_list_is_read
case_end

case_begin "classification-table-is-read-from-the-index" "bin/check-root-names/main.js"
c_staged_table_is_read
case_end

case_begin "empty-index-change-passes" "bin/check-root-names/main.js"
c_nothing_staged
case_end

case_begin "staged-rerun-is-stable-and-read-only" "bin/check-root-names.sh"
c_staged_rerun
case_end

case_begin "usage-errors-exit-2" "bin/check-root-names.sh"
c_usage_errors
case_end

. "$(dirname "$0")/feature-2561-root-names/staged-inputs.sh"

case_begin "only-selects-one-check-and-no-flag-runs-all-five" "bin/check-root-names/main.js"
c_only_selects_one_check
case_end

case_begin "scope-keeps-whole-path-segments" "bin/check-root-names/main.js"
c_scope
case_end

case_begin "tree-run-reads-tracked-text-files" "bin/check-root-names/main.js"
c_tree_inputs
case_end

case_begin "staged-flag-reads-the-gates-own-index" "bin/check-root-names/main.js"
c_staged_from_another_directory
case_end

case_begin "staged-flag-fails-closed-without-an-index-or-its-inputs" "bin/check-root-names/main.js"
c_staged_fails_closed
case_end

case_begin "staged-path-without-a-readable-blob-exits-2-and-a-gitlink-is-skipped" "bin/check-root-names/main.js"
c_staged_blob_must_be_readable
case_end

case_begin "tree-or-scope-without-a-file-exits-2-and-an-empty-index-passes" "bin/check-root-names/main.js"
c_empty_input
case_end

case_begin "report-is-sorted-and-free-of-repeats" "bin/check-root-names/main.js"
c_report_order
case_end

case_begin "file-arguments-select-the-files" "bin/check-root-names/main.js"
c_file_arguments
case_end

case_begin "hostile-arguments-are-not-executed" "bin/check-root-names.sh"
c_hostile_arguments
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[[ "$FAIL" -eq 0 ]]
