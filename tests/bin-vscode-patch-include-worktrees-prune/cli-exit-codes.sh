# Part of tests/bin-vscode-patch-include-worktrees-prune.sh (sourced, not standalone).
# F — the command-line surface: flag dependency, argument rejection, report shape,
# and the exit-code contract.
#
# The exit code is the only part of this tool a caller (a shell script, a CI step, the
# user's own eye) actually reads. Its rule is a split, not a severity ladder:
#   DECISION REACHED   (none / kept / pruned / would-prune / changed) -> exit 0
#   OBSERVATION FAILED (unclassified / unreadable / scan-error / failed) -> exit 1
#   CALLER ERROR       (bad or missing arguments) -> exit 2
# `changed` sitting on the exit-0 side is the counter-intuitive one and is asserted
# explicitly below: a race that was correctly detected and refused is a success, not a
# fault — nothing was lost and a re-run will settle it.

# ---- F1: flag dependency and argument rejection ----------------------------

# F01 — the prune path is strictly opt-in. Without the flag the tool must behave
# exactly as it did before this feature existed: no prune output at all, and — the
# assertion that matters — nothing deleted, even from a tree that would obviously
# qualify.
run_f_opt_in() {
  local home ext stub
  home="$(new_home)"; ext="$(new_ext_root)"
  make_ext_dir "$ext" "$EXT_DIR_A" "$BODY_FALSY"
  { title_line "$SID_A" "Alpha"; } | mk_session "$home/.claude/projects/stub" "$SID_A"
  { content_line "$SID_A"; title_line "$SID_A" "Alpha"; } | mk_session "$home/.claude/projects/real" "$SID_A"
  stub="$(session_path "$home/.claude/projects/stub" "$SID_A")"

  run_iso "$home" "$ext"
  check "F01a: exit 0" "0" "$CLI_RC"
  check_absent "F01b: no prune-root line without the flag" "prune-root:" "$CLI_OUT"
  check_absent "F01c: no prune-summary line without the flag" "prune-summary:" "$CLI_OUT"
  check_absent "F01d: no zero-root message without the flag" "nothing to prune" "$CLI_OUT"
  check_file "F01e: an obviously prunable stub is left alone without the flag" "$stub"
  check_contains "F01f: the patch path still ran" "patched=1" "$CLI_OUT"
}

# F02 — --claude-projects-dir is meaningless on its own. Silently accepting it would
# leave a caller believing a prune ran when none did; the failure must be loud and on
# the caller-error side.
run_f_dependency() {
  local home ext proj
  home="$(new_home)"; ext="$(new_ext_root)"; proj="$(new_proj_root)"
  run_iso_split "$home" "$ext" --claude-projects-dir "$(native_path "$proj")"
  check "F02a: --claude-projects-dir without --prune-stub-sessions exits 2" "2" "$CLI_RC"
  check_contains "F02b: the diagnostic carries the stderr prefix" "$STDERR_PREFIX" "$CLI_STDERR"
  check_contains "F02c: the diagnostic names the flag it depends on" \
    "--prune-stub-sessions" "$CLI_STDERR"
  check "F02d: nothing on stdout" "" "$CLI_STDOUT"
}

# F03 — the --claude-projects-dir value table, mirroring cli-args.sh run_c6_case for
# --extensions-dir: same five rejection shapes, because a second path-valued option
# that validated differently from the first would be a trap. Each row supplies a VALID
# prunable root alongside the bad one, so "exit 2" is never accepted on its own — the
# valid root's stub must still be there afterwards, proving the run aborted before any
# deletion rather than half-way through.
run_f_bad_projects_dir() {
  local home ext guard guard_stub bad

  run_f_case() { # <name> <extra-args...>
    local n="$1"; shift
    run_iso_split "$home" "$ext" --prune-stub-sessions \
      --claude-projects-dir "$(native_path "$guard")" "$@"
    check "$n: exits 2" "2" "$CLI_RC"
    check_contains "$n: diagnostic on stderr" "$STDERR_PREFIX" "$CLI_STDERR"
    check "$n: no report on stdout" "" "$CLI_STDOUT"
    check_file "$n: the valid root's stub was not touched" "$guard_stub"
  }

  home="$(new_home)"; ext="$(new_ext_root)"; guard="$(new_proj_root)"
  { title_line "$SID_A" "Alpha"; } | mk_session "$guard/stub" "$SID_A"
  { content_line "$SID_A"; title_line "$SID_A" "Alpha"; } | mk_session "$guard/real" "$SID_A"
  guard_stub="$(session_path "$guard/stub" "$SID_A")"
  bad="$(native_path "$guard")"

  # An empty value: parseArgs accepts it (the flag DID receive a value), so only the
  # absolute-path check can reject it. Treating a falsy value as "not supplied" would
  # silently fall back to scanning the real ~/.claude/projects.
  run_f_case "F03a-empty-value"     --claude-projects-dir ""
  run_f_case "F03b-relative"        --claude-projects-dir "relative/projects"
  # Absolute AND existent, but carries a traversal segment.
  run_f_case "F03c-dotdot"          --claude-projects-dir "$bad/stub/.."
  run_f_case "F03d-nonexistent"     --claude-projects-dir "$bad/definitely-not-here"
  run_f_case "F03e-file-not-a-dir"  --claude-projects-dir "$bad/stub/$SID_A.jsonl"
  run_f_case "F03f-missing-value"   --claude-projects-dir
}

# ---- F2: report shape ------------------------------------------------------

# F04 — the flag is ADDITIVE, not a mode selector. A run that quietly stopped patching
# because a prune was requested would be a silent regression of the shipped behaviour.
run_f_additive() {
  local home ext proj
  home="$(new_home)"; ext="$(new_ext_root)"; proj="$(new_proj_root)"
  make_ext_dir "$ext" "$EXT_DIR_A" "$BODY_FALSY"
  { title_line "$SID_A" "Alpha"; } | mk_session "$proj/stub" "$SID_A"
  { content_line "$SID_A"; title_line "$SID_A" "Alpha"; } | mk_session "$proj/real" "$SID_A"

  run_cli_prune "$home" "$ext" "$proj"
  check "F04a: exit 0" "0" "$CLI_RC"
  check_token "F04b: the patch path still reports patched" "patched" "$CLI_OUT"
  check_contains "F04c: the patch summary is still emitted" "summary: roots=1" "$CLI_OUT"
  check_contains "F04d: the patch summary counts the patched bundle" "patched=1" "$CLI_OUT"
  check_contains "F04e: the prune summary is emitted too" "prune-summary:" "$CLI_OUT"
  check_contains "F04f: the extension was really patched" 'includeWorktrees:!0' \
    "$(cat "$ext/$EXT_DIR_A/extension.js")"
}

# F05 — the summary line's full literal shape. Field ORDER and the presence of the
# always-zero counters are both pinned: the failure counters (unreadable /
# unclassified / scan-errors) must be printed even when zero, otherwise a reader has
# no way to distinguish "nothing went wrong" from "this build does not report it".
run_f_summary_shape() {
  local home ext proj
  home="$(new_home)"; ext="$(new_ext_root)"; proj="$(new_proj_root)"
  { title_line "$SID_A" "Alpha"; } | mk_session "$proj/stub" "$SID_A"
  { content_line "$SID_A"; title_line "$SID_A" "Alpha"; } | mk_session "$proj/real" "$SID_A"

  run_cli_prune "$home" "$ext" "$proj"
  check "F05a: exit 0" "0" "$CLI_RC"
  check_contains "F05b: the summary line has the documented field order" \
    "prune-summary: prune-roots=1 scanned=2 groups=1 pruned=1 would-prune=0 kept=0 changed=0 unreadable=0 unclassified=0 scan-errors=0 failed=0" \
    "$CLI_OUT"
  check_contains "F05c: the root is announced with an absolute path" \
    "prune-root: $(native_path "$proj")" "$CLI_OUT"
  check_contains "F05d: the pruned line names the counterpart that justified it" \
    "via=" "$(prune_line "pruned" "$CLI_OUT")"
  check_contains "F05e: the pruned line carries the group counts" \
    "real-copies=1" "$(prune_line "pruned" "$CLI_OUT")"
}

# F06 — privacy. customTitle is user content: it is the text of someone's private
# session. The report is counts and paths, never titles — on either stream, whether the
# file was deleted or kept. The kept row is the riskier of the two, because a
# "title-not-covered" explanation is exactly where an implementation is tempted to
# print the title that was not covered.
run_f_privacy() {
  local home ext proj
  home="$(new_home)"; ext="$(new_ext_root)"; proj="$(new_proj_root)"
  # Group A: prunable — the title appears in both copies.
  { title_line "$SID_A" "$SECRET_TITLE"; } | mk_session "$proj/stub" "$SID_A"
  { content_line "$SID_A"; title_line "$SID_A" "$SECRET_TITLE"; } | mk_session "$proj/real" "$SID_A"
  # Group B: kept — the counterpart does not carry the stub's title.
  { title_line "$SID_B" "$SECRET_TITLE"; } | mk_session "$proj/stub" "$SID_B"
  { content_line "$SID_B"; title_line "$SID_B" "Bravo"; } | mk_session "$proj/real" "$SID_B"

  run_cli_prune_split "$home" "$ext" "$proj"
  check "F06a: exit 0" "0" "$CLI_RC"
  check_token "F06b: the covered stub was pruned" "pruned" "$CLI_STDOUT"
  check_token "F06c: the uncovered stub was kept" "kept" "$CLI_STDOUT"
  check_contains "F06d: the kept line explains why" "reason=title-not-covered" "$CLI_STDOUT"
  check_absent "F06e: no session title reaches stdout" "$SECRET_TITLE" "$CLI_STDOUT"
  check_absent "F06f: no session title reaches stderr" "$SECRET_TITLE" "$CLI_STDERR"
}

# ---- F3: the exit-code contract --------------------------------------------

# Fixture builders for the exit-code table. Each returns non-zero when this host cannot
# construct the situation (POSIX permission semantics), so the row degrades to a
# documented SKIP rather than a false PASS.
#
# SKIPPED (when deny_read / deny_unlink cannot prove the denial): the X5, X6, X7 and X8
#          rows — unreadable file, unreadable directory, unlink failure, and the
#          mixed success+failure run.
# Because: chmod is advisory on MSYS/Windows and ignored under root.
# Needed:  a POSIX host running as a non-root user.
# TL3 gap: restricted ACLs in a real profile, or a read-only session store.

exf_none() { # no stub anywhere: every file is a real transcript
  { content_line "$SID_A"; title_line "$SID_A" "Alpha"; } | mk_session "$1/a" "$SID_A"
  { content_line "$SID_A"; title_line "$SID_A" "Alpha"; } | mk_session "$1/b" "$SID_A"
}

exf_pruned() {
  { title_line "$SID_A" "Alpha"; } | mk_session "$1/stub" "$SID_A"
  { content_line "$SID_A"; title_line "$SID_A" "Alpha"; } | mk_session "$1/real" "$SID_A"
}

exf_kept() { # a stub whose only sibling cannot be shown to be a real copy
  { title_line "$SID_A" "Alpha"; } | mk_session "$1/stub" "$SID_A"
  { broken_line; } | mk_session "$1/ind" "$SID_A"
}

# Past CLASSIFY_MAX_SCAN with nothing but title records: the verdict is not knowable,
# which is an observation failure rather than a decision to keep.
exf_unclassified() {
  mkdir -p "$1/big"
  gen_big "$(session_path "$1/big" "$SID_A")" "$SID_A" $((CLASSIFY_MAX_SCAN + 128)) title none none
  { content_line "$SID_A"; title_line "$SID_A" "Alpha"; } | mk_session "$1/real" "$SID_A"
}

exf_unreadable() {
  { content_line "$SID_B"; } | mk_session "$1/other" "$SID_B"
  { title_line "$SID_B" "Alpha"; } | mk_session "$1/locked" "$SID_B"
  deny_read "$(session_path "$1/locked" "$SID_B")" || return 1
}

exf_scan_error() {
  mkdir -p "$1/locked"
  { title_line "$SID_B" "Alpha"; } | mk_session "$1/locked" "$SID_B"
  deny_read "$1/locked" || return 1
}

# A prunable stub whose directory is read-only: the decision succeeds, the unlink does
# not. That is `failed`, and it must not be reported as `pruned`.
exf_failed() {
  { title_line "$SID_A" "Alpha"; } | mk_session "$1/stub" "$SID_A"
  { content_line "$SID_A"; title_line "$SID_A" "Alpha"; } | mk_session "$1/real" "$SID_A"
  deny_unlink "$1/stub" || return 1
}

# The row that keeps the exit code honest in the common case: one group prunes cleanly
# while another cannot be observed. A successful deletion must never mask the failure.
exf_mixed() {
  { title_line "$SID_A" "Alpha"; } | mk_session "$1/stub" "$SID_A"
  { content_line "$SID_A"; title_line "$SID_A" "Alpha"; } | mk_session "$1/real" "$SID_A"
  { content_line "$SID_B"; } | mk_session "$1/other" "$SID_B"
  { title_line "$SID_B" "Alpha"; } | mk_session "$1/locked" "$SID_B"
  deny_read "$(session_path "$1/locked" "$SID_B")" || return 1
}

# Column 4/5 are summary counters rather than report-line tokens: the counters exist
# for every state (an all-`none` run legitimately prints no report lines at all), so
# they are the only assertion shape that works uniformly across the table. `-` means
# "no second needle".
run_f_exit_codes() {
  local name builder want_exit n1 n2 home ext root
  home="$(new_home)"; ext="$(new_ext_root)"
  while IFS='|' read -r name builder want_exit n1 n2; do
    name="${name//[[:space:]]/}"
    case "$name" in ''|'#'*) continue ;; esac
    builder="${builder//[[:space:]]/}"
    want_exit="${want_exit//[[:space:]]/}"
    n1="${n1//[[:space:]]/}"
    n2="${n2//[[:space:]]/}"
    root="$(new_proj_root)"
    if ! "$builder" "$root"; then
      skip_case "$name (this host cannot construct the fixture: chmod is advisory, or running as root)"
      allow_read "$root"
      continue
    fi
    run_cli_prune "$home" "$ext" "$root"
    allow_read "$root"
    check "$name: exit code" "$want_exit" "$CLI_RC"
    check_contains "$name: summary carries $n1" "$n1" "$CLI_OUT"
    if [ "$n2" != "-" ]; then
      check_contains "$name: summary carries $n2" "$n2" "$CLI_OUT"
    fi
  done <<'TABLE'
X1-all-real-no-stub  | exf_none         | 0 | pruned=0       | groups=1
X2-pruned            | exf_pruned       | 0 | pruned=1       | kept=0
X3-kept              | exf_kept         | 0 | kept=1         | pruned=0
X4-unclassified      | exf_unclassified | 1 | unclassified=1 | pruned=0
X5-unreadable-file   | exf_unreadable   | 1 | unreadable=1   | pruned=0
X6-scan-error        | exf_scan_error   | 1 | scan-errors=1  | pruned=0
X7-unlink-failed     | exf_failed       | 1 | failed=1       | pruned=0
X8-mixed-partial     | exf_mixed        | 1 | unreadable=1   | pruned=1
TABLE

  # Row 9 of the table: caller error. Invoked separately because it is rejected at the
  # argument layer, before any root is scanned, so it has no fixture.
  root="$(new_proj_root)"
  run_iso "$home" "$ext" --prune-stub-sessions \
    --claude-projects-dir "$(native_path "$root")/definitely-not-here"
  check "X9-bad-argument: exit code" "2" "$CLI_RC"
}

# The `changed` state's exit code, pinned at the module boundary. It cannot be reached
# through a spawned CLI without timing-dependent injection into a live subprocess,
# which the plan rules out as inherently flaky (6.6) — but leaving it unasserted would
# leave the most surprising row of the contract undefended. The union rule is the
# documented definition of the exit code, so it is asserted directly: a run whose only
# non-trivial outcome is `changed` reports success, because a detected-and-refused race
# lost nothing and a re-run will settle it.
run_f_changed_exit_rule() {
  race_fixture
  R_ROOT="$(native_path "$RACE_ROOT")" R_CP="$(native_file "$RACE_CP")" \
    node_m "
const m=require('$REQUIRE_PATH');
const fs=require('fs');
const planned=m.planPruneRoots({roots:[process.env.R_ROOT]});
fs.writeFileSync(process.env.R_CP,'');
const t=m.executePrunePlan({plan:planned.plan, dryRun:false, onEntry:function(){}});
const failures=(t.failed||0)+(planned.scanErrors.length)+(t.unreadable||0)+(t.unclassified||0);
console.log('CHANGED='+(t.changed||0)+' PRUNED='+(t.pruned||0)+' FAILURES='+failures);"
  check "F07: a detected race is a decision, not an observation failure" \
    "CHANGED=1 PRUNED=0 FAILURES=0" "$NODE_OUT"
}

run_f_opt_in
run_f_dependency
run_f_bad_projects_dir
run_f_additive
run_f_summary_shape
run_f_privacy
run_f_exit_codes
run_f_changed_exit_rule
