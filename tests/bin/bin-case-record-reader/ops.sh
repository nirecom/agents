# The bash caseEmbedRules part, reached through the registry after crr_read in the same
# shell: rules-doc, deps, leftover-defs, self-impl, skip-reason, result-summary.
# Sourced by the dispatcher.

echo ""
echo "=== bash caseEmbedRules ==="

case_begin "op-rules-doc" "bin/lib/test-language-parts/bash-case-embed.sh"
op "$AGENTS_DIR" "$FXD/none.sh" rules-doc "$FXD/none.sh"
assert_eq "rc=$OP_RC out=$OP_OUT" "rc=0 out=skills/sweep-tests/embed-rules/bash.md"
if [ -f "$AGENTS_DIR/skills/sweep-tests/embed-rules/bash.md" ]; then
  pass "rules doc exists in the repo"
else
  fail "rules doc exists in the repo" "skills/sweep-tests/embed-rules/bash.md missing"
fi
case_end

case_begin "op-deps" "bin/lib/test-language-parts/bash-case-embed.sh"
# <case-idx>\t<csv>: a case with deps has its line; no line may list a dep it lacks.
op "$AGENTS_DIR" "$FXD/conforming.sh" deps "$FXD/conforming.sh"
assert_eq "rc=$OP_RC" "rc=0"
has_line "case 0 lists both helpers" "$OP_OUT" "0${T}helper_a,helper_b"
extra="$(printf '%s\n' "$OP_OUT" | awk -F'\t' '$1 == "1" && $2 != "" { print }')"
assert_eq "case 1 has no deps: [$extra]" "case 1 has no deps: []"
op "$AGENTS_DIR" "$FXD/deps-heredoc.sh" deps "$FXD/deps-heredoc.sh"
assert_eq "heredoc deps: $OP_OUT" "heredoc deps: 0${T}real_fn"
case_end

case_begin "op-leftover-defs" "bin/lib/test-language-parts/bash-case-embed.sh"
# name|file|want (\t written as <TAB>; empty = no output)
while IFS='|' read -r lname lfile lwant; do
  [ -n "$lname" ] || continue
  op "$AGENTS_DIR" "$FXD/$lfile" leftover-defs "$FXD/$lfile"
  assert_eq "$lname rc=$OP_RC out=$OP_OUT" "$lname rc=0 out=${lwant//<TAB>/$T}"
done <<'ROWS'
unreferenced-function|leftover.sh|4<TAB>orphan_fn
called-in-case-and-outside|deps-heredoc.sh|
helpers-called-by-cases|conforming.sh|
heredoc-mention-is-no-reference|heredoc-pseudo.sh|2<TAB>hd_fn
ROWS
case_end

case_begin "op-self-impl" "bin/lib/test-language-parts/bash-case-embed.sh"
# <line>\t<kind>\t<detail>: the line numbers are the contract; kind/detail are free text.
op "$AGENTS_DIR" "$FXD/self-impl.sh" self-impl "$FXD/self-impl.sh"
assert_eq "rc=$OP_RC" "rc=0"
lines="$(printf '%s\n' "$OP_OUT" | awk -F'\t' 'NF >= 3 { print $1 }' | sort -n | tr '\n' ' ')"
assert_eq "flagged lines: $lines" "flagged lines: 3 4 5 "
op "$AGENTS_DIR" "$FXD/self-impl-clean.sh" self-impl "$FXD/self-impl-clean.sh"
assert_eq "clean: rc=$OP_RC out=[$OP_OUT]" "clean: rc=0 out=[]"
case_end

case_begin "op-skip-reason" "bin/lib/test-language-parts/bash-case-embed.sh"
# Only a tests/lib/*harness*.sh other than the shared harness is narrow-harness.
while IFS='|' read -r sname swant; do
  [ -n "$sname" ] || continue
  op "$AGENTS_DIR" "$FXD/skip-$sname.sh" skip-reason "$FXD/skip-$sname.sh"
  assert_eq "$sname rc=$OP_RC out=[$OP_OUT]" "$sname rc=0 out=[$swant]"
done <<'ROWS'
narrow-dot-agents|narrow-harness
narrow-source-repo-root|narrow-harness
narrow-unquoted|narrow-harness
shared-harness|
section-runner|
narrow-in-heredoc|
ROWS
case_end

case_begin "op-result-summary" "bin/lib/test-language-parts/bash-case-embed.sh"
# name|rc|stdout text (\n as <NL>)|want class|pass|fail
while IFS='|' read -r rname rrc rtext rwant; do
  [ -n "$rname" ] || continue
  printf '%s\n' "${rtext//<NL>/$'\n'}" >"$FXD/out-$rname.txt"
  op "$AGENTS_DIR" "$FXD/none.sh" result-summary "$rrc" "$FXD/out-$rname.txt"
  assert_eq "$rname rc=$OP_RC out=$OP_OUT" "$rname rc=0 out=${rwant//<TAB>/$T}"
done <<'ROWS'
pass-with-counts|0|PASS: a<NL>Results: 3 passed, 0 failed|pass<TAB>3<TAB>0
fail-with-counts|1|FAIL: b<NL>Results: 2 passed, 1 failed|fail<TAB>2<TAB>1
skip-77|77|SKIP: node not available|skip<TAB><TAB>
pass-no-results-line|0|done|pass<TAB><TAB>
other-rc-is-fail|5|Results: 4 passed, 0 failed|fail<TAB>4<TAB>0
trailing-skipped-count|0|Results: 5 passed, 0 failed, 2 skipped|pass<TAB>5<TAB>0
ROWS
case_end
