#!/usr/bin/env bash
# Tests: bin/check-root-names.sh, bin/check-root-names/residue.js
# Tags: root-names, residue, retired-names, gate, static-check, bin, scope:issue-specific, TL2
# #2561: the residue check of the root-name gate. This is the ONLY tracked file
# that may carry a retired spelling: the gate, the launcher and the decoy builder
# all read the list between the two marker lines below.
# TL3 gap (what this test does NOT catch):
# - the pre-commit and CI wiring; a real commit / runner proves the gate fires there.
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
. "$(dirname "$0")/feature-2561-root-names/residue-cases.sh"

# One entry per comment line: kind, then the spelling (the rest of the line).
#   env  — a retired environment variable; matched on word boundaries.
#   name — a retired identifier or label; matched on word boundaries.
#   stem — a retired concept; matched as a run of words after splitting identifiers
#          on "_", "-", whitespace and case changes, ignoring case.
#   keep — a spelling that stays; removed from the text before matching.
# The `: "..."` lines are labelled no-ops that keep each comment run short; readers skip them.
SELF_REL="tests/bin/feature-2561-root-names-residue.sh"
# retired-names:begin
# env AGENTS_CONFIG_DIR
# env AGENTS_DIR
# name REPO_DIR
# name MAIN_ROOT
# name MAIN_WORKTREE_PATH
# name MAIN_WORKTREE
# name mainRoot
# name main-root
# name main_root
: "names, derived"
# name MAIN_ROOT_RAW
# name _MAIN_ROOT
# name DISCOVERED_MAIN_ROOTS
# name mainRootArg
# name mainRootRaw
# name normalizedMainRoot
# name main_root_cand
# name main_root_norm
# name mainWorktreePath
# name main_worktree_path
: "names, flags and labels"
# name --main-root
# name resolveMainRoot
# name mainWorktreeOf
# name trustedMainWorktrees
# name main-root-mismatch
# name main-root-anchored
# name main-root-docs
# name anchor-main-root
# name anchor-acd
# name fakeacd
: "names, second retired variable"
# name AGENTS_DIR_N
# name AGENTS_DIR_NODE
# name _AGENTS_DIR_NODE
# name AGENTS_DIR_NATIVE
# name agents_config_dir
# name resolveAgentsConfigDir
# name resolveAcd
# name configDirCandidates
# name agentsConfigDir
# name resolveConfigDir
: "names, stems"
# name usableConfigDir
# name configDir
# name SavedConfigDir
# stem acd
# stem agents config dir
# stem config dir
: "kept spellings"
# keep CLAUDE_CONFIG_DIR
# keep GH_CONFIG_DIR
# keep GLAB_CONFIG_DIR
# keep gh config dir
# keep glab config dir
# keep isMainWorktree
# keep isAllowedMainWorktreeCleanup
# keep setup_main_worktree
# keep main-worktree-allows
: "kept spellings, test helpers"
# keep main_worktree_dir
# keep _main_worktree_dir
# keep _main_worktree_node
# keep _main_worktree_denies
# retired-names:end

# The retired spellings the sourced cases write into fixtures; they live here only.
OLD_ENV="AGENTS_CONFIG_DIR"
OLD_ENV2="AGENTS_DIR"
OLD_NAME="mainRoot"

# Fixture tables, columns: <repo-relative path>|<verdict>|<one line of content>.
# The verdict is accepted, or <kind> <spelling>@<line> for the entry the line is
# reported under (line 0: the path itself). The bodies are literal text; only
# EXEMPT_ROWS is expanded, for the path of this file.
table BAD_ROWS <<'TABLE'
hooks/env-first.js|env AGENTS_CONFIG_DIR@1|const d = process.env.AGENTS_CONFIG_DIR;
bin/env-second.sh|env AGENTS_DIR@1|x="$AGENTS_DIR/bin/tool"
skills/demo/SKILL.md|env AGENTS_CONFIG_DIR@1|Run `$AGENTS_CONFIG_DIR/bin/tool` first.
bin/name-repo.sh|name REPO_DIR@1|REPO_DIR=/tmp/x
bin/name-upper.sh|name MAIN_ROOT@1|echo "$MAIN_ROOT"
bin/name-camel.js|name mainRoot@1|const mainRoot = 1;
bin/name-flag.js|name --main-root@1|args.push("--main-root");
docs/name-anchor.md|name main-root@1|the "main-root" anchor
bin/name-snake.sh|name main_root@1|main_root=x
bin/name-derived.sh|name _AGENTS_DIR_NODE@1|echo "$_AGENTS_DIR_NODE"
bin/name-fn.js|name resolveMainRoot@1|resolveMainRoot();
tests/name-unsplit.sh|name fakeacd@1|mkdir "$tmp/fakeacd"
tests/stem-upper.sh|stem acd@1|FAKE_ACD=/tmp/f
hooks/stem-camel.js|stem acd@1|const payloadAcd = p;
hooks/stem-kebab.js|stem acd@1|const t = "other-acd";
tests/stem-path.txt|stem acd@1|run /acd/bin/tool
docs/stem-spaced.md|stem agents config dir@1|Resolve the agents config dir first.
docs/stem-caps.md|stem config dir@1|The Config Dir of the checkout.
hooks/stem-fn.js|stem config dir@1|const d = pickUsableConfigDirNow();
hooks/keep-then-env.js|env AGENTS_CONFIG_DIR@1|const d = process.env.CLAUDE_CONFIG_DIR || process.env.AGENTS_CONFIG_DIR;
hooks/keep-then-stem.js|stem config dir@1|const d = GH_CONFIG_DIR + pickConfigDir();
TABLE
# Spellings that stay because the list keeps them: without their keep entry a stem hits.
table KEPT_ROWS <<'TABLE'
hooks/ok-claude.js|accepted|const k = process.env.CLAUDE_CONFIG_DIR;
hooks/ok-gh.js|accepted|const k = "GH_CONFIG_DIR";
hooks/ok-glab.js|accepted|const k = "GLAB_CONFIG_DIR";
hooks/ok-gh-words.js|accepted|// the child reads the same gh config dir
docs/ok-glab-words.md|accepted|Point the glab config dir at a fixture.
TABLE
# Look-alikes: new names, unchanged names and longer words that match no entry at all.
table LOOKALIKE_ROWS <<'TABLE'
bin/ok-launch.sh|accepted|echo "$LAUNCH_AGENTS_DIR"
hooks/ok-predicate.js|accepted|if (isMainWorktree(p)) isAllowedMainWorktreeCleanup(p);
tests/ok-helpers.sh|accepted|setup_main_worktree; _main_worktree_dir=x; main_worktree_dir
tests/ok-helpers2.sh|accepted|_main_worktree_node; _main_worktree_denies
bin/ok-new-upper.sh|accepted|echo "$AGENTS_MAIN_ROOT $TARGET_MAIN_ROOT $TARGET_CHECKOUT_ROOT"
bin/ok-new-camel.js|accepted|const targetMainRoot = anchors.scriptCheckoutRoot;
bin/ok-new-kebab.js|accepted|args.push("--target-main-root", "anchor-target-main-root", "target-main-root-docs");
bin/ok-new-snake.sh|accepted|target_main_root=x; script_checkout_root=y; echo "$_TARGET_MAIN_ROOT"
bin/ok-new-derived.sh|accepted|echo "$TARGET_MAIN_ROOT_RAW $DISCOVERED_TARGET_MAIN_ROOTS"
docs/ok-unsplit.md|accepted|A sacd player behind a facade; reconfigure the directory.
docs/ok-main-worktree.md|accepted|The main worktree; see hooks/enforce-worktree/main-worktree-allows/.
TABLE
table BAD_PATHS <<'TABLE'
hooks/lib/agents-config-dir.js|stem agents config dir@0|module.exports = {};
tests/hooks/fix-1630-config-dir-resolver/case.sh|stem config dir@0|true
tests/fixtures/fake-acd/readme.txt|stem acd@0|fixture
docs/main-root.md|name main-root@0|notes
TABLE
table GOOD_PATHS <<'TABLE'
hooks/enforce-worktree/main-worktree-allows/standard.js|accepted|module.exports = {};
hooks/lib/script-checkout-root.js|accepted|module.exports = {};
docs/target-main-root.md|accepted|notes
TABLE
# The exempt set is docs/history.md, docs/history/, CHANGELOG.md, changelog/ and this file — from the root.
table EXEMPT_ROWS <<TABLE
docs/history.md|accepted|- renamed AGENTS_CONFIG_DIR
docs/history/2026.md|accepted|- renamed mainRoot
docs/history/a.md|accepted|- renamed MAIN_ROOT
CHANGELOG.md|accepted|- renamed AGENTS_DIR
changelog/2026-10.md|accepted|- dropped the acd anchor
$SELF_REL|accepted|# name mainRoot
TABLE
table NOT_EXEMPT_ROWS <<'TABLE'
notes/history.md|env AGENTS_CONFIG_DIR@1|- renamed AGENTS_CONFIG_DIR
sub/docs/history.md|name mainRoot@1|- renamed mainRoot
docs/history-2025.md|name MAIN_ROOT@1|- renamed MAIN_ROOT
docs/history-foo/a.md|name mainRoot@1|- renamed mainRoot
docs/historyX.md|env AGENTS_CONFIG_DIR@1|- renamed AGENTS_CONFIG_DIR
sub/CHANGELOG.md|env AGENTS_DIR@1|- renamed AGENTS_DIR
CHANGELOG.md.bak|env AGENTS_DIR@1|- renamed AGENTS_DIR
sub/changelog/2026.md|stem acd@1|- dropped the acd anchor
changelog-old/2026.md|stem acd@1|- dropped the acd anchor
tests/bin/other-residue.sh|name mainRoot@1|# name mainRoot
sub/tests/bin/feature-2561-root-names-residue.sh|name mainRoot@1|# name mainRoot
TABLE

# msg_of <kind> <spelling> — the entry a report line names.
msg_of() { printf 'retired %s "%s"' "${1%% *}" "${1#* }"; }

c_list_section() {
  local n_begin n_end body bad kind spelling
  n_begin="$(grep -c '^# retired-names:begin$' "$RETIRED_LIST" || true)"
  n_end="$(grep -c '^# retired-names:end$' "$RETIRED_LIST" || true)"
  expect "list: exactly one begin marker" test "$n_begin" = 1
  expect "list: exactly one end marker" test "$n_end" = 1
  body="$(sed -n '/^# retired-names:begin$/,/^# retired-names:end$/p' "$RETIRED_LIST" | sed '1d;$d')"
  expect "list: the section is not empty" test -n "$body"
  bad="$(grep -vE '^(# (env|name|stem|keep) [^ ].*|: "[a-z, ]+")$' <<<"$body" || true)"
  expect "list: every line is '# <kind> <spelling>' or a labelled no-op" test -z "$bad"
  expect "list: no entry is written twice" test -z "$(list_entries | sort | uniq -d)"
  # Columns: kind|spelling. The body is read on descriptor 3, off grep's stdin.
  while IFS='|' read -r kind spelling <&3; do
    [[ -n "$kind" ]] || continue
    expect "list: carries '$kind $spelling'" grep -qxF -e "# $kind $spelling" <<<"$body"
  done 3<<'TABLE'
env|AGENTS_CONFIG_DIR
env|AGENTS_DIR
name|REPO_DIR
name|MAIN_ROOT
name|MAIN_WORKTREE_PATH
name|MAIN_WORKTREE
name|mainRoot
name|main-root
name|main_root
name|--main-root
stem|acd
stem|agents config dir
stem|config dir
keep|CLAUDE_CONFIG_DIR
keep|GH_CONFIG_DIR
keep|GLAB_CONFIG_DIR
keep|gh config dir
keep|glab config dir
keep|isMainWorktree
keep|isAllowedMainWorktreeCleanup
keep|setup_main_worktree
keep|main-worktree-allows
keep|main_worktree_dir
keep|_main_worktree_dir
keep|_main_worktree_node
keep|_main_worktree_denies
TABLE
  expect "list: the fixed table names every keep entry" \
    test "$(list_entries | grep -c '^keep|')" = 13
}

# c_rows <kit-name> <want-rc> <label> <table>... — seed the tables, run the check,
# assert the exit code and one verdict per row.
c_rows() {
  local name="$1" want="$2" label="$3" rows
  shift 3
  make_kit "$name"
  new_repo "$name"
  for rows in "$@"; do seed "$REPO" "$rows" 1; done
  commit_all "$REPO"
  run_gate "$KIT" --root "$REPO" --only residue
  expect "$label: exits $want" rc_is "$want"
  for rows in "$@"; do expect_rows "$label" residue <<<"${!rows}"; done
}

c_path_hits() {
  c_rows paths 1 "path" BAD_PATHS GOOD_PATHS
  fx "$REPO/tests/fixtures/fake-acd/both.sh" 'echo "$MAIN_ROOT"'
  commit_all "$REPO"
  run_gate "$KIT" --root "$REPO" --only residue
  expect_rows "path and content" residue <<'TABLE'
tests/fixtures/fake-acd/both.sh|stem acd@0
tests/fixtures/fake-acd/both.sh|name MAIN_ROOT@1
TABLE
}

case_begin "retired-list-section-is-well-formed" "bin/check-root-names/residue.js"
c_list_section
case_end

case_begin "retired-spelling-in-content-is-reported" "bin/check-root-names/residue.js"
c_rows hits 1 "content" BAD_ROWS
case_end

case_begin "every-list-entry-is-reported-or-kept" "bin/check-root-names/residue.js"
c_every_entry
case_end

case_begin "new-and-kept-names-are-not-reported" "bin/check-root-names/residue.js"
c_rows sanctioned 0 "sanctioned" KEPT_ROWS LOOKALIKE_ROWS
case_end

case_begin "keep-entries-are-what-frees-the-kept-spellings" "bin/check-root-names/residue.js"
c_keep_effect
case_end

case_begin "retired-word-in-tracked-path-is-reported" "bin/check-root-names/residue.js"
c_path_hits
case_end

case_begin "history-and-this-test-are-exempt" "bin/check-root-names/residue.js"
c_exempt_paths
case_end

case_begin "retired-names-from-replaces-the-list" "bin/check-root-names/residue.js"
c_custom_list
case_end

case_begin "unreadable-list-exits-2" "bin/check-root-names/residue.js"
c_unreadable_list
case_end

case_begin "rerun-is-stable-and-read-only" "bin/check-root-names.sh"
c_rerun_stable
case_end

case_begin "hostile-names-and-content-are-not-executed" "bin/check-root-names.sh"
c_hostile_text
case_end

case_begin "root-and-scope-stay-inside-the-tree" "bin/check-root-names.sh"
c_root_stays_inside
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[[ "$FAIL" -eq 0 ]]
