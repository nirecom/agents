# Tests: bin/resolve-accepted-tradeoffs-file
# Tags: codex, review, accepted-tradeoffs, security, traversal, boundary, scope:issue-specific
# ARGUMENT BOUNDARY cases (S22-S24) — the shapes of the three caller-supplied
# arguments that the existing rows never present: a Windows-style BACKSLASH
# traversal (S22), an EMPTY string in each position (S23), and the value
# boundaries duplicates and near-limit lengths sit on (S24). The resolver
# normalises `\` to `/` before deciding containment, so a backslash payload is a
# first-class attack input on this host, not a curiosity.
# Sourced by tests/feature-2154-accepted-tradeoffs-fallback.sh; split per rules/coding/file-split.md (Pattern A).
echo "=== Resolver argument boundaries: backslash traversal, empty strings, limits ==="

# TL3 gap (what this file does NOT catch): a real NTFS host reached through a
# non-MSYS shell, where `\` is the only separator the OS accepts and the
# forward-slash reference S22 compares against does not exist; and, for S28, the
# working directory a production wrapper actually runs in — the relative spellings
# are exercised against a fixture CWD, never against a caller that changed
# directories mid-run; and, for S28j, a POSIX host where `//x` is an ordinary path, on
# which the root rejection comes from the containment test rather than from MSYS's UNC
# reading of the doubled prefix. Closest-to-action: check-verification-gate.sh.

if [[ "${RESOLVER_READY:-0}" -eq 0 ]]; then
  skip "S22-S24: resolver unavailable (see S0)"
else

# --- S22 (C5): backslash traversal. S5 and S13 present `../` only. `lex_norm`
# rewrites `\` to `/` precisely so `..\..\x` cannot slip past a check written for
# `../../x` — and nothing tested that rewrite, so dropping it would leave the
# suite green while reopening the escape on the one platform that uses `\`.
# Judged as PARITY against the forward-slash form resolved in the same run, so
# the row cannot be satisfied by a resolver that merely fails both ways.
P_BS="$(make_plans s22 intent)"
mkdir -p "$P_BS/SID-sub"
BS_TARGET="$TMPROOT/s22-backslash-escape.md"
BS_SECRET="BACKSLASH-ESCAPE-SECRET-2154-QZWX"
printf '# outside the plans dir\n\n%s\n' "$BS_SECRET" > "$BS_TARGET"
BS_TARGET_BEFORE="$(cat "$BS_TARGET" 2>/dev/null || printf 'MISSING')"

# The two suffixes name the SAME external file — one through `/`, one through
# `\`. Anything the resolver does to the first it must do to the second.
BS_SFX_FWD='sub/../../s22-backslash-escape'
BS_SFX_BSL='sub\..\..\s22-backslash-escape'

# S22-0 (fixture precondition): the payload must really reach the external file
# on this filesystem, or the parity rows below compare two harmless no-ops.
if [[ -f "$P_BS/SID-$BS_SFX_BSL.md" ]]; then
  pass "S22-0: the backslash suffix really names the external file on this filesystem — the escape is presentable"
else
  fail "S22-0: the backslash suffix does not resolve to the external file; S22 would compare two inert inputs"
fi

resolve_e "$P_BS" SID "$BS_SFX_FWD" intent
BS_FWD_OUT="$RES_OUT"; BS_FWD_RC="$RES_RC"
resolve_e "$P_BS" SID "$BS_SFX_BSL" intent
assert_eq "S22: a backslash traversal suffix is skipped exactly like its '../' twin (stdout)" "$BS_FWD_OUT" "$RES_OUT"
assert_eq "S22: a backslash traversal suffix is skipped exactly like its '../' twin (exit code)" "$BS_FWD_RC" "$RES_RC"
# Anti-vacuity for the parity rows: the reference itself must be the CONTAINED
# outcome, not a shared crash. Without this row a resolver that exited 127 on
# both inputs would satisfy both comparisons above.
assert_eq "S22-ref: the '../' reference stays contained → the next candidate (intent) is emitted" \
  "$P_BS/SID-intent.md" "$BS_FWD_OUT"
assert_eq "S22-ref: the '../' reference exits 0 (skip, not refusal)" "0" "$BS_FWD_RC"
assert_contained "S22: the backslash-suffix emitted path" "$P_BS"

# S22-lone — the same payload as the ONLY candidate, so the exempt last-candidate
# fallback is reached with a path that leaves PLANS_DIR. Refusing the `/` form
# and forwarding the `\` form is the exact bypass this row closes.
BSL_ERRF="$TMPROOT/s22-lone-stderr.txt"
rm -f "$BSL_ERRF"
BS_LONE_FWD_OUT="$(with_timeout bash "$RESOLVER" "$P_BS" SID "$BS_SFX_FWD" 2>/dev/null)"
BS_LONE_FWD_RC=$?
BS_LONE_BSL_OUT="$(with_timeout bash "$RESOLVER" "$P_BS" SID "$BS_SFX_BSL" 2>"$BSL_ERRF")"
BS_LONE_BSL_RC=$?
BSL_ERR="$(cat "$BSL_ERRF" 2>/dev/null || true)"
assert_eq "S22-lone: the '../' reference as the lone candidate is REFUSED (exit 3)" "3" "$BS_LONE_FWD_RC"
assert_eq "S22-lone: a lone backslash traversal candidate is refused identically (exit code)" "$BS_LONE_FWD_RC" "$BS_LONE_BSL_RC"
assert_eq "S22-lone: a lone backslash traversal candidate is refused identically (stdout)" "$BS_LONE_FWD_OUT" "$BS_LONE_BSL_OUT"
assert_eq "S22-lone: the backslash refusal emits nothing on stdout" "" "$BS_LONE_BSL_OUT"
if [[ -s "$BSL_ERRF" ]]; then
  pass "S22-lone: the backslash refusal carries a diagnostic on stderr"
else
  fail "S22-lone: refused silently — nothing tells the operator a backslash traversal was rejected"
fi
if [[ "$BSL_ERR" == *"$BS_SECRET"* || "$BS_LONE_BSL_OUT" == *"$BS_SECRET"* ]]; then
  fail "S22-lone: the external file's content leaked — stdout: [$BS_LONE_BSL_OUT] stderr: [$BSL_ERR]"
else
  pass "S22-lone: the external file's content appears on neither stdout nor stderr"
fi
# Protection Pattern 1: the file outside PLANS_DIR is the protected asset.
assert_eq "S22-asset: the external file is byte-for-byte unchanged after both refusals" \
  "$BS_TARGET_BEFORE" "$(cat "$BS_TARGET" 2>/dev/null || printf 'MISSING')"

# --- S23 (C8): the EMPTY STRING in each argument position. Every existing row
# passes non-empty values, yet an empty PLANS_DIR or SESSION_ID is exactly what a
# wrapper hands over when an upstream variable is unset — and `$PLANS_DIR/$SID-`
# would then name a path in the CURRENT directory. The resolver's `[[ -n ... ]]`
# usage guard is what stops that, and these rows pin it.
P_EMPTY="$(make_plans s23 outline intent)"
resolve_e "" SID detail outline intent
assert_eq "S23a: an empty PLANS_DIR → exit 2 (usage error), not a lookup rooted at the CWD" "2" "$RES_RC"
assert_eq "S23a: an empty PLANS_DIR → empty stdout" "" "$RES_OUT"
resolve_e "$P_EMPTY" "" detail outline intent
assert_eq "S23b: an empty SESSION_ID → exit 2 (usage error)" "2" "$RES_RC"
assert_eq "S23b: an empty SESSION_ID → empty stdout" "" "$RES_OUT"

# S23c — an empty SUFFIX is NOT a usage error: the guard covers only the first
# two arguments, so `""` is an ordinary suffix naming `<SID>-.md`. Pinned as the
# behaviour that exists, not as the behaviour one might prefer; the rows below
# say what a caller can rely on today.
resolve_e "$P_EMPTY" SID "" outline intent
assert_eq "S23c: an empty suffix names an absent candidate → the scan continues to outline" \
  "$P_EMPTY/SID-outline.md" "$RES_OUT"
assert_eq "S23c: an empty suffix → exit 0 (skipped, not rejected)" "0" "$RES_RC"
printf '# blank-suffix draft\n\nblank\n' > "$P_EMPTY/SID-.md"
resolve_e "$P_EMPTY" SID "" outline intent
assert_eq "S23d: an empty suffix whose file EXISTS is used like any other candidate" \
  "$P_EMPTY/SID-.md" "$RES_OUT"
assert_eq "S23d: an existing empty-suffix candidate → exit 0" "0" "$RES_RC"
assert_contained "S23d: the empty-suffix emitted path" "$P_EMPTY"

# --- S24 (C9): value boundaries. (a) DUPLICATE suffixes — a caller that passes
# the same stage twice must get the documented first match, not a second scan or
# a skipped candidate; (b) a session id near the filesystem's path-length limit,
# where a resolver that truncated or mangled the name would answer a path that
# opens to the wrong file.
P_DUP="$(make_plans s24 detail outline intent)"
resolve_e "$P_DUP" SID detail detail outline intent
assert_eq "S24a: a duplicated first suffix still resolves to the first match" "$P_DUP/SID-detail.md" "$RES_OUT"
assert_eq "S24a: duplicated suffixes → exit 0" "0" "$RES_RC"
rm -f "$P_DUP/SID-detail.md"
# With the duplicated stage now ABSENT, both of its occurrences must be skipped —
# a resolver that re-entered the chain on the second occurrence would answer
# detail again, or stall; the documented answer is the next present stage.
resolve_e "$P_DUP" SID detail outline detail intent
assert_eq "S24b: a duplicate of an ABSENT suffix is skipped both times → outline" "$P_DUP/SID-outline.md" "$RES_OUT"
assert_eq "S24b: duplicate of an absent suffix → exit 0" "0" "$RES_RC"
resolve_e "$P_DUP" SID outline outline outline
assert_eq "S24c: the same suffix repeated as the whole chain resolves once" "$P_DUP/SID-outline.md" "$RES_OUT"
assert_eq "S24c: a wholly duplicated chain → exit 0" "0" "$RES_RC"

# S24d — the length boundary. The id is built long enough to push the candidate
# path toward the classic 260-character Windows limit while staying creatable;
# where the filesystem refuses it the case says so instead of asserting on a file
# that was never written.
# SKIPPED (when the long candidate cannot be created): the exact-path assertion.
# Because: without the file the run exercises the absent-candidate fallback,
#          which Layer A case 4 already owns.
S24_LONG_SID="$(printf 'L%.0s' $(seq 1 180))"
if printf '# intent\n\nlong\n' > "$P_DUP/$S24_LONG_SID-intent.md" 2>/dev/null && [[ -s "$P_DUP/$S24_LONG_SID-intent.md" ]]; then
  resolve_e "$P_DUP" "$S24_LONG_SID" detail outline intent
  assert_eq "S24d: a near-limit-length session id resolves to its exact, untruncated path" \
    "$P_DUP/$S24_LONG_SID-intent.md" "$RES_OUT"
  assert_eq "S24d: near-limit-length session id → exit 0" "0" "$RES_RC"
  assert_contained "S24d: the near-limit emitted path" "$P_DUP"
else
  skip "S24d: near-limit path-length case (this filesystem refused a ${#S24_LONG_SID}-character session id)"
fi

# S24e — the same boundary in the SUFFIX position, with a following stage that
# does exist: an over-long candidate must be skipped like any other absent one
# rather than aborting the scan.
S24_LONG_SFX="$(printf 'S%.0s' $(seq 1 200))"
resolve_e "$P_DUP" SID "$S24_LONG_SFX" outline
assert_eq "S24e: an over-long suffix is skipped → the next present stage is emitted" \
  "$P_DUP/SID-outline.md" "$RES_OUT"
assert_eq "S24e: an over-long suffix → exit 0 (no crash, no abort)" "0" "$RES_RC"

# --- S28 (C4): RELATIVE PLANS_DIR spellings. Every fixture in this suite hands the
# resolver an absolute directory, but `lex_norm` decides containment on the STRING,
# and its two comparands are spelled differently for a relative argument: a `.` or
# `./` normalises to the EMPTY string, so the fallback's `"$LEX_LAST" != "$LEX_DIR"/*`
# test compares against the pattern `/*` and can never match. Nothing observed which
# spellings still forward and which do not, so the rows below pin the resolved path
# and status EMPIRICALLY per spelling rather than assuming one contract for all.
S28_ROOT="$TMPROOT/s28-relative"
mkdir -p "$S28_ROOT/sub"
printf '# detail\n\nrel\n' > "$S28_ROOT/SID-detail.md"
printf '# detail\n\nrel\n' > "$S28_ROOT/sub/SID-detail.md"
S28_OUTSIDE="$TMPROOT/s28-outside.md"
printf '# outside\n\nS28-OUTSIDE-SECRET-2154-QZWX\n' > "$S28_OUTSIDE"

# rel_run <plans-dir> <sid> <suffix...> — the resolver with its CWD moved into the
# fixture root, which is what makes a relative PLANS_DIR mean what the caller meant.
rel_run() {
  local errf="$TMPROOT/s28-stderr.txt"
  rm -f "$errf"
  REL_OUT="$(cd "$S28_ROOT" && with_timeout bash "$RESOLVER" "$@" 2>"$errf")"
  REL_RC=$?
  REL_ERR="$(cat "$errf" 2>/dev/null || true)"
}

# S28-0 (fixture precondition): the present-candidate half must really have files to
# find through BOTH the bare-dot and the named-subdirectory spellings, or its rows
# would silently become all-absent rows and prove the wrong thing.
if [[ -s "$S28_ROOT/SID-detail.md" && -s "$S28_ROOT/sub/SID-detail.md" ]]; then
  pass "S28-0: both relative-fixture candidates exist — the present-candidate rows are not vacuous"
else
  fail "S28-0: the relative fixture is incomplete; S28 present-candidate rows would test absence instead"
fi

# spelling | session id | expected exit | expected stdout (empty = none)
S28_ESCAPES=""
while IFS='|' read -r r_dir r_sid r_rc r_out; do
  [[ -n "$r_dir" ]] || continue
  rel_run "$r_dir" "$r_sid" detail outline intent
  assert_eq "S28[$r_dir/$r_sid]: exit status" "$r_rc" "$REL_RC"
  assert_eq "S28[$r_dir/$r_sid]: emitted path is the caller's own spelling, verbatim" "$r_out" "$REL_OUT"
  # Containment, judged on the path as the CALLER would open it: from the fixture
  # CWD. A relative spelling that resolved outside the root is the escape this case
  # exists to catch, and stdout comparison alone would not name it.
  if [[ -n "$REL_OUT" ]] && command -v realpath >/dev/null 2>&1; then
    r_abs="$(cd "$S28_ROOT" && realpath -m -- "$REL_OUT" 2>/dev/null || true)"
    r_root="$(cd "$S28_ROOT" && realpath -m -- . 2>/dev/null || true)"
    if [[ -z "$r_abs" || -z "$r_root" || "$r_abs" != "$r_root"/* ]]; then
      S28_ESCAPES="$S28_ESCAPES [$r_dir/$r_sid → $r_abs]"
    fi
  fi
done <<'S28ROWS'
.|SID|0|./SID-detail.md
./|SID|0|.//SID-detail.md
sub|SID|0|sub/SID-detail.md
sub/|SID|0|sub//SID-detail.md
./sub|SID|0|./sub/SID-detail.md
./sub/|SID|0|./sub//SID-detail.md
sub/.|SID|0|sub/./SID-detail.md
.|SIDX|3|
./|SIDX|3|
sub|SIDX|0|sub/SIDX-intent.md
sub/|SIDX|0|sub//SIDX-intent.md
./sub|SIDX|0|./sub/SIDX-intent.md
./sub/|SIDX|0|./sub//SIDX-intent.md
sub/.|SIDX|0|sub/./SIDX-intent.md
S28ROWS
if command -v realpath >/dev/null 2>&1; then
  if [[ -z "$S28_ESCAPES" ]]; then
    pass "S28-contain: every path emitted for a relative PLANS_DIR resolves inside the fixture root"
  else
    fail "S28-contain: a relative spelling emitted a path that leaves the fixture root:$S28_ESCAPES"
  fi
else
  skip "S28-contain: no realpath on this host, so the emitted relative paths cannot be canonicalised"
fi

# S28f — the asymmetry the table records, stated as its own claim so a future change
# that made `.` forward silently would fail here by name: the dot spellings are the
# ONLY ones whose all-absent fallback is refused, and the refusal is fail-closed
# (exit 3, empty stdout, a diagnostic on stderr).
rel_run "." SIDX detail outline intent
assert_eq "S28f: a bare-dot PLANS_DIR refuses the all-absent fallback (exit 3)" "3" "$REL_RC"
assert_eq "S28f: the bare-dot refusal emits nothing on stdout" "" "$REL_OUT"
if [[ -n "$REL_ERR" ]]; then
  pass "S28f: the bare-dot refusal names the reason on stderr"
else
  fail "S28f: refused silently — nothing tells the caller why a relative plans dir produced no path"
fi

# S28g — a relative spelling must not become a traversal vehicle. The payload walks
# out through a REAL directory, so the filesystem genuinely opens the outside file;
# `REAL_DIR` is then a relative-derived canonical path, the one comparand no earlier
# row exercised. Protection Pattern 1: the outside file is the asset.
mkdir -p "$S28_ROOT/sub/SID-sub"
S28_ATTACK='sub/../../../s28-outside'
S28_OUTSIDE_BEFORE="$(cat "$S28_OUTSIDE" 2>/dev/null || printf 'MISSING')"
if [[ -f "$S28_ROOT/sub/SID-$S28_ATTACK.md" ]]; then
  pass "S28g-0: the traversal payload really opens the outside file from the relative root — the escape is presentable"
else
  fail "S28g-0: the traversal payload does not reach the outside file; S28g would test an inert input"
fi
rel_run sub SID "$S28_ATTACK" detail
assert_eq "S28g: an escaping candidate under a relative plans dir is skipped → the next present stage" \
  "sub/SID-detail.md" "$REL_OUT"
assert_eq "S28g: the escaping candidate is skipped, not honoured (exit 0)" "0" "$REL_RC"
# The same payload ALONE reaches the exempt last-candidate fallback, where a
# relative-dir comparison that silently normalised to nothing would forward it.
rel_run sub SID "$S28_ATTACK"
assert_eq "S28h: the escaping candidate as the LONE candidate is refused (exit 3)" "3" "$REL_RC"
assert_eq "S28h: the refusal emits nothing on stdout" "" "$REL_OUT"
if [[ "$REL_OUT" == *"S28-OUTSIDE-SECRET-2154-QZWX"* || "$REL_ERR" == *"S28-OUTSIDE-SECRET-2154-QZWX"* ]]; then
  fail "S28h: the outside file's content leaked — stdout: [$REL_OUT] stderr: [$REL_ERR]"
else
  pass "S28h: the outside file's content appears on neither stdout nor stderr"
fi
assert_eq "S28h-asset: the file outside the relative root is byte-for-byte unchanged after both runs" \
  "$S28_OUTSIDE_BEFORE" "$(cat "$S28_OUTSIDE" 2>/dev/null || printf 'MISSING')"

# --- S28i-S28k (C6): a FILESYSTEM-ROOT PLANS_DIR. Both containment tests concatenate a
# separator — `"$REAL_DIR"/*` and `"$LEX_DIR"/*` — and at the root that comparand becomes
# `//*`, which no ordinary single-slash child path matches. The rows below pin what the
# resolver ACTUALLY does at `/` and at the Windows drive-root spellings, and record the
# asymmetry between them; they assert today's behaviour, not a preferred one.
S28_FSROOT="$TMPROOT/s28-fsroot"
mkdir -p "$S28_FSROOT"
S28_FSROOT_BODY="S28-FSROOT-BODY-2154-QZWX"
printf '# detail\n\n%s\n' "$S28_FSROOT_BODY" > "$S28_FSROOT/SID-detail.md"
S28_FSROOT_BEFORE="$(cat "$S28_FSROOT/SID-detail.md" 2>/dev/null || printf 'MISSING')"
# The fixture addressed from the root: its own spelling in the namespace whose root IS
# `/`. On MSYS the suite's `cygpath -m` fixture root is a `C:/...` path, which is not
# under `/` at all, so the `-u` spelling is what makes the root case presentable.
S28_FSROOT_U="$S28_FSROOT"
if command -v cygpath >/dev/null 2>&1; then S28_FSROOT_U="$(cygpath -u "$S28_FSROOT" 2>/dev/null || printf '%s' "$S28_FSROOT")"; fi

# S28i — the ALL-ABSENT chain under `/`. Decided by `lex_norm` alone (no candidate
# exists, so no canonicalizer runs), which makes it the deterministic pin of the
# doubled-separator defect: `/SID-intent.md` can never match the pattern `//*`, so a
# root plans dir can never forward its own direct child.
resolve_e "/" "S28FSROOT2154QZWX" detail outline intent
assert_eq "S28i: an all-absent chain under a filesystem-root PLANS_DIR is REFUSED (exit 3)" "3" "$RES_RC"
assert_eq "S28i: the root refusal emits nothing on stdout" "" "$RES_OUT"
if [[ -n "$RES_ERR" ]]; then
  pass "S28i: the root refusal names the reason on stderr"
else
  fail "S28i: refused silently — nothing tells the caller why a root plans dir produced no path"
fi
# The refused candidate must not have been created as a side effect at the real root.
if [[ -e "/S28FSROOT2154QZWX-intent.md" ]]; then
  fail "S28i-asset: the resolver created a file at the filesystem root"
else
  pass "S28i-asset: nothing was written at the filesystem root"
fi

# S28j — the same root spelling with a candidate that GENUINELY exists and is readable.
# S28j-ref proves the fixture resolves normally through its ordinary absolute spelling,
# so any difference below is caused by the root spelling alone.
if [[ "$S28_FSROOT_U" != /* || ! -s "$S28_FSROOT_U/SID-detail.md" ]]; then
  skip "S28j: existing-candidate-under-root case (the fixture has no spelling rooted at '/': [$S28_FSROOT_U])"
else
  pass "S28j-0: the fixture candidate is readable through a '/'-rooted spelling — the root case is presentable"
  resolve_e "$S28_FSROOT_U" SID detail outline intent
  assert_eq "S28j-ref: through its ordinary absolute spelling the candidate resolves normally" \
    "$S28_FSROOT_U/SID-detail.md" "$RES_OUT"
  assert_eq "S28j-ref: ordinary absolute spelling → exit 0" "0" "$RES_RC"
  resolve_e "/" "${S28_FSROOT_U#/}/SID" detail outline intent
  # Two hosts, two mechanisms, one observable: MSYS reads the doubled `//` prefix as a
  # UNC root so the candidate is not even seen, while a POSIX host sees it and fails the
  # `//*` containment test. Either way the run is fail-closed, never a silent escape.
  if [[ "$RES_RC" -eq 3 && -z "$RES_OUT" ]]; then
    pass "S28j: an EXISTING readable candidate under a root PLANS_DIR is still refused (exit 3, empty stdout) — the doubled separator rejects a valid child"
  elif [[ "$RES_RC" -eq 0 && "$RES_OUT" == "//${S28_FSROOT_U#/}/SID-detail.md" ]]; then
    pass "S28j: this host accepts the root-spelled direct child and emits it verbatim ([$RES_OUT])"
  else
    fail "S28j: neither documented root outcome — rc=$RES_RC stdout=[$RES_OUT] stderr=[$RES_ERR]"
  fi
  if [[ "$RES_OUT" == *"$S28_FSROOT_BODY"* || "$RES_ERR" == *"$S28_FSROOT_BODY"* ]]; then
    fail "S28j-leak: the candidate's content leaked — stdout: [$RES_OUT] stderr: [$RES_ERR]"
  else
    pass "S28j-leak: the candidate's content appears on neither stdout nor stderr"
  fi
  assert_eq "S28j-asset: the candidate is byte-for-byte unchanged after the root-spelled run" \
    "$S28_FSROOT_BEFORE" "$(cat "$S28_FSROOT/SID-detail.md" 2>/dev/null || printf 'MISSING')"
fi

# S28k — the Windows DRIVE-ROOT spellings, the asymmetry S28i exists to contrast with:
# `C:/` lexically normalises to `C:` (no leading-slash prefix), so `C:/SID-x.md` DOES
# match `C:/*` and the all-absent fallback FORWARDS a doubled-separator path instead of
# refusing it. Pinned as observed; the row also proves nothing is written at the drive root.
# SKIPPED (off Windows): both spellings — there is no drive root to address.
if command -v cygpath >/dev/null 2>&1; then
  for s28_droot in 'C:/' 'C:\'; do
    resolve_e "$s28_droot" "S28DRIVEROOT2154QZWX" detail outline intent
    assert_eq "S28k[$s28_droot]: an all-absent chain under a drive root is FORWARDED (exit 0), unlike '/'" "0" "$RES_RC"
    assert_eq "S28k[$s28_droot]: the emitted path is the caller's own spelling plus the extra separator, verbatim" \
      "${s28_droot}/S28DRIVEROOT2154QZWX-intent.md" "$RES_OUT"
    if [[ -e "${s28_droot}S28DRIVEROOT2154QZWX-intent.md" ]]; then
      fail "S28k[$s28_droot]: the resolver created a file at the drive root"
    else
      pass "S28k[$s28_droot]: nothing was written at the drive root"
    fi
  done
else
  skip "S28k: drive-root PLANS_DIR spellings (no cygpath — this host has no Windows drive root to address)"
fi

fi  # RESOLVER_READY

echo ""
