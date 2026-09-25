# shellcheck shell=bash
# Tests: bin/review-doc-size
# Tags: TL2, docs, review-docs, staged, git, scope:issue-specific, pwsh-not-required
#
# GROUP A: the size gate. WARN=300 / HARD=500 lines. --staged judges the git
# index blob (commit-bound), --all judges the working tree but is advisory (never
# non-zero). history.md / CHANGELOG.md / _archive* are excluded from both. A
# blocking violation is HARD-only: only >500 staged lines yields exit 1.

# stage_md <repo> <relpath> <n> — write an N-line md and stage it (index blob).
stage_md() {
  local repo="$1" rel="$2" n="$3"
  gen_md "$repo/$rel" "$n"
  git -C "$repo" add "$rel" >/dev/null 2>&1
}

run_group_a() {
  require_bin "A" "bin/review-doc-size" || return 0
  local repo

  # A1: 550-line .md staged → HARD violation, commit-bound.
  repo="$(new_doc_repo)"
  stage_md "$repo" "big.md" 550
  run_tool "$repo" "bin/review-doc-size" --staged
  assert_eq "A1: 550-line staged md → --staged exits 1 (HARD)" "1" "$TOOL_RC"

  # A2: same 550 lines on disk but NOT staged → the index blob is the small
  # committed version, so --staged reads nothing over threshold.
  repo="$(new_doc_repo)"
  stage_md "$repo" "tracked.md" 250
  git -C "$repo" commit -q -m "add tracked.md"
  gen_md "$repo/tracked.md" 550        # working tree only; no git add
  run_tool "$repo" "bin/review-doc-size" --staged
  assert_eq "A2: 550-line unstaged md → --staged exits 0 (index blob, not worktree)" "0" "$TOOL_RC"

  # A3: 350-line staged → WARN band (>300, <=500): advisory, still exit 0.
  repo="$(new_doc_repo)"
  stage_md "$repo" "warn.md" 350
  run_tool "$repo" "bin/review-doc-size" --staged
  assert_eq "A3: 350-line staged md → --staged exits 0 (WARN, non-blocking)" "0" "$TOOL_RC"

  # A4: 250-line staged → below WARN, no finding.
  repo="$(new_doc_repo)"
  stage_md "$repo" "ok.md" 250
  run_tool "$repo" "bin/review-doc-size" --staged
  assert_eq "A4: 250-line staged md → --staged exits 0 (no warn)" "0" "$TOOL_RC"

  # A5: --all is advisory even for a HARD-size file on disk.
  repo="$(new_doc_repo)"
  gen_md "$repo/huge.md" 600
  run_tool "$repo" "bin/review-doc-size" --all
  assert_eq "A5: 600-line file on disk → --all exits 0 (advisory mode)" "0" "$TOOL_RC"

  # A6/A7/A8: excluded paths never block, even at 600 staged lines.
  repo="$(new_doc_repo)"
  stage_md "$repo" "docs/history.md" 600
  run_tool "$repo" "bin/review-doc-size" --staged
  assert_eq "A6: 600-line docs/history.md staged → excluded, exits 0" "0" "$TOOL_RC"

  repo="$(new_doc_repo)"
  stage_md "$repo" "_archive/old.md" 600
  run_tool "$repo" "bin/review-doc-size" --staged
  assert_eq "A7: 600-line _archive/ md staged → excluded, exits 0" "0" "$TOOL_RC"

  repo="$(new_doc_repo)"
  stage_md "$repo" "CHANGELOG.md" 600
  run_tool "$repo" "bin/review-doc-size" --staged
  assert_eq "A8: 600-line CHANGELOG.md staged → excluded, exits 0" "0" "$TOOL_RC"

  # A9: --staged and --all together is contradictory → SKIP (no error), exit 0.
  repo="$(new_doc_repo)"
  stage_md "$repo" "big.md" 600
  run_tool "$repo" "bin/review-doc-size" --staged --all
  assert_eq "A9: --staged and --all together → exits 0 (SKIP, mutual exclusion)" "0" "$TOOL_RC"

  # A10: no mode flag → SKIP (no error), exit 0.
  repo="$(new_doc_repo)"
  stage_md "$repo" "big.md" 600
  run_tool "$repo" "bin/review-doc-size"
  assert_eq "A10: no mode flag → exits 0 (SKIP)" "0" "$TOOL_RC"

  # --- A-NEW: SOFT/HARD boundary + edge coverage (#2340 gap C2) ---
  # SOFT=300, HARD=500. The block condition is strictly >500 staged lines
  # (header: "only >500 staged lines yields exit 1"), so 300/301/500 sit in the
  # WARN band or below and stay exit 0; 501 is the first blocking size.

  # A-NEW-1: exactly 300 staged (SOFT threshold, not over) → no WARN yet.
  # WARN fires strictly >300 (A3 header: "WARN band (>300, <=500)"), symmetric with
  # the HARD boundary in A-NEW-3 where 500 (==HARD, not >500) does not block. So at
  # exactly the threshold the band is not entered; the WARN token is asserted at 301
  # (A-NEW-2b/2c), the first size over SOFT, where it holds under either boundary.
  repo="$(new_doc_repo)"
  stage_md "$repo" "soft300.md" 300
  run_tool "$repo" "bin/review-doc-size" --staged
  assert_eq "A-NEW-1: 300-line staged md → --staged exits 0 (at SOFT, not >300)" "0" "$TOOL_RC"

  # A-NEW-2: 301 staged (just over SOFT) → WARN band, non-blocking. Like A-NEW-1,
  # assert the WARN diagnostic is emitted (not just exit 0): a build missing the
  # SOFT threshold would also exit 0, so the output token proves SOFT fired.
  repo="$(new_doc_repo)"
  stage_md "$repo" "soft301.md" 301
  run_tool "$repo" "bin/review-doc-size" --staged
  assert_eq "A-NEW-2: 301-line staged md → --staged exits 0 (over SOFT, WARN)" "0" "$TOOL_RC"
  assert_contains "A-NEW-2b: 301-line staged md → --staged emits a WARN diagnostic" "WARN" "$TOOL_OUT"
  assert_contains "A-NEW-2c: 301-line WARN diagnostic names the file" "soft301.md" "$TOOL_OUT"

  # A-NEW-3: exactly 500 staged (at HARD threshold, not over) → not blocking.
  repo="$(new_doc_repo)"
  stage_md "$repo" "hard500.md" 500
  run_tool "$repo" "bin/review-doc-size" --staged
  assert_eq "A-NEW-3: 500-line staged md → --staged exits 0 (at HARD, not >500)" "0" "$TOOL_RC"

  # A-NEW-4: 501 staged (first size over HARD) → HARD block.
  repo="$(new_doc_repo)"
  stage_md "$repo" "hard501.md" 501
  run_tool "$repo" "bin/review-doc-size" --staged
  assert_eq "A-NEW-4: 501-line staged md → --staged exits 1 (HARD, >500)" "1" "$TOOL_RC"

  # A-NEW-5: an empty (0-line) staged md → clean, no finding.
  repo="$(new_doc_repo)"
  : > "$repo/empty.md"
  git -C "$repo" add empty.md >/dev/null 2>&1
  run_tool "$repo" "bin/review-doc-size" --staged
  assert_eq "A-NEW-5: empty (0-line) staged md → --staged exits 0 (clean)" "0" "$TOOL_RC"

  # A-NEW-6: several staged docs, exactly one over HARD → the set blocks.
  repo="$(new_doc_repo)"
  stage_md "$repo" "clean-a.md" 100
  stage_md "$repo" "clean-b.md" 250
  stage_md "$repo" "over.md" 501
  run_tool "$repo" "bin/review-doc-size" --staged
  assert_eq "A-NEW-6: one of several staged docs over HARD → --staged exits 1" "1" "$TOOL_RC"

  # A-NEW-7: 350 staged (mid WARN band) → exit 0 AND a WARN diagnostic naming the
  # file. Pairs with A-NEW-1 so both edges of the WARN band prove SOFT fired.
  repo="$(new_doc_repo)"
  stage_md "$repo" "warn350.md" 350
  run_tool "$repo" "bin/review-doc-size" --staged
  assert_eq "A-NEW-7: 350-line staged md → --staged exits 0 (WARN band)" "0" "$TOOL_RC"
  assert_contains "A-NEW-7b: 350-line staged md → --staged emits a WARN diagnostic" "WARN" "$TOOL_OUT"
  assert_contains "A-NEW-7c: 350-line WARN diagnostic names the file" "warn350.md" "$TOOL_OUT"
}
