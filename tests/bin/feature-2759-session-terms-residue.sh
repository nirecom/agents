#!/usr/bin/env bash
# Tests: bin/check-root-names.sh, bin/check-root-names/main.js, bin/check-root-names/residue.js, bin/check-root-names/session-terms.js
# Tags: root-names, session-terms, residue, gate, static-check, bin, scope:issue-specific, layer:TL2, test-lang-exception:e2e
# lang-check: ignore -- fixtures and assertions match the Japanese glossary Definition wording under test.
# #2759: the session-terms check of the root-name gate, driven through its shell entry point.
# This file holds the list of rejected session terms and is the only test allowed to spell them.
# TL3 gap (what this test does NOT catch):
# - the installed pre-commit hook calling the gate; a real commit proves that wiring.
set -euo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
T="$(np "$(make_tmp)")"
readonly T
harness_isolate "$T/iso"
trap 'rm -rf "$T"' EXIT
REAL_GATE="$SCRIPT_CHECKOUT_ROOT/bin/check-root-names.sh"
RETIRED_LIST="$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-2561-root-names-residue.sh"
. "$(dirname "$0")/feature-2561-root-names/common.sh"

# retired-names:begin
# stem donor
# stem donors
# stem heir
# stem heirs
# keep heir_session_id
# retired-names:end

TERM_LIST="$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-2759-session-terms-residue.sh"
TERM_REL="tests/bin/feature-2759-session-terms-residue.sh"
REGISTRY_REL="bin/lib/check-migration-blocks/retired-tokens.txt"
CHECKER="$SCRIPT_CHECKOUT_ROOT/bin/lib/check-migration-blocks.js"
GLOSSARY_REL="docs/glossary/internal.md"
UP_DEF='- **Definition**: 引き継ぎ元のセッション。--from で再開されるときの、再開元の世代。不採用の同義語は donor。'
DOWN_DEF='- **Definition**: 引き継ぎ先のセッション。--from で再開した側の世代。不採用の同義語は heir。'

# term_kit <name> — a gate copy with the fixture table and this file's list; sets KIT.
term_kit() {
  make_kit "$1"
  write_table "$KIT"
  cp "$TERM_LIST" "$KIT/tests/bin/"
}

# read_kit — one gate copy for every case that only reads it (process starts are slow on Windows).
read_kit() {
  if [[ -d "$T/kits/read" ]]; then KIT="$T/kits/read"; else term_kit read; fi
}

# staged_kit <name> — the gate copy is itself the repository under test; sets KIT.
staged_kit() {
  term_kit "$1"
  init_repo "$KIT"
  fx "$KIT/bin/base.sh" 'echo base'
  commit_all "$KIT"
}

# tracked — the fixture repo tracks what was written to it.
tracked() { git -C "$REPO" add -A; }

# terms [<args>...] — only this check, over the tracked files of REPO.
terms() { run_gate "$KIT" --root "$REPO" --only session-terms "$@"; }

# staged_terms — only this check, over the index of KIT.
staged_terms() { run_gate_at "$KIT" "$KIT" --staged --only session-terms; }

# run_checker — the migration checker over REPO; sets GATE_OUT / GATE_RC.
run_checker() {
  GATE_RC=0
  GATE_OUT="$(cd "$T" && run_with_timeout 120 node "$CHECKER" --all "$REPO" 2>&1)" || GATE_RC=$?
}

gate_says() { [[ "$GATE_OUT" == *"$1"* ]]; }

c_detected_in_lines_and_paths() {
  read_kit
  local rows name rel content want rc
  # word form | file | file content | line the report names (0 = the path itself) | expected exit code
  rows='stem inside an identifier|src/sid.js|const heirSid = 1;|1|1
stem before a digit suffix|src/value.js|const v = "heir-2920";|1|1
singular after a dot|src/verdict.js|verdict.donor = 1;|1|1
plural in prose|src/plural.md|the donors list|1|1
upper case plural|src/upper.txt|HEIRS = []|1|1
singular in a file name|src/heir-tool.js|const clean = 1;|0|1
plural in a directory name|src/donors/x.js|const clean = 1;|0|1
kept field in a file name|docs/heir_session_id.md|clean|0|1'
  while IFS='|' read -r name rel content want rc; do
    new_repo detect
    fx "$REPO/$rel" "$content"
    tracked
    terms
    expect "detect: $name ($rel) exits $rc" rc_is "$rc"
    expect "detect: $name ($rel) is reported at line $want" reports "$rel" session-terms "$want"
    expect "detect: $name ($rel) report never uses the residue label" never_says "residue:"
  done <<<"$rows"
}

c_no_false_positives() {
  read_kit
  local rows name rel content rc
  # word form | file | file content | expected exit code
  rows='their|src/their.md|their|0
theirs|src/theirs.md|theirs|0
inherit|src/inherit.md|inherit|0
all three together|src/words.md|their theirs inherit|0'
  while IFS='|' read -r name rel content rc; do
    new_repo nofalse
    fx "$REPO/$rel" "$content"
    tracked
    terms
    expect "no false positive: $name ($rel) exits $rc" rc_is "$rc"
    expect "no false positive: $name ($rel) is not reported" clean_for "$rel" session-terms
    expect "no false positive: $name ($rel) prints nothing" test -z "$GATE_OUT"
  done <<<"$rows"
}

c_keep_pairs_with_the_migration_axis() {
  read_kit
  new_repo keep
  fx "$REPO/src/kept.js" 'const f = "heir_session_id";'
  mkdir -p "$REPO/$(dirname "$REGISTRY_REL")"
  cp "$SCRIPT_CHECKOUT_ROOT/$REGISTRY_REL" "$REPO/$REGISTRY_REL"
  tracked
  terms
  expect "keep: the kept field passes the session-terms check" rc_is 0
  expect "keep: the kept field is not reported" clean_for src/kept.js session-terms
  run_checker
  expect "keep: the same line outside a block fails the migration check" rc_is 1
  expect "keep: the failure is the retired-token axis" gate_says "outside its temporary block"
  fx "$REPO/src/kept.js" 'const f = 1;'
  run_checker
  expect "keep: without the line the migration check passes" rc_is 0
}

c_exempt_files() {
  read_kit
  new_repo exempt
  local rel exempt=(docs/history.md docs/history/old.md CHANGELOG.md changelog/old.md "$TERM_REL")
  for rel in "${exempt[@]}"; do fx "$REPO/$rel" 'the heir of a donor'; done
  fx "$REPO/docs/history-notes.md" 'the heir of a donor'
  tracked
  terms
  expect "exempt: a neighbour name is still reported" reports docs/history-notes.md session-terms 1
  for rel in "${exempt[@]}"; do
    expect "exempt: $rel is not reported" clean_for "$rel" session-terms
  done
}

# glossary_run <line>... — REPO's glossary file holds these lines, then the check.
glossary_run() {
  fx "$REPO/$GLOSSARY_REL" "$@"
  tracked
  terms
}

c_glossary_exception() {
  read_kit
  new_repo gloss-ok
  glossary_run '### session-upstream' "$UP_DEF" '- **Related**: [a](b.md)' '' '### session-downstream' "$DOWN_DEF" '- **Related**: [a](b.md)'
  expect "glossary: both Definition phrases pass" rc_is 0
  expect "glossary: nothing is reported" test -z "$GATE_OUT"
}

c_glossary_exception_boundary() {
  read_kit
  new_repo bound-file
  fx "$REPO/docs/other.md" '### session-upstream' "$UP_DEF"
  tracked
  terms
  expect "boundary: the phrase in another file is reported" reports docs/other.md session-terms 2
  new_repo bound-glossary
  glossary_run '### session-model' "$UP_DEF"
  expect "boundary: the phrase in another entry is reported" reports "$GLOSSARY_REL" session-terms 2
  glossary_run '### session-upstream' "$DOWN_DEF" '### session-downstream' "$UP_DEF"
  expect "boundary: a swapped phrase in the first entry is reported" reports "$GLOSSARY_REL" session-terms 2
  expect "boundary: a swapped phrase in the second entry is reported" reports "$GLOSSARY_REL" session-terms 4
  glossary_run '### session-upstream' "$UP_DEF" '- **Related**: 不採用の同義語は donor。'
  expect "boundary: the phrase on the Related line is reported" reports "$GLOSSARY_REL" session-terms 3
  expect "boundary: the Definition line beside it stays clean" silent_on "$GLOSSARY_REL" session-terms 2
  glossary_run '### session-upstream' '- **Definition**: donor のセッション。不採用の同義語は donor。'
  expect "boundary: a lone word beside the phrase is reported" reports "$GLOSSARY_REL" session-terms 2
  glossary_run '### session-upstream' '- **Definition**: 引き継ぎ元。不採用の同義語は donor-sid。'
  expect "boundary: a hyphen suffix on the phrase is reported" reports "$GLOSSARY_REL" session-terms 2
}

c_staged_reads_the_index() {
  staged_kit stagedrun
  fx "$KIT/src/s.js" 'const heirSid = 1;'
  git -C "$KIT" add src/s.js
  fx "$KIT/src/s.js" 'const clean = 1;'
  staged_terms
  expect "staged: the staged content is reported" reports src/s.js session-terms 1
  git -C "$KIT" add src/s.js
  fx "$KIT/src/s.js" 'const heirSid = 1;'
  staged_terms
  expect "staged: a working-tree-only word exits 0" rc_is 0
}

c_staged_reads_the_list_from_the_index() {
  staged_kit stagedlist
  local reduced
  printf -v reduced '# retired-names:%s\n# stem fixtureword\n# retired-names:%s\n' begin end
  fx "$KIT/src/s.js" 'const heirSid = 1;'
  git -C "$KIT" add src/s.js
  fx "$KIT/$TERM_REL" "${reduced%$'\n'}"
  staged_terms
  expect "staged list: control, the committed list reports the staged word although the working-tree list dropped it" reports src/s.js session-terms 1
  git -C "$KIT" add "$TERM_REL"
  cp "$TERM_LIST" "$KIT/$TERM_REL"
  staged_terms
  expect "staged list: a word the staged list dropped exits 0 although the working-tree list holds it" rc_is 0
  expect "staged list: that word is not reported" clean_for src/s.js session-terms
}

c_only_and_full_run() {
  read_kit
  new_repo paths
  fx "$REPO/plain/x.md" 'the heir word'
  tracked
  terms
  expect "paths: the named check reports the file" reports plain/x.md session-terms 1
  run_gate "$KIT" --root "$REPO"
  expect "paths: a run without a check name includes it" reports plain/x.md session-terms 1
}

c_fail_closed() {
  staged_kit closed
  fx "$KIT/src/s.js" 'const clean = 1;'
  git -C "$KIT" add src/s.js
  staged_terms
  expect "closed: control, an intact list exits 0" rc_is 0
  git -C "$KIT" rm -q --cached "$TERM_REL"
  staged_terms
  expect "closed: a list missing from the index exits 2" rc_is 2
  expect "closed: the error names the list" gate_says "$TERM_REL"
  run_gate_at "$KIT" "$KIT" --staged
  expect "closed: a run without a check name exits 2 too" rc_is 2
  expect "closed: that error names the list too" gate_says "$TERM_REL"
  fx "$KIT/$TERM_REL" '# no section here'
  git -C "$KIT" add "$TERM_REL"
  staged_terms
  expect "closed: a list without markers exits 2" rc_is 2
  expect "closed: the error names the missing section" gate_says "marked section"
  term_kit closedtree
  new_repo closedtree
  fx "$REPO/plain/x.md" 'clean'
  tracked
  rm -f "$KIT/$TERM_REL"
  terms
  expect "closed: a list missing from the checkout exits 2" rc_is 2
  expect "closed: that error names the list" gate_says "$TERM_REL"
}

c_list_is_independent() {
  read_kit
  new_repo independent
  fx "$REPO/plain/old.md" 'the heir word'
  fx "$REPO/plain/other.md" 'the fixtureword word'
  tracked
  local other="$T/other-list.txt"
  printf '# retired-names:%s\n# stem fixtureword\n# retired-names:%s\n' begin end > "$other"
  terms --retired-names-from "$other"
  expect "independent: the session-term list still applies" reports plain/old.md session-terms 1
  expect "independent: the other list adds nothing to it" clean_for plain/other.md session-terms
  run_gate "$KIT" --root "$REPO" --only residue --retired-names-from "$other"
  expect "independent: control, the flag does move the residue check" reports plain/other.md residue 1
}

c_real_tree_is_clean() {
  run_gate_at "$T" "$SCRIPT_CHECKOUT_ROOT" --only session-terms
  expect "self: the real checkout has no session-term hit" rc_is 0
}

case_begin "terms-detected-in-lines-and-paths" "bin/check-root-names/session-terms.js"
c_detected_in_lines_and_paths
case_end
case_begin "terms-no-false-positives" "bin/check-root-names/session-terms.js"
c_no_false_positives
case_end
case_begin "kept-field-pairs-with-migration-axis" "bin/check-root-names/session-terms.js"
c_keep_pairs_with_the_migration_axis
case_end
case_begin "terms-exempt-files" "bin/check-root-names/session-terms.js"
c_exempt_files
case_end
case_begin "glossary-definition-exception" "bin/check-root-names/session-terms.js"
c_glossary_exception
case_end
case_begin "glossary-exception-boundary" "bin/check-root-names/session-terms.js"
c_glossary_exception_boundary
case_end
case_begin "staged-reads-the-index" "bin/check-root-names/main.js"
c_staged_reads_the_index
case_end
case_begin "staged-reads-the-list-from-the-index" "bin/check-root-names/main.js"
c_staged_reads_the_list_from_the_index
case_end
case_begin "only-flag-and-full-run" "bin/check-root-names/main.js"
c_only_and_full_run
case_end
case_begin "term-list-fails-closed" "bin/check-root-names/main.js"
c_fail_closed
case_end
case_begin "term-list-is-independent" "bin/check-root-names/main.js"
c_list_is_independent
case_end
case_begin "real-tree-has-no-term" "bin/check-root-names/session-terms.js"
c_real_tree_is_clean
case_end

echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[[ "$FAIL" -eq 0 ]]
