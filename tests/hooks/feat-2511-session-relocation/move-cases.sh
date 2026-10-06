# Normal-path move cases (M1-M4, invalid sid) for feat-2511-session-relocation.sh.
# Sourced by the dispatcher after its pin; defines case bodies only.

c_m1_pinned() {
  local sid pin before_leg before_pin
  new_home m1
  sid="$(sid_of 101)"
  pin="$(np "$T/pins/m1")"
  mkdir -p "$pin"
  seed_session "$LEG" "$sid"
  seed_session "$pin" "$sid"
  before_leg="$(snap "$LEG")"
  before_pin="$(snap "$pin")"
  MV_EXTRA=("WORKFLOW_STATE_DIR=$pin")
  move "$sid"
  MV_EXTRA=()
  like "M1 pinned: one RELOCATE_SKIPPED reason=pinned line" "$MV_OUT" "RELOCATE_SKIPPED*reason=pinned*"
  eq "M1 pinned: exit 0" "$MV_RC" "0"
  eq "M1 pinned: the legacy root is untouched" "$(snap "$LEG")" "$before_leg"
  eq "M1 pinned: the pinned dir is untouched" "$(snap "$pin")" "$before_pin"
  eq "M1 pinned: no new root is created" "$(test -e "$NEW" || echo absent)" "absent"
}

c_m2_move() {
  local sid other n before_other
  new_home m2
  sid="$(sid_of 201)"
  other="$(sid_of 202)"
  seed_session "$LEG" "$sid"
  seed_session "$LEG" "$other"
  printf 'near\n' >"$LEG/${sid}x.txt"
  mkdir -p "$T/m2-orig"
  cp -R "$LEG/$sid.control" "$LEG/$sid.instructions-loaded" "$LEG/$sid.json" "$T/m2-orig/"
  before_other="$(snap "$LEG" | grep -F "$other" || true)"
  eq "M2 resolving alone never moves: the route is still legacy" "$(route "$sid")" "$LEG"
  eq "M2 resolving alone never moves: no new-root entry yet" "$(entries "$NEW" "$sid")" ""
  move "$sid"
  like "M2 one RELOCATED line with leftovers=0" "$MV_OUT" "RELOCATED sid=$sid entries=[1-9]* leftovers=0"
  eq "M2 exactly one stdout line" "$(lines "$MV_OUT")" "1"
  eq "M2 stderr is empty" "$MV_ERR" ""
  eq "M2 exit 0" "$MV_RC" "0"
  for n in "$sid.json" "$sid.control" "$sid.workflow-off" "$sid.instructions-loaded" "$sid.confirm-plan-turn-x.json"; do
    eq "M2 $n is in the new root" "$(test -e "$NEW/$n" && echo present)" "present"
    eq "M2 $n is gone from the legacy root" "$(test -e "$LEG/$n" || echo gone)" "gone"
  done
  eq "M2 supervisor state is byte-identical" \
    "$(cmp -s "$T/m2-orig/$sid.control/supervisor-state.json" "$NEW/$sid.control/supervisor-state.json" && echo same)" "same"
  eq "M2 the instructions-loaded content moved" \
    "$(cat "$NEW/$sid.instructions-loaded/CLAUDE.md" 2>/dev/null || true)" "loaded"
  eq "M2 the session now routes to the new root" "$(route "$sid")" "$NEW"
  eq "M2 another session is untouched" "$(snap "$LEG" | grep -F "$other" || true)" "$before_other"
  eq "M2 another session is not copied" "$(entries "$NEW" "$other")" ""
  eq "M2 <sid>x.txt (no separator) stays legacy" "$(test -f "$LEG/${sid}x.txt" && echo kept)" "kept"
  eq "M2 <sid>x.txt is not copied" "$(test -e "$NEW/${sid}x.txt" || echo absent)" "absent"
  eq "M2 no work dir is left" "$(workdirs "$NEW" "$sid")" ""
}

# The five spellings of one root: native, JSON-escaped, slash, MSYS, tilde. Native and
# MSYS only differ from the slash form on a drive-letter (Windows) path.
m3_forms() {
  SLASH="$1"
  NATIVE="$SLASH"
  MSYS=""
  if [[ "$SLASH" =~ ^[A-Za-z]:/ ]]; then
    NATIVE="${SLASH//\//\\}"
    local d="${SLASH:0:1}"
    MSYS="/${d,,}${SLASH:2}"
  fi
  ESC="${NATIVE//\\/\\\\}"
}

c_m3_rewrite() {
  local sid f lsl lna lms les nsl nna nms got
  new_home m3
  sid="$(sid_of 301)"
  seed_session "$LEG" "$sid"
  m3_forms "$LEG"
  lsl="$SLASH" lna="$NATIVE" lms="$MSYS" les="$ESC"
  m3_forms "$NEW"
  nsl="$SLASH" nna="$NATIVE" nms="$MSYS"
  f="$LEG/$sid.control/paths.txt"
  {
    printf 'native=%s\\x\n' "$lna"
    printf 'slash=%s/x\n' "$lsl"
    printf 'tilde=~/.claude/projects/workflow/x\n'
    printf 'boundary=%s2/keep\n' "$lsl"
    if [[ -n "$lms" ]]; then
      printf 'msys=%s/x\n' "$lms"
      printf 'lowerdrive=%s/x\n' "${lsl,,}"
    fi
  } >"$f"
  printf '{"session_id":"%s","plan":"%s\\\\x","quoted":"%s"}\n' "$sid" "$les" "$lsl" >"$LEG/$sid.json"
  # A file holding a NUL byte is binary: copied, never rewritten (plan stage 6 step 6).
  printf 'bin\000%s/x\n' "$lsl" >"$LEG/$sid.control/blob.bin"
  cp "$LEG/$sid.control/blob.bin" "$T/m3-blob.orig"
  move "$sid"
  eq "M3 a NUL-containing file is copied byte-identical (not rewritten)" \
    "$(cmp -s "$T/m3-blob.orig" "$NEW/$sid.control/blob.bin" && echo same)" "same"
  like "M3 the move succeeds" "$MV_OUT" "RELOCATED*"
  f="$NEW/$sid.control/paths.txt"
  eq "M3 native form rewritten" "$(grep '^native=' "$f" 2>/dev/null || true)" "native=$nna\\x"
  eq "M3 slash form rewritten" "$(grep '^slash=' "$f" 2>/dev/null || true)" "slash=$nsl/x"
  eq "M3 tilde form rewritten" "$(grep '^tilde=' "$f" 2>/dev/null || true)" "tilde=~/.workflow-state/x"
  eq "M3 a longer name sharing the prefix is not rewritten" \
    "$(grep '^boundary=' "$f" 2>/dev/null || true)" "boundary=${lsl}2/keep"
  if [[ -n "$lms" ]]; then
    eq "M3 MSYS form rewritten" "$(grep '^msys=' "$f" 2>/dev/null || true)" "msys=$nms/x"
    # Lower-case in bash: GNU grep 3.0 (Git for Windows) aborts on `-i` combined with `-F`.
    m3_ld="$(grep '^lowerdrive=' "$f" 2>/dev/null || true)"; m3_want="lowerdrive=$nsl/x"
    eq "M3 a lower-case drive letter still matches" "${m3_ld,,}" "${m3_want,,}"
  else
    skip "M3 MSYS and drive-letter forms (not a drive-letter path on this host)"
  fi
  got="$(node -e 'try { const j = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    process.stdout.write(j.plan + "|" + j.quoted); } catch (e) { process.stdout.write("INVALID"); }' \
    "$NEW/$sid.json" 2>/dev/null || true)"
  eq "M3 the json stays valid and both escaped and slash forms are rewritten" "$got" "$nna\\x|$nsl"
}

c_m4_idempotent() {
  local sid before fresh
  new_home m4
  sid="$(sid_of 401)"
  seed_session "$LEG" "$sid"
  move "$sid"
  before="$(snap "$NEW")"
  move "$sid"
  like "M4 a second move reports already-new" "$MV_OUT" "RELOCATE_SKIPPED*reason=already-new*"
  eq "M4 a second move exits 0" "$MV_RC" "0"
  eq "M4 SKIPPED is one stdout line with an empty stderr" "$(lines "$MV_OUT")|$MV_ERR" "1|"
  eq "M4 a second move changes nothing in the new root" "$(snap "$NEW")" "$before"
  fresh="$(sid_of 402)"
  move "$fresh"
  like "M4 a sid with no legacy entry reports no-entries" "$MV_OUT" "RELOCATE_SKIPPED*reason=no-entries*"
  eq "M4 no-entries creates nothing for the sid" "$(entries "$NEW" "$fresh")" ""
}

# #2512 C3: `<sid>-other` is another session (its own json, markers and work dir), so
# moving <sid> neither copies, deletes nor sweeps any of it.
c_m15_dash_sibling() {
  local sid other before_other
  new_home m15
  sid="$(sid_of 1501)"
  other="$sid-other"
  seed_session "$LEG" "$sid"
  seed_session "$LEG" "$other"
  mkdir -p "$NEW/.relocating-$other-1"
  printf 'off\n' >"$NEW/$other.workflow-off"
  before_other="$(snap "$LEG" | grep -F "$other" || true)"
  move "$sid"
  like "M15 the move of <sid> succeeds" "$MV_OUT" "RELOCATED sid=$sid entries=[1-9]* leftovers=0"
  eq "M15 <sid>-other's legacy entries are untouched" "$(snap "$LEG" | grep -F "$other" || true)" "$before_other"
  eq "M15 <sid>-other's json is not copied" "$(test -e "$NEW/$other.json" || echo absent)" "absent"
  eq "M15 <sid>-other's control dir is not copied" "$(test -e "$NEW/$other.control" || echo absent)" "absent"
  eq "M15 <sid>-other's new-root marker is not swept" "$(cat "$NEW/$other.workflow-off" 2>/dev/null || echo gone)" "off"
  eq "M15 <sid>-other's work dir is not swept" "$(test -d "$NEW/.relocating-$other-1" && echo kept)" "kept"
  eq "M15 <sid>-other still routes legacy" "$(route "$other")" "$LEG"
}

# #2512 round 2 C3: a dot is legal inside a sid, so `<sid>.peer` is another session whose
# `<sid>.peer.json` / `<sid>.peer.control` must not be claimed by <sid>; only the known
# `<sid>.<suffix>` names (and their transient tails) are <sid>'s.
c_m15b_dot_sibling() {
  local sid other before_other got
  new_home m15b
  sid="$(sid_of 1511)"
  other="$sid.peer"
  seed_session "$LEG" "$sid"
  seed_session "$LEG" "$other"
  mkdir -p "$NEW"
  printf 'off\n' >"$NEW/$other.workflow-off"
  before_other="$(snap "$LEG" | grep -F "$other" || true)"
  move "$sid"
  like "M15b the move of <sid> succeeds" "$MV_OUT" "RELOCATED sid=$sid entries=[1-9]* leftovers=0"
  eq "M15b <sid>.peer's legacy entries are untouched" "$(snap "$LEG" | grep -F "$other" || true)" "$before_other"
  eq "M15b <sid>.peer.json is not copied" "$(test -e "$NEW/$other.json" || echo absent)" "absent"
  eq "M15b <sid>.peer.control is not copied" "$(test -e "$NEW/$other.control" || echo absent)" "absent"
  eq "M15b <sid>.peer's new-root marker is not swept" "$(cat "$NEW/$other.workflow-off" 2>/dev/null || echo gone)" "off"
  eq "M15b <sid>.peer still routes legacy" "$(route "$other")" "$LEG"
  got="$(cd "$T/cwd" && run_with_timeout 30 "${DENV[@]}" node -e '
    const { isSidEntry } = require(process.argv[1]);
    const sid = "X";
    const yes = ["X.json", "X.control", "X.instructions-loaded", "X.workflow-off", "X.next-step-paused",
      "X.gh-env", "X.off-clearance", "X.off-clearance.mint.claimed", "X.confirm-plan-turn-ab12cd34.json",
      "X.json.lock", "X.workflow-off.tmp", "X.workflow-off.123.tmp", "X.json.123.4.tmp",
      "X.off-clearance.consuming-0123456789abcdef.tmp", "X.off-clearance.mint.lock.tmp",
      "X.off-clearance.mint.4242.0123456789ab.tmp"];
    const no = ["X", "X.Y.json", "X.Y.control", "X.Y", "X.Y.workflow-off", "X.late-marker", "X.json.Y",
      "X-other", "XY.json", "X.confirm-plan-turn-.json", "X.Y.json.lock", "X.Y.off-clearance.mint.4242.0123456789ab.tmp"];
    const bad = [...yes.filter((n) => !isSidEntry(n, sid)).map((n) => "missed:" + n),
      ...no.filter((n) => isSidEntry(n, sid)).map((n) => "claimed:" + n)];
    process.stdout.write(bad.join(",") || "ok");' \
    "$A/hooks/lib/temporary-migrations/state-dir-relocation/legacy.js" 2>&1)" || true
  eq "M15b isSidEntry accepts the known suffixes and rejects bare X and X.Y.* for X" "$got" "ok"
}

# #2512 security F1: a dotted sid ending in an owned suffix (`<A>.json`, `<A>.control`)
# names session A's own entries; it neither claims them nor is accepted by move.
c_m15c_entry_shaped_sid() {
  local sid before got
  new_home m15c
  sid="$(sid_of 1521)"
  seed_session "$LEG" "$sid"
  before="$(snap "$LEG")"
  got="$(cd "$T/cwd" && run_with_timeout 30 "${DENV[@]}" node -e '
    const { isSidEntry, isEntryShapedSid } = require(process.argv[1]);
    const bad = [];
    for (const s of ["X.json", "X.control", "X.workflow-off", "X.off-clearance"]) {
      if (isSidEntry(s, s)) bad.push("self:" + s);
      if (!isEntryShapedSid(s)) bad.push("unflagged:" + s);
    }
    for (const n of ["X.json.lock", "X.control.tmp"]) {
      if (isSidEntry(n, n.slice(0, n.lastIndexOf(".")))) bad.push("tail:" + n);
    }
    for (const s of ["X", "X.peer", "X.Y.json.Z"]) if (isEntryShapedSid(s)) bad.push("flagged:" + s);
    process.stdout.write(bad.join(",") || "ok");' \
    "$A/hooks/lib/temporary-migrations/state-dir-relocation/legacy.js" 2>&1)" || true
  eq "M15c an entry-shaped sid claims nothing of its own name and is flagged" "$got" "ok"
  move "$sid.json"
  eq "M15c move of <sid>.json is refused with exit 2" "$MV_RC" "2"
  eq "M15c the refused move prints no RELOCATED line" "$(case "$MV_OUT" in RELOCATED*) echo moved ;; *) echo refused ;; esac)" "refused"
  move "$sid.control"
  eq "M15c move of <sid>.control is refused with exit 2" "$MV_RC" "2"
  eq "M15c the base session's legacy entries are untouched" "$(snap "$LEG")" "$before"
  eq "M15c nothing of the base session lands in the new root" "$(entries "$NEW" "$sid")" ""
}

c_m_invalid_sid() {
  local up
  new_home minv
  up="$H/.claude/projects"
  mkdir -p "$LEG"
  printf '{}\n' >"$up/evil.json"
  move "../evil"
  eq "invalid sid: nothing is relocated" "$(case "$MV_OUT" in RELOCATED*) echo moved ;; *) echo refused ;; esac)" "refused"
  eq "invalid sid: the file outside the legacy root is untouched" "$(cat "$up/evil.json" 2>/dev/null || true)" "{}"
  eq "invalid sid: nothing lands in the new root" "$(ls -A "$NEW" 2>/dev/null || true)" ""
}
