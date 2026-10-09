# Cases of the residue check that spell no retired name themselves (#2561). Sourced
# by tests/bin/feature-2561-root-names-residue.sh, which owns the list, the fixture
# tables and the OLD_* spellings. Defines functions only.

# list_entries — "kind|spelling" for every entry between the two marker lines.
list_entries() {
  sed -n '/^# retired-names:begin$/,/^# retired-names:end$/p' "$RETIRED_LIST" |
    sed -nE 's/^# (env|name|stem|keep) (.+)$/\1|\2/p'
}

upper() { printf '%s' "$1" | tr '[:lower:]' '[:upper:]'; }

# Every entry of the list gets a fixture of its own: a retired entry is reported
# under its own kind and spelling (a stem in four writings), a kept one is not.
c_every_entry() {
  local kind spelling w camel snake kebab n=0 want="" total
  make_kit entries
  new_repo entries
  while IFS='|' read -r kind spelling; do
    n=$((n + 1))
    if [[ "$kind" == keep ]]; then
      fx "$REPO/gen/k$n.txt" "x $spelling y"
      want+="gen/k$n.txt|accepted"$'\n'
    elif [[ "$kind" == stem ]]; then
      camel="fake" snake="FAKE" kebab="fake"
      for w in $spelling; do
        camel+="$(upper "${w:0:1}")${w:1}"
        snake+="_$(upper "$w")"
        kebab+="-$w"
      done
      fx "$REPO/gen/s$n.txt" "x $spelling y" "$camel" "$snake" "$kebab"
      for w in 1 2 3 4; do want+="gen/s$n.txt|stem $spelling@$w"$'\n'; done
    else
      fx "$REPO/gen/e$n.txt" "x $spelling y"
      want+="gen/e$n.txt|$kind $spelling@1"$'\n'
    fi
  done < <(list_entries)
  commit_all "$REPO"
  run_gate "$KIT" --root "$REPO" --only residue
  total="$(sed -n '/^# retired-names:begin$/,/^# retired-names:end$/p' "$RETIRED_LIST" | grep -c '^# [a-z][a-z]* ' || true)"
  expect "entries: every entry line of the list got a fixture ($n of $total)" test "$n" = "$total"
  expect "entries: the list has not shrunk ($n entries)" test "$n" -ge 58
  expect "entries: a tree of every entry exits 1" rc_is 1
  expect_rows "entry" residue <<<"$want"
}

# The same fixtures against the list without its keep lines: the kept spellings are
# reported there, and the look-alikes still match nothing.
c_keep_effect() {
  local nokeep="$T/no-keep-list.txt" path _rest
  make_kit keep
  new_repo keep
  seed "$REPO" KEPT_ROWS 1
  seed "$REPO" LOOKALIKE_ROWS 1
  commit_all "$REPO"
  grep -v '^# keep ' "$RETIRED_LIST" > "$nokeep"
  run_gate "$KIT" --root "$REPO" --only residue --retired-names-from "$nokeep"
  expect "keep: without the keep lines the kept spellings exit 1" rc_is 1
  while IFS='|' read -r path _rest; do
    expect "keep: $path is reported once its keep entry is gone" reports "$path" residue 1 'retired stem'
  done <<<"$KEPT_ROWS"
  expect_rows "look-alike without keep lines" residue <<<"$LOOKALIKE_ROWS"
}

c_custom_list() {
  local list="$T/custom-list.txt"
  make_kit custom
  new_repo custom
  fx "$list" '# retired-names:begin' '# env ZZQ_OLD_ENV' '# name zzqName' '# stem zzq word' \
    '# keep KEEP_ZZQ_WORD' '# retired-names:end'
  fx "$REPO/bin/c-env.sh" 'echo "$ZZQ_OLD_ENV"'
  fx "$REPO/bin/c-name.js" 'zzqName();'
  fx "$REPO/bin/c-stem.js" 'const fakeZzqWord = 1;'
  fx "$REPO/bin/c-keep.sh" 'echo "$KEEP_ZZQ_WORD"'
  fx "$REPO/bin/c-longer.sh" 'echo "$MY_ZZQ_OLD_ENV zzqNameX"'
  fx "$REPO/bin/c-default-only.sh" "echo \"\$$OLD_ENV\""
  commit_all "$REPO"
  run_gate "$KIT" --root "$REPO" --only residue --retired-names-from "$list"
  expect "custom list: exits 1" rc_is 1
  expect_rows "custom list" residue <<'TABLE'
bin/c-env.sh|env ZZQ_OLD_ENV@1
bin/c-name.js|name zzqName@1
bin/c-stem.js|stem zzq word@1
bin/c-keep.sh|accepted
bin/c-longer.sh|accepted
bin/c-default-only.sh|accepted
TABLE
  run_gate "$KIT" --root "$REPO" --only residue
  expect "default list: the built-in entry hits again" \
    reports "bin/c-default-only.sh" residue 1 "$(msg_of "env $OLD_ENV")"
  expect "default list: the custom entries are unknown" clean_for "bin/c-env.sh"
}

c_unreadable_list() {
  make_kit unreadable
  new_repo unreadable
  fx "$REPO/bin/clean.sh" 'true'
  commit_all "$REPO"
  fx "$T/no-markers.txt" '# name zzqName'
  fx "$T/no-end.txt" '# retired-names:begin' '# name zzqName'
  fx "$T/end-first.txt" '# retired-names:end' '# name zzqName' '# retired-names:begin'
  fx "$T/no-entry.txt" '# retired-names:begin' '# retired-names:end'
  fx "$T/keep-only.txt" '# retired-names:begin' '# keep KEEP_ZZQ_WORD' ': "a label"' '# retired-names:end'
  # Columns: list file under the temp root|what is wrong with it.
  local file what
  while IFS='|' read -r file what; do
    run_gate "$KIT" --root "$REPO" --only residue --retired-names-from "$T/$file"
    expect "unreadable: $what exits 2, never 0" rc_is 2
  done <<'TABLE'
absent-list.txt|a missing list file
no-markers.txt|a file without the marker lines
no-end.txt|an unterminated section
end-first.txt|a section whose end comes first
no-entry.txt|a section with no entry
keep-only.txt|a section with keep entries only
TABLE
  run_gate "$KIT" --root "$REPO" --only residue --retired-names-from
  expect "unreadable: the flag without a value exits 2" rc_is 2
  rm -f "$KIT/$SELF_REL"
  run_gate "$KIT" --root "$REPO" --only residue
  expect "unreadable: a missing default list exits 2" rc_is 2
}

c_rerun_stable() {
  make_kit rerun
  new_repo rerun
  seed "$REPO" BAD_ROWS 1
  seed "$REPO" LOOKALIKE_ROWS 1
  commit_all "$REPO"
  expect_rerun_stable "rerun" 1 "$REPO" "$KIT" --root "$REPO" --only residue
  expect "rerun: the fixture repo stays clean" test -z "$(git -C "$REPO" status --porcelain)"
}

c_hostile_text() {
  make_kit hostile
  new_repo hostile
  fx "$REPO/bin/\$(touch PWNED_A).sh" "echo \"\$$OLD_ENV\""
  fx "$REPO/bin/;touch PWNED_B;.sh" "echo \"\$$OLD_ENV\""
  fx "$REPO/bin/has space & amp.sh" "x=\`touch PWNED_C\`; y=\$(touch PWNED_D); echo \"\$$OLD_ENV2\""
  commit_all "$REPO"
  run_gate "$KIT" --root "$REPO" --only residue
  expect "hostile: the files are still read and reported (exit 1)" rc_is 1
  expect "hostile: the file with a space is reported" \
    reports "bin/has space & amp.sh" residue 1 "$(msg_of "env $OLD_ENV2")"
  expect "hostile: the substitution file is reported" \
    reports "bin/\$(touch PWNED_A).sh" residue 1 "$(msg_of "env $OLD_ENV")"
  expect "hostile: the separator file is reported" \
    reports "bin/;touch PWNED_B;.sh" residue 1 "$(msg_of "env $OLD_ENV")"
  expect "hostile: no file name or content was executed" no_marker_file
}

c_root_stays_inside() {
  make_kit inside
  new_repo inside
  fx "$REPO/bin/in.sh" "echo \"\$$OLD_ENV\""
  fx "$REPO/hooks/in.js" "const $OLD_NAME = 1;"
  commit_all "$REPO"
  fx "$T/repos/outside-leak.sh" "echo \"\$$OLD_ENV\""
  run_gate "$KIT" --root "$REPO/bin/.." --only residue
  expect "traversal: a root with dot-dot resolves to the same tree (exit 1)" rc_is 1
  expect "traversal: the inside file is reported" reports "bin/in.sh" residue 1
  expect "traversal: the other inside file is reported" reports "hooks/in.js" residue 1
  expect "traversal: no reported path climbs out" never_says "../"
  expect "traversal: the sibling of the root is not scanned" never_says "outside-leak"
  run_gate "$KIT" --root "$REPO" --only residue --scope "../"
  expect "traversal: a dot-dot scope matches nothing (exit 0)" rc_is 0
  expect "traversal: a scope never reports a file outside the root" test "${GATE_OUT/outside-leak/}" = "$GATE_OUT"
  run_gate "$KIT" --root "$T/repos/absent/../nowhere" --only residue
  expect "traversal: a root that does not exist exits 2" rc_is 2
}
