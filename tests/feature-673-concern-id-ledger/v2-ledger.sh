# tests/feature-673-concern-id-ledger/v2-ledger.sh
# Tests: bin/build-codex-context, bin/review-loop-verdict, bin/review-plan-codex, bin/run-codex-review-loop, bin/concern-ledger, bin/lib/concern-ledger.sh, bin/lib/concern-ledger/core.sh, bin/lib/concern-ledger/parse.sh, bin/lib/concern-ledger/reduce.sh
# Tags: worktree, codex, review, bin, env, scope:issue-specific
# Sourced by tests/feature-673-concern-id-ledger.sh (appended cases 14-18).

# Cases 1-13 of the parent file pin the *behaviour* of the plan-format loop and
# must keep passing unchanged — that equivalence is the acceptance condition for
# the reducer swap. The cases here pin what the swap adds on top: the on-disk
# ledger becomes the v2 schema, a v1 ledger is read and written back as v2, the
# round-2 admission policy stays closed with its current wording, and a round 1
# that meets a live ledger archives the previous cycle instead of discarding the
# round's concerns.

# The parent's helpers (setup_mock_env / setup_plans_dir / make_review_codex_mock
# / invoke / pass / fail) are reused; assert_eq is defined here because the
# parent has no assertion helper.

# Fixture isolation for everything below this point: the loop and anything it
# spawns must not resolve the developer's real workflow state.
V2_ISO="$(mktemp -d)"
mkdir -p "$V2_ISO/workflow" "$V2_ISO/plans"
export CLAUDE_WORKFLOW_DIR="$V2_ISO/workflow"
export WORKFLOW_PLANS_DIR="$V2_ISO/plans"
unset CLAUDE_SESSION_ID
unset CLAUDE_CODE_SESSION_ID

# Known-gap assertions for case 18's pipe-count boundary. The parent counts
# failures in ERRORS, so FAIL is opened here as the helper's own counter and
# folded back into ERRORS at the end of this file.
FAIL=0
# shellcheck source=../lib/xfail.sh
. "$AGENTS_WORKTREE/tests/lib/xfail.sh"

# assert_eq <label> <want> <got>
assert_eq() {
    if [[ "$2" == "$3" ]]; then
        pass "$1"
    else
        fail "$1 — want=$(printf '%q' "$2") got=$(printf '%q' "$3")"
    fi
}

# v2_header <ledger> → the first line, or 'no-file'
v2_header() { [[ -f "$1" ]] || { printf 'no-file'; return; }; head -n 1 "$1" 2>/dev/null; }

# v2_rows <ledger> → number of non-comment (data) lines
# (counted inside awk: `grep -c` exits 1 on a zero count, which would append a
#  second value through the `||` fallback.)
v2_rows() {
    [[ -f "$1" ]] || { printf 0; return; }
    awk '!/^#/ { n++ } END { printf "%d", n + 0 }' "$1" 2>/dev/null
}

# v2_rows_with_11 <ledger> → number of data lines carrying exactly 11 fields
v2_rows_with_11() {
    [[ -f "$1" ]] || { printf 0; return; }
    awk -F'|' '!/^#/ && NF == 11 { n++ } END { printf "%d", n + 0 }' "$1" 2>/dev/null
}

# v2_field <ledger> <id> <n> → field n of the row whose ID is <id>
v2_field() {
    [[ -f "$1" ]] || { printf 'no-file'; return; }
    awk -F'|' -v id="$2" -v n="$3" '!/^#/ && $1 == id { print $n; exit }' "$1" 2>/dev/null
}

# has_row <ledger> <id> → yes | no
has_row() {
    [[ -f "$1" ]] || { printf 'no'; return; }
    if awk -F'|' -v id="$2" '!/^#/ && $1 == id { found = 1 } END { exit !found }' "$1" 2>/dev/null; then
        printf 'yes'
    else
        printf 'no'
    fi
}

# ---------------------------------------------------------------------------
# 14. The ledger the plan loop writes at round 1 is v2: a schema header plus
#     11-field rows. (Cases 1-2 only require `^C1|HIGH|`, which a v1 3-field
#     row also satisfies — this is the case that tells the two apart.)
# ---------------------------------------------------------------------------
{
  TMP=$(mktemp -d); trap 'rm -rf "$TMP"' RETURN
  MOCK=$(setup_mock_env "$TMP")
  PLANS=$(setup_plans_dir "$TMP")
  LEDGER="$TMP/ledger.txt"
  make_review_codex_mock "$MOCK" "NEEDS_REVISION
1. [HIGH] the round 1 ledger must be written in the v2 schema
2. [MEDIUM] every row must carry all eleven fields"
  invoke "$MOCK" --format detail-plan --session-id sid14 --plans-dir "$PLANS" \
    --draft-file "$PLANS/draft.md" --cap 3 --max-extensions 2 --extensions-used 0 \
    --accepted-tradeoffs "$PLANS/outline.md" --round 1 --ledger "$LEDGER" >/dev/null 2>&1 || true

  assert_eq "14: the ledger opens with the v2 schema header" \
    "#concern-ledger-v2|detail-plan|sid14|cycle=1" "$(v2_header "$LEDGER")"
  # Composite: "0 of 0 rows are malformed" is not evidence of anything, and the
  # SEVERITY column alone is column 2 in v1 as well, so the row count, the
  # 11-field count and the per-column reads are asserted as one value.
  assert_eq "14: both concerns become 11-field rows with the v2 columns filled" \
    "rows=2 eleven=2 sev=HIGH state=open first=1" \
    "rows=$(v2_rows "$LEDGER") eleven=$(v2_rows_with_11 "$LEDGER") sev=$(v2_field "$LEDGER" C1 2) state=$(v2_field "$LEDGER" C1 3) first=$(v2_field "$LEDGER" C1 4)"
  assert_eq "14: the concern body lands in the last column" \
    "the round 1 ledger must be written in the v2 schema" \
    "$(awk -F'|' '$1 == "C1" { sub(/^([^|]*\|){10}/, ""); print; exit }' "$LEDGER" 2>/dev/null)"
}

# ---------------------------------------------------------------------------
# 15. A v1 ledger (3 fields, no header) is still readable at round 2 and is
#     written back in v2 form — the migration path for a session that started
#     before the reducer landed.
# ---------------------------------------------------------------------------
{
  TMP=$(mktemp -d); trap 'rm -rf "$TMP"' RETURN
  MOCK=$(setup_mock_env "$TMP")
  PLANS=$(setup_plans_dir "$TMP")
  LEDGER="$TMP/ledger.txt"
  printf 'C1|HIGH|original alpha\nC2|MEDIUM|original beta\n' > "$LEDGER"
  make_review_codex_mock "$MOCK" "NEEDS_REVISION
C1: unresolved — original alpha is still open"
  invoke "$MOCK" --format detail-plan --session-id sid15 --plans-dir "$PLANS" \
    --draft-file "$PLANS/draft.md" --cap 3 --max-extensions 2 --extensions-used 0 \
    --accepted-tradeoffs "$PLANS/outline.md" --round 2 --ledger "$LEDGER" >/dev/null 2>&1 || true

  assert_eq "15: the v1 input is written back with a v2 header" \
    "#concern-ledger-v2|detail-plan|sid15|cycle=1" "$(v2_header "$LEDGER")"
  # Composite: both carried-over rows must be upgraded, not just the one the
  # reviewer mentioned — a single migrated row would otherwise pass.
  assert_eq "15: both v1 rows survive the migration as 11-field rows" \
    "rows=2 eleven=2" "rows=$(v2_rows "$LEDGER") eleven=$(v2_rows_with_11 "$LEDGER")"
  assert_eq "15: the round the reviewer re-raised C1 in is recorded" \
    "state=open last=2" \
    "state=$(v2_field "$LEDGER" C1 3) last=$(v2_field "$LEDGER" C1 5)"
  assert_eq "15: the unmentioned C2 is closed out, not dropped" \
    "present=yes state=resolved" \
    "present=$(has_row "$LEDGER" C2) state=$(v2_field "$LEDGER" C2 3)"
  assert_eq "15: the v1 body text is carried into the v2 row" \
    "original alpha" \
    "$(awk -F'|' '$1 == "C1" { sub(/^([^|]*\|){10}/, ""); print; exit }' "$LEDGER" 2>/dev/null)"
}

# ---------------------------------------------------------------------------
# 16. The plan formats keep a *closed* admission policy from round 2 on: an ID
#     the reviewer invented is discarded rather than numbered, and the stderr
#     wording is the one the current wrapper already emits.
# ---------------------------------------------------------------------------
{
  TMP=$(mktemp -d); trap 'rm -rf "$TMP"' RETURN
  MOCK=$(setup_mock_env "$TMP")
  PLANS=$(setup_plans_dir "$TMP")
  LEDGER="$TMP/ledger.txt"
  printf 'C1|HIGH|original alpha\n' > "$LEDGER"
  make_review_codex_mock "$MOCK" "NEEDS_REVISION
C1: unresolved — original alpha is still open
C99: unresolved — an identifier the reviewer invented"
  ERRFILE="$TMP/stderr.txt"
  invoke "$MOCK" --format detail-plan --session-id sid16 --plans-dir "$PLANS" \
    --draft-file "$PLANS/draft.md" --cap 3 --max-extensions 2 --extensions-used 0 \
    --accepted-tradeoffs "$PLANS/outline.md" --round 2 --ledger "$LEDGER" \
    >/dev/null 2>"$ERRFILE" || true

  WARNED=no
  grep -Fq 'discarded new concern IDs in round 2: C99' "$ERRFILE" 2>/dev/null && WARNED=yes
  # Composite: an empty ledger would satisfy "C99 is absent" on its own, so the
  # warning, the absence of C99 and the presence of C1 are asserted together.
  assert_eq "16: round 2 admission is closed — C99 is discarded and announced" \
    "warned=yes c99=no c1=yes" \
    "warned=$WARNED c99=$(has_row "$LEDGER" C99) c1=$(has_row "$LEDGER" C1)"
  assert_eq "16: no ID is minted for the discarded concern" \
    "rows=1" "rows=$(v2_rows "$LEDGER")"
}

# ---------------------------------------------------------------------------
# 17. Round 1 arriving on top of a live ledger is a new cycle, not a discard:
#     the previous cycle is archived beside the ledger and this round's concerns
#     are admitted normally.
# ---------------------------------------------------------------------------
{
  TMP=$(mktemp -d); trap 'rm -rf "$TMP"' RETURN
  MOCK=$(setup_mock_env "$TMP")
  PLANS=$(setup_plans_dir "$TMP")
  LEDGER="$TMP/ledger.txt"
  ARCHIVE="$TMP/ledger-cycle1.txt"
  OLD_TEXT="a concern left open by the previous cycle"
  NEW_TEXT="a concern raised by the first round of the new cycle"
  {
    printf '#concern-ledger-v2|detail-plan|sid17|cycle=1\n'
    printf 'C1|HIGH|open|1|2|detail-plan#draft:correctness|a1b2c3|review-plan-codex|review-plan-codex|-|%s\n' \
      "$OLD_TEXT"
  } > "$LEDGER"
  make_review_codex_mock "$MOCK" "NEEDS_REVISION
1. [HIGH] $NEW_TEXT"
  ERRFILE="$TMP/stderr.txt"
  invoke "$MOCK" --format detail-plan --session-id sid17 --plans-dir "$PLANS" \
    --draft-file "$PLANS/draft.md" --cap 3 --max-extensions 2 --extensions-used 0 \
    --accepted-tradeoffs "$PLANS/outline.md" --round 1 --ledger "$LEDGER" \
    >/dev/null 2>"$ERRFILE" || true

  ARCHIVED=no; [[ -s "$ARCHIVE" ]] && ARCHIVED=yes
  ADMITTED=no; grep -Fq -- "$NEW_TEXT" "$LEDGER" 2>/dev/null && ADMITTED=yes
  DISCARDED=no
  grep -Fq 'discarded new concern IDs' "$ERRFILE" 2>/dev/null && DISCARDED=yes
  CARRIED=no; grep -Fq -- "$OLD_TEXT" "$LEDGER" 2>/dev/null && CARRIED=yes
  # Composite: "nothing was discarded" and "the old concern is gone from the
  # live ledger" are both trivially true of a plain overwrite, so all four
  # observations are asserted as one value.
  assert_eq "17: round 1 on a live ledger opens a new cycle instead of discarding" \
    "archived=yes admitted=yes discarded=no carried=no" \
    "archived=$ARCHIVED admitted=$ADMITTED discarded=$DISCARDED carried=$CARRIED"
  assert_eq "17: the archive holds the previous cycle's open concern" \
    "yes" "$(grep -Fq -- "$OLD_TEXT" "$ARCHIVE" 2>/dev/null && printf yes || printf no)"
  assert_eq "17: the fresh ledger is stamped as the second cycle" \
    "#concern-ledger-v2|detail-plan|sid17|cycle=2" "$(v2_header "$LEDGER")"
}

# ---------------------------------------------------------------------------
# 18. The v1 -> v2 read boundary. cl_read_v1_or_v2 tells the two schemas apart
#     by counting '|' separators, and v1's TEXT is free-form prose that may
#     legitimately contain pipes. Every separator count below the v2 arity must
#     promote as v1 with its prose intact, or a reviewer who quotes a table row
#     silently loses the tail of their own finding.
# ---------------------------------------------------------------------------
{
  TMP=$(mktemp -d); trap 'rm -rf "$TMP"' RETURN
  PROBE_OUT="$TMP/probe.out"

  # One v1 row per probe, its TEXT carrying <n> literal pipes. Emitted as
  # '<n>|<separator-count-of-the-result>|<the-result-row>'.
  (
    set +u
    source "$AGENTS_WORKTREE/bin/lib/concern-ledger.sh" >/dev/null 2>&1 || exit 127
    for n in 0 1 7 8 9; do
      text="head"
      for ((i = 0; i < n; i++)); do text="$text|seg$i"; done
      printf 'C1|HIGH|%s\n' "$text" > "$TMP/led.txt"
      out="$(cl_read_v1_or_v2 "$TMP/led.txt" 3 | head -n1)"
      seps="${out//[^|]/}"
      printf '%s|%s|%s\n' "$n" "${#seps}" "$out"
    done
  ) > "$PROBE_OUT" 2>/dev/null

  # p_seps / p_state / p_text — columns of the result row for a given <n>.
  p_seps()  { grep -m1 -- "^$1|" "$PROBE_OUT" 2>/dev/null | cut -d'|' -f2; }
  p_state() { grep -m1 -- "^$1|" "$PROBE_OUT" 2>/dev/null | cut -d'|' -f5; }
  p_text()  { grep -m1 -- "^$1|" "$PROBE_OUT" 2>/dev/null | cut -d'|' -f13-; }

  # want_text <n> — the TEXT that went in.
  want_text() {
    local t="head" i
    for ((i = 0; i < $1; i++)); do t="$t|seg$i"; done
    printf '%s' "$t"
  }

  assert_eq "18: the reader produced a row for every probe" \
    "5" "$(grep -c '^[0-9]*|' "$PROBE_OUT" 2>/dev/null || printf 0)"

  # The requirement, stated once for the whole domain: a v1 row promotes to a
  # well-formed v2 row whatever its prose contains — 10 structural separators
  # plus however many the prose carries, state 'open', and the TEXT byte-identical.
  # Which schema a line belongs to is decided by validated structure (the header
  # and the state enum), never by counting separators, because prose is free to
  # hold as many as it likes.

  # probe_row <n> — the observed triple for a pipe count, as one comparable string.
  probe_row() { printf '%s %s %s' "$(p_seps "$1")" "$(p_state "$1")" "$(p_text "$1")"; }
  want_row()  { printf '%s open %s' "$((10 + $1))" "$(want_text "$1")"; }

  # Table-driven over the whole boundary. The 'pin' column names the cases the
  # separator-count heuristic gets wrong today; they assert the same correct
  # expectation as their siblings, pinned rather than weakened (see xfail.sh).
  while read -r N PIN; do
    [ -n "$N" ] || continue
    if [ "$PIN" = "pinned" ]; then
      xfail_eq "18: a v1 TEXT with $N pipes round-trips through the v2 promotion" \
        "$(want_row "$N")" "$(probe_row "$N")"
    else
      assert_eq "18: a v1 TEXT with $N pipes round-trips through the v2 promotion" \
        "$(want_row "$N")" "$(probe_row "$N")"
    fi
  done <<'PIPES'
0 ok
1 ok
7 ok
8 pinned
9 pinned
PIPES

  # The discriminator itself. Field 3 of a real v2 row is a state enum, so a
  # line whose field 3 is prose is not a v2 row no matter how many separators it
  # carries — this is the structural check the heuristic is missing.
  GAP8="$(p_state 8)"
  IS_STATE=no
  case "$GAP8" in open|resolved) IS_STATE=yes ;; esac
  assert_eq "18: a misread v1 row fails the v2 state-enum invariant" "no" "$IS_STATE"

  # And the header is the other half of the same discriminator: the probe file
  # carries no '#concern-ledger-v2' line, so every row in it is v1 by construction.
  assert_eq "18: the probe ledger declares no v2 header, so its rows are v1 by construction" \
    "0" "$(awk '/^#concern-ledger-v2/ { n++ } END { printf "%d", n + 0 }' "$TMP/led.txt" 2>/dev/null)"
}

xfail_summary
# Fold the xfail helper's XPASS failures into the parent's counter.
ERRORS=$((ERRORS + FAIL))

rm -rf "$V2_ISO"
