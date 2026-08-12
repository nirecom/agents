#!/bin/bash
# tests/feature-worktree-start-non-interactive/env-nonexposure.sh
# Tests: skills/worktree-start/scripts/derive-worktree-name.sh, bin/check-private-repo-name.js
# Tags: worktree, start, private-repo, environment, leak, security, TL2, scope:issue-specific
# B26 [F3] — the private-repo-name list must never enter a child process's environment.
#
# Why this needs its own group: the list is "every private repo the user owns", and it
# used to be `export`ed by derive-worktree-name.sh so that scan_clean()'s checker could
# read it. An exported variable is not scoped to the one consumer that needs it — it is
# inherited by node, git, bash, the scan-outbound.sh subprocess and everything they
# spawn in turn, where any process-inspection interface on the host can read it back.
# F3 removes the export and hands the list to its single consumer over stdin instead.
#
# Nothing about the *verdicts* changes, which is exactly why this cannot be tested by
# asserting on derived names: B21 and B25 pass identically under both mechanisms. The
# property is about what the children can SEE, so it is asserted from inside them — a
# stand-in AGENTS_CONFIG_DIR whose scan-outbound.sh and check-private-repo-name.js each
# record, per invocation, the candidate they were handed, the name list actually
# delivered to them, and whether either cache variable was present in their own
# environment.
#
# The declared-cache contract the rest of this suite uses cannot be used here: exporting
# PRIVATE_REPO_NAMES_CACHE into the script under test would put it in every child's
# environment by the test's own doing, and the assertion would be false for a reason
# that has nothing to do with the source. So these cases unset both variables and let
# the script populate its cache itself from a stand-in lister — the production shape,
# and the only one where the plain (non-exported) assignment inside the script is what
# decides the outcome.
# Part of the feature-worktree-start-non-interactive suite — see the dispatcher.

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"
setup_fixture

# ── The spy AGENTS_CONFIG_DIR ───────────────────────────────────────────────
C_CFG="$FIXTURE/spy-cfg"
mkdir -p "$C_CFG/bin" "$C_CFG/hooks/lib"
# parse-closes-issues resolves its lib as <cfg>/hooks/lib/; the issue number is what
# makes the D6 tier-0/tier-1 pair distinguishable in the routing table below.
cp "$AGENTS_DIR/bin/parse-closes-issues" "$C_CFG/bin/parse-closes-issues"
cp "$AGENTS_DIR/hooks/lib/parse-closes-issues.js" "$C_CFG/hooks/lib/parse-closes-issues.js"
# bin/is-github-dotcom-remote is deliberately absent (as in d6-fallback-cascade.sh): the
# D4 gh label lookup becomes a no-op, so no network is touched and BRANCH_TYPE stays
# title-derived.

C_LOG="$FIXTURE/spy-log.txt"
C_LIST="$FIXTURE/spy-list.txt"
C_REJECT="$FIXTURE/spy-reject-re.txt"
: > "$C_LOG"; : > "$C_LIST"; : > "$C_REJECT"
# Paths baked into JS string literals get no MSYS argv translation, so they must already
# be in the platform-native spelling Node can open — otherwise the spy would throw,
# record nothing, and every "no leak" assertion below would pass vacuously.
C_LOG_NATIVE="$(native_path "$C_LOG")"
C_LIST_NATIVE="$(native_path "$C_LIST")"
C_REJECT_NATIVE="$(native_path "$C_REJECT")"

# Spy scanner: the first half of scan_clean(). It receives only the candidate, so what
# it contributes is the environment observation — this is the child that had no business
# ever seeing the list, and the one an operator is least likely to think about.
cat > "$C_CFG/bin/scan-outbound.sh" <<STUB
#!/bin/bash
sp_cand="\$(cat)"
sp_cache=unset; sp_set=unset
[ -n "\${PRIVATE_REPO_NAMES_CACHE+x}" ] && sp_cache=set
[ -n "\${PRIVATE_REPO_NAMES_CACHE_SET+x}" ] && sp_set=set
printf 'SCAN|%s|list=n/a|cache=%s|set=%s\n' "\$sp_cand" "\$sp_cache" "\$sp_set" >> "$C_LOG"
exit 0
STUB
chmod +x "$C_CFG/bin/scan-outbound.sh"

# Spy checker: the second half, and the list's one legitimate consumer. Records what was
# DELIVERED over stdin (not what some variable happened to hold), so the routing
# assertions are about the real wire content.
cat > "$C_CFG/bin/check-private-repo-name.js" <<STUB
'use strict';
const fs = require('fs');
let raw = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', (d) => { raw += d; });
process.stdin.on('end', () => {
  const cand = process.argv[2] || '';
  const list = raw.split('\n').filter(Boolean);
  const has = (k) => (k in process.env ? 'set' : 'unset');
  fs.appendFileSync('$C_LOG_NATIVE',
    ['CHECK', cand, 'list=' + list.join(','),
     'cache=' + has('PRIVATE_REPO_NAMES_CACHE'),
     'set=' + has('PRIVATE_REPO_NAMES_CACHE_SET')].join('|') + '\n');
  let re = '';
  try { re = fs.readFileSync('$C_REJECT_NATIVE', 'utf8').trim(); } catch (e) { re = ''; }
  if (re && new RegExp(re).test(cand)) process.exit(1);
  process.exit(0);
});
STUB

# Stand-in lister: the script's own one-shot resolution step. Supplying it here is what
# lets the cache be populated by a plain in-script assignment instead of by an inherited
# export — see the header note on why the declared-cache contract cannot be used.
cat > "$C_CFG/bin/list-private-repo-names.js" <<STUB
process.stdout.write(require('fs').readFileSync('$C_LIST_NATIVE', 'utf8'));
STUB

# Self-check: a spy that cannot write its log would make every "no leak" and "wrong list"
# assertion below read as clean. Prove the recording works before trusting a single one.
: > "$C_LOG"
printf 'probe\n' | PRIVATE_REPO_NAMES_STDIN=1 node "$C_CFG/bin/check-private-repo-name.js" 'probe-candidate' >/dev/null 2>&1
if [ "$(grep -c '^CHECK|probe-candidate|list=probe|' "$C_LOG")" -eq 1 ]; then
    pass "B26/spy: the stand-in checker records the candidate and the list delivered to it (the assertions below are real)"
else
    fail "B26/spy: the stand-in checker cannot record invocations — B26 cannot be trusted (log='$(cat "$C_LOG")')"
fi

# A repo whose origin resolves to its own basename, so D0a actually fires and the
# self-excluded list is genuinely different from the full one. Without an origin the
# filter is skipped (fail closed) and every call site would see the same list, making
# the routing table below unable to distinguish the two.
C_REPO="$FIXTURE/spy-repo"
mkdir -p "$C_REPO"
git -C "$C_REPO" init -q >/dev/null 2>&1
git -C "$C_REPO" config core.hooksPath /dev/null
git -C "$C_REPO" remote add origin https://github.com/acme-org/spy-repo.git

# A title that slugifies to nothing forces D2's repo-name fallback — the second of the
# two self-excluded call sites, and the one a blanket-export implementation would get
# right by accident.
C_INTENT="$FIXTURE/spy-intent.md"
write_intent "$C_INTENT" '!!! @@@' '- #4242: env non-exposure'

C_SAVED_CFG="$AGENTS_CONFIG_DIR"
# c_run <label> — drive one derivation with both cache variables absent from the
# script's own environment, which is the only condition under which the script's
# non-exported assignment is what the children see.
c_run() {
    : > "$C_LOG"
    unset PRIVATE_REPO_NAMES_CACHE
    unset PRIVATE_REPO_NAMES_CACHE_SET
    export AGENTS_CONFIG_DIR="$C_CFG"
    run_derive "$1" --intent "$C_INTENT" --repo-dir "$C_REPO"
    export AGENTS_CONFIG_DIR="$C_SAVED_CFG"
    # Restore the suite-wide insulation immediately (private-repo-gate.sh does the same):
    # any later run_derive in this file must not fall through to a live `gh` call.
    export PRIVATE_REPO_NAMES_CACHE_SET=1
    export PRIVATE_REPO_NAMES_CACHE=''
}
# c_routes — the ordered "candidate => delivered list" projection of the CHECK records,
# with the UTC disambiguator normalized so the expected block is a fixed string.
c_routes() {
    grep '^CHECK|' "$C_LOG" | awk -F'|' '{ print $2 " => " $3 }' | sed -E 's/[0-9]{14}/<ts>/'
}

# --- B26a [F3]: no child ever sees either cache variable --------------------
# The direct regression guard for the leak. Asserted across EVERY scan_clean() call in
# one run and over both spies, because the old `export` was indiscriminate: a fix that
# only stopped exporting on the D6 path, or that left PRIVATE_REPO_NAMES_CACHE_SET
# behind, would still hand a child the flag that says "this empty list is authoritative"
# — the worst of the three states, since a child reading it would fail OPEN on every
# candidate and silently disable the gate.
printf '%s\n' 'spy-repo' 'secret-thing' > "$C_LIST"
printf '%s\n' '^4242-' > "$C_REJECT"
c_run B26a

B26_RECORDS="$(grep -c '^\(SCAN\|CHECK\)|' "$C_LOG")"
B26_LEAKS="$(grep -c 'cache=set\|set=set' "$C_LOG")"
if [ "$B26_RECORDS" -ge 8 ] && [ "$B26_LEAKS" -eq 0 ]; then
    pass "B26a/no-env-leak: across all $B26_RECORDS spy invocations neither PRIVATE_REPO_NAMES_CACHE nor PRIVATE_REPO_NAMES_CACHE_SET is present in the child's environment"
else
    fail "B26a/no-env-leak: expected >=8 recorded invocations and 0 carrying either variable (records=$B26_RECORDS, leaks=$B26_LEAKS, log='$(cat "$C_LOG")')"
fi
# The mechanism, pinned at the source: a re-added `export` is the single edit that
# reintroduces the leak, so it is worth catching by name as well as by behaviour.
if ! grep -q 'export PRIVATE_REPO_NAMES' "$SCRIPT"; then
    pass "B26a/no-export: derive-worktree-name.sh exports neither cache variable"
else
    fail "B26a/no-export: an 'export PRIVATE_REPO_NAMES...' line is back in derive-worktree-name.sh ($(grep -n 'export PRIVATE_REPO_NAMES' "$SCRIPT"))"
fi

# --- B26b [F3]: the mechanism swap did not re-route anything ----------------
# Delivery routing is the part a stdin rewrite can silently break, and no emitted name
# would reveal it: the two REPO_NAME gates (D0, and D2's repo-name fallback) must get the
# SELF-EXCLUDED list, while the title scan and the D6 tiers must get the FULL one. Under
# the old prefix-assignment form the scoping was accidental — a variable assignment
# prefixed onto a *function* call also exports it into every process that call spawns,
# which is the very leak F3 removed — so the argument form must reproduce the same
# routing exactly. Asserted on the delivered list CONTENTS: a pass/fail verdict alone
# cannot tell "the right list was delivered" from "the wrong list happened to agree".
B26_WANT="$(printf '%s\n' \
    'spy-repo => list=secret-thing' \
    '!!! @@@ => list=spy-repo,secret-thing' \
    'spy-repo => list=secret-thing' \
    '4242-spy-repo => list=spy-repo,secret-thing' \
    "4242-worktree-<ts> => list=spy-repo,secret-thing")"
assert_eq "B26b/routing: D0 and the D2 repo-name fallback receive the self-excluded list; the title scan and both D6 tiers receive the full one" \
    "$B26_WANT" "$(c_routes)"

# The same run also re-proves F1 from the delivery side: tier 2 is emitted without ever
# being handed to either spy, so it appears in no record at all.
B26A_TN="$(task_name)"
if [ "$RC" -eq 0 ] && printf '%s' "$B26A_TN" | grep -qE "^worktree-$TS_RE\$" \
    && ! grep -qF "|$B26A_TN|" "$C_LOG"; then
    pass "B26b/tier2: the emitted tier-2 name ($B26A_TN) reaches neither spy — it is emitted unscanned"
else
    fail "B26b/tier2: expected TASK_NAME=worktree-<ts> absent from every spy record (rc=$RC, tn='$B26A_TN', log='$(cat "$C_LOG")')"
fi

# --- B26c [F3]: an explicitly EMPTY list is authoritative, not a fallback ----
# scan_clean()'s default is `${2-${PRIVATE_REPO_NAMES_CACHE:-}}` — unset-only. The
# distinction is invisible until the self-exclusion filter empties the list completely,
# which is precisely the single-private-repo case: the user owns exactly one private
# repo, it is this one, D0a removes it, and D0 is then called with an empty second
# argument meaning "authoritative empty list — nothing to match against". With a
# `${2:-...}` default that empty argument would silently swap the FULL cache back in,
# check the repo's own name against the very entry D0a had just excluded, and self-block
# the repo at D0 — reinstating the bug D0a exists to fix, for every single-private-repo
# user.
# Route: through the script's own call sites, not by sourcing scan_clean() directly — a
# harness calling the function in isolation would prove the default's shape but not that
# any real call site can reach it, and reachability is the whole point here.
printf '%s\n' 'spy-repo' > "$C_LIST"
: > "$C_REJECT"
c_run B26c

B26C_WANT="$(printf '%s\n' \
    'spy-repo => list=' \
    '!!! @@@ => list=spy-repo' \
    'spy-repo => list=' \
    '4242-spy-repo => list=spy-repo')"
assert_eq "B26c/unset-vs-empty: an explicitly empty second argument delivers an empty list, while the unset ones still fall back to the full cache" \
    "$B26C_WANT" "$(c_routes)"
B26C_TN="$(task_name)"
if [ "$RC" -eq 0 ] && [ "$B26C_TN" = '4242-spy-repo' ] && [ "$(repo_name)" = 'spy-repo' ]; then
    pass "B26c/no-self-block: the sole-private-repo case derives normally instead of failing closed at D0 ($B26C_TN)"
else
    fail "B26c/no-self-block: expected rc=0 with TASK_NAME=4242-spy-repo and REPO_NAME=spy-repo (rc=$RC, tn='$B26C_TN', rn='$(repo_name)', err='$ERR')"
fi

report_shape env-nonexposure
finish
