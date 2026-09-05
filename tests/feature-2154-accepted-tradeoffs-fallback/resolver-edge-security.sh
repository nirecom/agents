# Tests: bin/resolve-accepted-tradeoffs-file
# Tags: codex, review, accepted-tradeoffs, security, injection, scope:issue-specific
# Resolver error / edge / CONTAINMENT contracts (S0-S4, S9, S12, S17-S18) and
# idempotency (I1). The untrusted-input injection half lives in the sibling
# resolver-untrusted-input-injection.sh, which the dispatcher sources AFTER this
# file and which consumes the S0 guard and the helpers defined below.
# Patterns: skills/_shared/test-design/protection-fix-tests.md — every rejection
# case asserts the protected resource (the filesystem outside PLANS_DIR) is
# unchanged, not merely that an exit code was non-zero.
# Sourced by tests/feature-2154-accepted-tradeoffs-fallback.sh; split per rules/coding/file-split.md (Pattern A).
echo "=== Resolver error / edge / containment cases ==="

# TL3 gap (TL2 substrate is not POSIX; a real POSIX host also verifies): S4 — an
# unopenable candidate is skipped (mode bits are advisory on MSYS); S9-contain /
# S9-fallback and S18 — run only while git-bash honours
# MSYS=winsymlinks:nativestrict; S12 and S18 — built by emptying PATH, so an
# absolute-path realpath call is out of reach; I1 — a same-length in-place
# rewrite (needs a hasher). Closest-to-action: check-verification-gate.sh.
# --- S0: guard, shared with the injection sibling. Without an executable
# resolver every case below would "pass" on exit 127 — the empty-stdout
# assertions and the injection canaries most of all, since nothing ran at all.
RESOLVER_READY=0
if [[ -x "$RESOLVER" ]]; then
  RESOLVER_READY=1
  pass "S0: bin/resolve-accepted-tradeoffs-file exists and is executable"
else
  fail "S0: bin/resolve-accepted-tradeoffs-file missing or not executable — S1-S18/I1 cannot exercise it"
fi

if [[ "$RESOLVER_READY" -eq 0 ]]; then
  skip "S1-S4, S9, S12, S17-S18, I1: resolver unavailable (see S0)"
else

# resolve_e <args...> — same as `resolve`, but KEEPS stderr in RES_ERR instead of
# discarding it. Every row that judges a diagnostic (S1/S2 usage errors) or a
# content leak (S9-leak, S13) must use this: a resolver that printed the secret
# on fd 2 satisfies a stdout-only leak check while still handing the operator's
# terminal — and any log capturing it — the very bytes containment exists to keep
# out of the review channel.
RES_ERR=""
resolve_e() {
  local errf="$TMPROOT/res-stderr.txt"
  rm -f "$errf"
  RES_OUT="$(with_timeout bash "$RESOLVER" "$@" 2>"$errf")"
  RES_RC=$?
  RES_ERR="$(cat "$errf" 2>/dev/null || true)"
}

# --- S1: no arguments at all → usage error (exit 2), nothing on stdout.
resolve_e
assert_eq "S1: no arguments → exit 2 (usage error)" "2" "$RES_RC"
assert_eq "S1: no arguments → empty stdout" "" "$RES_OUT"
# S1b: exit code + empty stdout alone leave the operator with nothing to act on.
# A usage error is only useful if it SAYS something.
if [[ -n "$RES_ERR" ]]; then
  pass "S1b: the usage error carries a diagnostic on stderr"
else
  fail "S1b: the usage error is silent — exit 2 with nothing on stderr tells the caller nothing"
fi

# --- S2: plans-dir given but <SID> missing → usage error (exit 2).
PS="$(make_plans s2 intent)"
resolve_e "$PS"
assert_eq "S2: missing <SID> → exit 2 (usage error)" "2" "$RES_RC"
assert_eq "S2: missing <SID> → empty stdout" "" "$RES_OUT"

# --- S2b: the usage diagnostic must be USEFUL and NON-LEAKING. The argument here
# is attacker-shaped; a diagnostic that echoes it back verbatim replays untrusted
# bytes into the operator's terminal and into whatever log captures stderr.
USAGE_MARKER='USAGE_ECHO_MARKER_2154_QZWX;$(touch /nonexistent-2154)`id`'
resolve_e "$USAGE_MARKER"
assert_eq "S2b: single attacker-shaped argument → exit 2 (usage error)" "2" "$RES_RC"
assert_eq "S2b: single attacker-shaped argument → empty stdout" "" "$RES_OUT"
if [[ -z "$RES_ERR" ]]; then
  fail "S2b: the usage error is silent — nothing on stderr to tell the caller what was wrong"
elif [[ "$RES_ERR" == *"USAGE_ECHO_MARKER_2154_QZWX"* ]]; then
  fail "S2b: the usage diagnostic echoes the caller-supplied argument back verbatim: [$RES_ERR]"
else
  pass "S2b: the usage diagnostic is non-empty and does not echo the supplied argument back"
fi

# --- S3: a candidate that exists as a DIRECTORY is not a usable tradeoffs file.
# `[[ -s dir ]]` is true for a directory, so a size-only check would hand
# review-plan-codex a path it can never read; the resolver must skip to the
# next candidate instead.
P_DIR="$(make_plans s3 outline intent)"
mkdir -p "$P_DIR/SID-detail.md"
resolve "$P_DIR" SID detail outline intent
assert_eq "S3: directory candidate skipped → outline path" "$P_DIR/SID-outline.md" "$RES_OUT"
assert_eq "S3: directory candidate → exit 0" "0" "$RES_RC"

# --- S4: a candidate that exists but is UNREADABLE is skipped.
# Guarded, never silently passed: on Windows/msys chmod is frequently a no-op,
# and a still-readable file would make this case vacuous.
# SKIPPED (when `chmod 000` leaves the file readable): assert that the
#          unreadable detail.md is skipped and outline.md is emitted instead.
# Because: mode bits are advisory on Windows/MSYS, so the precondition the case
#          rests on does not exist — asserting it would prove nothing.
# TL3 gap: only a real POSIX filesystem exercises the unopenable-candidate path.
P_UNREAD="$(make_plans s4 outline intent)"
printf '# detail\n\nsecret\n' > "$P_UNREAD/SID-detail.md"
chmod 000 "$P_UNREAD/SID-detail.md" 2>/dev/null || true
if [[ -r "$P_UNREAD/SID-detail.md" ]]; then
  skip "S4: unreadable-candidate case (chmod 000 ineffective on this filesystem — file still readable)"
else
  resolve "$P_UNREAD" SID detail outline intent
  assert_eq "S4: unreadable detail.md skipped → outline path" "$P_UNREAD/SID-outline.md" "$RES_OUT"
  assert_eq "S4: unreadable candidate → exit 0" "0" "$RES_RC"
fi
chmod 644 "$P_UNREAD/SID-detail.md" 2>/dev/null || true

# assert_contained <name> <plans-dir> — the emitted path must either be refused
# (non-zero exit) or stay inside PLANS_DIR with no traversal segment left in it.
assert_contained() {
  local name="$1" dir="$2"
  if [[ "$RES_RC" -eq 127 ]]; then
    fail "$name — the resolver was never executed (exit 127); containment is unproven"
    return
  fi
  if [[ "$RES_RC" -ne 0 ]]; then
    pass "$name — refused with exit $RES_RC"
    return
  fi
  # Judge SEGMENTS, not substrings. `*".."*` also matches an in-directory name
  # that merely CONTAINS two dots (`plans..archive`, `notes..bak`), so the old
  # form over-blocked a legitimate path and, worse, was not testing traversal at
  # all — it was testing for a dot pair. Wrapping in slashes makes a leading or
  # trailing `..` segment match too. S17 is the sanctioned-lookalike allow case.
  case "/$RES_OUT/" in
    */../*)
      fail "$name — emitted a path with a '..' traversal SEGMENT: [$RES_OUT]"
      return
      ;;
  esac
  case "$RES_OUT" in
    "$dir"/*) pass "$name — contained inside PLANS_DIR" ;;
    *) fail "$name — emitted a path outside PLANS_DIR: [$RES_OUT]" ;;
  esac
}

# CANONICAL containment (S9). assert_contained above judges the emitted path
# LEXICALLY, so an in-directory symlink whose target is an external secret would
# pass it — the precise false green tests/fix-2108-subagent-artifact-write-path/
# cases-symlink-containment.sh exists to close (its A22 rows resolve the link
# before judging). Both sides go through the SAME tool so an msys `/c/...` vs
# `C:/...` mismatch cannot masquerade as an escape.
CANON_TOOL=""
if command -v realpath >/dev/null 2>&1; then CANON_TOOL="realpath"
elif readlink -f / >/dev/null 2>&1; then CANON_TOOL="readlink -f"; fi
canon() { if [[ -n "$CANON_TOOL" ]]; then $CANON_TOOL "$1" 2>/dev/null; fi; }

# canon_verdict <path> <plans-dir> → inside | outside | unknown.
# `unknown` when no canonicalizer exists — the caller must SKIP rather than fall
# back to a lexical verdict, which is the false green being removed.
canon_verdict() {
  local real_out real_dir
  [[ -n "$CANON_TOOL" ]] || { printf 'unknown'; return; }
  real_out="$(canon "$1")"; real_dir="$(canon "$2")"
  [[ -n "$real_out" && -n "$real_dir" ]] || { printf 'unknown'; return; }
  case "$real_out" in "$real_dir"/*) printf 'inside' ;; *) printf 'outside' ;; esac
}

# --- S9: a candidate that is a SYMLINK pointing outside PLANS_DIR. Judged
# CANONICALLY below: the lexical verdict alone reports "contained" for an
# in-directory link whose target is an external secret.
# Guarded like S4 — a failed `ln -s` must never read as a containment proof.
# SKIPPED (when `ln -s` fails): the whole symlink-escape assertion.
# Because: symlink creation is a Windows privilege (Developer Mode /
#          SeCreateSymbolicLink), not a filesystem feature, so the escape the
#          case exists to refute cannot be constructed on this host.
# TL3 gap: only a real POSIX host builds the link and exercises the path.
P_LINK="$(make_plans s9 outline intent)"
LINK_TARGET="$TMPROOT/symlink-escape-detail.md"
# A distinctive body, so the stdout assertion compares CONTENT, not existence.
LINK_SECRET="SYMLINK-ESCAPE-SECRET-2154-QZWX"
printf '# outside the plans dir\n\n%s\n' "$LINK_SECRET" > "$LINK_TARGET"
# Protection Pattern 1: the symlink TARGET is the protected asset. Snapshot it so
# the rows below can assert it survived the resolution unmodified — a resolver
# that opened it for write, truncated it, or rewrote it in place would otherwise
# satisfy every path-shaped assertion in S9.
LINK_TARGET_BEFORE="$(cat "$LINK_TARGET" 2>/dev/null || printf 'MISSING')"
# MSYS=winsymlinks:nativestrict makes git-bash emit a REAL symlink instead of a
# copy; on POSIX the variable is inert. Without it this case skips on Windows.
if (export MSYS=winsymlinks:nativestrict; ln -s "$LINK_TARGET" "$P_LINK/SID-detail.md" 2>/dev/null) && [[ -L "$P_LINK/SID-detail.md" ]]; then
  # Fixture precondition: the link must really traverse, or every row below
  # reports on a broken link instead of on containment.
  if grep -qF -- "$LINK_SECRET" "$P_LINK/SID-detail.md" 2>/dev/null; then
    pass "S9-0: the planted symlink really resolves to the external file"
  else
    fail "S9-0: the planted symlink does not traverse — S9's verdict would be vacuous"
  fi
  resolve "$P_LINK" SID detail outline intent
  assert_contained "S9: symlink candidate — the emitted path is LEXICALLY inside PLANS_DIR" "$P_LINK"

  # S9-control — the canonicalizer itself, proven on an ordinary candidate.
  # Without it the residual row below could "pass" against a canon() that had
  # simply stopped resolving anything.
  resolve "$P_LINK" SID outline intent
  S9_CTRL="$(canon_verdict "$RES_OUT" "$P_LINK")"
  if [[ "$S9_CTRL" == "unknown" ]]; then
    skip "S9-control: canonical verdict (no realpath / readlink -f on PATH)"
  else
    assert_eq "S9-control: a plain in-directory candidate canonically resolves INSIDE PLANS_DIR" "inside" "$S9_CTRL"
  fi

  # S9-contain — a REQUIREMENT under the amended plan Step 1 containment clause:
  # a candidate whose CANONICAL path leaves PLANS_DIR is treated as absent, so
  # the scan CONTINUES and the emitted path is the NEXT candidate (outline).
  # Skip, not refusal — exit stays 0 and the fallback chain keeps its meaning.
  # SKIPPED (only when no canonicalizer is on PATH): the canonical half of the
  #          verdict; the exact-path and exit-code halves still run.
  # Because: without realpath / readlink -f the test cannot itself decide where
  #          the emitted path really points, and a lexical verdict is precisely
  #          the false green this row exists to remove.
  resolve "$P_LINK" SID detail outline intent
  assert_eq "S9-contain: escaping symlink candidate skipped → next candidate (outline) emitted" \
    "$P_LINK/SID-outline.md" "$RES_OUT"
  assert_eq "S9-contain: escaping symlink candidate → exit 0 (skip, not refusal)" "0" "$RES_RC"
  S9_REAL="$(canon_verdict "$RES_OUT" "$P_LINK")"
  if [[ "$S9_REAL" == "unknown" ]]; then
    skip "S9-contain canonical verdict: no realpath / readlink -f on PATH"
  else
    assert_eq "S9-contain: the emitted path canonically stays INSIDE PLANS_DIR" "inside" "$S9_REAL"
  fi

  # S9-leak — a REQUIREMENT, and the contract-bound half of C1: the resolver is
  # a path lookup, so the external file's BODY must never reach the caller — on
  # EITHER stream. stdout alone is half the channel: the diagnostic path (which
  # S9-fallback requires to exist) writes on fd 2, and that is exactly where a
  # well-meaning "here is what I found" dump would land.
  resolve_e "$P_LINK" SID detail outline intent
  if [[ "$RES_OUT" == *"$LINK_SECRET"* ]]; then
    fail "S9-leak: the external file's content appeared on the resolver's stdout: [$RES_OUT]"
  elif [[ "$RES_ERR" == *"$LINK_SECRET"* ]]; then
    fail "S9-leak: the external file's content appeared on the resolver's stderr: [$RES_ERR]"
  else
    pass "S9-leak: the external file's content appears on neither stdout nor stderr"
  fi

  # S9-asset (Protection Pattern 1) — the protected resource itself. Containment
  # is about what the resolver may REACH, and reaching includes writing.
  assert_eq "S9-asset: the external symlink target is byte-for-byte unchanged after resolution" \
    "$LINK_TARGET_BEFORE" "$(cat "$LINK_TARGET" 2>/dev/null || printf 'MISSING')"

  # S9-fallback — the ONE shape the amended Step 1 carves OUT of the exempt
  # last-candidate fallback: with the escaping symlink as the only candidate,
  # nothing satisfies the scan, so the fallback is reached with a path that
  # EXISTS after symlink resolution and fails containment. Emitting it at exit 0
  # would let review-plan-codex's `-f` open the external file — containment
  # bypassed through its own fallback. The amendment requires a non-zero exit
  # plus a diagnostic; the routine fail-soft (no candidate exists at all, so the
  # last path is emitted at exit 0 and run-codex-review-loop's
  # `[[ -n "$TRADEOFFS" ]] || die` still holds) is untouched and is proven by
  # Layer A case 4, not duplicated here.
  S9F_WANT_DIAG="the last candidate resolves outside the plans directory; refusing to forward it."
  # Asserted EXACTLY: "non-zero + something on stderr" is also satisfied by a
  # crash, by the exit-2 usage error, and by the OTHER refusal branch's sentence.
  # Only the canonical branch is reachable here — the candidate is lexically
  # inside PLANS_DIR, so nothing but symlink resolution can reject it; the lexical
  # twin is S13-fallback in the injection sibling.
  S9F_ERR="$TMPROOT/s9-fallback-stderr.txt"
  S9F_OUT="$(with_timeout bash "$RESOLVER" "$P_LINK" SID detail 2>"$S9F_ERR")"
  S9F_RC=$?
  S9F_ERR_BODY="$(cat "$S9F_ERR" 2>/dev/null || true)"
  if [[ "$S9F_RC" -eq 124 || "$S9F_RC" -eq 126 || "$S9F_RC" -eq 127 ]]; then
    fail "S9-fallback: the resolver never ran to completion (exit $S9F_RC) — the refusal is unproven"
  else
    assert_eq "S9-fallback: escaping symlink as the lone candidate → exit 3 (exit 0 would hand the escaping path to review-plan-codex's -f)" \
      "3" "$S9F_RC"
  fi
  assert_eq "S9-fallback: the refusal emits nothing on stdout" "" "$S9F_OUT"
  if [[ "$S9F_ERR_BODY" == *"$S9F_WANT_DIAG"* ]]; then
    pass "S9-fallback: stderr carries the resolves-outside diagnostic of the branch this fixture exercises"
  else
    fail "S9-fallback: stderr does not carry '$S9F_WANT_DIAG' — got: [$S9F_ERR_BODY]"
  fi
  if [[ "$S9F_OUT" == *"$LINK_SECRET"* ]]; then
    fail "S9-fallback: the external file's content appeared on stdout: [$S9F_OUT]"
  elif [[ "$S9F_ERR_BODY" == *"$LINK_SECRET"* ]]; then
    fail "S9-fallback: the external file's content appeared in the stderr diagnostic: [$S9F_ERR_BODY]"
  else
    pass "S9-fallback: the external file's content appears on neither stdout nor stderr"
  fi
  assert_eq "S9-fallback: the external symlink target is byte-for-byte unchanged after the refusal" \
    "$LINK_TARGET_BEFORE" "$(cat "$LINK_TARGET" 2>/dev/null || printf 'MISSING')"
else
  rm -f "$P_LINK/SID-detail.md"
  skip "S9: symlink-escape case (symlink creation unavailable on this filesystem — ln -s failed; Windows/MSYS without SeCreateSymbolicLink)"
fi

# --- S12 (fail-closed): where containment CANNOT be verified — neither realpath
# nor `readlink -f` reachable — the amended Step 1 requires the candidate to be
# SKIPPED, not emitted unchecked. Built by emptying PATH for the resolver's own
# process (the one portable way to drop both canonicalizers); bash and the
# resolver are named absolutely so it still starts. Every candidate is then
# unverifiable, so only the EXEMPT last candidate may be emitted — the carve-out
# needs an escape DETERMINED by canonicalization (S9-fallback) or an unverifiable
# SYMLINK (S18 below), and this fixture is neither.
# SKIPPED (when the resolver cannot complete without PATH): the whole row.
# Because: a resolver that dies on an empty PATH never reached the branch.
BASH_BIN="$(command -v bash)"
P_FC="$(make_plans s12 detail outline intent)"
FC_OUT="$(PATH="" "$BASH_BIN" "$RESOLVER" "$P_FC" SID detail outline intent 2>/dev/null)"
FC_RC=$?
# S18 needs to know whether this substrate runs the resolver without a PATH at all:
# there a refusal and a crash both exit non-zero, so it cannot re-derive the fact.
NOPATH_RAN=0
if [[ "$FC_RC" -ne 0 || -z "$FC_OUT" ]]; then
  skip "S12: fail-closed-without-canonicalizer case (the resolver did not complete with an empty PATH: rc=$FC_RC)"
else
  NOPATH_RAN=1
  assert_eq "S12: no canonicalizer reachable → every candidate skipped fail-closed, exempt last candidate emitted" \
    "$P_FC/SID-intent.md" "$FC_OUT"
fi

# --- S18: the combination S9-fallback and S12 each cover only HALF — an escaping
# SYMLINK as the lone candidate with NO canonicalizer reachable. S9-fallback proves
# the refusal when canonicalization DECIDES the path resolves outside; S12 proves an
# ordinary regular file is still emitted at exit 0 when containment is merely
# UNDECIDABLE. Neither reaches the branch refusing an UNDECIDABLE candidate that is
# ALSO a symlink — an unverifiable link is an attack signature, not a routine miss.
# Fixture: S12's empty-PATH technique + S9's ln -s guard.
# SKIPPED (when ln -s fails, or S12 found the resolver needs a PATH): the refusal.
# Because: symlink creation is a Windows privilege (SeCreateSymbolicLink), and a
#          resolver that dies on an empty PATH never reached the branch under test.
P_NC="$TMPROOT/plans-s18"
mkdir -p "$P_NC"
NC_TARGET="$TMPROOT/nocanon-symlink-target.md"
NC_SECRET="NOCANON-SYMLINK-SECRET-2154-QZWX"
printf '# outside the plans dir\n\n%s\n' "$NC_SECRET" > "$NC_TARGET"
NC_TARGET_BEFORE="$(cat "$NC_TARGET" 2>/dev/null || printf 'MISSING')"
if [[ "$NOPATH_RAN" -eq 0 ]]; then
  skip "S18: undecidable-symlink refusal (the resolver did not complete with an empty PATH — see S12)"
elif (export MSYS=winsymlinks:nativestrict; ln -s "$NC_TARGET" "$P_NC/SID-detail.md" 2>/dev/null) && [[ -L "$P_NC/SID-detail.md" ]]; then
  # Fixture precondition (S9-0's shape): without a traversing link every row below
  # judges a broken link instead of an unverifiable escape.
  if grep -qF -- "$NC_SECRET" "$P_NC/SID-detail.md" 2>/dev/null; then
    pass "S18-0: the planted symlink really resolves to the external file"
  else
    fail "S18-0: the planted symlink does not traverse — S18's verdict would be vacuous"
  fi
  NC_ERR="$TMPROOT/s18-stderr.txt"
  rm -f "$NC_ERR"
  NC_OUT="$(PATH="" "$BASH_BIN" "$RESOLVER" "$P_NC" SID detail 2>"$NC_ERR")"
  NC_RC=$?
  if [[ "$NC_RC" -eq 0 ]]; then
    fail "S18: unverifiable symlink as the lone candidate → exit 0; the unverifiable path reaches review-plan-codex's -f: [$NC_OUT]"
  elif [[ "$NC_RC" -eq 124 || "$NC_RC" -eq 126 || "$NC_RC" -eq 127 ]]; then
    fail "S18: the resolver never ran to completion (exit $NC_RC) — the refusal is unproven"
  else
    pass "S18: unverifiable symlink as the lone candidate → refused with exit $NC_RC"
  fi
  assert_eq "S18: the refusal emits nothing on stdout" "" "$NC_OUT"
  if [[ -s "$NC_ERR" ]]; then
    pass "S18: the refusal carries a diagnostic on stderr"
  else
    fail "S18: refused silently — nothing on stderr to tell the operator an unverifiable symlink was found"
  fi
  NC_ERR_BODY="$(cat "$NC_ERR" 2>/dev/null || true)"
  if [[ "$NC_OUT" == *"$NC_SECRET"* || "$NC_ERR_BODY" == *"$NC_SECRET"* ]]; then
    fail "S18: the external file's content leaked — stdout: [$NC_OUT] stderr: [$NC_ERR_BODY]"
  else
    pass "S18: the external file's content appears on neither stdout nor stderr"
  fi
  assert_eq "S18: the external symlink target is byte-for-byte unchanged after the refusal" \
    "$NC_TARGET_BEFORE" "$(cat "$NC_TARGET" 2>/dev/null || printf 'MISSING')"
else
  rm -f "$P_NC/SID-detail.md"
  skip "S18: undecidable-symlink refusal (symlink creation unavailable on this filesystem — ln -s failed; Windows/MSYS without SeCreateSymbolicLink)"
fi

# --- S17 (allow path, protection-fix-tests.md Pattern 4): the sanctioned
# LOOKALIKE. `plans..archive` carries two dots but no traversal segment; a check
# written against the `..` SUBSTRING over-blocks it. Both-direction counterpart
# of S5/S13 (injection sibling), and the row that pins assert_contained above.
# SKIPPED (when mkdir fails): the whole lookalike assertion.
# Because: where the filesystem refuses the name, the sanctioned input cannot be
#          presented at all — see S10/S11.
P_DOTS="$TMPROOT/plans..archive"
if mkdir -p "$P_DOTS" 2>/dev/null && [[ -d "$P_DOTS" ]]; then
  printf '# intent\n\nkeep it\n' > "$P_DOTS/SID-intent.md"
  resolve_e "$P_DOTS" SID detail outline intent
  assert_eq "S17: a plans dir named 'plans..archive' resolves to its exact intent path" \
    "$P_DOTS/SID-intent.md" "$RES_OUT"
  assert_eq "S17: sanctioned '..'-containing name → exit 0 (not over-blocked)" "0" "$RES_RC"
  assert_contained "S17: emitted path" "$P_DOTS"
else
  skip "S17: sanctioned-lookalike case (mkdir refused a directory name containing '..' on this filesystem)"
fi

# --- I1 (idempotency): two identical invocations agree, and neither creates nor
# mutates anything under PLANS_DIR — the resolver is a pure lookup.
# The snapshot carries a CONTENT HASH per file, not just path|size: an in-place
# rewrite with same-length content is exactly the mutation a size-only snapshot
# cannot see. HASHER is empty when no hasher exists — the fallback then degrades
# to path|size and says so, rather than claiming an unproven guarantee.
P_IDEM="$(make_plans i1 detail outline intent)"
if command -v sha256sum >/dev/null 2>&1; then HASHER="sha256sum"
elif command -v shasum >/dev/null 2>&1; then HASHER="shasum -a 256"
elif command -v md5sum >/dev/null 2>&1; then HASHER="md5sum"
else HASHER=""; fi
# snapshot_dir <dir> → one `path|size|hash` line per regular file, sorted.
snapshot_dir() {
  local d="$1" f
  (
    cd "$d" || return 1
    while IFS= read -r f; do
      local size hash
      size="$(wc -c < "$f" 2>/dev/null || echo '?')"
      if [[ -n "$HASHER" ]]; then hash="$($HASHER < "$f" 2>/dev/null | awk '{print $1}')"; else hash="NOHASH"; fi
      printf '%s|%s|%s\n' "$f" "${size// /}" "$hash"
    done < <(find . -type f 2>/dev/null | LC_ALL=C sort)
  )
}
# SKIPPED (when no hasher exists): the content-hash strength of the I1 snapshot.
# Because: with no sha256sum/shasum/md5sum on PATH the snapshot can only record
#          path|size, which a same-length in-place rewrite satisfies — the
#          purity guarantee would be claimed, not proven.
# TL3 gap: a real POSIX host always ships a hasher and closes this.
if [[ -z "$HASHER" ]]; then
  skip "I1 content-hash strength: no sha256sum/shasum/md5sum on PATH — the snapshot degrades to path|size and cannot detect a same-length in-place rewrite"
fi
IDEM_BEFORE="$(snapshot_dir "$P_IDEM")"
resolve "$P_IDEM" SID detail outline intent
IDEM_OUT1="$RES_OUT"; IDEM_RC1="$RES_RC"
resolve "$P_IDEM" SID detail outline intent
IDEM_AFTER="$(snapshot_dir "$P_IDEM")"
assert_eq "I1: second invocation returns the same stdout" "$IDEM_OUT1" "$RES_OUT"
assert_eq "I1: second invocation returns the same exit code" "$IDEM_RC1" "$RES_RC"
assert_eq "I1: PLANS_DIR contents (path|size|hash) unchanged across both invocations" "$IDEM_BEFORE" "$IDEM_AFTER"

fi  # RESOLVER_READY

echo ""
