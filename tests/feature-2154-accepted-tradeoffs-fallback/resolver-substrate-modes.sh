# Tests: bin/resolve-accepted-tradeoffs-file
# Tags: codex, review, accepted-tradeoffs, security, symlink, canonicalization, scope:issue-specific
# SUBSTRATE cases (S19-S21) — where the verdict depends on what the HOST provides,
# not on what the caller passed: an in-tree symlink (S19), an unreadable candidate
# (S20), and which canonicalizer is on PATH (S21). resolver-edge-security.sh covers
# only the refusing half of each; a check that rejects EVERY symlink, or answers
# differently under realpath than under readlink, breaks the sanctioned path while
# every existing row passes. S27 extends S20's candidate-shape family to the LAST
# candidate, the position where the scan's usability guard is not re-applied.
# Sourced by tests/feature-2154-accepted-tradeoffs-fallback.sh; split per rules/coding/file-split.md (Pattern A).
echo "=== Resolver substrate modes: in-tree symlink, unreadable candidate, canonicalizer ==="

# TL3 gap (what this file does NOT catch): the OS-level rows of S20 and S27c need
# a filesystem that honours mode bits, which MSYS does not — the deterministic
# rows below stand in for them here. S20d closes the real-subprocess half wherever
# mode bits bite (a POSIX/container run as an unprivileged user), and reports its
# own skip where they do not. Closest-to-action: check-verification-gate.sh.

if [[ "${RESOLVER_READY:-0}" -eq 0 ]]; then
  skip "S19-S21, S27: resolver unavailable (see S0)"
else

# --- S19 (allow path, protection-fix-tests.md Pattern 4): the SANCTIONED
# symlink. S9 proves an ESCAPING link is skipped; nothing proved a link that
# stays inside PLANS_DIR is still accepted. A containment check written as
# "reject anything that is a symlink" passes every S9 row and silently drops the
# ordinary case of a plans dir whose drafts are links into a shared tree.
# SKIPPED (when `ln -s` fails): both halves.
# Because: symlink creation is a Windows privilege (SeCreateSymbolicLink), so the
#          sanctioned input cannot be presented at all — the S9/S18 idiom.
P_INTREE="$(make_plans s19 outline intent)"
INTREE_BODY="IN-TREE-SYMLINK-BODY-2154-QZWX"
printf '# the real detail draft\n\n%s\n' "$INTREE_BODY" > "$P_INTREE/SID-realdetail.md"
# The absolute variant runs against the SHELL's own spelling of the same
# directory. `realpath` reports a resolved link target in the native namespace,
# so an absolute link and a plans dir spelled in two different namespaces cannot
# be compared — an MSYS-only artifact of this fixture's `cygpath -m` root, not a
# shape the stage wrappers ever produce. S19-mixed below pins what happens then.
P_INTREE_NAT="$P_INTREE"
if command -v cygpath >/dev/null 2>&1; then P_INTREE_NAT="$(cygpath -u "$P_INTREE" 2>/dev/null || printf '%s' "$P_INTREE")"; fi

# s19_link <mode> — plant SID-detail.md as an absolute or relative in-tree link.
s19_link() {
  rm -f "$P_INTREE/SID-detail.md"
  if [[ "$1" == "absolute" ]]; then
    (export MSYS=winsymlinks:nativestrict; ln -s "$P_INTREE_NAT/SID-realdetail.md" "$P_INTREE/SID-detail.md" 2>/dev/null)
  else
    (cd "$P_INTREE" && export MSYS=winsymlinks:nativestrict && ln -s "SID-realdetail.md" "SID-detail.md" 2>/dev/null)
  fi
  [[ -L "$P_INTREE/SID-detail.md" ]]
}

for s19_mode in absolute relative; do
  if ! s19_link "$s19_mode"; then
    rm -f "$P_INTREE/SID-detail.md"
    skip "S19 ($s19_mode): in-tree symlink case (symlink creation unavailable — ln -s failed; Windows/MSYS without SeCreateSymbolicLink)"
    continue
  fi
  if [[ "$s19_mode" == "absolute" ]]; then S19_DIR="$P_INTREE_NAT"; else S19_DIR="$P_INTREE"; fi
  # Fixture precondition (S9-0's idiom): a link that does not traverse would make
  # every row below a report on a broken link, not on acceptance.
  if grep -qF -- "$INTREE_BODY" "$P_INTREE/SID-detail.md" 2>/dev/null; then
    pass "S19-0 ($s19_mode): the planted in-tree symlink really resolves to its target inside PLANS_DIR"
  else
    fail "S19-0 ($s19_mode): the planted in-tree symlink does not traverse — S19's verdict would be vacuous"
  fi
  resolve_e "$S19_DIR" SID detail outline intent
  assert_eq "S19 ($s19_mode): an in-tree symlink candidate is ACCEPTED → its own path is emitted" \
    "$S19_DIR/SID-detail.md" "$RES_OUT"
  assert_eq "S19 ($s19_mode): in-tree symlink candidate → exit 0" "0" "$RES_RC"
  assert_eq "S19 ($s19_mode): accepting it is silent — no refusal diagnostic on stderr" "" "$RES_ERR"
  # The point of accepting it: the consumer must be able to READ the draft
  # through the emitted path. An emitted path that no longer opens would satisfy
  # the string comparison above and still break review-plan-codex's `-f`.
  assert_eq "S19 ($s19_mode): the emitted path really opens to the linked draft" \
    "$INTREE_BODY" "$(grep -F -- "$INTREE_BODY" "$RES_OUT" 2>/dev/null || printf 'UNREADABLE')"
  S19_V="$(canon_verdict "$RES_OUT" "$S19_DIR")"
  if [[ "$S19_V" == "unknown" ]]; then
    skip "S19 ($s19_mode) canonical verdict: no realpath / readlink -f on PATH"
  else
    assert_eq "S19 ($s19_mode): the accepted link canonically resolves INSIDE PLANS_DIR" "inside" "$S19_V"
  fi
done

# S19-mixed — the absolute link addressed through the OTHER spelling of the same
# directory. On MSYS the canonicalizer then answers in a namespace the plans dir
# is not written in, and the candidate is skipped fail-closed; elsewhere the two
# spellings are identical and it is accepted. Both outcomes are safe, so the row
# asserts what must hold EITHER way — contained, exit 0, and no target content on
# either stream — rather than pinning one host's answer as the contract.
if s19_link absolute; then
  resolve_e "$P_INTREE" SID detail outline intent
  assert_eq "S19-mixed: an in-tree absolute link under the other path spelling → exit 0 (accepted or skipped, never refused)" \
    "0" "$RES_RC"
  assert_contained "S19-mixed: the emitted path" "$P_INTREE"
  if [[ "$RES_OUT" == *"$INTREE_BODY"* || "$RES_ERR" == *"$INTREE_BODY"* ]]; then
    fail "S19-mixed: the linked draft's content leaked — stdout: [$RES_OUT] stderr: [$RES_ERR]"
  else
    pass "S19-mixed: the linked draft's content appears on neither stdout nor stderr"
  fi
fi
rm -f "$P_INTREE/SID-detail.md"

# --- S20 (C6): the unreadable candidate, WITHOUT depending on chmod. S4 skips
# whenever `chmod 000` is a no-op, which on this host is always — so the
# readability conjunct of the candidate guard has never been exercised here at
# all, and deleting `-r "$CAND"` from the source would keep the suite green.
# S20a reads the guard line OUT OF THE SOURCE and evaluates it, so the row is
# bound to the code under test rather than restating it; S20b then drives the
# same `|| continue` handler end-to-end through a conjunct this substrate can
# falsify. Layer A's E2 (empty detail.md) is the `-s` sibling of S20b and is not
# duplicated here.
S20_GUARD_RAW="$(grep -m1 -- '-r "\$CAND"' "$RESOLVER" 2>/dev/null || true)"
S20_EXPR="$(printf '%s' "$S20_GUARD_RAW" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*||[[:space:]]*continue[[:space:]]*$//')"
if [[ -z "$S20_EXPR" ]]; then
  fail "S20a: no candidate guard testing '-r \"\$CAND\"' found in $RESOLVER — the readability check is gone, or moved and is now untested"
else
  pass "S20a-0: the candidate guard line was located in the source: [$S20_EXPR]"
  case "$S20_GUARD_RAW" in
    *"|| continue") pass "S20a-0: a failing candidate guard falls through to 'continue' (skip), not to an abort" ;;
    *) fail "S20a-0: the candidate guard no longer ends in '|| continue': [$S20_GUARD_RAW]" ;;
  esac
fi

# The mock: the SOURCE's own guard expression, evaluated here with only its
# readability operand redirected at a path that cannot be read. Nothing else
# about the expression is rewritten, so a guard that stopped consulting `-r`
# would fail S20a-neg — the assertion `chmod 000` cannot make on this host.
S20_FROM='-r "$CAND"'
S20_TO='-r "$RPROBE"'
S20_NEG="${S20_EXPR/"$S20_FROM"/"$S20_TO"}"
P_S20="$(make_plans s20 detail outline intent)"
CAND="$P_S20/SID-detail.md"
RPROBE="$TMPROOT/s20-no-such-file-2154-QZWX"
rm -f "$RPROBE"
if [[ -z "$S20_EXPR" ]]; then
  skip "S20a positive/negative evaluation: the guard expression could not be extracted"
elif [[ "$S20_NEG" == "$S20_EXPR" ]]; then
  fail "S20a: the readability operand could not be isolated in [$S20_EXPR] — the negative row would re-run the positive one"
else
  if eval "$S20_EXPR"; then
    pass "S20a+: the source's candidate guard ACCEPTS a readable, non-empty candidate"
  else
    fail "S20a+: the source's candidate guard rejects an ordinary readable candidate — S20a- would pass for the wrong reason"
  fi
  if eval "$S20_NEG"; then
    fail "S20a-: the source's candidate guard still passes when its readability operand is unreadable — the '-r' conjunct is not decisive"
  else
    pass "S20a-: the source's candidate guard REJECTS when readability fails"
  fi
fi
unset CAND RPROBE

# S20b — the same handler, end to end, through the one conjunct this substrate
# can falsify deterministically: a candidate that is not a regular file. It pins
# the observable half of S4's contract (skip and continue to the next candidate,
# exit 0) on every host, chmod or no chmod.
P_S20B="$(make_plans s20b outline intent)"
mkfifo "$P_S20B/SID-detail.md" 2>/dev/null || printf 'x' > "$P_S20B/SID-detail.md"
if [[ -p "$P_S20B/SID-detail.md" ]]; then
  resolve "$P_S20B" SID detail outline intent
  assert_eq "S20b: an unopenable (non-regular) candidate is skipped → outline path emitted" \
    "$P_S20B/SID-outline.md" "$RES_OUT"
  assert_eq "S20b: unopenable candidate → exit 0 (skip, not refusal)" "0" "$RES_RC"
else
  skip "S20b: non-regular-candidate case (mkfifo unavailable on this filesystem)"
fi
rm -f "$P_S20B/SID-detail.md"

# S20c — the strong OS-level contract, run only where mode bits are real. Kept
# alongside S4 rather than replacing it: where the host honours chmod this is the
# assertion that actually observes a permission denial.
P_S20C="$(make_plans s20c outline intent)"
printf '# detail\n\nsecret\n' > "$P_S20C/SID-detail.md"
chmod 000 "$P_S20C/SID-detail.md" 2>/dev/null || true
if [[ -r "$P_S20C/SID-detail.md" ]]; then
  skip "S20c: OS-level unreadable-candidate case (chmod 000 ineffective here — S20a/S20b carry the deterministic coverage)"
else
  resolve "$P_S20C" SID detail outline intent
  assert_eq "S20c: a genuinely unreadable candidate is skipped → outline path emitted" \
    "$P_S20C/SID-outline.md" "$RES_OUT"
  assert_eq "S20c: genuinely unreadable candidate → exit 0" "0" "$RES_RC"
fi
chmod 644 "$P_S20C/SID-detail.md" 2>/dev/null || true

# --- S20d (C5): the REAL SUBPROCESS permission boundary. S20a evaluates the source's
# guard expression in THIS shell, so the kernel's open(2) denial is never on the path;
# S20c runs the resolver but decides readability from the same shell's `-r`. S20d probes
# unreadability the way a consumer meets it — a separate process that actually tries to
# open the file — and only then runs the resolver as its own `bash "$RESOLVER"` process.
# SKIPPED (when the probe still opens the file): the whole row.
# Because: mode bits are advisory on Windows/MSYS (the S4 / S20c / S27c precedent), so
#          the unreadable shape cannot be built here at all.
P_S20D="$(make_plans s20d outline intent)"
S20D_BODY="S20D-UNREADABLE-BODY-2154-QZWX"
S20D_CAND="$P_S20D/SID-detail.md"
printf '# detail\n\n%s\n' "$S20D_BODY" > "$S20D_CAND"
S20D_BEFORE="$(cat "$S20D_CAND" 2>/dev/null || printf 'MISSING')"
chmod 000 "$S20D_CAND" 2>/dev/null || true
# The probe is a child process, not a `[[ -r ]]` test: that is the boundary the concern
# names, and on a host where mode bits are advisory it is the half that still answers.
if with_timeout bash -c 'cat -- "$1" >/dev/null 2>&1' _ "$S20D_CAND"; then
  skip "S20d: real-subprocess unreadable-candidate case (a child process still opens the chmod-000 candidate on this filesystem — mode bits are advisory here; S20a/S20b carry the deterministic coverage)"
else
  pass "S20d-0: a child process is genuinely denied the candidate — the permission boundary is real on this host"
  resolve_e "$P_S20D" SID detail outline intent
  assert_eq "S20d: the resolver subprocess skips the unreadable candidate → outline path emitted" \
    "$P_S20D/SID-outline.md" "$RES_OUT"
  assert_eq "S20d: unreadable candidate → exit 0 (skip, not refusal)" "0" "$RES_RC"
  assert_eq "S20d: skipping it is silent — no diagnostic replays the candidate on stderr" "" "$RES_ERR"
  if [[ "$RES_OUT" == *"$S20D_BODY"* || "$RES_ERR" == *"$S20D_BODY"* ]]; then
    fail "S20d: the unreadable candidate's content leaked — stdout: [$RES_OUT] stderr: [$RES_ERR]"
  else
    pass "S20d: the unreadable candidate's content appears on neither stdout nor stderr"
  fi
  # Protection Pattern 1: the file the resolver could not read is the protected asset.
  chmod 644 "$S20D_CAND" 2>/dev/null || true
  assert_eq "S20d-asset: the unreadable candidate is byte-for-byte unchanged after the run" \
    "$S20D_BEFORE" "$(cat "$S20D_CAND" 2>/dev/null || printf 'MISSING')"
fi
chmod 644 "$S20D_CAND" 2>/dev/null || true

# --- S21 (C7): the canonicalizer the resolver picks is whatever the host offers
# — `realpath` when present, else `readlink -f`. Every other row runs under
# whichever one this machine happens to have, so a containment verdict that is
# correct under one and wrong under the other would show up on some developers'
# machines and not others. S21 pins BOTH by handing the resolver a PATH holding
# exactly one of them.
S21_RP="$(command -v realpath 2>/dev/null || true)"
S21_RL="$(command -v readlink 2>/dev/null || true)"
S21_BASH="$(command -v bash)"
S21_FIX_RP="$TMPROOT/s21-path-realpath-only"
S21_FIX_RL="$TMPROOT/s21-path-readlink-only"
mkdir -p "$S21_FIX_RP" "$S21_FIX_RL"
if [[ -n "$S21_RP" ]]; then
  printf '#!/bin/bash\nexec "%s" "$@"\n' "$S21_RP" > "$S21_FIX_RP/realpath"
  chmod +x "$S21_FIX_RP/realpath"
fi
if [[ -n "$S21_RL" ]]; then
  printf '#!/bin/bash\nexec "%s" "$@"\n' "$S21_RL" > "$S21_FIX_RL/readlink"
  chmod +x "$S21_FIX_RL/readlink"
fi
# PATH entries are colon-separated, so the `C:/...` spelling this fixture root
# uses would split into two bogus entries and leave the fixture unreachable —
# the canonicalizer would then look absent and the modes would be
# indistinguishable from S21-control. PATH always gets the native spelling.
if command -v cygpath >/dev/null 2>&1; then
  S21_FIX_RP="$(cygpath -u "$S21_FIX_RP" 2>/dev/null || printf '%s' "$S21_FIX_RP")"
  S21_FIX_RL="$(cygpath -u "$S21_FIX_RL" 2>/dev/null || printf '%s' "$S21_FIX_RL")"
fi

P_S21="$(make_plans s21 detail outline intent)"
# s21_run <fixture-dir> <plans-dir> → S21_OUT / S21_RC, PATH holding only that
# fixture. Called WITHOUT with_timeout on purpose: the timeout helper itself
# lives on PATH, and S12 established the same direct form for this reason.
s21_run() {
  S21_OUT="$(PATH="$1" "$S21_BASH" "$RESOLVER" "$2" SID detail outline intent 2>/dev/null)"
  S21_RC=$?
}

# S21-control: with NEITHER canonicalizer reachable the resolver is fail-closed
# (S12) and answers `intent`, not `detail`. That difference is what makes the two
# rows below meaningful — without it a fixture whose canonicalizer never ran
# would produce the same `detail` answer and the case would prove nothing.
s21_run "" "$P_S21"
S21_CTRL_OUT="$S21_OUT"; S21_CTRL_RC="$S21_RC"
if [[ "$S21_CTRL_RC" -ne 0 || -z "$S21_CTRL_OUT" ]]; then
  skip "S21: canonicalizer-mode cases (the resolver does not complete with a restricted PATH: rc=$S21_CTRL_RC)"
elif [[ "$S21_CTRL_OUT" == "$P_S21/SID-detail.md" ]]; then
  skip "S21: canonicalizer-mode cases (no canonicalizer produces the same answer as one — the fixtures cannot be told apart on this host)"
else
  assert_eq "S21-control: with no canonicalizer on PATH the scan is fail-closed → exempt last candidate" \
    "$P_S21/SID-intent.md" "$S21_CTRL_OUT"
  for s21_mode in realpath readlink; do
    if [[ "$s21_mode" == "realpath" ]]; then s21_fix="$S21_FIX_RP"; s21_have="$S21_RP"; else s21_fix="$S21_FIX_RL"; s21_have="$S21_RL"; fi
    if [[ -z "$s21_have" ]]; then
      skip "S21 ($s21_mode-only): no $s21_mode on this host to build the fixture from"
      continue
    fi
    s21_run "$s21_fix" "$P_S21"
    assert_eq "S21 ($s21_mode-only): the first candidate is verified and emitted" \
      "$P_S21/SID-detail.md" "$S21_OUT"
    assert_eq "S21 ($s21_mode-only): exit 0" "0" "$S21_RC"
  done
fi

# S21-escape — the containment VERDICT, not just the happy path, under each
# canonicalizer. The two tools differ on symlinks and trailing components, so an
# escaping link skipped under one must be skipped under the other too.
# SKIPPED (when ln -s fails, or S21's fixtures could not be told apart): both rows.
# Because: without a real symlink there is no escape to canonicalize, and without
#          a discriminating control a matching answer proves nothing.
P_S21E="$(make_plans s21e outline intent)"
S21E_TARGET="$TMPROOT/s21-escape-target.md"
printf '# outside\n\nS21-ESCAPE-SECRET-2154-QZWX\n' > "$S21E_TARGET"
if [[ "$S21_CTRL_RC" -ne 0 || -z "$S21_CTRL_OUT" ]]; then
  skip "S21-escape: canonicalizer-mode containment (the resolver does not complete with a restricted PATH — see S21)"
elif (export MSYS=winsymlinks:nativestrict; ln -s "$S21E_TARGET" "$P_S21E/SID-detail.md" 2>/dev/null) && [[ -L "$P_S21E/SID-detail.md" ]]; then
  if grep -qF -- "S21-ESCAPE-SECRET-2154-QZWX" "$P_S21E/SID-detail.md" 2>/dev/null; then
    pass "S21-escape-0: the planted symlink really resolves to the external file"
  else
    fail "S21-escape-0: the planted symlink does not traverse — S21-escape's verdict would be vacuous"
  fi
  for s21_mode in realpath readlink; do
    if [[ "$s21_mode" == "realpath" ]]; then s21_fix="$S21_FIX_RP"; s21_have="$S21_RP"; else s21_fix="$S21_FIX_RL"; s21_have="$S21_RL"; fi
    if [[ -z "$s21_have" ]]; then
      skip "S21-escape ($s21_mode-only): no $s21_mode on this host to build the fixture from"
      continue
    fi
    s21_run "$s21_fix" "$P_S21E"
    assert_eq "S21-escape ($s21_mode-only): the escaping symlink is skipped → outline path emitted" \
      "$P_S21E/SID-outline.md" "$S21_OUT"
    assert_eq "S21-escape ($s21_mode-only): exit 0 (skip, not refusal)" "0" "$S21_RC"
  done
else
  rm -f "$P_S21E/SID-detail.md"
  skip "S21-escape: canonicalizer-mode containment (symlink creation unavailable — ln -s failed; Windows/MSYS without SeCreateSymbolicLink)"
fi

# --- S27 (C6): an EXISTING-but-UNUSABLE candidate in the LAST position. The scan
# loop guards `-f && -s && -r` and skips whatever fails it (S3 directory, S4/S20
# unreadable, Layer A's E2 empty). The last-candidate fallback re-checks
# CONTAINMENT ONLY, so those same shapes are emitted at exit 0 once nothing
# earlier qualified. Layer A case 4 owns the ABSENT last candidate; these rows own
# the three EXISTING-but-unusable ones and pin the contract that EXISTS today —
# tightening the fallback to re-apply the scan guard must edit them, not add to them.
P_S27A="$(make_plans s27a)"
: > "$P_S27A/SID-intent.md"
S27A_PATH="$P_S27A/SID-intent.md"
if [[ -f "$S27A_PATH" && ! -s "$S27A_PATH" ]]; then
  pass "S27a-0: the last candidate exists as a zero-byte regular file — the exact shape the scan guard's '-s' conjunct rejects"
else
  fail "S27a-0: the fixture is not a zero-byte regular file — S27a would judge a different shape"
fi
resolve_e "$P_S27A" SID detail outline intent
assert_eq "S27a: an EMPTY last candidate is still emitted → its exact path" "$S27A_PATH" "$RES_OUT"
assert_eq "S27a: empty last candidate → exit 0 (the fallback does not re-apply the scan's '-s' guard)" "0" "$RES_RC"
assert_eq "S27a: emitting it is silent — nothing on stderr warns the caller the file is empty" "" "$RES_ERR"
assert_contained "S27a: emitted path" "$P_S27A"
# The downstream consequence, asserted rather than assumed: review-plan-codex
# admits the tradeoffs file on `-f` alone, which an empty file passes — so the
# settled-decisions block renders empty and the review silently proceeds without it.
if [[ -f "$RES_OUT" ]]; then
  pass "S27a-downstream: the emitted path passes review-plan-codex's own '-f' admission check while carrying no settled-decision content"
else
  fail "S27a-downstream: the emitted path no longer passes '-f' — the downstream reading of this contract has changed: [$RES_OUT]"
fi

# S27b — the same position, the shape S3 skips mid-scan.
P_S27B="$(make_plans s27b)"
mkdir -p "$P_S27B/SID-intent.md"
resolve_e "$P_S27B" SID detail outline intent
assert_eq "S27b: a DIRECTORY as the last candidate is still emitted → its exact path" "$P_S27B/SID-intent.md" "$RES_OUT"
assert_eq "S27b: directory last candidate → exit 0 (the fallback does not re-apply the scan's '-f' guard)" "0" "$RES_RC"
assert_contained "S27b: emitted path" "$P_S27B"
if [[ -f "$RES_OUT" ]]; then
  fail "S27b-downstream: a directory path passed review-plan-codex's '-f' admission check: [$RES_OUT]"
else
  pass "S27b-downstream: the emitted directory path is caught downstream by review-plan-codex's own '-f' admission check"
fi

# S27c — the shape S4/S20c skip mid-scan. Guarded like them: where chmod is a
# no-op the fixture is not unreadable and the row would judge an ordinary file.
# SKIPPED (when `chmod 000` leaves the file readable): the whole row.
# Because: mode bits are advisory on Windows/MSYS, so the shape cannot be built.
P_S27C="$(make_plans s27c)"
S27C_BODY="S27-UNREADABLE-BODY-2154-QZWX"
printf '# intent\n\n%s\n' "$S27C_BODY" > "$P_S27C/SID-intent.md"
chmod 000 "$P_S27C/SID-intent.md" 2>/dev/null || true
if [[ -r "$P_S27C/SID-intent.md" ]]; then
  skip "S27c: unreadable last candidate (chmod 000 ineffective on this filesystem — the file is still readable)"
else
  resolve_e "$P_S27C" SID detail outline intent
  assert_eq "S27c: an UNREADABLE last candidate is still emitted → its exact path" "$P_S27C/SID-intent.md" "$RES_OUT"
  assert_eq "S27c: unreadable last candidate → exit 0 (the fallback does not re-apply the scan's '-r' guard)" "0" "$RES_RC"
  assert_contained "S27c: emitted path" "$P_S27C"
  if [[ "$RES_OUT" == *"$S27C_BODY"* || "$RES_ERR" == *"$S27C_BODY"* ]]; then
    fail "S27c: the unreadable candidate's content leaked — stdout: [$RES_OUT] stderr: [$RES_ERR]"
  else
    pass "S27c: the unreadable candidate's content appears on neither stdout nor stderr"
  fi
fi
chmod 644 "$P_S27C/SID-intent.md" 2>/dev/null || true

fi  # RESOLVER_READY

echo ""
