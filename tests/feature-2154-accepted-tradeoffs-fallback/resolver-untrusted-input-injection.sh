# Tests: bin/resolve-accepted-tradeoffs-file
# Tags: codex, review, accepted-tradeoffs, security, injection, traversal, scope:issue-specific
# Resolver UNTRUSTED-INPUT contracts by input class: the session id (S5/S5b, S6-S8),
# the plans directory (S10-S11), the candidate suffix (S13/S13-fallback, S14-S16),
# plus the ALLOW half for a sanctioned id and suffix that LOOK like attacks (S25-S26).
# Patterns: skills/_shared/test-design/protection-fix-tests.md — every rejection
# case asserts the filesystem outside PLANS_DIR is unchanged, not just an exit code.
# Split (rules/coding/file-split.md Pattern A) from resolver-edge-security.sh, which
# keeps containment, is sourced FIRST, and owns S0 / RESOLVER_READY plus the
# resolve_e / assert_contained / canon helpers used below.
echo "=== Resolver untrusted-input injection / traversal cases ==="
# Sourced by tests/feature-2154-accepted-tradeoffs-fallback.sh.
# TL3 gap (TL2 substrate is not POSIX; a real POSIX host also verifies): S10, S11
# — presented only where the filesystem accepts ';', '$', backticks, spaces and
# parentheses in a directory name; S29's ALLOW half likewise needs a filesystem that
# accepts an embedded newline, CR or tab in a filename (NTFS refuses all three, so
# there the sanctioned rows skip and only the refusals are proven).
# The sibling resolver-edge-security.sh owns the S4 / S9 / S12 / S18 / I1 gap rows.
# Closest-to-action: check-verification-gate.sh.

if [[ "$RESOLVER_READY" -eq 0 ]]; then
  skip "S5-S8, S10-S11, S13-S16, S25-S26: resolver unavailable (see S0 in resolver-edge-security.sh)"
else

# --- S5: a session id carrying ../ traversal segments.
P_TRAV="$(make_plans s5 intent)"
CANARY_TRAV="$TMPROOT/traversal-escape-intent.md"
CANARY_TRAV_BODY="OUTSIDE-CANARY-2154-QZWX"
printf '%s\n' "$CANARY_TRAV_BODY" > "$CANARY_TRAV"
resolve_e "$P_TRAV" "../../traversal-escape" detail outline intent
assert_contained "S5: '../..' session id neither escapes PLANS_DIR" "$P_TRAV"

# --- S5b: the same attack at the depth that actually REACHES the canary. `../..`
# lands one level above $TMPROOT, so the canary is not on its path and an asset
# assertion there would be vacuous; S5b-0 pins that non-vacuity before asserting.
assert_eq "S5b-0: the traversal names exactly the canary file (attack is reachable)" \
  "$(canon "$CANARY_TRAV")" "$(canon "$P_TRAV/../traversal-escape-intent.md")"
resolve_e "$P_TRAV" "../traversal-escape" detail outline intent
assert_contained "S5b: '..' session id neither escapes PLANS_DIR" "$P_TRAV"
# Protection Pattern 1 (protection-fix-tests.md): an attack case must assert the
# PROTECTED ASSET, not only the return value. A resolver that touched, truncated
# or rewrote the file it was steered at satisfies every containment row above.
assert_eq "S5b: the file the traversal aimed at is byte-for-byte unchanged" \
  "$CANARY_TRAV_BODY" "$(cat "$CANARY_TRAV" 2>/dev/null || printf 'MISSING')"
# ...and its content must not have been read back out on either stream.
if [[ "$RES_OUT" == *"$CANARY_TRAV_BODY"* || "$RES_ERR" == *"$CANARY_TRAV_BODY"* ]]; then
  fail "S5b: the outside file's content leaked into the resolver's output — stdout: [$RES_OUT] stderr: [$RES_ERR]"
else
  pass "S5b: the outside file's content appears on neither stdout nor stderr"
fi

# --- S6-S8: shell metacharacters in the session id must never be executed.
# The canary is the negative assertion (protection-fix-tests.md Pattern 1): if
# any substitution or chaining ran, the file would exist.
CANARY="$TMPROOT/injection-canary.txt"
P_INJ="$(make_plans s6 intent)"
inj_case() {
  local name="$1" sid="$2" dir="$3"
  rm -f "$CANARY"
  resolve "$dir" "$sid" detail outline intent
  if [[ -e "$CANARY" ]]; then
    fail "$name — the injected command EXECUTED (canary $CANARY was created)"
  else
    pass "$name — no command executed (canary absent)"
  fi
  assert_contained "$name: emitted path" "$dir"
}
inj_case "S6: ';' command chaining in <SID>"       "a;touch $CANARY;b" "$P_INJ"
inj_case "S7: '\$(...)' substitution in <SID>"     'a$(touch '"$CANARY"')b' "$P_INJ"
inj_case "S8: backtick + space in <SID>"           'a `touch '"$CANARY"'` b' "$P_INJ"

# --- S10 (injection, CPR-ORTH with S6-S8): the metacharacters ride on the
# PLANS DIRECTORY argument instead of <SID>. Both are user-controlled CLI
# inputs, so covering only one leaves half the input domain unproven.
# SKIPPED (when mkdir fails): the whole plans-dir injection assertion.
# Because: `;`, `$`, backtick and parentheses are legal in a filename only on
#          filesystems that accept them — where mkdir refuses, the adversarial
#          input cannot be presented at all.
P_META="$TMPROOT/meta;\$(touch $CANARY)\`touch $CANARY\` dir"
if mkdir -p "$P_META" 2>/dev/null && [[ -d "$P_META" ]]; then
  printf '# intent\n\nkeep it\n' > "$P_META/SID-intent.md"
  rm -f "$CANARY"
  resolve "$P_META" SID detail outline intent
  if [[ -e "$CANARY" ]]; then
    fail "S10: metacharacters in the PLANS_DIR path EXECUTED (canary $CANARY was created)"
  else
    pass "S10: metacharacters in the PLANS_DIR path — no command executed (canary absent)"
  fi
  assert_contained "S10: emitted path" "$P_META"
else
  skip "S10: plans-dir injection case (mkdir refused a directory name carrying ';', '\$' and backticks on this filesystem)"
fi

# --- S11 (normal case, the positive counterpart of S10): a plans directory
# whose name carries spaces and shell-special characters but no injection
# attempt. This is the classic missing-quotes failure — a resolver that word-
# splits its arguments returns a truncated path or nothing at all.
# SKIPPED (when mkdir fails): the exact-path assertion below.
# Because: the directory name cannot be created, so there is nothing to look
#          up — see S10.
P_SPACE="$TMPROOT/plans dir (2154) & 'quoted' [x]"
if mkdir -p "$P_SPACE" 2>/dev/null && [[ -d "$P_SPACE" ]]; then
  printf '# outline\n\nkeep it\n' > "$P_SPACE/SID-outline.md"
  printf '# intent\n\nkeep it\n' > "$P_SPACE/SID-intent.md"
  resolve "$P_SPACE" SID detail outline intent
  assert_eq "S11: spaces + shell-special chars in PLANS_DIR → exact outline path" \
    "$P_SPACE/SID-outline.md" "$RES_OUT"
  assert_eq "S11: spaces + shell-special chars in PLANS_DIR → exit 0" "0" "$RES_RC"
else
  skip "S11: spaced plans-dir case (mkdir refused a directory name carrying spaces, parentheses, '&' and quotes)"
fi

# --- S13-S16 (CPR-ORTH with S5-S8/S10-S11, CPR-UNV): candidate SUFFIXES are the
# third CLI input class. A candidate is `$PLANS_DIR/$SESSION_ID-<suffix>.md`, so
# the suffix sits inside the path the amended Step 1 containment contract governs.

# --- S13: a suffix whose `../` segments REALLY escape — an intermediate dir is
# planted so `-f` succeeds on the escaped path (an unresolvable traversal would
# be skipped for being absent and would prove nothing).
P_SFX="$(make_plans s13 intent)"
mkdir -p "$P_SFX/SID-x"
SFX_TARGET="$TMPROOT/suffix-escape-target.md"
SFX_SECRET="SUFFIX-ESCAPE-SECRET-2154-QZWX"
printf '# outside the plans dir\n\n%s\n' "$SFX_SECRET" > "$SFX_TARGET"
SFX_TARGET_BEFORE="$(cat "$SFX_TARGET" 2>/dev/null || printf 'MISSING')"
SFX_TRAV="x/../../suffix-escape-target"
if [[ -f "$P_SFX/SID-$SFX_TRAV.md" ]]; then
  pass "S13-0: the traversal suffix really reaches the external file (the case is not vacuous)"
else
  fail "S13-0: the traversal suffix does not reach the external file — S13's verdict would be vacuous"
fi
resolve_e "$P_SFX" SID "$SFX_TRAV" intent
assert_eq "S13: escaping candidate suffix skipped → next candidate (intent) emitted" \
  "$P_SFX/SID-intent.md" "$RES_OUT"
assert_eq "S13: escaping candidate suffix → exit 0 (skip, not refusal)" "0" "$RES_RC"
assert_contained "S13: emitted path" "$P_SFX"
if [[ "$RES_OUT" == *"$SFX_SECRET"* || "$RES_ERR" == *"$SFX_SECRET"* ]]; then
  fail "S13: the escaped file's content leaked — stdout: [$RES_OUT] stderr: [$RES_ERR]"
else
  pass "S13: the escaped file's content appears on neither stdout nor stderr"
fi
assert_eq "S13: the escaped file is byte-for-byte unchanged after resolution" \
  "$SFX_TARGET_BEFORE" "$(cat "$SFX_TARGET" 2>/dev/null || printf 'MISSING')"

# --- S13-fallback: the suffix-borne twin of S9-fallback (which stays in the
# sibling resolver-edge-security.sh) — the same escaping suffix as the LONE
# candidate, so the exempt last-candidate fallback is reached holding a path that
# EXISTS and fails containment.
SFX_WANT_DIAG="the last candidate path leaves the plans directory; refusing to forward it."
# Asserted EXACTLY, CPR-ORTH with S9-fallback: "non-zero exit + non-empty stderr"
# is also satisfied by a crash, by the exit-2 usage error, and by the OTHER
# refusal branch. This fixture reaches the LEXICAL branch — `SID-x/../../…`
# normalises above PLANS_DIR before any canonicalizer is consulted, so the verdict
# is host-independent (S9-fallback owns the symlink-resolution branch).
resolve_e "$P_SFX" SID "$SFX_TRAV"
if [[ "$RES_RC" -eq 124 || "$RES_RC" -eq 126 || "$RES_RC" -eq 127 ]]; then
  fail "S13-fallback: the resolver never ran to completion (exit $RES_RC) — the refusal is unproven"
else
  assert_eq "S13-fallback: escaping suffix as the lone candidate → exit 3 (exit 0 would hand the escaping path to review-plan-codex's -f)" \
    "3" "$RES_RC"
fi
assert_eq "S13-fallback: the refusal emits nothing on stdout" "" "$RES_OUT"
if [[ "$RES_ERR" == *"$SFX_WANT_DIAG"* ]]; then
  pass "S13-fallback: stderr carries the leaves-the-plans-directory diagnostic of the branch this fixture exercises"
else
  fail "S13-fallback: stderr does not carry '$SFX_WANT_DIAG' — got: [$RES_ERR]"
fi
assert_contained "S13-fallback: escaping suffix as the lone candidate" "$P_SFX"
if [[ "$RES_OUT" == *"$SFX_SECRET"* || "$RES_ERR" == *"$SFX_SECRET"* ]]; then
  fail "S13-fallback: the escaped file's content leaked — stdout: [$RES_OUT] stderr: [$RES_ERR]"
else
  pass "S13-fallback: the escaped file's content appears on neither stdout nor stderr"
fi
assert_eq "S13-fallback: the escaped file is byte-for-byte unchanged" \
  "$SFX_TARGET_BEFORE" "$(cat "$SFX_TARGET" 2>/dev/null || printf 'MISSING')"

# --- S14-S16: shell metacharacters on a candidate SUFFIX, in inj_case's shape
# (S6-S8). `intent` follows as a real candidate, so each row also proves the
# poisoned suffix was SKIPPED rather than fatal.
sfx_inj_case() {
  local name="$1" sfx="$2" dir="$3"
  rm -f "$CANARY"
  resolve_e "$dir" SID "$sfx" intent
  if [[ -e "$CANARY" ]]; then
    fail "$name — the injected command EXECUTED (canary $CANARY was created)"
  else
    pass "$name — no command executed (canary absent)"
  fi
  assert_eq "$name: falls through to the next candidate (intent)" "$dir/SID-intent.md" "$RES_OUT"
  assert_contained "$name: emitted path" "$dir"
}
sfx_inj_case "S14: ';' command chaining in a candidate suffix"   "a;touch $CANARY;b" "$P_INJ"
sfx_inj_case "S15: '\$(...)' substitution in a candidate suffix" 'a$(touch '"$CANARY"')b' "$P_INJ"
sfx_inj_case "S16: backtick + space in a candidate suffix"       'a `touch '"$CANARY"'` b' "$P_INJ"

# --- S25-S26 (C7; CPR-ORTH with S6-S8/S14-S16, protection-fix-tests.md Pattern 4):
# the SANCTIONED LOOKALIKE in the id and suffix positions. S6-S8/S14-S16 prove an
# attack-shaped value is never EXECUTED — but in each of them the named file is
# ABSENT, so a resolver that filtered every value carrying a space or a
# metacharacter satisfies them all. S11 pins the ALLOW half for PLANS_DIR only;
# nothing proved a REAL candidate whose id or suffix legitimately carries those
# characters is still SELECTED. Both halves are asserted per row: the exact path
# (nothing expanded `$HOME` or split on the spaces) and an absent canary.
# A RELATIVE canary name is used — an absolute one carries a `:` that NTFS
# refuses inside a filename, so the payload could not be presented at all.
S25_CANARY="s25-legit-canary-2154-QZWX.txt"
S25_BODY="LEGIT-METACHAR-SID-BODY-2154-QZWX"
S25_SID='sess 2154;touch '"$S25_CANARY"';$HOME & (rev1)'
P_LEGIT="$(make_plans s25)"
rm -f "$S25_CANARY" "$TMPROOT/$S25_CANARY"
# SKIPPED (when the filename is refused): the whole sanctioned-id assertion.
# Because: where the filesystem rejects the name the sanctioned input cannot be
#          presented at all — the S10/S11/S17 idiom.
if printf '# intent\n\n%s\n' "$S25_BODY" > "$P_LEGIT/$S25_SID-intent.md" 2>/dev/null \
   && [[ -s "$P_LEGIT/$S25_SID-intent.md" ]]; then
  pass "S25-0: a candidate named with spaces, ';', '\$', '&' and parentheses really exists here — the sanctioned input is presentable"
  resolve_e "$P_LEGIT" "$S25_SID" detail outline intent
  assert_eq "S25: a legitimate metacharacter-bearing session id resolves to its exact candidate path" \
    "$P_LEGIT/$S25_SID-intent.md" "$RES_OUT"
  assert_eq "S25: legitimate metacharacter-bearing session id → exit 0 (not over-blocked by containment)" "0" "$RES_RC"
  assert_eq "S25: selecting it is silent — no refusal diagnostic on stderr" "" "$RES_ERR"
  assert_contained "S25: emitted path" "$P_LEGIT"
  assert_eq "S25: the emitted path really opens to the sanctioned candidate" \
    "$S25_BODY" "$(grep -F -- "$S25_BODY" "$RES_OUT" 2>/dev/null || printf 'UNREADABLE')"
  if [[ -e "$S25_CANARY" || -e "$TMPROOT/$S25_CANARY" ]]; then
    fail "S25: resolving the sanctioned id EXECUTED its text (canary $S25_CANARY was created)"
  else
    pass "S25: no command executed while resolving the sanctioned id (canary absent)"
  fi
else
  skip "S25: sanctioned metacharacter session id (this filesystem refused a filename carrying ';', '\$', '&' and parentheses)"
fi

# S26 — the same shape one argument over. `intent` follows as a real candidate, so
# a resolver that quietly skipped the metacharacter suffix would answer intent.md
# and the exact-path row fails loudly instead of the case passing on a fallback.
S26_CANARY="s26-legit-canary-2154-QZWX.txt"
S26_BODY="LEGIT-METACHAR-SFX-BODY-2154-QZWX"
S26_SFX='detail;touch '"$S26_CANARY"';$HOME & (final)'
P_LEGIT_SFX="$(make_plans s26 intent)"
rm -f "$S26_CANARY" "$TMPROOT/$S26_CANARY"
if printf '# custom stage\n\n%s\n' "$S26_BODY" > "$P_LEGIT_SFX/SID-$S26_SFX.md" 2>/dev/null \
   && [[ -s "$P_LEGIT_SFX/SID-$S26_SFX.md" ]]; then
  pass "S26-0: a candidate whose SUFFIX carries spaces, ';', '\$', '&' and parentheses really exists here"
  resolve_e "$P_LEGIT_SFX" SID "$S26_SFX" intent
  assert_eq "S26: a legitimate metacharacter-bearing suffix is SELECTED, not skipped in favour of intent" \
    "$P_LEGIT_SFX/SID-$S26_SFX.md" "$RES_OUT"
  assert_eq "S26: legitimate metacharacter-bearing suffix → exit 0 (not over-blocked by containment)" "0" "$RES_RC"
  assert_eq "S26: selecting it is silent — no refusal diagnostic on stderr" "" "$RES_ERR"
  assert_contained "S26: emitted path" "$P_LEGIT_SFX"
  assert_eq "S26: the emitted path really opens to the sanctioned candidate" \
    "$S26_BODY" "$(grep -F -- "$S26_BODY" "$RES_OUT" 2>/dev/null || printf 'UNREADABLE')"
  if [[ -e "$S26_CANARY" || -e "$TMPROOT/$S26_CANARY" ]]; then
    fail "S26: resolving the sanctioned suffix EXECUTED its text (canary $S26_CANARY was created)"
  else
    pass "S26: no command executed while resolving the sanctioned suffix (canary absent)"
  fi
else
  skip "S26: sanctioned metacharacter suffix (this filesystem refused a filename carrying ';', '\$', '&' and parentheses)"
fi

# --- S29 (C5, CPR-ORTH with S5-S8/S13-S16/S25-S26): EMBEDDED CONTROL CHARACTERS —
# newline, CR and tab — in the id and suffix positions. Every payload above is
# single-line, yet `lex_norm` splits its input by IFS and the resolver's own comment
# records why (a here-string `read` would end at the first newline and silently drop
# the rest of a path). A control character is therefore the one input class that can
# make the string a checker sees differ from the string the OS opens. Both halves per
# row: the traversal must still be REFUSED, and the sanctioned twin still SELECTED.
P29="$(make_plans s29 intent)"
S29_TARGET="$TMPROOT/s29-escape-detail.md"
S29_SECRET="S29-CONTROL-CHAR-SECRET-2154-QZWX"
printf '# outside the plans dir\n\n%s\n' "$S29_SECRET" > "$S29_TARGET"
S29_TARGET_BEFORE="$(cat "$S29_TARGET" 2>/dev/null || printf 'MISSING')"
S29_DIAG="the last candidate path leaves the plans directory; refusing to forward it."

# Rows carry the character's NAME, not the character: a raw newline would end the
# table row itself. position | character name
while IFS='|' read -r r_pos r_name; do
  [[ -n "$r_pos" ]] || continue
  case "$r_name" in
    newline) s29_c=$'\n' ;;
    CR)      s29_c=$'\r' ;;
    tab)     s29_c=$'\t' ;;
    *) fail "S29[$r_pos/$r_name]: unknown control-character name in the row table"; continue ;;
  esac
  # REFUSE half — the traversal segments precede the control character, so a checker
  # that stopped reading at it would see a contained path and forward the escape.
  if [[ "$r_pos" == "sid" ]]; then
    resolve_e "$P29" "../../s29-escape${s29_c}X" detail
  else
    resolve_e "$P29" SID "x/../../s29-escape${s29_c}X"
  fi
  assert_eq "S29[$r_pos/$r_name]: an escaping path carrying an embedded $r_name is refused (exit 3)" "3" "$RES_RC"
  assert_eq "S29[$r_pos/$r_name]: the refusal emits nothing on stdout" "" "$RES_OUT"
  if [[ "$RES_ERR" == *"$S29_DIAG"* ]]; then
    pass "S29[$r_pos/$r_name]: stderr carries the leaves-the-plans-directory diagnostic"
  else
    fail "S29[$r_pos/$r_name]: stderr does not carry '$S29_DIAG' — got: [$RES_ERR]"
  fi
  # The diagnostic is fixed text: it must not echo the attacker's raw bytes back,
  # which is how an embedded CR or newline reaches a terminal or a log line.
  if [[ "$RES_ERR" == *"$s29_c"* || "$RES_ERR" == *"s29-escape"* ]]; then
    fail "S29[$r_pos/$r_name]: the diagnostic echoed the attacker-controlled argument back onto stderr — [$RES_ERR]"
  else
    pass "S29[$r_pos/$r_name]: the diagnostic carries no raw $r_name and no attacker text"
  fi
  if [[ "$RES_OUT" == *"$S29_SECRET"* || "$RES_ERR" == *"$S29_SECRET"* ]]; then
    fail "S29[$r_pos/$r_name]: the outside file's content leaked — stdout: [$RES_OUT] stderr: [$RES_ERR]"
  else
    pass "S29[$r_pos/$r_name]: the outside file's content appears on neither stream"
  fi

  # ALLOW half (Pattern 4) — the same character in a candidate that legitimately
  # bears it. Without this a resolver that rejected every control character would
  # satisfy the refusals above while breaking real sessions.
  # SKIPPED (when the filename is refused): the sanctioned assertion — the S25/S26 idiom.
  if [[ "$r_pos" == "sid" ]]; then
    s29_sid="ok${s29_c}2154"; s29_sfx="intent"
  else
    s29_sid="SID29"; s29_sfx="st${s29_c}age"
  fi
  s29_want="$P29/$s29_sid-$s29_sfx.md"
  if printf '# stage\n\n%s\n' "S29-BODY-$r_pos-$r_name" > "$s29_want" 2>/dev/null && [[ -s "$s29_want" ]]; then
    pass "S29[$r_pos/$r_name]-0: a candidate bearing an embedded $r_name really exists here — the sanctioned input is presentable"
    resolve_e "$P29" "$s29_sid" detail "$s29_sfx"
    assert_eq "S29[$r_pos/$r_name]: the sanctioned candidate resolves to its exact path, control character intact" "$s29_want" "$RES_OUT"
    assert_eq "S29[$r_pos/$r_name]: the sanctioned candidate → exit 0 (not over-blocked)" "0" "$RES_RC"
    assert_eq "S29[$r_pos/$r_name]: selecting it is silent — no refusal diagnostic on stderr" "" "$RES_ERR"
    assert_contained "S29[$r_pos/$r_name]: sanctioned emitted path" "$P29"
    assert_eq "S29[$r_pos/$r_name]: the emitted path really opens the sanctioned candidate" \
      "S29-BODY-$r_pos-$r_name" "$(grep -F -- "S29-BODY-$r_pos-$r_name" "$RES_OUT" 2>/dev/null || printf 'UNREADABLE')"
  else
    skip "S29[$r_pos/$r_name]: sanctioned control-character candidate (this filesystem refused a filename carrying an embedded $r_name)"
  fi
done <<'S29ROWS'
sid|newline
sid|CR
sid|tab
suffix|newline
suffix|CR
suffix|tab
S29ROWS
# Protection Pattern 1, once for the whole table: the file every refusal row aimed at
# must be untouched — a resolver that opened or rewrote it satisfies each exit code.
assert_eq "S29-asset: the file outside PLANS_DIR is byte-for-byte unchanged after all six refusals" \
  "$S29_TARGET_BEFORE" "$(cat "$S29_TARGET" 2>/dev/null || printf 'MISSING')"

# --- S30 (C5 sibling of S29, CPR-ORTH with S25-S26): GLOB METACHARACTERS — `*`,
# `?`, `[...]` — in the id and suffix positions. `lex_norm` wraps its `segs=($p)`
# split in `set -f` / `set +f` for exactly this input class: unquoted expansion
# would let a pathname pattern in the checked string match files in the process's
# CWD and hand the containment comparison a path the caller never supplied.
# No payload above carries one, so both halves are pinned here: the escape is
# still REFUSED, and a real candidate whose name legitimately bears the character
# is still SELECTED (the over-blocking half S25-S26 pin for metacharacters).
P30="$(make_plans s30 intent)"
S30_TARGET="$TMPROOT/s30-escapeZZZ.md"
S30_SECRET="S30-GLOB-SECRET-2154-QZWX"
printf '# outside the plans dir\n\n%s\n' "$S30_SECRET" > "$S30_TARGET"
S30_TARGET_BEFORE="$(cat "$S30_TARGET" 2>/dev/null || printf 'MISSING')"
S30_DIAG="the last candidate path leaves the plans directory; refusing to forward it."

# REFUSE half. The escaping payload lands beside $S30_TARGET, so its glob really
# has something to match if pathname expansion were ever enabled here.
# position | payload-carrying argument
while IFS='|' read -r r30_pos r30_char; do
  [[ -n "$r30_pos" ]] || continue
  if [[ "$r30_pos" == "sid" ]]; then
    resolve_e "$P30" "../../s30-escape${r30_char}" detail
  else
    resolve_e "$P30" SID "x/../../s30-escape${r30_char}"
  fi
  assert_eq "S30[$r30_pos/$r30_char]: an escaping path carrying a glob metacharacter is refused (exit 3)" "3" "$RES_RC"
  assert_eq "S30[$r30_pos/$r30_char]: the refusal emits nothing on stdout" "" "$RES_OUT"
  if [[ "$RES_ERR" == *"$S30_DIAG"* ]]; then
    pass "S30[$r30_pos/$r30_char]: stderr carries the leaves-the-plans-directory diagnostic"
  else
    fail "S30[$r30_pos/$r30_char]: stderr does not carry '$S30_DIAG' — got: [$RES_ERR]"
  fi
  if [[ "$RES_OUT" == *"$S30_SECRET"* || "$RES_ERR" == *"$S30_SECRET"* ]]; then
    fail "S30[$r30_pos/$r30_char]: the neighbouring outside file's content leaked — stdout: [$RES_OUT] stderr: [$RES_ERR]"
  else
    pass "S30[$r30_pos/$r30_char]: the neighbouring outside file's content appears on neither stream"
  fi
done <<'S30ROWS'
sid|*
sid|?
sid|[Z]
suffix|*
suffix|?
suffix|[Z]
S30ROWS
# Protection Pattern 1, once for the whole table: the file the globs could have
# matched must be untouched — a resolver that opened or rewrote it satisfies each
# exit code above.
assert_eq "S30-asset: the glob-matchable file outside PLANS_DIR is byte-for-byte unchanged after all six refusals" \
  "$S30_TARGET_BEFORE" "$(cat "$S30_TARGET" 2>/dev/null || printf 'MISSING')"

# ALLOW half (Pattern 4) — a REAL candidate whose id or suffix literally contains
# the metacharacter. Without it a resolver that rejected every glob character
# would satisfy all six refusals while breaking a legitimate session.
# SKIPPED (per row, when the filename is refused): that row's sanctioned assertion.
# Because: `*` and `?` are illegal in an NTFS filename, so on this substrate the
#          sanctioned input cannot be presented at all — the S25/S26/S29 idiom.
while IFS='|' read -r a30_pos a30_char; do
  [[ -n "$a30_pos" ]] || continue
  if [[ "$a30_pos" == "sid" ]]; then
    a30_sid="sess${a30_char}2154"; a30_sfx="intent"
  else
    a30_sid="SID30"; a30_sfx="st${a30_char}age"
  fi
  a30_want="$P30/$a30_sid-$a30_sfx.md"
  a30_body="S30-BODY-$a30_pos-$a30_char"
  if printf '# stage\n\n%s\n' "$a30_body" > "$a30_want" 2>/dev/null && [[ -s "$a30_want" ]]; then
    pass "S30[$a30_pos/$a30_char]-0: a candidate named with a literal '$a30_char' really exists here — the sanctioned input is presentable"
    resolve_e "$P30" "$a30_sid" detail "$a30_sfx"
    assert_eq "S30[$a30_pos/$a30_char]: the sanctioned candidate resolves to its exact path, metacharacter intact" "$a30_want" "$RES_OUT"
    assert_eq "S30[$a30_pos/$a30_char]: the sanctioned candidate → exit 0 (not over-blocked)" "0" "$RES_RC"
    assert_eq "S30[$a30_pos/$a30_char]: selecting it is silent — no refusal diagnostic on stderr" "" "$RES_ERR"
    assert_contained "S30[$a30_pos/$a30_char]: sanctioned emitted path" "$P30"
    assert_eq "S30[$a30_pos/$a30_char]: the emitted path really opens the sanctioned candidate" \
      "$a30_body" "$(grep -F -- "$a30_body" "$RES_OUT" 2>/dev/null || printf 'UNREADABLE')"
  else
    skip "S30[$a30_pos/$a30_char]: sanctioned glob-metacharacter candidate (this filesystem refused a filename carrying a literal '$a30_char')"
  fi
done <<'S30ALLOWROWS'
sid|[Z]
sid|*
sid|?
suffix|[Z]
suffix|*
suffix|?
S30ALLOWROWS

fi  # RESOLVER_READY

echo ""
