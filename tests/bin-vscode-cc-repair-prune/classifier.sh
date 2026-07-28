# Part of tests/bin-vscode-cc-repair-prune.sh (sourced, not standalone).
# Tests: bin/lib/vscode-cc-repair/prune.js, bin/lib/vscode-cc-repair/prune/verify.js
# Tags: bin, vscode, prune, classifier, session-files, scope:common, pwsh-not-required, TL2
#
# A — classifySessionFile, the gate every deletion passes through. Driven directly
# through the exported function on REAL fixture files (single-line JSONL is cheap to
# generate) because the verdict alphabet is wider than the CLI report exposes:
# `indeterminate` never produces a report line at all, yet it is precisely the verdict
# that keeps a file alive, so it can only be pinned here.
#
# Verdict alphabet: stub | real | indeterminate | unclassified | unreadable.
# The load-bearing distinction (detail plan 3.2) is DECISION-REACHED
# (`stub`/`real`/`indeterminate` — every line was seen) versus OBSERVATION-FAILED
# (`unclassified`/`unreadable` — the material was never fully read). Only the second
# group contributes to exit 1.

expect_verdict() { # <name> <file> <want-verdict>
  FIXFILE="$(native_file "$2")" node_m 'const m=require("'"$REQUIRE_PATH"'");
console.log("V="+m.classifySessionFile(process.env.FIXFILE).verdict);'
  check "$1: verdict" "V=$3" "$NODE_OUT"
}

# ---- A1: stub, and the three shapes that must NOT be stub -------------------

run_a_stub_shapes() {
  local d f

  d="$(new_dir)"
  { title_line "$SID_A" "Alpha"; } | mk_session "$d" "$SID_A"
  expect_verdict "A01-single-title-line" "$(session_path "$d" "$SID_A")" "stub"

  d="$(new_dir)"
  { title_line "$SID_A" "Alpha"; title_line "$SID_A" "Bravo"; title_line "$SID_A" "Chrly"; } \
    | mk_session "$d" "$SID_A"
  expect_verdict "A02-multiple-title-lines" "$(session_path "$d" "$SID_A")" "stub"

  # R13 / detail plan 3.3: TITLE_RECORD_TYPE is `custom-title` ALONE. `ai-title` is a
  # deliberate scope exclusion, so an ai-title-only file is neither prunable nor
  # evidence for pruning anything else.
  d="$(new_dir)"
  { ai_title_line "$SID_A" "Alpha"; } | mk_session "$d" "$SID_A"
  expect_verdict "A03-ai-title-only-is-not-stub" "$(session_path "$d" "$SID_A")" "indeterminate"

  d="$(new_dir)"
  { title_line "$SID_A" "Alpha"; ai_title_line "$SID_A" "Alpha"; } | mk_session "$d" "$SID_A"
  expect_verdict "A04-custom-title-plus-ai-title" "$(session_path "$d" "$SID_A")" "indeterminate"

  # KNOWN_TITLE_FIELDS allowlist: an unrecognised field carries information whose
  # presence in the counterpart cannot be proven, so the file falls to the keep side.
  d="$(new_dir)"
  { title_line_extra "$SID_A" "Alpha"; } | mk_session "$d" "$SID_A"
  expect_verdict "A05-unknown-title-field" "$(session_path "$d" "$SID_A")" "indeterminate"

  # Blank lines are counted and ignored; the absence of a trailing newline must not
  # swallow the final record.
  d="$(new_dir)"
  { blank_line; title_line "$SID_A" "Alpha"; blank_line; blank_line
    printf '{"type":"custom-title","sessionId":"%s","customTitle":"Bravo"}' "$SID_A"; } \
    | mk_session "$d" "$SID_A"
  expect_verdict "A06-blank-lines-and-no-trailing-newline" "$(session_path "$d" "$SID_A")" "stub"

  f="$(session_path "$d" "$SID_A")"
  FIXFILE="$(native_file "$f")" node_m 'const m=require("'"$REQUIRE_PATH"'");
const r=m.classifySessionFile(process.env.FIXFILE);
console.log("T="+r.counts.titles+" B="+r.counts.blank+" C="+r.counts.content);'
  check "A06b: blank lines counted separately, both titles seen" "T=2 B=3 C=0" "$NODE_OUT"
}

# ---- A2: `real` — the positive evidence that keeps a counterpart alive ------

run_a_real_shapes() {
  local d kind
  for kind in user assistant summary; do
    d="$(new_dir)"
    { content_line "$SID_A" "$kind"; } | mk_session "$d" "$SID_A"
    expect_verdict "A07-content-$kind-matches-basename" "$(session_path "$d" "$SID_A")" "real"
  done

  # 3.6.1 — the classifier must NOT give up on the first line it cannot use. Each of
  # these three rows puts an unusable line FIRST and a valid content line LATER; an
  # early bail-out would mark a genuine transcript `indeterminate` and permanently
  # strand its stub twin.
  d="$(new_dir)"
  { content_line_nosid; content_line "$SID_A"; } | mk_session "$d" "$SID_A"
  expect_verdict "A08-malformed-content-first-then-match" "$(session_path "$d" "$SID_A")" "real"

  d="$(new_dir)"
  { broken_line; content_line "$SID_A"; } | mk_session "$d" "$SID_A"
  expect_verdict "A09-broken-json-first-then-match" "$(session_path "$d" "$SID_A")" "real"

  d="$(new_dir)"
  { content_line "$SID_B"; content_line "$SID_A"; } | mk_session "$d" "$SID_A"
  expect_verdict "A10-foreign-session-first-then-match" "$(session_path "$d" "$SID_A")" "real"
}

# ---- A3: everything that is neither stub nor real --------------------------

run_a_indeterminate_shapes() {
  local d

  # Content records exist but every one belongs to a different session: this file
  # cannot serve as I2 evidence for the basename it carries.
  d="$(new_dir)"
  { content_line "$SID_B"; content_line "$SID_C"; } | mk_session "$d" "$SID_A"
  expect_verdict "A11-all-content-sessionid-mismatched" "$(session_path "$d" "$SID_A")" "indeterminate"

  # ~/.claude/projects/codex-review/ ships UUID-named .jsonl audit logs with no
  # `type` field at all, and their basenames collide with real sessions elsewhere.
  d="$(new_dir)"
  { notype_line; notype_line; } | mk_session "$d" "$SID_A"
  expect_verdict "A12-notype-audit-log-shape" "$(session_path "$d" "$SID_A")" "indeterminate"

  d="$(new_dir)"
  { broken_line; broken_line; } | mk_session "$d" "$SID_A"
  expect_verdict "A13-broken-json-only" "$(session_path "$d" "$SID_A")" "indeterminate"

  d="$(new_dir)"
  { nonobject_line; nonobject_line; } | mk_session "$d" "$SID_A"
  expect_verdict "A14-non-object-lines-only" "$(session_path "$d" "$SID_A")" "indeterminate"

  d="$(new_dir)"
  : | mk_session "$d" "$SID_A"
  check "A15a: precondition — fixture is zero bytes" "0" "$(bytes "$(session_path "$d" "$SID_A")")"
  expect_verdict "A15-empty-file" "$(session_path "$d" "$SID_A")" "indeterminate"

  d="$(new_dir)"
  { printf '   \n\t\n\n'; } | mk_session "$d" "$SID_A"
  expect_verdict "A16-whitespace-only" "$(session_path "$d" "$SID_A")" "indeterminate"
}

# ---- A4: the scan cap, pinned on its exact boundary ------------------------

run_a_scan_cap() {
  local d f tail_bytes

  # All-title file larger than CLASSIFY_MAX_SCAN: I1 ("every line is a custom-title")
  # cannot be proven, so this is an OBSERVATION FAILURE, not `indeterminate`.
  d="$(new_dir)"; f="$(session_path "$d" "$SID_A")"
  mkdir -p "$d"
  gen_big "$f" "$SID_A" $((CLASSIFY_MAX_SCAN + 128)) title none none
  expect_verdict "A17-all-titles-over-cap" "$f" "unclassified"
  FIXFILE="$(native_file "$f")" node_m 'const m=require("'"$REQUIRE_PATH"'");
const r=m.classifySessionFile(process.env.FIXFILE);
console.log("TR="+(r.truncated===true));'
  check "A17b: truncated flag is set" "TR=true" "$NODE_OUT"

  # The same oversized file, but with a matching content line at the very front: the
  # positive early cutoff fires long before the cap, so the cap costs nothing on the
  # common path.
  d="$(new_dir)"; f="$(session_path "$d" "$SID_A")"
  mkdir -p "$d"
  gen_big "$f" "$SID_A" $((CLASSIFY_MAX_SCAN + 128)) title content none
  expect_verdict "A18-over-cap-with-early-content-line" "$f" "real"

  # Boundary pin: exactly CLASSIFY_MAX_SCAN bytes of unusable lines, then a matching
  # content line starting at byte CLASSIFY_MAX_SCAN. The cap must stop the scan
  # BEFORE that line — reading one byte further would flip the verdict to `real` and
  # silently widen the read budget.
  d="$(new_dir)"; f="$(session_path "$d" "$SID_A")"
  mkdir -p "$d"
  gen_big "$f" "$SID_A" "$CLASSIFY_MAX_SCAN" garbage none content
  tail_bytes="$(content_line "$SID_A" | wc -c | tr -d '[:space:]')"
  check "A19a: precondition — the content line starts exactly at the cap" \
    "$((CLASSIFY_MAX_SCAN + tail_bytes))" "$(bytes "$f")"
  expect_verdict "A19-cap-boundary-content-line-just-past-it" "$f" "unclassified"
}

# ---- A5: unreadable --------------------------------------------------------

# A directory standing where the session file is expected is the one read fault
# reproducible without permission bits: Node raises EISDIR (POSIX) / EISDIR-or-EPERM
# (win32) from the open/read. Probed first so a host that happily reads a directory
# produces a documented SKIP rather than a false PASS.
#
# SKIPPED (when the probe passes): a chmod-000 session file -> `unreadable` with
#          reason=EACCES.
# Because: chmod is advisory on MSYS/Windows and ignored under root, so the denial
#          cannot be proven to have taken effect. The EACCES spelling is covered on
#          POSIX by scan.sh D09 (which uses deny_read and skips the same way).
# Needed:  a POSIX host running as a non-root user.
# TL3 gap: a real ~/.claude/projects containing a file owned by another user.
run_a_unreadable() {
  local d f probe
  d="$(new_dir)"
  f="$(session_path "$d" "$SID_A")"
  mkdir -p "$f"
  : > "$f/placeholder"

  FIXFILE="$(native_file "$f")" node_m 'const fs=require("fs");
try { fs.readFileSync(process.env.FIXFILE); console.log("P=readable"); }
catch (e) { console.log("P=faulted"); }'
  probe="$NODE_OUT"
  if [ "$probe" != "P=faulted" ]; then
    skip_case "A20 unreadable session file (host does not fault on reading a directory)"
    return 0
  fi
  expect_verdict "A20-unreadable-session-file" "$f" "unreadable"
}

# ---- A6: titleKeys, the unit I4 is proven in -------------------------------

# titleKeys no longer travels to the counterpart side: after #1655 a counterpart is
# judged on its content record alone. The set survives because the STUB side still needs
# it — `prunable` re-classifies the stub immediately before the unlink and compares
# sameKeys(fresh.titleKeys, decision.titleKeys) (I4), which is how a stub that was
# rewritten between plan and unlink is caught even when its size and mtime are unchanged
# (lifecycle-race.sh R-8). A key format that was unstable across two reads of the SAME
# file would make that comparison fire at random, so the normalization is pinned here.

run_a_title_keys() {
  local d
  d="$(new_dir)"
  # Two records with an identical (sessionId, customTitle) pair plus one distinct
  # pair: the normalized key set must collapse to 2, otherwise a stub that merely
  # repeated a title would compare unequal to itself across the two reads.
  { title_line "$SID_A" "Alpha"; title_line "$SID_A" "Alpha"; title_line "$SID_A" "Bravo"; } \
    | mk_session "$d" "$SID_A"
  FIXFILE="$(native_file "$(session_path "$d" "$SID_A")")" node_m 'const m=require("'"$REQUIRE_PATH"'");
const r=m.classifySessionFile(process.env.FIXFILE);
const keys=Array.from(r.titleKeys);
console.log("N="+keys.length+" U="+(new Set(keys)).size+" T="+r.counts.titles);'
  check "A21: duplicate (sessionId, customTitle) pairs collapse to one key" \
    "N=2 U=2 T=3" "$NODE_OUT"

  # The key is derived from BOTH fields: the same title text under a different sessionId
  # is a different key, so a stub that swapped one for the other is not mistaken for
  # unchanged. Stated ACROSS TWO FILES rather than inside one, because a single file only
  # ever contributes titles for its own session now (A25) — the old one-file spelling of
  # this row would be asserting the very thing the ownership rule forbids.
  d="$(new_dir)"
  { title_line "$SID_A" "Alpha"; } | mk_session "$d" "$SID_A"
  { title_line "$SID_B" "Alpha"; } | mk_session "$d" "$SID_B"
  K_ONE="$(native_file "$(session_path "$d" "$SID_A")")" \
  K_TWO="$(native_file "$(session_path "$d" "$SID_B")")" \
    node_m 'const m=require("'"$REQUIRE_PATH"'");
const a=Array.from(m.classifySessionFile(process.env.K_ONE).titleKeys);
const b=Array.from(m.classifySessionFile(process.env.K_TWO).titleKeys);
console.log("N="+(new Set(a.concat(b))).size+" A="+a.length+" B="+b.length);'
  check "A22: the key spans sessionId as well as customTitle" "N=2 A=1 B=1" "$NODE_OUT"
}

# ---- A7: the payload rule — a content record must carry its transcript -----
#
# #1655 F1. Removing I3 left `isMatchingContentRecord` as the ONLY thing standing between
# a foreign file and an unrecoverable delete, and it accepted any object whose `type` was
# a content type and whose `sessionId` string-matched. A single 60-byte line therefore
# authorised the deletion of a real user file. The rule now is that every content type
# names the field carrying its payload — `message` (a non-null, non-array object) for
# user/assistant, `summary` (a non-empty string) for summary — and a record lacking it is
# a shell, never a transcript.
#
# Both directions are covered from one table (Pattern 4): the shell/ill-shaped rows must
# fall to `indeterminate` (the file is not evidence for anything, and it is not a stub
# either, so it stays alive), and the well-shaped rows must still reach `real`. Shipping
# only the first half would silently refuse every genuine prune.
payload_verdict_case() { # <name> <type> <json-payload|-> <want-verdict>
  local d
  d="$(new_dir)"
  if [ "$3" = "-" ]; then
    { content_line_shell "$SID_A" "$2"; } | mk_session "$d" "$SID_A"
  else
    { content_line_payload "$SID_A" "$2" "$3"; } | mk_session "$d" "$SID_A"
  fi
  expect_verdict "$1" "$(session_path "$d" "$SID_A")" "$4"
}

run_a_content_payload() {
  local name type payload want
  while IFS='|' read -r name type payload want; do
    name="${name//[[:space:]]/}"
    case "$name" in ''|'#'*) continue ;; esac
    type="${type//[[:space:]]/}"
    payload="${payload//[[:space:]]/}"
    want="${want//[[:space:]]/}"
    payload_verdict_case "$name" "$type" "$payload" "$want"
  done <<'TABLE'
A23a-user-no-message        | user      | -                             | indeterminate
A23b-assistant-no-message   | assistant | -                             | indeterminate
A23c-summary-no-summary     | summary   | -                             | indeterminate
A23d-user-message-null      | user      | null                          | indeterminate
A23e-user-message-array     | user      | []                            | indeterminate
A23f-user-message-string    | user      | "hi"                          | indeterminate
A23g-user-message-number    | user      | 7                             | indeterminate
A23h-summary-empty-string   | summary   | ""                            | indeterminate
A23i-summary-number         | summary   | 12                            | indeterminate
A23j-summary-object         | summary   | {"text":"x"}                  | indeterminate
A24a-user-message-object    | user      | {"role":"user","content":"hi"} | real
A24b-assistant-msg-object   | assistant | {"role":"assistant","content":"ok"} | real
A24c-summary-nonempty-text  | summary   | "a recap"                     | real
TABLE

  # A24d — the `message` rule is about SHAPE, not about the payload being interesting: an
  # empty object is still a non-null, non-array object, so it stays on the allow side.
  # Pinned separately because it is the boundary between the two halves of the table.
  payload_verdict_case "A24d-user-message-empty-object" user '{}' real

  # A24e — a shell record does not become evidence by being followed by a real one, and a
  # real one is not spoiled by a shell preceding it: the predicate is per-record.
  local d
  d="$(new_dir)"
  { content_line_shell "$SID_A"; content_line "$SID_A"; } | mk_session "$d" "$SID_A"
  expect_verdict "A24e-shell-first-then-a-real-record" "$(session_path "$d" "$SID_A")" "real"
}

# ---- A8: title ownership — a title record belongs to its own file ----------
#
# #1655 codex HIGH. classifySessionFile derives the session id from the basename and used
# to count every schema-valid custom-title toward `counts.titles` without requiring
# `record.sessionId` to equal it. `A.jsonl` holding a title for session B was therefore
# still a `stub`, and was deleted the moment any other copy of `A.jsonl` carried content
# for A — destroying B's title, which exists nowhere else.
#
# This was already asymmetric with how the same function treats CONTENT records for
# another session: those increment `other` and force `indeterminate`. A foreign title is
# the same kind of thing — real information this tool cannot account for.
run_a_title_ownership() {
  local d

  d="$(new_dir)"
  { title_line "$SID_B" "Alpha"; } | mk_session "$d" "$SID_A"
  expect_verdict "A25a-foreign-title-only" "$(session_path "$d" "$SID_A")" "indeterminate"

  d="$(new_dir)"
  { title_line "$SID_A" "Alpha"; title_line "$SID_B" "Bravo"; } | mk_session "$d" "$SID_A"
  expect_verdict "A25b-own-title-plus-foreign-title" "$(session_path "$d" "$SID_A")" \
    "indeterminate"

  # The foreign pair must not enter titleKeys either. If it did, I4 would re-prove a key
  # the file has no business carrying, and — worse — `sameKeys` would compare equal across
  # two reads of a file whose foreign title is precisely the information at risk.
  O_SID="$SID_A" FIXFILE="$(native_file "$(session_path "$d" "$SID_A")")" \
    node_m 'const m=require("'"$REQUIRE_PATH"'");
const keys=Array.from(m.classifySessionFile(process.env.FIXFILE).titleKeys);
console.log("N="+keys.length+" OWN="+keys.filter(function(k){
  return k.indexOf(process.env.O_SID)>=0;}).length);'
  check "A25c: a foreign title never enters titleKeys" "N=1 OWN=1" "$NODE_OUT"

  # Pattern 4 — the sanctioned direction. Ownership must not turn every stub into an
  # indeterminate: a file whose titles all name its own session is still exactly the thing
  # this tool exists to prune.
  d="$(new_dir)"
  { title_line "$SID_A" "Alpha"; title_line "$SID_A" "Bravo"; } | mk_session "$d" "$SID_A"
  expect_verdict "A26a-own-titles-only-is-still-a-stub" "$(session_path "$d" "$SID_A")" "stub"
  FIXFILE="$(native_file "$(session_path "$d" "$SID_A")")" node_m 'const m=require("'"$REQUIRE_PATH"'");
const r=m.classifySessionFile(process.env.FIXFILE);
console.log("N="+Array.from(r.titleKeys).length+" T="+r.counts.titles);'
  check "A26b: own titles still populate titleKeys" "N=2 T=2" "$NODE_OUT"
}

run_a_stub_shapes
run_a_real_shapes
run_a_indeterminate_shapes
run_a_scan_cap
run_a_unreadable
run_a_title_keys
run_a_content_payload
run_a_title_ownership
