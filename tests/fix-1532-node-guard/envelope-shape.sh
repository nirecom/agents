# Part of tests/fix-1532-node-guard-*.sh (sourced, not standalone).
# Tests: bin/get-config-var, bin/confirm-off, bin/resolve-session-id, bin/resolve-worktree-path, bin/is-github-dotcom-remote
# Tags: bin, polyglot-guard, envelope-shape, orthogonality, scope:issue-specific, pwsh-not-required, TL2

# G1-G6: the CROSS-TARGET checks. These always look at all five targets, whichever
# single dispatcher is running, because the property they defend is that the five
# agree (CPR-ORTH) — a per-target view cannot see disagreement at all.

echo "=== G: envelope shape, across all five targets ==="

G_TMP="$TESTTMP/envelope-shape"
mkdir -p "$G_TMP"

# ---- G1: the head and the tail are byte-identical in all five ---------------
# The envelope names no script, so the 12 head lines and the 2 tail lines are the
# same bytes everywhere. That is what makes "applied to four of five" and "one file
# drifted" mechanically visible; without it the omission is invisible until a node
# misinvocation happens in production.
g1_isomorphic() {
  local t f n ref_head="" ref_tail="" missing="" absent=""
  for t in $TARGETS; do
    f="$(target_path "$t")"
    if [ ! -f "$f" ]; then missing="$missing $t"; continue; fi
    envelope_present "$f" || { absent="$absent $t"; continue; }
    n="$(wc -l < "$f" | tr -d ' ')"
    sed -n "2,$((HEAD_LINES + 1))p" "$f" > "$G_TMP/$t.head"
    sed -n "$((n - TAIL_LINES + 1)),${n}p" "$f" > "$G_TMP/$t.tail"
    [ -n "$ref_head" ] || { ref_head="$G_TMP/$t.head"; ref_tail="$G_TMP/$t.tail"; }
  done
  if [ -n "$missing" ]; then
    fail "G1a: every target exists under bin/ -- missing:$missing"
    return 0
  fi
  if [ -n "$absent" ]; then
    fail "G1a: every target carries the #1532 guard envelope -- not inserted yet in:$absent (head line 2 must be exactly the guard's opening line and the 2nd-from-last line must start with the tail marker)"
    return 0
  fi
  pass "G1a: every target carries the #1532 guard envelope"
  for t in $TARGETS; do
    if cmp -s "$ref_head" "$G_TMP/$t.head"; then
      pass "G1b[$t]: the ${HEAD_LINES}-line head block is byte-identical to the reference target"
    else
      fail "G1b[$t]: the ${HEAD_LINES}-line head block differs from the reference target -- the five must be edited together (CPR-ORTH)"
    fi
    if cmp -s "$ref_tail" "$G_TMP/$t.tail"; then
      pass "G1c[$t]: the ${TAIL_LINES}-line tail block is byte-identical to the reference target"
    else
      fail "G1c[$t]: the ${TAIL_LINES}-line tail block differs from the reference target -- the five must be edited together (CPR-ORTH)"
    fi
  done
  # Marker set. Pins the DESIGN, not just the agreement: an envelope that reverted
  # to process.stderr.write + process.exit would still be isomorphic across five
  # files and still lose the diagnostic on an asynchronous stderr. The two absence
  # assertions are the ones that catch that revert at the literal level.
  g1_marker "$ref_head" "the guard's opening line" "$ENVELOPE_FIRST_LINE" present
  g1_marker "$ref_head" "the quoted here-document delimiter" "$ENVELOPE_DELIMITER" present
  g1_marker "$ref_head" "the JavaScript block-comment opener" '/*' present
  g1_marker "$ref_head" "the natural-exit code assignment" "process.exitCode = $GUARD_EXIT_CODE;" present
  g1_marker "$ref_head" "the synchronous fd-2 write" 'writeSync(2,' present
  g1_marker "$ref_head" "no forced process.exit(" 'process.exit(' absent
  g1_marker "$ref_head" "no asynchronous process.stderr.write" 'process.stderr.write' absent
}

g1_marker() { # <head-file> <label> <needle> present|absent
  local hf="$1" label="$2" needle="$3" want="$4" got="absent"
  grep -qF -- "$needle" "$hf" && got="present"
  check "G1d: the head block carries $label" "$want" "$got"
}

# ---- G1e/G1f: the geometry constants are pinned to the real files -----------
# Every other row reads HEAD_LINES/TAIL_LINES/ENVELOPE_LINES and trusts them.
# envelope_present() only checks line 2 and the tail marker, and G1b compares the
# five head slices against EACH OTHER -- so a stale HEAD_LINES cuts the same wrong
# slice in all five files and every row stays green while the constant lies.
# G1e is the independent pin: line HEAD_LINES+1 must be the here-document
# delimiter, which is the real end of the head block.
g1e_head_boundary() {
  local t f got
  for t in $TARGETS; do
    f="$(target_path "$t")"
    if [ ! -f "$f" ]; then
      fail "G1e[$t]: line $((HEAD_LINES + 1)) is the here-document delimiter -- file is missing"
      continue
    fi
    got="$(sed -n "$((HEAD_LINES + 1))p" "$f")"
    check "G1e[$t]: line $((HEAD_LINES + 1)) is exactly the here-document delimiter (this is what pins HEAD_LINES to the real end of the head block)" "$ENVELOPE_DELIMITER" "$got"
  done
}

# G1f: ENVELOPE_LINES is used by bash-invariance.sh B0 as the stripped-twin line
# delta, but nothing forced it to stay consistent with the two constants it is
# derived from. Editing HEAD_LINES without ENVELOPE_LINES would otherwise pass here
# and mis-measure there.
g1f_envelope_total() {
  check "G1f: ENVELOPE_LINES equals HEAD_LINES + TAIL_LINES" "$((HEAD_LINES + TAIL_LINES))" "$ENVELOPE_LINES"
}

# ---- G2: node parses every target as JavaScript -----------------------------
g2_node_check() {
  local t f rc
  # Missing node is a precondition failure, not a skip -- see require_node.
  require_node "G2" || return 0
  for t in $TARGETS; do
    f="$(target_path "$t")"
    run_with_timeout 30 node --check "$f" >/dev/null 2>&1
    rc=$?
    check "G2[$t]: node --check parses the file (a bash body outside the block comment makes this fail)" "0" "$rc"
  done
}

# ---- G3: the body never closes the block comment early ----------------------
# Redundant with G2 by construction, and kept anyway: G2 fails with a JavaScript
# parse error that says nothing about WHY, while this row names the rule that was
# broken and the file that broke it.
g3_syntax_reservation() {
  local t f n
  for t in $TARGETS; do
    f="$(target_path "$t")"
    n="$(body_text "$f" | grep -cF -- '*/' || true)"
    check "G3[$t]: the script body contains no JavaScript block-comment terminator" "0" "$n"
  done
}

# ---- G4: negative control for G2 --------------------------------------------
# G2 asserts a zero exit code, and an assertion that can only ever see zero is not
# an assertion. Inject the forbidden two characters into a copy of the body and
# require node --check to reject it.
g4_negative_control() {
  local t f copy rc
  require_node "G4" || return 0
  t="${TARGETS%% *}"
  f="$(target_path "$t")"
  copy="$G_TMP/negative-control"
  # The injected line must land INSIDE the block comment, i.e. in the body — a line
  # placed above the head would be rejected for being bash rather than for the two
  # characters under test, and the control would prove the wrong thing.
  if envelope_present "$f"; then
    { sed -n "1,$((HEAD_LINES + 1))p" "$f"
      printf 'true # */ injected terminator\n'
      sed -n "$((HEAD_LINES + 2)),\$p" "$f"; } > "$copy"
  else
    { cat "$f"; printf 'true # */ injected terminator\n'; } > "$copy"
  fi
  run_with_timeout 30 node --check "$copy" >/dev/null 2>&1
  rc=$?
  if [ "$rc" -eq 0 ]; then
    fail "G4: node --check rejects a body line carrying the block-comment terminator -- it accepted one, so G2 proves nothing"
  else
    pass "G4: node --check rejects a body line carrying the block-comment terminator"
  fi
}

# ---- G5: the execute bit survives the envelope insertion --------------------
g5_exec_bit() {
  local t mode
  for t in $TARGETS; do
    mode="$(git -C "$REPO_ROOT" ls-files -s -- "bin/$t" 2>/dev/null | awk '{print $1}')"
    check "G5[$t]: the command is recorded 100755 in the git index" "100755" "${mode:-untracked}"
  done
}

# ---- G6: test selection coverage (the pin for the 5-dispatcher decision) ----
# bin/select-tests.sh Tier 1 turns a changed `bin/<name>` into the stem `<name>` and
# selects any tests/*.sh whose FILENAME contains that stem — frontmatter is never
# read there. So the guarantee "editing any one of the five selects a test that
# checks it" lives entirely in the dispatcher filenames, and this row is what keeps
# a sixth target from being added without its dispatcher.
g6_selection_coverage() {
  local t d base missing="" orphan=""
  for t in $TARGETS; do
    d="$REPO_ROOT/tests/fix-1532-node-guard-$t.sh"
    if [ ! -f "$d" ]; then
      missing="$missing $t"
    else
      case "fix-1532-node-guard-$t.sh" in
        *"$t"*) ;;
        *) missing="$missing $t(stem-mismatch)" ;;
      esac
    fi
  done
  check "G6a: every entry in TARGETS has a top-level dispatcher whose filename contains its stem" "" "${missing# }"
  for d in "$REPO_ROOT"/tests/fix-1532-node-guard-*.sh; do
    [ -f "$d" ] || continue
    base="$(basename "$d" .sh)"
    base="${base#fix-1532-node-guard-}"
    case " $TARGETS " in
      *" $base "*) ;;
      *) orphan="$orphan $base" ;;
    esac
  done
  check "G6b: every fix-1532-node-guard-*.sh dispatcher corresponds to an entry in TARGETS" "" "${orphan# }"
}

# ---- G6c: each dispatcher checks the target its own FILENAME advertises ------
# G6a/G6b only weigh filenames against TARGETS. The selection guarantee actually
# has two links: select-tests picks the file by its stem, and the file then sets
# GUARD_TARGET. A copy-paste that left GUARD_TARGET on the file it was copied from
# keeps both links individually plausible while editing bin/<X> silently runs the
# suite against bin/<Y> -- and every row would be green (review round 3, C2).
g6c_guard_target_matches_stem() {
  local d base decl val n
  for d in "$REPO_ROOT"/tests/fix-1532-node-guard-*.sh; do
    [ -f "$d" ] || continue
    base="$(basename "$d" .sh)"
    base="${base#fix-1532-node-guard-}"
    n="$(grep -c '^GUARD_TARGET=' "$d" || true)"
    check "G6c[$base]: the dispatcher assigns GUARD_TARGET exactly once" "1" "$n"
    [ "$n" = "1" ] || continue
    decl="$(grep -m1 '^GUARD_TARGET=' "$d")"
    val="${decl#GUARD_TARGET=}"
    # Tolerate quoting in the declaration, nothing else.
    val="${val%\"}"; val="${val#\"}"
    val="${val%\'}"; val="${val#\'}"
    check "G6d[$base]: GUARD_TARGET equals the stem of the dispatcher's own filename" "$base" "$val"
  done
}

g1_isomorphic
g1e_head_boundary
g1f_envelope_total
g2_node_check
g3_syntax_reservation
g4_negative_control
g5_exec_bit
g6_selection_coverage
g6c_guard_target_matches_stem
