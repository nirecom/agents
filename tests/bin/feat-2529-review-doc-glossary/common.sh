# tests/bin/feat-2529-review-doc-glossary/common.sh
# Shared fixture of the #2529 glossary gate tests: fixture repo, glossary builders,
# the gate driver and its assertions. Sourced after the pins by
# tests/bin/feat-2529-review-doc-glossary.sh, tests/bin/feat-2529-review-doc-glossary-ranges.sh and
# tests/bin/feat-2529-review-doc-glossary-index.sh.

GATE="$SCRIPT_CHECKOUT_ROOT/bin/review-doc-glossary"
REPO=""
REPO_SEQ=0

# new_repo — fresh fixture git repo with one baseline commit; sets REPO.
new_repo() {
  REPO_SEQ=$((REPO_SEQ + 1))
  REPO="$T/repo-$REPO_SEQ"
  mkdir -p "$REPO/docs/glossary"
  harness_git_init "$REPO"
  git -C "$REPO" config core.autocrlf false
  git -C "$REPO" config user.email "test@example.com"
  git -C "$REPO" config user.name "test"
  printf 'baseline\n' > "$REPO/.seed"
  git -C "$REPO" add .seed
  git -C "$REPO" commit -q -m baseline
}

# gloss_head <file> — H1 + one-line intro, no entries.
gloss_head() {
  mkdir -p "$(dirname "$1")"
  printf '# Glossary\n\nFixture glossary for the #2529 gate tests.\n\n' > "$1"
}

# entry <term> — one valid entry block.
entry() {
  printf '### %s\n- **Definition**: %s is a fixture term.\n- **Related**: [owner](architecture/owner.md)\n\n' "$1" "$1"
}

# gloss <file> <term>... — a valid glossary file holding the terms in the given order.
gloss() {
  local f="$1" t
  shift
  gloss_head "$f"
  for t in "$@"; do entry "$t" >> "$f"; done
}

stage() {
  local r="$1"
  shift
  git -C "$r" add -- "$@"
}

commit_all() {
  git -C "$1" add -A
  git -C "$1" commit -q -m fixture
}

# prose_edit <file> — rewrite only the intro line; the term set and every definition stay.
prose_edit() {
  sed 's/^Fixture glossary for the #2529 gate tests\.$/Fixture glossary for the #2529 gate tests (edited)./' "$1" > "$1.tmp"
  mv "$1.tmp" "$1"
}

# stage_as_prose_edit <repo> <relpath>... — commit the files as written, then stage an
# intro-prose edit of each. A pass case staged this way carries zero term operations, so
# the glossary provenance check the gate runs after the format check (#2529) has nothing to block
# and the case stays about form.
stage_as_prose_edit() {
  local r="$1" f
  shift
  commit_all "$r"
  for f in "$@"; do prose_edit "$r/$f"; done
  stage "$r" "$@"
}

# run_gate <repo> <args...> — sets GATE_OUT / GATE_RC; a missing gate fails loudly (RED).
run_gate() {
  local r="$1"
  shift
  if [[ ! -f "$GATE" ]]; then
    GATE_OUT="TOOL NOT FOUND: bin/review-doc-glossary (not yet implemented, #2529)"
    GATE_RC=127
    return 0
  fi
  GATE_RC=0
  GATE_OUT="$(cd "$r" && run_with_timeout 120 bash "$GATE" "$@" 2>&1)" || GATE_RC=$?
}

expect_rc() {
  if [[ "$GATE_RC" == "$2" ]]; then pass "$1 (rc=$2)"
  else fail "$1" "want rc=$2 got rc=$GATE_RC; output: ${GATE_OUT:0:600}"; fi
}

expect_out() {
  if [[ "$GATE_OUT" == *"$2"* ]]; then pass "$1 (output has [$2])"
  else fail "$1" "expected [$2] in output: ${GATE_OUT:0:600}"; fi
}
