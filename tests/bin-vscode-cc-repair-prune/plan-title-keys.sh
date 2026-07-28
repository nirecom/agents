# Part of tests/bin-vscode-cc-repair-prune.sh (sourced, not standalone).
# Tests: bin/lib/vscode-cc-repair/prune/execute.js, bin/lib/vscode-cc-repair/prune.js
# Tags: bin, vscode, prune, execute, security, type-safety, title-keys, session-files, scope:common, pwsh-not-required, TL2
#
# M6-M9 — the LAST raw dereference of a caller-supplied plan field: `decision.titleKeys`.
#
# Sourced after plan-raw-deref.sh: the drivers (deref_case / deref_batch /
# deref_batch_fixture) and the fixture helpers (guard_fixture / guard_survives) are defined
# there and in execute-guard.sh, and this file only adds rows to the same class.
#
# THE SITE. `sameKeys(fresh.titleKeys, decision.titleKeys)` is reached on the ONE condition
# that the file on disk is still a stub — no other guard stands in front of it, because it
# sits ABOVE the isCounterpartPath call that the containment and identity rows are about.
# sameKeys builds `new Set(b || [])`, and `||` rescues falsy values only: every TRUTHY
# non-iterable reaches the Set constructor and throws `TypeError: X is not iterable`, out of
# executePrunePlan, out of the whole batch. A string is the quiet variant — it IS iterable,
# so `'ab'` becomes the two-element set {a, b} and compares silently wrong.
#
# The consequence is the one L02/M03 already ruled unacceptable: the throw escapes with
# earlier entries in the batch already renamed, no tally is returned, and the report cannot
# name the files it just displaced.
#
# WHAT IS OWED, AND WHY NOT COERCION. The planner puts a Set of titleKey() strings here on
# every path it can take (prune.js:137/175/194/220); it never produces undefined, null, or
# anything else. So a non-iterable is a CALLER error and belongs in `failed` with the other
# malformed-plan outcomes (J04), NOT coerced to the empty set: an empty set means "a stub
# carrying no titles", which is a claim about the DISK, and letting a malformed field spell
# it makes a forged plan indistinguishable from an observation. It must not be answered
# `changed:stub-changed` either — that reason means "the file moved under us", a race
# correctly refused, and a caller error dressed as a race invites a pointless re-run.
#
# `failed:not-a-title-set` is therefore its own reason: `not-a-session-file` and
# `not-a-counterpart` both accuse a PATH, and here the path is beyond reproach — a genuine
# session file, in the right root, with a genuine counterpart. Only the evidence the I4
# comparison would have been made against is malformed.
#
# The type coverage is TABLE-DRIVEN (skills/_shared/test-design/parser-regex-tests.md).

# ---- M6: every non-iterable spelling of decision.titleKeys ------------------

# `'ab'` earns its row for the opposite reason to the rest: it does not throw today, so no
# crash-shaped assertion can see it. It is in the table because a silently wrong comparison
# on the LAST gate before the rename is worse than an exception, not better.
#
# The FALSY half of the table (`''`, `0`, `false`, `NaN`, plus null/undefined) is the half
# that matters most, and for a reason the crashing spellings cannot show. `b || []` swallows
# exactly these: they never reach the Set constructor, never throw, and arrive at the I4
# comparison as an EMPTY SET — the one value that means "this stub carries no titles", a
# claim about the disk. A table made only of throwing spellings would go green under the
# very implementation this file exists to forbid (coerce the malformed value to `new Set()`
# and carry on), because that implementation changes nothing for these four.
#
# Read this table together with M08f below. M08f pins an EXPLICIT `new Set()` as
# `changed:stub-changed` — legitimate evidence that simply disagrees. The only implementation
# that satisfies both halves is one that rejects a value which is not a set of keys and
# leaves a genuine empty set alone; anything that folds the two together kills one or the
# other.
run_m_title_keys_type() {
  local name expr proj h
  while IFS='|' read -r name expr; do
    if [ -z "$name" ]; then continue; fi
    case "$name" in \#*|*[[:space:]]\#*) continue ;; esac
    name="${name//[[:space:]]/}"
    proj="$(guard_fixture)"; h="$(hash_of "$(session_path "$proj/stub" "$SID_A")")"
    deref_case "$proj" "cand.titleKeys=$expr;"
    check "M06[$name]a: a titleKeys that is not a set of keys is a caller error, not a crash" \
      "E=failed:not-a-title-set R=returned" "$NODE_OUT"
    guard_survives "M06[$name]b" "$proj" "$h"
  done <<TABLE
object    | ({})
proto     | ({a:1})
number    | 42
boolean   | true
string    | 'ab'
null      | null
undefined | undefined
empty-str | ''
zero      | 0
false     | false
nan       | NaN
TABLE
}

# ---- M7: the answer is owed BEFORE the file is read -------------------------

# The same placement ruling plan-raw-deref.sh M1 applies to `decision.file`: a malformed
# plan is answerable without a syscall, so it must be answered without one. Pinned by
# OBSERVABLE behaviour rather than by reading the source — the target names a file that does
# not exist, so a guard sitting below classifySessionFile cannot reach the titleKeys
# comparison at all and must produce the ENOENT verdict instead.
run_m_title_keys_before_disk() {
  local proj h

  proj="$(guard_fixture)"; h="$(hash_of "$(session_path "$proj/stub" "$SID_A")")"
  deref_case "$proj" "cand.file=path.join(cand.root,'$SID_B.jsonl');cand.titleKeys=({});"
  check "M07a: a malformed titleKeys is answered without reading the disk at all" \
    "E=failed:not-a-title-set R=returned" "$NODE_OUT"
  guard_survives "M07b" "$proj" "$h"

  # The control that makes M07a mean something: the SAME non-existent target with the
  # titleKeys the planner produced still reports the disk's answer, so M07a is pinning the
  # guard's position rather than the file's absence.
  proj="$(guard_fixture)"
  deref_case "$proj" "cand.file=path.join(cand.root,'$SID_B.jsonl');"
  check "M07c: the same absent target with a well-formed titleKeys still reports the race" \
    "E=changed:stub-changed R=returned" "$NODE_OUT"
}

# ---- M8: the guard must not swallow the comparison it protects --------------

# Pattern 4, three directions. A fix that rejects everything, or that coerces the malformed
# value to an empty set, would satisfy every row in M6 and destroy the I4 comparison itself:
# `pruned` has to stay reachable, and a genuine key MISMATCH has to stay `changed`.
run_m_title_keys_still_compares() {
  local proj

  proj="$(guard_fixture)"
  deref_case "$proj" "void 0;"
  check "M08a: the Set the planner itself produced still prunes" \
    "E=pruned:- R=returned" "$NODE_OUT"
  check_no_file "M08b: the stub was displaced" "$(session_path "$proj/stub" "$SID_A")"

  # An Array of the same keys is the other sanctioned spelling — sameKeys has always
  # accepted any iterable, and a guard written as `instanceof Set` would break a caller
  # that round-tripped the plan through JSON.
  proj="$(guard_fixture)"
  deref_case "$proj" "cand.titleKeys=Array.from(cand.titleKeys);"
  check "M08c: an Array carrying the same keys still prunes" \
    "E=pruned:- R=returned" "$NODE_OUT"
  check_no_file "M08d: the stub was displaced" "$(session_path "$proj/stub" "$SID_A")"

  # A real Set holding the WRONG key: the file changed under the plan, which is the race
  # this comparison exists to detect and is NOT a caller error.
  proj="$(guard_fixture)"
  deref_case "$proj" "cand.titleKeys=new Set(['a-title-this-stub-does-not-carry']);"
  check "M08e: a genuine key mismatch is still the race verdict, not a caller error" \
    "E=changed:stub-changed R=returned" "$NODE_OUT"

  # The row that separates rejection from coercion, and the direct counterpart of the falsy
  # spellings in M06 (`''`, `0`, `false`, `NaN`, null, undefined). An EXPLICIT empty Set is a
  # legitimate claim ("the stub carried no titles") that simply disagrees with a stub that
  # has one, so it is `changed`. Those six are not claims at all and are `failed`. The two
  # answers are indistinguishable to `b || []` today; an implementation that keeps them
  # indistinguishable has merely renamed the hole.
  proj="$(guard_fixture)"
  deref_case "$proj" "cand.titleKeys=new Set();"
  check "M08f: an explicitly empty Set is a mismatch, not a malformed plan" \
    "E=changed:stub-changed R=returned" "$NODE_OUT"
}

# ---- M9: the batch runs to completion through this door too -----------------

run_m_title_keys_batch_survives() {
  local proj sa sb sc
  proj="$(deref_batch_fixture)"
  deref_batch "$proj" "bad.titleKeys=({});"
  check "M09a: a non-iterable titleKeys mid-batch does not abort the batch" \
    "R=returned ENTRIES=3 SUM=3 PRUNED=2 FAILED=1" "$NODE_OUT"
  sa="$(session_path "$proj/stub-a" "$SID_A")"
  sb="$(session_path "$proj/stub-b" "$SID_B")"
  sc="$(session_path "$proj/stub-c" "$SID_C")"
  check_no_file "M09b: the entry before the malformed one was displaced" "$sa"
  check_file "M09c: and its rescue copy exists, so the report can be trusted" "$sa.bak"
  check_no_file "M09d: the entry after the malformed one was displaced too" "$sc"
  check_file "M09e: with its own rescue copy" "$sc.bak"
  check_file "M09f: the malformed entry's stub is untouched" "$sb"
  check_no_file "M09g: and nothing was written beside it" "$sb.bak"
}

# SKIPPED: a titleKeys holding a non-string member (a Set of objects, a Set of numbers).
# Because: Set equality is decided by SameValueZero on whatever the members are, so a
#          non-string member can only ever MISS against the strings classifySessionFile
#          produces — it lands in the `changed` branch M08e already pins, and adding rows
#          would assert the same code path with a different literal.
# L3 gap:  a plan whose titleKeys survived a JSON round trip through a real IPC boundary,
#          where a Set degrades to `{}` — the shape M06[object] forges in-process.

run_m_title_keys_type
run_m_title_keys_before_disk
run_m_title_keys_still_compares
run_m_title_keys_batch_survives
