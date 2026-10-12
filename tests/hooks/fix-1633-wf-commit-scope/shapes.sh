# shellcheck shell=bash
# Case bodies: commit shapes the enumerator cannot place. With one set member (A) an
# ambiguous commit is checked at A once the WF has begun, and approved before it has.
# The second runCommands element and the second logical line are both judged.
# Sourced by fix-1633-wf-commit-scope.sh, which holds the case markers;
# relies on helpers from common.sh.

tc_shapes_begun_checked() {
  helper state shb detail "{\"cwd\":\"$A\"}"
  expect "(shapes) begun: printf x | xargs git commit -> block" block detail \
    "$(gate shb "$A" "$A" Bash '["printf x | xargs git commit -m"]')"
  expect "(shapes) begun: git -C \"\$X\" commit -> block" block detail \
    "$(gate shb "$A" "$A" Bash "[\"git -C \\\"\$X\\\" commit -m x\"]")"
  # A heredoc body itself is dropped by commit detection; the commit carrying the heredoc
  # spans several lines, so its default target is ambiguous (multi-line-span).
  expect "(shapes) begun: git commit -F - <<EOF (multi-line heredoc) -> block" block detail \
    "$(gate shb "$A" "$A" Bash "[\"git commit -F - <<EOF\\nmsg\\nEOF\"]")"
  # An explicit -C target is preserved through a heredoc span (walkJoinedSpan keeps explicit).
  expect "(shapes) begun: git -C A commit -F - <<EOF (explicit heredoc) -> block" block detail \
    "$(gate shb "$A" "$A" Bash "[\"git -C $A commit -F - <<EOF\\nmsg\\nEOF\"]")"
}

tc_shapes_not_begun_approves() {
  helper state shn "workflow_init,detail" "{\"cwd\":\"$A\"}"
  expect "(shapes) not begun: printf x | xargs git commit -> approve" approve - \
    "$(gate shn "$A" "$A" Bash '["printf x | xargs git commit -m"]')"
  expect "(shapes) not begun: git -C \"\$X\" commit -> approve" approve - \
    "$(gate shn "$A" "$A" Bash "[\"git -C \\\"\$X\\\" commit -m x\"]")"
  expect "(shapes) not begun: git commit -F - <<EOF (multi-line heredoc) -> approve" approve - \
    "$(gate shn "$A" "$A" Bash "[\"git commit -F - <<EOF\\nmsg\\nEOF\"]")"
}

tc_shapes_later_element() {
  helper state shl detail "{\"cwd\":\"$A\"}"
  expect "(shapes) runCommands [status B, commit A] -> block" block detail \
    "$(gate shl "$A" "$A" runCommands "[\"git -C $B status\",\"git -C $A commit -m x\"]")"
  expect "(shapes) runCommands [status A, commit B] -> approve" approve - \
    "$(gate shl "$A" "$A" runCommands "[\"git -C $A status\",\"git -C $B commit -m x\"]")"
}

# -c consumes its value; were it not skipped, -C <A> would go unseen and the commit approve.
tc_shapes_value_flag_skipped() {
  helper state shv detail "{\"cwd\":\"$A\"}"
  expect "(shapes) payload cwd B: git -c user.name=x -C A commit -> block" block detail \
    "$(gate shv "$B" "$B" Bash "[\"git -c user.name=x -C $A commit -m x\"]")"
}

tc_shapes_later_line() {
  helper state shm detail "{\"cwd\":\"$A\"}"
  expect "(shapes) Bash 'status B<newline>commit A' -> block" block detail \
    "$(gate shm "$A" "$A" Bash "[\"git -C $B status\\ngit -C $A commit -m x\"]")"
}
