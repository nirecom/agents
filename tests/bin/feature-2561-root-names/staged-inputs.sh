# Input-selection cases of the gate's command line (#2561). Sourced by
# tests/bin/feature-2561-root-names-staged.sh, which defines staged_kit, staged and
# the OLD_* spellings. Defines functions only.

CHECK_NAMES="residue table-match structural script-root-form env-name"

# Columns: check|path|line|part of the message|fixture content (<NL> = new line).
# One finding per check, so a run can be asked which checks really ran.
five_check_rows() {
  cat <<TABLE
residue|bin/o-res.sh|1|retired env "$OLD_ENV"|$OLD_LINE
env-name|bin/o-env.sh|1|never a local variable|$N_AMR=/x
table-match|plain/o-tm.sh|1|is not allowed by the rule of this file|echo "$V_SCR"
structural|bin/o-struct.sh|1|but it is exported|export $N_SCR
script-root-form|bin/o-form.sh|2|not assigned in the standard form|#!/usr/bin/env bash<NL>$N_SCR=/fixed
TABLE
}

# expect_checks <label> <check>... — every named check reports its row; no line of
# any other check is printed.
expect_checks() {
  local label="$1" check path line text _content other
  shift
  while IFS='|' read -r check path line text _content; do
    if [[ " $* " == *" $check "* ]]; then
      expect "$label: the $check check reports $path" reports "$path" "$check" "$line" "$text"
    else
      expect "$label: no line of the $check check" never_says ": $check: "
    fi
  done < <(five_check_rows)
}

c_only_selects_one_check() {
  local check path _line _text content
  make_kit select
  write_table "$KIT"
  new_repo select
  while IFS='|' read -r check path _line _text content; do
    fx "$REPO/$path" "${content//<NL>/$'\n'}"
  done < <(five_check_rows)
  commit_all "$REPO"
  run_gate "$KIT" --root "$REPO"
  expect "only: without the flag the run exits 1" rc_is 1
  # shellcheck disable=SC2086
  expect_checks "only: without the flag" $CHECK_NAMES
  for check in $CHECK_NAMES; do
    run_gate "$KIT" --root "$REPO" --only "$check"
    expect_checks "only $check" "$check"
  done
}

c_scope() {
  make_kit scope
  write_table "$KIT"
  new_repo scope
  fx "$REPO/bin/o-res.sh" "$OLD_LINE"
  fx "$REPO/bin/o-more.sh" "$OLD_LINE"
  fx "$REPO/hooks/o-res.js" "use(\"$OLD_ENV\");"
  fx "$REPO/bi/o-clean.sh" 'echo clean'
  fx "$REPO/bin/o-res/o-clean.sh" 'echo clean'
  commit_all "$REPO"
  # Columns: scope|verdict for bin/o-res.sh|for bin/o-more.sh|for hooks/o-res.js.
  local scope a b c
  while IFS='|' read -r scope a b c <&3; do
    run_gate "$KIT" --root "$REPO" --only residue --scope "$scope"
    expect_rows "scope '$scope'" residue <<ROWS
bin/o-res.sh|$a
bin/o-more.sh|$b
hooks/o-res.js|$c
ROWS
  done 3<<'TABLE'
bin|env@1|env@1|accepted
bin/|env@1|env@1|accepted
hooks/|accepted|accepted|env@1
bin/o-res.sh|env@1|accepted|accepted
bi|accepted|accepted|accepted
bin/o-res|accepted|accepted|accepted
TABLE
  run_gate "$KIT" --root "$REPO" --only residue --scope bi
  expect "scope: a prefix that only begins a directory name exits 0" rc_is 0
}

c_hostile_arguments() {
  make_kit args
  write_table "$KIT"
  new_repo args
  fx "$REPO/bin/h.sh" 'echo clean'
  commit_all "$REPO"
  run_gate "$KIT" --root "$REPO" --only '$(touch PWNED_O)'
  expect "hostile: a command substitution as a check name exits 2" rc_is 2
  run_gate "$KIT" --root "$REPO;touch PWNED_R"
  expect "hostile: a root with a command separator exits 2" rc_is 2
  run_gate "$KIT" --root "$REPO" --repo 'agents`touch PWNED_P`'
  expect "hostile: a backtick in the repo value exits 2" rc_is 2
  run_gate "$KIT" --root "$REPO" --scope '$(touch PWNED_S);touch PWNED_T'
  expect "hostile: a hostile scope selects no file (exit 2)" rc_is 2
  run_gate "$KIT" --root "$REPO" --retired-names-from '$(touch PWNED_L)'
  expect "hostile: a hostile list path exits 2" rc_is 2
  expect "hostile: no argument was executed" no_marker_file
}

# What a tree run reads: tracked files only, every file outside git, and of a
# binary file its path alone.
c_tree_inputs() {
  local plain="$T/plain-tree"
  make_kit inputs
  write_table "$KIT"
  fx "$plain/bin/n-bad.sh" "$OLD_LINE"
  fx "$plain/bin/n-good.sh" 'echo clean'
  run_gate "$KIT" --root "$plain" --only residue
  expect "inputs: a directory outside git is read file by file" reports "bin/n-bad.sh" residue 1
  expect "inputs: its clean file is not reported" clean_for "bin/n-good.sh"
  fx "$plain/sub/n-deep.sh" "$OLD_LINE"
  fx "$plain/node_modules/pkg/n-dep.sh" "$OLD_LINE"
  fx "$plain/sub/node_modules/n-dep.sh" "$OLD_LINE"
  fx "$plain/sub/.git/n-meta.sh" "$OLD_LINE"
  run_gate "$KIT" --root "$plain" --only residue
  expect_rows "inputs outside git" residue <<'TABLE'
bin/n-bad.sh|env@1
sub/n-deep.sh|env@1
node_modules/pkg/n-dep.sh|accepted
sub/node_modules/n-dep.sh|accepted
sub/.git/n-meta.sh|accepted
TABLE
  new_repo inputs
  fx "$REPO/bin/t-clean.sh" 'echo clean'
  printf 'a\0b %s\n' "$OLD_ENV" > "$REPO/bin/t-blob.bin"
  commit_all "$REPO"
  fx "$REPO/bin/t-untracked.sh" "$OLD_LINE"
  run_gate "$KIT" --root "$REPO" --only residue
  expect "inputs: an untracked file and binary content exit 0" rc_is 0
  mkdir -p "$REPO/$(dirname "$OLD_PATH")"
  printf '\0%s\n' "$OLD_ENV" > "$REPO/$OLD_PATH"
  git -C "$REPO" add "$OLD_PATH"
  run_gate "$KIT" --root "$REPO" --only residue
  expect "inputs: the path of a binary file is still judged" reports "$OLD_PATH" residue 0 'the path carries'
  expect "inputs: the content of a binary file is not" test "$(lines_for "$OLD_PATH")" = 1
  expect "inputs: the other binary file stays unreported" clean_for "bin/t-blob.bin"
  git -C "$REPO" add bin/t-untracked.sh
  run_gate "$KIT" --root "$REPO" --only residue
  expect "inputs: a file is judged once it is tracked" reports "bin/t-untracked.sh" residue 1
}

# The staged flag reads the index of the gate's own checkout, wherever it is called from.
c_staged_from_another_directory() {
  staged_kit cwd
  fx "$KIT/bin/s-k.sh" "$OLD_LINE"
  git -C "$KIT" add bin/s-k.sh
  new_repo elsewhere
  fx "$REPO/bin/s-other.sh" "$OLD_LINE"
  git -C "$REPO" add -A
  run_gate_at "$REPO" "$KIT" --staged --only residue
  expect "cwd: from another repository the gate's own index is judged" reports "bin/s-k.sh" residue 1
  expect "cwd: the index of the calling directory is not" clean_for "bin/s-other.sh"
  run_gate_at "$T" "$KIT" --staged --only residue
  expect "cwd: from a directory outside git the verdict is the same" reports "bin/s-k.sh" residue 1
}

says() { [[ "$GATE_OUT" == *"$1"* ]]; }

# The staged flag never falls back to the working tree: without an index, or with an
# index that lacks one of the gate's own data files, the run exits 2.
c_staged_fails_closed() {
  local name check rel
  make_kit noindex
  write_table "$KIT"
  fx "$KIT/bin/base.sh" 'echo base'
  run_gate_at "$KIT" "$KIT" --only residue --scope bin/base.sh
  expect "closed: the copy outside git passes a tree run (exit 0)" rc_is 0
  staged --only residue
  expect "closed: the staged flag outside git exits 2" rc_is 2
  expect "closed: it says the index cannot be read" says 'cannot read the index'
  # Columns: kit name|check that needs the file|the gate's own data file.
  while IFS='|' read -r name check rel <&3; do
    staged_kit "$name"
    fx "$KIT/bin/s-m.sh" 'echo clean'
    git -C "$KIT" add bin/s-m.sh
    staged --only "$check"
    expect "closed ($check): with its data file in the index the run exits 0" rc_is 0
    git -C "$KIT" rm -q --cached "$rel"
    staged --only "$check"
    expect "closed ($check): the data file gone from the index exits 2" rc_is 2
    expect "closed ($check): it names the missing file" says "the index does not hold $rel"
    expect "closed ($check): the working copy it did not read is still there" test -f "$KIT/$rel"
  done 3<<TABLE
notable|table-match|$TABLE_REL
nolist|residue|$LIST_REL
TABLE
}

# A staged path whose blob cannot be read stops the run; a gitlink has no blob and is skipped.
c_staged_blob_must_be_readable() {
  local hash
  staged_kit gitlink
  git -C "$KIT" update-index --add --cacheinfo "160000,$(printf '%040d' 1),sub"
  staged --only residue
  expect "gitlink: a staged gitlink alone exits 0" rc_is 0
  fx "$KIT/bin/s-n.sh" "$OLD_LINE"
  git -C "$KIT" add bin/s-n.sh
  staged --only residue
  expect "gitlink: the file staged beside it is still judged" reports "bin/s-n.sh" residue 1
  staged_kit lostblob
  fx "$KIT/bin/s-p.sh" 'echo zzq lost blob'
  git -C "$KIT" add bin/s-p.sh
  hash="$(git -C "$KIT" rev-parse :bin/s-p.sh)"
  rm -f "$KIT/.git/objects/${hash:0:2}/${hash:2}"
  expect "lost blob: the staged object is gone" test ! -e "$KIT/.git/objects/${hash:0:2}/${hash:2}"
  staged --only residue
  expect "lost blob: a staged path without its blob exits 2, never 0" rc_is 2
  expect "lost blob: it names the path" says 'cannot read the staged content of bin/s-p.sh'
}

# A tree or a scope that selects no file is an error; only an empty index is a clean answer.
c_empty_input() {
  local scope want _what
  make_kit empty
  write_table "$KIT"
  new_repo empty
  mkdir -p "$T/empty-dir/sub"
  run_gate "$KIT" --root "$REPO"
  expect "empty: a git repo without a tracked file exits 2" rc_is 2
  expect "empty: it says there is no file to check" says 'no file to check'
  run_gate "$KIT" --root "$T/empty-dir"
  expect "empty: a directory without a file exits 2" rc_is 2
  fx "$REPO/bin/e.sh" 'echo clean'
  commit_all "$REPO"
  # Columns: scope|exit code|what the scope selects.
  while IFS='|' read -r scope want _what <&3; do
    run_gate "$KIT" --root "$REPO" --only residue --scope "$scope"
    expect "empty: the scope '$scope' exits $want" rc_is "$want"
  done 3<<'TABLE'
bin|0|the one tracked file
docs|2|no file
bin/e|2|no file: half a file name
TABLE
  staged_kit emptyindex
  staged
  expect "empty: the staged flag with nothing staged exits 0" rc_is 0
  staged --scope docs
  expect "empty: nothing staged under a scope exits 0 as well" rc_is 0
}

c_file_arguments() {
  staged_kit files
  fx "$KIT/bin/f-bad.sh" "$OLD_LINE"
  fx "$KIT/bin/f-good.sh" 'echo clean'
  fx "$T/outside/f-out.sh" "$OLD_LINE"
  commit_all "$KIT"
  run_gate_at "$KIT" "$KIT" --only residue bin/f-bad.sh
  expect "files: a named file is judged" reports "bin/f-bad.sh" residue 1
  run_gate_at "$KIT" "$KIT" --only residue bin/f-good.sh
  expect "files: only the named file is judged (exit 0)" rc_is 0
  run_gate_at "$KIT" "$KIT" --only residue bin/f-good.sh bin/f-bad.sh
  expect "files: several files are judged together" reports "bin/f-bad.sh" residue 1
  run_gate_at "$KIT" "$KIT" --only residue bin/f-bad.sh bin/f-bad.sh
  expect "files: a file named twice is reported once" test "$(lines_for bin/f-bad.sh)" = 1
  run_gate_at "$KIT" "$KIT" --only residue "$KIT/bin/f-bad.sh"
  expect "files: an absolute path inside the checkout is reported by its relative path" \
    reports "bin/f-bad.sh" residue 1
  run_gate_at "$KIT" "$KIT" --only residue "$T/outside/f-out.sh"
  expect "files: an absolute path outside the checkout is reported as it was given" \
    reports "$T/outside/f-out.sh" residue 1
  run_gate_at "$KIT" "$KIT" --only residue ../../outside/f-out.sh
  expect "files: a relative path outside the checkout is reported as it was given" \
    reports "../../outside/f-out.sh" residue 1
  run_gate_at "$KIT" "$KIT" --only residue bin/f-absent.sh
  expect "files: a file that does not exist exits 2" rc_is 2
  run_gate_at "$KIT" "$KIT" --only residue bin/f-bad.sh bin/f-absent.sh
  expect "files: one missing file among real ones exits 2" rc_is 2
}

c_report_order() {
  local body
  make_kit order
  write_table "$KIT"
  new_repo order
  fx "$REPO/zz/last.sh" "$OLD_LINE"
  fx "$REPO/bin/many.sh" "$OLD_LINE" 'echo clean' "$OLD_LINE" 'echo 4' 'echo 5' 'echo 6' 'echo 7' 'echo 8' 'echo 9' "$OLD_LINE"
  fx "$REPO/aa/first.sh" "$OLD_LINE"
  fx "$REPO/Bin/upper.sh" "$OLD_LINE"
  commit_all "$REPO"
  run_gate "$KIT" --root "$REPO" --only residue
  expect "order: exits 1" rc_is 1
  body="$(grep -v '^check-root-names: ' <<<"$GATE_OUT" | tr -d '\r')"
  expect "order: one line per finding" test "$(grep -c . <<<"$body")" = 6
  expect "order: the report lines are sorted" test "$body" = "$(LC_ALL=C sort <<<"$body")"
  expect "order: no line is printed twice" test -z "$(LC_ALL=C sort <<<"$body" | uniq -d)"
  expect "order: the closing line counts the findings" test "${GATE_OUT/check-root-names: 6 violation(s)./}" != "$GATE_OUT"
}
