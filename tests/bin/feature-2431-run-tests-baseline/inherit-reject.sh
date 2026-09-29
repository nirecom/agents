# shellcheck shell=bash
# tests/bin/feature-2431-run-tests-baseline/inherit-reject.sh
# Tests: bin/run-tests-baseline
# Tags: run-tests, baseline, ledger, scope:issue-specific, pwsh-not-required, TL2
# Sourced by the dispatcher after ledger.sh (reuses mk_inherit_repo); never run standalone.
# Plan inheritance (b) needs: same host, B1 ancestor of B2, and no diff B1..B2 in
# `<T>` or `<dir>/` (T minus extension). Each case breaks exactly one condition.

# ir_seed_b1 <label> <repo> <cache> <t> — run at B1 so the ledger holds a fail record.
ir_seed_b1() {
  seed_failing "$1a-$$" "$4"
  rtb_cli_run "$3" "$2" "$1a-$$"
  printf '%s\n' "$RTB_CLI_OUT" | grep -qE "^BASELINE: preexisting[[:space:]]+$4"
}

# ir_expect_rejected <label> <repo> <cache> <t> — at the new base the test passes, so
# a refused inheritance re-runs and classifies broken (exit 1).
ir_expect_rejected() {
  seed_failing "$1b-$$" "$4"
  rtb_cli_run "$3" "$2" "$1b-$$"
  if printf '%s\n' "$RTB_CLI_OUT" | grep -qE "^BASELINE: broken[[:space:]]+$4" \
    && ! printf '%s\n' "$RTB_CLI_OUT" | grep -q "preexisting-inherited" \
    && [ "$RTB_CLI_RC" -eq 1 ]; then
    pass "$1: inheritance refused, re-run classifies broken"
  else
    fail "$1: expected broken without inheritance + exit 1, rc=$RTB_CLI_RC out=$(printf '%s' "$RTB_CLI_OUT" | grep '^BASELINE' | tr '\n' '|')"
  fi
}

run_ledger_inherit_reject_cases() {
  local id
  if [ ! -f "$BASELINE_CLI" ]; then
    for id in L8-non-descendant L8-subdir-changed L8-other-host; do
      fail "$id: bin/run-tests-baseline not found (impl pending)"
    done
    return
  fi
  local t="tests/bin/test-flag.sh" repo cache b1 b2 seg

  # ---- L8-non-descendant: new base B2 is a sibling of B1 (test file identical) ----
  repo="$TMPROOT/repo-ir-nd"; cache="$TMPROOT/cache-ir-nd"; mkdir -p "$cache"
  b1="$(mk_inherit_repo "$repo" | head -1)"
  if ir_seed_b1 irnd "$repo" "$cache" "$t"; then
    git -C "$repo" checkout -q -b side "$b1"
    printf 'x\n' > "$repo/flag-pass"
    git -C "$repo" add flag-pass
    git -C "$repo" commit -q -m "sibling base"
    # Rebuild main on a parentless B2 (B1's tree + flag-pass): unrelated to B1.
    b2="$(git -C "$repo" commit-tree "$(git -C "$repo" rev-parse 'side^{tree}')" -m B2-sibling)"
    git -C "$repo" branch -f main "$b2"
    git -C "$repo" checkout -q -B feature "$b2"
    printf 'feat2\n' > "$repo/feat2.txt"
    git -C "$repo" add feat2.txt
    git -C "$repo" commit -q -m "feature on sibling base"
    if git -C "$repo" merge-base --is-ancestor "$b1" "$b2" \
      || ! git -C "$repo" diff --quiet "$b1" "$b2" -- "$t"; then
      fail "L8-non-descendant: fixture error — B2 must be unrelated to B1 with $t unchanged"
    else
      ir_expect_rejected "L8-non-descendant" "$repo" "$cache" "$t"
    fi
  else
    fail "L8-non-descendant: seed run at B1 did not classify $t preexisting (rc=$RTB_CLI_RC)"
  fi

  # ---- L8-subdir-changed: only <dir>/ (tests/bin/test-flag/) changes between B1 and B2 ----
  repo="$TMPROOT/repo-ir-sd"; cache="$TMPROOT/cache-ir-sd"; mkdir -p "$cache"
  b1="$(mk_inherit_repo "$repo" | head -1)"
  if ir_seed_b1 irsd "$repo" "$cache" "$t"; then
    git -C "$repo" checkout -q main
    mkdir -p "$repo/tests/bin/test-flag"
    printf 'helper\n' > "$repo/tests/bin/test-flag/data.txt"
    printf 'x\n' > "$repo/flag-pass"
    git -C "$repo" add flag-pass tests/bin/test-flag/data.txt
    git -C "$repo" commit -q -m "B2 subdir change"
    git -C "$repo" checkout -q feature
    git -C "$repo" merge -q --no-edit main
    b2="$(git -C "$repo" rev-parse main)"
    if git -C "$repo" diff --quiet "$b1" "$b2" -- "$t" \
      && git -C "$repo" merge-base --is-ancestor "$b1" "$b2"; then
      ir_expect_rejected "L8-subdir-changed" "$repo" "$cache" "$t"
    else
      fail "L8-subdir-changed: fixture error — only tests/bin/test-flag/ may differ"
    fi
  else
    fail "L8-subdir-changed: seed run at B1 did not classify $t preexisting (rc=$RTB_CLI_RC)"
  fi

  # ---- L8-other-host: the B1 fail record belongs to a different host token ----
  repo="$TMPROOT/repo-ir-oh"; cache="$TMPROOT/cache-ir-oh"; mkdir -p "$cache"
  b1="$(mk_inherit_repo "$repo" | head -1)"
  if ir_seed_b1 iroh "$repo" "$cache" "$t"; then
    local rewritten=0 dir base
    while IFS= read -r seg; do
      [ -n "$seg" ] || continue
      dir="$(dirname "$seg")"; base="$(basename "$seg")"
      awk -F '\t' 'BEGIN { OFS = "\t" } { $3 = "otherhost9"; print }' "$seg" \
        > "$dir/otherhost9-${base#*-}"
      rm -f "$seg"
      rewritten=$((rewritten + 1))
    done < <(find "$cache/baseline" -path '*/worktrees' -prune -o -type f -name '*.seg' -print 2>/dev/null)
    advance_base "$repo" 0
    if [ "$rewritten" -ge 1 ]; then
      ir_expect_rejected "L8-other-host" "$repo" "$cache" "$t"
    else
      fail "L8-other-host: no ledger segment found to re-home"
    fi
  else
    fail "L8-other-host: seed run at B1 did not classify $t preexisting (rc=$RTB_CLI_RC)"
  fi
}

# ir_glob_repo <repo> — mk_inherit_repo plus a new B1 on main holding a test whose name has
# glob characters (fails unless ./flag-pass) and a sibling that name's glob would match.
# Prints B1.
ir_glob_repo() {
  mk_inherit_repo "$1" >/dev/null
  git -C "$1" checkout -q main
  printf '#!/usr/bin/env bash\n[ -f flag-pass ] && exit 0\nexit 1\n' > "$1/tests/bin/test-[a].sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$1/tests/bin/test-a.sh"
  chmod +x "$1/tests/bin/test-[a].sh" "$1/tests/bin/test-a.sh"
  git -C "$1" add -A tests
  git -C "$1" commit -q -m "B1 glob-named test"
  git -C "$1" rev-parse HEAD
  git -C "$1" checkout -q feature
  git -C "$1" merge -q --no-edit main >/dev/null
}

# ir_has_line <class> <path> — the CLI printed `BASELINE: <class> <path> ...`, compared literally.
ir_has_line() {
  printf '%s\n' "$RTB_CLI_OUT" | grep -qF "BASELINE: $1 $2 "
}

# L8-literal-glob-*: a test path with glob characters is a literal pathspec in both the file
# and the "$d/" directory form. B2 changes only the glob-matching sibling (inherit) or only
# the test's own data dir (refuse).
run_ledger_inherit_glob_cases() {
  local t="tests/bin/test-[a].sh" variant label repo cache b1 b2
  for variant in sibling datadir; do
    label="L8-literal-glob-$variant"
    repo="$TMPROOT/repo-ir-glob-$variant"; cache="$TMPROOT/cache-ir-glob-$variant"; mkdir -p "$cache"
    b1="$(ir_glob_repo "$repo" | head -1)"
    seed_failing "irg${variant}a-$$" "$t"
    rtb_cli_run "$cache" "$repo" "irg${variant}a-$$"
    if ! ir_has_line preexisting "$t"; then
      fail "$label: seed run at B1 did not classify $t preexisting (rc=$RTB_CLI_RC)"
      continue
    fi
    git -C "$repo" checkout -q main
    printf 'x\n' > "$repo/flag-pass"
    if [ "$variant" = sibling ]; then
      printf '# edited between B1 and B2\n' >> "$repo/tests/bin/test-a.sh"
    else
      mkdir -p "$repo/tests/bin/test-[a]"
      printf 'helper\n' > "$repo/tests/bin/test-[a]/data.txt"
    fi
    git -C "$repo" add -A .
    git -C "$repo" commit -q -m "B2 $variant change"
    git -C "$repo" checkout -q feature
    git -C "$repo" merge -q --no-edit main >/dev/null
    b2="$(git -C "$repo" rev-parse main)"
    seed_failing "irg${variant}b-$$" "$t"
    rtb_cli_run "$cache" "$repo" "irg${variant}b-$$"
    if [ "$variant" = sibling ]; then
      # Non-vacuity: a glob pathspec WOULD see test-a.sh as a change to test-[a].sh.
      if git -C "$repo" diff --quiet "$b1" "$b2" -- "$t"; then
        fail "$label: fixture error — glob pathspec must match the edited sibling"
      elif ir_has_line preexisting-inherited "$t" && [ "$RTB_CLI_RC" -eq 0 ]; then
        pass "$label: sibling edit ignored, B1 fail record inherited (literal pathspec)"
      else
        fail "$label: expected preexisting-inherited + exit 0, rc=$RTB_CLI_RC out=$(printf '%s' "$RTB_CLI_OUT" | grep '^BASELINE' | tr '\n' '|')"
      fi
    elif ir_has_line broken "$t" && ! ir_has_line preexisting-inherited "$t" && [ "$RTB_CLI_RC" -eq 1 ]; then
      pass "$label: a change under the glob-named \"\$d/\" dir refuses inheritance"
    else
      fail "$label: expected broken without inheritance + exit 1, rc=$RTB_CLI_RC out=$(printf '%s' "$RTB_CLI_OUT" | grep '^BASELINE' | tr '\n' '|')"
    fi
  done
}
