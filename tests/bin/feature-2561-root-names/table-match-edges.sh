# Edge cases of the table-match check (#2561). Sourced by
# tests/bin/feature-2561-root-names-table-match.sh, which defines msg_of, TABLE and
# EXC_NAMED first. Defines functions only.

# A single star stays inside one path segment; a double star with a slash also
# matches no directory at all; a directory name is matched whole.
c_glob_edges() {
  make_kit glob
  write_table "$KIT"
  new_repo glob
  fx "$REPO/profile-snippet.sh" "echo \"$V_AMR\""
  fx "$REPO/profile-snippet.d/x.sh" "echo \"$V_AMR\""
  fx "$REPO/skills/scripts/zero.sh" "echo \"$V_SCR\""
  fx "$REPO/skills/s/scripts/one.sh" "echo \"$V_SCR\""
  fx "$REPO/skills/s/t/scripts/deep/two.sh" "echo \"$V_SCR\""
  fx "$REPO/skills/s/scripts-old/x.sh" "echo \"$V_SCR\""
  fx "$REPO/bin-old/x.sh" "echo \"$V_SCR\""
  fx "$REPO/hooks" 'no root name here'
  commit_all "$REPO"
  run_gate "$KIT" --root "$REPO" --only table-match
  expect "glob: exits 1" rc_is 1
  expect_rows "glob" table-match <<'TABLE'
profile-snippet.sh|accepted
profile-snippet.d/x.sh|norule@0
skills/scripts/zero.sh|accepted
skills/s/scripts/one.sh|accepted
skills/s/t/scripts/deep/two.sh|accepted
skills/s/scripts-old/x.sh|scr@1
bin-old/x.sh|norule@0
hooks|norule@0
TABLE
}

# An exception belongs to one repo: the one it names, agents when it names none.
c_exception_repo() {
  local dot="{\"file\":\"dot/named.sh\",\"repo\":\"dotfiles\",\"allow\":[\"$N_SCR\"],\"forms\":[],\"reason\":\"fixture\"}"
  local agents_dot="{\"file\":\"dot/agents-only.sh\",\"allow\":[\"$N_SCR\"],\"forms\":[],\"reason\":\"fixture\"}"
  local dot_bin="{\"file\":\"bin/named-dot.js\",\"repo\":\"dotfiles\",\"allow\":[\"$N_AMR\"],\"forms\":[],\"reason\":\"fixture\"}"
  make_kit excrepo
  write_table "$KIT" "$EXC_NAMED" "$dot" "$agents_dot" "$dot_bin"
  new_repo excrepo
  fx "$REPO/dot/named.sh" "echo \"$V_SCR\""
  fx "$REPO/dot/agents-only.sh" "echo \"$V_SCR\""
  fx "$REPO/dot/plain.sh" "echo \"$V_AMR\""
  fx "$REPO/bin/named-dot.js" "read($N_AMR);"
  fx "$REPO/bin/named.js" "read($N_AMR);"
  commit_all "$REPO"
  run_gate "$KIT" --root "$REPO" --only table-match --repo dotfiles
  expect_rows "exception repo (dotfiles run)" table-match <<'TABLE'
dot/named.sh|accepted
dot/agents-only.sh|scr@1
dot/plain.sh|accepted
TABLE
  run_gate "$KIT" --root "$REPO" --only table-match
  expect_rows "exception repo (agents run)" table-match <<'TABLE'
bin/named-dot.js|amr@1
bin/named.js|accepted
TABLE
}

c_broken_shapes() {
  local what json
  make_kit shapes
  new_repo shapes
  fx "$REPO/bin/ok.sh" "echo \"$V_SCR\""
  commit_all "$REPO"
  fx "$KIT/$TABLE" "{\"rules\":[{\"repo\":\"agents\",\"glob\":\"**\",\"allow\":[\"$N_SCR\"]}]}"
  run_gate "$KIT" --root "$REPO" --only table-match
  expect "shape: the smallest well-formed table passes this tree (exit 0)" rc_is 0
  # Columns: what is wrong|the table text. Each differs from the table above in one point.
  while IFS='|' read -r what json <&3; do
    fx "$KIT/$TABLE" "$json"
    run_gate "$KIT" --root "$REPO" --only table-match
    expect "shape: $what exits 2" rc_is 2
  done 3<<'TABLE'
an empty file|
a top level that is a list|[]
a top level that is null|null
a rule list that is an object|{"rules":{}}
exceptions that are not a list|{"rules":[{"repo":"agents","glob":"**","allow":[]}],"exceptions":{}}
a rule that is not an object|{"rules":[null]}
a rule without a glob|{"rules":[{"repo":"agents","allow":[]}]}
a rule with an empty glob|{"rules":[{"repo":"agents","glob":"","allow":[]}]}
a rule of an unknown repo|{"rules":[{"repo":"elsewhere","glob":"**","allow":[]}]}
a rule without an allow list|{"rules":[{"repo":"agents","glob":"**"}]}
a rule that allows an unknown name|{"rules":[{"repo":"agents","glob":"**","allow":["SOME_ROOT"]}]}
an exception that is not an object|{"rules":[{"repo":"agents","glob":"**","allow":[]}],"exceptions":["bin/x.sh"]}
an exception without forms|{"rules":[{"repo":"agents","glob":"**","allow":[]}],"exceptions":[{"file":"bin/x.sh","allow":[]}]}
an exception that allows an unknown name|{"rules":[{"repo":"agents","glob":"**","allow":[]}],"exceptions":[{"file":"bin/x.sh","allow":["SOME_ROOT"],"forms":[]}]}
a carrier without files|{"rules":[{"repo":"agents","glob":"**","allow":[]}],"exceptions":[{"carrier":"a.b","kind":"property","source":"bin/x.js"}]}
TABLE
}
