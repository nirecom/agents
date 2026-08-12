#!/bin/bash
# tests/feature-check-private-repo-name/cache-and-live.sh
# Tests: bin/check-private-repo-name.js, bin/list-private-repo-names.js
# Tags: private-repo, outbound-scan, security, classifier, table-driven, TL2, scope:common
# P1-P7 — the matching semantics, the env-cache name source, the live (gh-backed) name
# source, and the producer/consumer wire format.
# The higher-precedence stdin source lives in stdin-mode.sh, which also owns the
# precedence assertions. Part of the feature-check-private-repo-name suite.

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"

if [ ! -f "$CHECK" ] || [ ! -f "$LIST" ]; then
    fail "setup: bin/check-private-repo-name.js and bin/list-private-repo-names.js must both exist (check='$CHECK', list='$LIST')"
    finish
fi

setup_fixture

# ── P1: matching semantics, table-driven ────────────────────────────────────
# label | cache (\n = separator between names) | candidate | expected exit code
#
# Rows 1-2 are the #1910 HIGH-1 regression pair. Before the fix the list was matched
# in full `owner/repo` form with '/' , '.', '-' and '_' all treated as *word*
# characters, so a bare private repo name embedded in a hyphen-joined slug could
# never match and the gate always exited 0 — a silently dead guard.
P1_ROWS=(
    'bare-hyphen-bounded|secret-thing|1910-secret-thing-fix|1'
    'owner-repo-form|acme-org/secret-thing|1910-secret-thing-fix|1'
    'no-match|secret-thing|1910-public-refactor|0'
    'substring-prefix|fix|1910-prefix-thing|0'
    'substring-suffix|fix|1910-fixture-setup|0'
    'substring-inner|secret|1910-secretthing-x|0'
    'empty-cache||1910-secret-thing-fix|0'
    'whole-candidate|secret-thing|secret-thing|1'
    'leading-token|secret-thing|secret-thing-fix|1'
    'trailing-token|secret-thing|1910-secret-thing|1'
    'underscore-boundary|secret-thing|1910_secret-thing_x|1'
    'case-insensitive|SecretThing|1910-secretthing-fix|1'
    'second-entry|pub-one\nsecret-thing|1910-secret-thing-fix|1'
    'metachar-literal|a.c|1910-abc-x|0'
    'metachar-escaped-match|a.c|1910-a.c-x|1'
    'blank-entries-ignored|\n\nsecret-thing\n|1910-nothing-here|0'
    'blank-entries-still-match|\n\nsecret-thing\n|1910-secret-thing-x|1'
    'dot-boundary|secret|my.secret.repo|1'
    # ── #1910 F1: a punctuated private name vs its slugified form ───────────
    # The candidate always arrives slugified (every non-[a-z0-9] run collapsed to a
    # single '-'), so a private name carrying punctuation could never match its own
    # slugified spelling while the pattern was one escaped literal: 'acme.internal'
    # vs '1910-acme-internal-fix' exited 0, and the gate was silently dead for every
    # repo whose name is not already in slug shape. The fix splits the name into
    # alnum tokens and rejoins them with the same non-alnum separator class the
    # boundaries use, so both spellings are caught by one pattern.
    'dotted-vs-slug|acme.internal|1910-acme-internal-fix|1'
    'underscored-vs-slug|acme_secret|1910-acme-secret-fix|1'
    'owner-repo-dotted|acme-org/acme.internal|1910-acme-internal-fix|1'
    # Orthogonal half: catching the slugified form must not cost the original one.
    'dotted-vs-original|acme.internal|1910-acme.internal-fix|1'
    # The separator class is what joins tokens, so any non-alnum run bridges them —
    # the candidate's separator need not be the one the private name used.
    'mixed-separators|acme.internal|1910-acme_internal-fix|1'
    'multi-run-separator|acme..internal|1910-acme-internal-x|1'
    # Three tokens: the join is applied between every adjacent pair, not just once.
    'three-token-dotted|a.b.c|x-a-b-c-y|1'
    'three-token-partial|a.b.c|x-a-b-y|0'
    # The join requires at least one separator character — token concatenation is
    # NOT a match, or the pattern would over-block ('acmeinternal' is a different
    # word). Same property metachar-literal pins for the single-character case.
    'dotted-needs-separator|acme.internal|1910-acmeinternal-fix|0'
    # A name that tokenizes to nothing (pure punctuation) must be skipped, not
    # compiled: joining zero tokens would yield /(^|[^a-zA-Z0-9])([^a-zA-Z0-9]|$)/i,
    # which matches almost any hyphenated slug — the same always-match degradation
    # blank-entries-ignored guards for the empty-string case.
    'all-dots-skipped|..|1910-a--b|0'
    'all-underscores-skipped|__|1910-a--b|0'
    'single-dot-skipped|.|1910-a--b|0'
    # ...and skipping it must not abandon the rest of the list (continue, not break).
    'punct-entry-does-not-shadow|..\nsecret-thing|1910-secret-thing-x|1'
)
for p1_row in "${P1_ROWS[@]}"; do
    IFS='|' read -r p1_label p1_cache_raw p1_cand p1_want <<< "$p1_row"
    p1_cache="$(printf '%b' "$p1_cache_raw")"
    run_check "$p1_cache" "$p1_cand"
    assert_eq "P1/$p1_label: candidate '$p1_cand' -> exit $p1_want" "$p1_want" "$RC"
done

# blank-entries-ignored above is load-bearing beyond its row: an unfiltered empty
# entry would compile to /(^|[^a-zA-Z0-9])([^a-zA-Z0-9]|$)/i, which matches almost any
# hyphenated slug — the gate would reject every derived name it was handed.

# ── P2: stderr discipline on a positive match ───────────────────────────────
# Both halves of the match are secret-bearing and neither may be echoed. The matched
# repo name is the very name this gate exists to keep off more-visible surfaces (CI
# logs, terminal transcripts, captured test output), and the candidate is the caller's
# own text, which may itself carry private information. So the diagnostic is one fixed
# literal that identifies neither — asserted verbatim, since a re-introduced `%s`
# cannot survive a whole-line match.
run_check 'secret-thing' 'ops-runbook-for-secret-thing-cluster'
P2_LINES="$(printf '%s\n' "$ERR" | grep -c '[^[:space:]]')"
assert_eq "P2/rc: a matched candidate exits 1" "1" "$RC"
if [ "$P2_LINES" -eq 1 ] && printf '%s\n' "$ERR" | grep -qxF "$REJECT_MSG"; then
    pass "P2/stderr: the match emits exactly one fixed, non-identifying line"
else
    fail "P2/stderr: expected the single line '$REJECT_MSG' (lines=$P2_LINES, err='$ERR')"
fi
# Combined streams, whole strings and every distinguishing fragment of each: the
# candidate must not leak, and neither must the private repo name that matched it.
P2_BOTH="$OUT$ERR"
P2_LEAKED=""
for p2_secret in 'ops-runbook-for-secret-thing-cluster' 'ops-runbook' 'cluster' 'secret-thing' 'secret'; do
    [[ "$P2_BOTH" == *"$p2_secret"* ]] && P2_LEAKED="$P2_LEAKED '$p2_secret'"
done
if [ -z "$P2_LEAKED" ]; then
    pass "P2/no-echo: neither the candidate nor the matched private repo name appears on stdout or stderr"
else
    fail "P2/no-echo: leaked to stdout/stderr:$P2_LEAKED (out='$OUT', err='$ERR')"
fi

# Symmetric counterpart: a clean candidate must be completely silent, or the caller
# (scan_clean(), which discards both streams) would still be paying for noise.
run_check 'secret-thing' '1910-public-refactor'
if [ "$RC" -eq 0 ] && [ -z "$ERR" ] && [ -z "$OUT" ]; then
    pass "P2/quiet: a clean candidate exits 0 with both streams empty"
else
    fail "P2/quiet: expected rc=0 and empty stdout/stderr on a clean candidate (rc=$RC, out='$OUT', err='$ERR')"
fi

# An armed-but-empty cache is the "confirmed: no private repos" state every fixture in
# this suite runs under, and the state derive-worktree-name.sh hands the checker when
# the lister found nothing. It must be exit 0 with both streams empty for ANY candidate
# — including one that would match under a populated cache.
run_check '' 'ops-runbook-for-secret-thing-cluster'
if [ "$RC" -eq 0 ] && [ -z "$ERR" ] && [ -z "$OUT" ]; then
    pass "P2/empty-cache-quiet: an armed but empty cache exits 0 with both streams empty, whatever the candidate"
else
    fail "P2/empty-cache-quiet: expected rc=0 and empty stdout/stderr with an empty armed cache (rc=$RC, out='$OUT', err='$ERR')"
fi

# ── P3: no candidate argument at all ────────────────────────────────────────
# Fail-open, matching listPrivateRepoNames()'s own contract. Pinned because the gate
# is invoked from shell (`node ... "$1"`), where an unset caller variable is the
# realistic way this happens — it must not become a hard abort mid-cascade.
run_check 'secret-thing'
if [ "$RC" -eq 0 ] && [ -z "$ERR" ]; then
    pass "P3/absent-arg: no candidate argument exits 0 (fail-open) and stays silent"
else
    fail "P3/absent-arg: expected rc=0 with empty stderr and no argv[2] (rc=$RC, err='$ERR')"
fi
run_check 'secret-thing' ''
if [ "$RC" -eq 0 ]; then
    pass "P3/empty-arg: an empty candidate argument exits 0 (fail-open)"
else
    fail "P3/empty-arg: expected rc=0 for an empty candidate (rc=$RC, err='$ERR')"
fi

# ── Stand-in AGENTS config: full control of the non-cache path ──────────────
# check-private-repo-name.js and list-private-repo-names.js both resolve their name
# source as <script-dir>/../hooks/lib/is-private-repo.js. Copying each script into a
# throwaway tree lets the live path be exercised against a stub instead of `gh`, and
# omitting the stub exercises the module-load fail-open. Neither shape touches the
# network, so the "live" path is testable without a live anything.
CFG="$TMP/cfg"
mkdir -p "$CFG/bin" "$CFG/hooks/lib"
cp "$CHECK" "$CFG/bin/check-private-repo-name.js"
cp "$LIST" "$CFG/bin/list-private-repo-names.js"
cat > "$CFG/hooks/lib/is-private-repo.js" <<'STUB'
// Stand-in for the real module: returns whatever STUB_PRIVATE_NAMES declares,
// in the same 'owner/repo' shape the real listPrivateRepoNames() produces.
function listPrivateRepoNames() {
  return (process.env.STUB_PRIVATE_NAMES || '').split('\n').filter(Boolean);
}
// Only the name SOURCE is stubbed — the matcher is not. escapeRegex/findPrivateName
// are copied verbatim from hooks/lib/is-private-repo.js so the P1/P4/P5 tables keep
// asserting against the real boundary semantics rather than a simplified stand-in.
function escapeRegex(s) {
  return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}
function findPrivateName(candidate, privateNames) {
  for (const name of privateNames) {
    const bare = name.split("/").pop();
    if (!bare) continue;
    const tokens = bare.split(/[^a-zA-Z0-9]+/).filter(Boolean).map(escapeRegex);
    if (tokens.length === 0) continue;
    const re = new RegExp(
      "(^|[^a-zA-Z0-9])" + tokens.join("[^a-zA-Z0-9]+") + "([^a-zA-Z0-9]|$)",
      "i"
    );
    if (re.test(candidate)) return bare;
  }
  return null;
}
module.exports = { listPrivateRepoNames, escapeRegex, findPrivateName };
STUB

NOMOD="$TMP/nomod"
mkdir -p "$NOMOD/bin"
cp "$CHECK" "$NOMOD/bin/check-private-repo-name.js"
cp "$LIST" "$NOMOD/bin/list-private-repo-names.js"

# ── P4: only PRIVATE_REPO_NAMES_CACHE_SET=1 arms the cache ──────────────────
# The flag is what makes an EMPTY cache mean "confirmed: no private repos" rather than
# "not asked yet". If any truthy-looking value armed it, an unrelated exported
# PRIVATE_REPO_NAMES_CACHE would silently become the authoritative list.
p4_run() {  # $1 = value for _SET (unset when the literal 'UNSET'), $2 = cache
    local errf="$TMP/p4-err.txt"
    if [ "$1" = "UNSET" ]; then
        env -u PRIVATE_REPO_NAMES_CACHE_SET PRIVATE_REPO_NAMES_CACHE="$2" \
            node "$CFG/bin/check-private-repo-name.js" '1910-secret-thing-fix' 2>"$errf"
    else
        env PRIVATE_REPO_NAMES_CACHE_SET="$1" PRIVATE_REPO_NAMES_CACHE="$2" \
            node "$CFG/bin/check-private-repo-name.js" '1910-secret-thing-fix' 2>"$errf"
    fi
    RC=$?
    ERR="$(cat "$errf")"
}
# STUB_PRIVATE_NAMES is deliberately empty for these three, so the live path can only
# ever return an empty list: any exit 1 below therefore came from the cache.
export STUB_PRIVATE_NAMES=''
p4_run 1 'secret-thing'
assert_eq "P4/armed: _SET=1 makes the cache authoritative (match -> exit 1)" "1" "$RC"
p4_run 0 'secret-thing'
assert_eq "P4/not-armed-zero: _SET=0 ignores the cache and takes the live path (exit 0)" "0" "$RC"
p4_run UNSET 'secret-thing'
assert_eq "P4/not-armed-unset: an unset _SET ignores the cache entirely (exit 0)" "0" "$RC"
p4_run 1 ''
assert_eq "P4/armed-empty: _SET=1 with an empty cache means 'no private repos' (exit 0)" "0" "$RC"
unset STUB_PRIVATE_NAMES

# ── P5: the live (non-cache) path ───────────────────────────────────────────
# listPrivateRepoNames() yields 'owner/repo'; the checker must reduce that to the bare
# name before matching, exactly as the cache path does. This is the arm the #1910 fix
# was actually about — the cache did not exist before it.
p5_run() {  # $1 = STUB_PRIVATE_NAMES, $2 = candidate, $3 = script dir
    local errf="$TMP/p5-err.txt"
    env -u PRIVATE_REPO_NAMES_CACHE_SET -u PRIVATE_REPO_NAMES_CACHE \
        STUB_PRIVATE_NAMES="$1" \
        node "$3/bin/check-private-repo-name.js" "$2" 2>"$errf"
    RC=$?
    ERR="$(cat "$errf")"
}
p5_run 'acme-org/secret-thing' '1910-secret-thing-fix' "$CFG"
assert_eq "P5/owner-repo: the live list's 'owner/repo' entry matches by bare name (exit 1)" "1" "$RC"
# Same fixed literal as the cache path (CPR-ORTH): both arms end in the same finish(),
# so the live path must be exactly as non-identifying — the owner-qualified name, the
# bare name and the candidate are all withheld.
P5_LEAKED=""
for p5_secret in 'acme-org/secret-thing' 'acme-org' 'secret-thing' 'secret' '1910-secret-thing-fix'; do
    [[ "$ERR" == *"$p5_secret"* ]] && P5_LEAKED="$P5_LEAKED '$p5_secret'"
done
if printf '%s\n' "$ERR" | grep -qxF "$REJECT_MSG" && [ -z "$P5_LEAKED" ]; then
    pass "P5/fixed-diagnostic: the live path emits the same fixed literal and names neither the repo nor the candidate"
else
    fail "P5/fixed-diagnostic: expected '$REJECT_MSG' alone on the live path (leaked:$P5_LEAKED, err='$ERR')"
fi
p5_run 'acme-org/secret-thing' '1910-unrelated-work' "$CFG"
assert_eq "P5/clean: an unrelated candidate still exits 0 on the live path" "0" "$RC"
p5_run 'acme-org/secret-thing' '1910-secret-thing-fix' "$NOMOD"
assert_eq "P5/fail-open: an unloadable is-private-repo.js exits 0 rather than blocking" "0" "$RC"

# ── P6: bin/list-private-repo-names.js, the producer ────────────────────────
# It exists to turn N identical `gh repo list` round-trips into one, so what matters is
# that its stdout is exactly the bare-name form the checker's cache consumes.
P6_OUT="$(env STUB_PRIVATE_NAMES=$'acme-org/secret-thing\nother-org/second-private' \
    node "$CFG/bin/list-private-repo-names.js" 2>"$TMP/p6-err.txt")"
P6_RC=$?
assert_eq "P6/rc: the lister exits 0" "0" "$P6_RC"
assert_eq "P6/bare-names: 'owner/repo' entries are emitted as bare names, one per line" \
    "$(printf 'secret-thing\nsecond-private')" "$P6_OUT"
if [ ! -s "$TMP/p6-err.txt" ]; then
    pass "P6/quiet: the lister writes nothing to stderr"
else
    fail "P6/quiet: expected empty stderr from the lister (err='$(cat "$TMP/p6-err.txt")')"
fi

P6_EMPTY="$(env STUB_PRIVATE_NAMES='' node "$CFG/bin/list-private-repo-names.js" 2>/dev/null)"
assert_eq "P6/empty: no private repos yields no output" "" "$P6_EMPTY"

P6_NOMOD="$(node "$NOMOD/bin/list-private-repo-names.js" 2>/dev/null)"
P6_NOMOD_RC=$?
if [ "$P6_NOMOD_RC" -eq 0 ] && [ -z "$P6_NOMOD" ]; then
    pass "P6/fail-open-module: an unloadable is-private-repo.js yields exit 0 and no output"
else
    fail "P6/fail-open-module: expected rc=0 and empty output (rc=$P6_NOMOD_RC, out='$P6_NOMOD')"
fi

# The real fail-open trigger in production is an absent or unusable `gh`. Reproduced by
# emptying PATH around the real module (node is invoked by absolute path), so this one
# case exercises hooks/lib/is-private-repo.js itself — still without a network call.
NODE_BIN="$(command -v node)"
mkdir -p "$TMP/nopath"
P6_NOGH="$(PATH="$TMP/nopath" "$NODE_BIN" "$LIST" 2>/dev/null)"
P6_NOGH_RC=$?
if [ "$P6_NOGH_RC" -eq 0 ] && [ -z "$P6_NOGH" ]; then
    pass "P6/fail-open-gh: an unreachable gh yields exit 0 and no output (fail-open, no hard error)"
else
    fail "P6/fail-open-gh: expected rc=0 and empty output with gh off PATH (rc=$P6_NOGH_RC, out='$P6_NOGH')"
fi

# ── P7: producer and consumer agree on the wire format ──────────────────────
# The two halves are only useful together: the lister's stdout is fed verbatim into
# PRIVATE_REPO_NAMES_CACHE. Asserting each side's format separately would still let a
# trailing-newline or separator mismatch through, so the round trip is pinned as one.
P7_CACHE="$(env STUB_PRIVATE_NAMES=$'acme-org/secret-thing\nother-org/second-private' \
    node "$CFG/bin/list-private-repo-names.js" 2>/dev/null)"
run_check "$P7_CACHE" '1910-second-private-cleanup'
assert_eq "P7/round-trip-match: the lister's own output, used as the cache, catches a private name" "1" "$RC"
run_check "$P7_CACHE" '1910-entirely-unrelated'
assert_eq "P7/round-trip-clean: the same cache leaves an unrelated candidate alone" "0" "$RC"

finish
