#!/usr/bin/env bash
# tests/bin/feature-2631-review-size-bins/records-integrity.sh — the size-check record-integrity
# bodies of tests/bin/feature-2631-review-size-bins.sh (case markers stay in the entry file).
# Sourced after the entry defines ROOT, TMP_ROOT, TABLE, build_tree, run_bin, scenario, judge and
# make_lines. A bin must not trust a record stream that a file name can forge, nor a size-check
# whose exit code and HARD records disagree: both are fail-closed rc 2, never a silent pass.

RI_DISAGREE="bin/size-check exit code and HARD records disagree"

# ri_code_hard — the code HARD limit, read from the SSOT (never hard-coded here).
ri_code_hard() {
  local limits
  limits="$(node "$ROOT/bin/print-size-limits" --get code)" || return 1
  printf '%s' "${limits##* }"
}

# ri_case_forged_targets_line — an index-only over-HARD blob whose name carries
# "\nTARGETS\t0\n": the forged line must not reset the count and turn the run into "no targets".
ri_case_forged_targets_line() {
  local hard repo blob name nl=$'\n' tab=$'\t'
  if ! hard="$(ri_code_hard)" || [ -z "$hard" ]; then
    fail "premise: bin/print-size-limits --get code gives the code HARD limit" "got '$hard'"
    return 0
  fi
  repo="$(new_repo)"
  make_lines $((hard + 1)) forged > "$TMP_ROOT/forged-body"
  blob="$(git -C "$repo" hash-object -w -- "$TMP_ROOT/forged-body")"
  name="bin/f${nl}TARGETS${tab}0${nl}x.js"
  # Git for Windows rejects a control character in an index path under core.protectNTFS (default on
  # there); the blob lives only in the index, so no file system ever has to hold the name.
  git -C "$repo" config core.protectNTFS false
  if ! git -C "$repo" update-index --add --cacheinfo "100644,$blob,$name" 2>/dev/null; then
    skip "forged TARGETS line — git refused an index path holding a newline here"
    return 0
  fi
  pass "premise: the index holds the newline-named over-HARD blob"
  run_bin "$TREE" "$repo" review-code-size --staged
  if [ "$RC" = 0 ] || printf '%s\n' "$OUT" | grep -q 'no code files staged'; then
    fail "forged TARGETS line in a file name does not turn the run into rc 0 / no targets" \
      "rc=$RC out=$(printf '%s' "$OUT" | head -c 400)"
  elif [ "$RC" = 1 ] && printf '%s\n' "$OUT" | grep -q 'HARD:'; then
    pass "forged TARGETS line: the over-HARD blob is still judged HARD (rc 1)"
  elif [ "$RC" = 2 ] && printf '%s\n' "$OUT" | grep -q 'ERROR'; then
    pass "forged TARGETS line: the forged record stream fails closed (ERROR, rc 2)"
  else
    fail "forged TARGETS line: rc 1 with a HARD line or ERROR rc 2" "rc=$RC out=$(printf '%s' "$OUT" | head -c 400)"
  fi
}

# ri_stub_tree <dir> <rc> <verdict> — a tree whose bin/size-check prints one TARGETS line and one
# <verdict> record for $RI_STUB_PATH, then exits <rc>.
ri_stub_tree() {
  local dir="$1" rc="$2" verdict="$3"
  build_tree "$dir" >/dev/null
  printf '#!/usr/bin/env node\nconst p = process.env.RI_STUB_PATH || "bin/stub.js";\nprocess.stdout.write("TARGETS\\t1\\n%s\\t900\\t10\\t300\\t500\\tlines\\t" + p + "\\n");\nprocess.exit(%s);\n' \
    "$verdict" "$rc" > "$dir/bin/size-check"
  chmod +x "$dir/bin/size-check"
  printf '%s' "$dir"
}

# ri_case_disagree <label> <rc> <verdict> — every bin, every mode: size-check's exit code and its
# HARD records disagree, so the bin reports the disagreement and exits 2.
ri_case_disagree() {
  local label="$1" tree row bin mode path hard repo
  tree="$(ri_stub_tree "$TMP_ROOT/stub-$label" "$2" "$3")"
  for row in "${TABLE[@]}"; do
    IFS='|' read -r bin mode path hard <<<"$row"
    repo="$(scenario "$mode" - make_lines 10 "$path")"
    export RI_STUB_PATH="$path"
    judge "$tree" "$bin" "$mode" "$repo"
    unset RI_STUB_PATH
    if [ "$RC" = 2 ] && printf '%s\n' "$OUT" | grep -qF ": ERROR — $RI_DISAGREE"; then
      pass "$bin $mode: size-check $label -> rc 2 '<hdr>: ERROR — $RI_DISAGREE'"
    else
      fail "$bin $mode: size-check $label -> rc 2 '<hdr>: ERROR — $RI_DISAGREE'" \
        "rc=$RC out=$(printf '%s' "$OUT" | head -c 400)"
    fi
  done
}

# ri_case_no_targets_line — every bin, every mode: a size-check that exits 0 but prints no TARGETS
# line has not reported a count, so the bin fails closed (rc 2) instead of reading "no targets".
ri_case_no_targets_line() {
  local tree="$TMP_ROOT/stub-no-targets" row bin mode path hard repo
  build_tree "$tree" >/dev/null
  printf '#!/usr/bin/env node\nprocess.exit(0);\n' > "$tree/bin/size-check"
  chmod +x "$tree/bin/size-check"
  for row in "${TABLE[@]}"; do
    IFS='|' read -r bin mode path hard <<<"$row"
    repo="$(scenario "$mode" - make_lines 10 "$path")"
    judge "$tree" "$bin" "$mode" "$repo"
    if [ "$RC" = 2 ] && printf '%s\n' "$OUT" | grep -q 'ERROR'; then
      pass "$bin $mode: size-check rc 0 with no TARGETS line -> rc 2 ERROR"
    else
      fail "$bin $mode: size-check rc 0 with no TARGETS line -> rc 2 ERROR" \
        "rc=$RC out=$(printf '%s' "$OUT" | head -c 400)"
    fi
  done
}
