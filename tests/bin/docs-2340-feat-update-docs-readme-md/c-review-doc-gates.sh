# shellcheck shell=bash
# Tests: bin/review-doc-gates, bin/review-doc-size, bin/review-doc-heading-order
# Tags: TL2, docs, review-docs, staged, git, aggregate, scope:issue-specific, pwsh-not-required
#
# GROUP C: the aggregate gate. review-doc-gates delegates to review-doc-size,
# review-doc-heading-order and (#2529) review-doc-glossary and OR-folds their exit
# codes: exit 1 if ANY sub-tool blocks, exit 0 only when all pass. --all stays advisory (always 0).

# stage_readme_c <repo> <n-lines> <heading-lines...> — README.md padded to N
# lines with the given ordered H2 sections, staged. N controls the size gate,
# the heading order controls the heading gate.
stage_readme_c() {
  local repo="$1" n="$2"; shift 2
  local f="$repo/README.md" h i emitted=0
  {
    echo "# Project"
    for h in "$@"; do
      echo "## $h"
      echo "body of $h"
      emitted=$((emitted + 2))
    done
    for ((i = emitted + 2; i <= n; i++)); do echo "filler $i"; done
  } > "$f"
  git -C "$repo" add README.md >/dev/null 2>&1
}

# stage_glossary_c <repo> <term...> — docs/glossary-user.md with one well-formed
# entry per term in the given order, staged (order drives the glossary gate, #2529).
stage_glossary_c() {
  local repo="$1" t; shift
  mkdir -p "$repo/docs"
  {
    printf '# Glossary\n\nFixture glossary.\n\n'
    for t in "$@"; do
      printf '### %s\n- **Definition**: %s is a fixture term.\n- **Related**: [owner](architecture/owner.md)\n\n' "$t" "$t"
    done
  } > "$repo/docs/glossary-user.md"
  git -C "$repo" add docs/glossary-user.md >/dev/null 2>&1
}

# stage_glossary_lines_c <repo> <docs-relpath> <n-lines> <term-prefix> — a well-formed
# glossary file of exactly N lines (4-line header, 4-line entries <prefix>-0001.. in
# order, blank-line padding to N), staged. N drives the size gate; the form stays valid.
stage_glossary_lines_c() {
  local repo="$1" rel="$2" n="$3" prefix="$4" i k=0 t
  mkdir -p "$repo/docs"
  {
    printf '# Glossary\n\nFixture glossary.\n\n'
    i=4
    while [ $((i + 4)) -le "$n" ]; do
      k=$((k + 1)); printf -v t '%s-%04d' "$prefix" "$k"
      printf '### %s\n- **Definition**: %s is a fixture term.\n- **Related**: [owner](architecture/owner.md)\n\n' "$t" "$t"
      i=$((i + 4))
    done
    while [ "$i" -lt "$n" ]; do echo; i=$((i + 1)); done
  } > "$repo/docs/$rel"
  git -C "$repo" add "docs/$rel" >/dev/null 2>&1
}

run_group_c() {
  require_bin "C" "bin/review-doc-gates" || return 0
  local repo

  # C1: size violation only (>500 lines, order canonical) → aggregate blocks.
  repo="$(new_doc_repo)"
  stage_readme_c "$repo" 550 "What" "Quickstart" "Usage" "Configuration"
  run_tool "$repo" "bin/review-doc-gates" --staged
  assert_eq "C1: size violation only → --staged exits 1" "1" "$TOOL_RC"

  # C2: heading-order violation only (small file, inverted order) → aggregate blocks.
  repo="$(new_doc_repo)"
  stage_readme_c "$repo" 40 "What" "Configuration" "Quickstart" "Usage"
  run_tool "$repo" "bin/review-doc-gates" --staged
  assert_eq "C2: heading-order violation only → --staged exits 1" "1" "$TOOL_RC"

  # C3: both violations at once → aggregate still non-zero (no double-count bug).
  repo="$(new_doc_repo)"
  stage_readme_c "$repo" 550 "Configuration" "Quickstart"
  run_tool "$repo" "bin/review-doc-gates" --staged
  assert_eq "C3: both violations → --staged exits 1" "1" "$TOOL_RC"

  # C4: neither violated → clean pass.
  repo="$(new_doc_repo)"
  stage_readme_c "$repo" 250 "What" "Quickstart" "Usage" "Configuration"
  run_tool "$repo" "bin/review-doc-gates" --staged
  assert_eq "C4: no violations → --staged exits 0" "0" "$TOOL_RC"

  # C5: --all is advisory even when both sub-gates would block.
  repo="$(new_doc_repo)"
  stage_readme_c "$repo" 550 "Configuration" "Quickstart"
  run_tool "$repo" "bin/review-doc-gates" --all
  assert_eq "C5: --all exits 0 even with violations (advisory)" "0" "$TOOL_RC"

  # C6: glossary violation only (no README staged, entries out of order) → aggregate
  # blocks, symmetric to C1/C2 (#2529).
  repo="$(new_doc_repo)"
  stage_glossary_c "$repo" beta alpha
  run_tool "$repo" "bin/review-doc-gates" --staged
  assert_eq "C6: glossary violation only → --staged exits 1" "1" "$TOOL_RC"
  assert_contains "C6: glossary sub-gate ran inside the aggregate" "Doc-glossary Review" "$TOOL_OUT"

  # C6b: well-formed glossary staged → aggregate passes (the glossary gate is not a blanket block).
  repo="$(new_doc_repo)"
  stage_glossary_c "$repo" alpha beta
  run_tool "$repo" "bin/review-doc-gates" --staged
  assert_eq "C6b: valid glossary staged → --staged exits 0" "0" "$TOOL_RC"

  # C7: the 500-line HARD boundary on a staged, otherwise valid glossary file (#2529):
  # the aggregate owns it because size and glossary form are checked together here.
  repo="$(new_doc_repo)"
  stage_glossary_lines_c "$repo" glossary-user.md 500 alpha
  assert_eq "C7a: fixture glossary is exactly 500 lines" "500" "$(wc -l < "$repo/docs/glossary-user.md" | tr -d ' ')"
  run_tool "$repo" "bin/review-doc-gates" --staged
  assert_eq "C7a: 500-line valid glossary → --staged exits 0" "0" "$TOOL_RC"

  repo="$(new_doc_repo)"
  stage_glossary_lines_c "$repo" glossary-user.md 501 alpha
  assert_eq "C7b: fixture glossary is exactly 501 lines" "501" "$(wc -l < "$repo/docs/glossary-user.md" | tr -d ' ')"
  run_tool "$repo" "bin/review-doc-gates" --staged
  assert_eq "C7b: 501-line valid glossary → --staged exits 1" "1" "$TOOL_RC"

  # C7c: the same oversized category split by range (a-m + n-z, no gap, no overlap), each
  # file under the limit → passes (the split is the sanctioned way past 500 lines).
  repo="$(new_doc_repo)"
  stage_glossary_lines_c "$repo" glossary-user-a-m.md 300 alpha
  stage_glossary_lines_c "$repo" glossary-user-n-z.md 300 november
  run_tool "$repo" "bin/review-doc-gates" --staged
  assert_eq "C7c: valid a-m + n-z range split (600 lines total) → --staged exits 0" "0" "$TOOL_RC"
}
