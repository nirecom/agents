#!/bin/bash
# tests/feature-worktree-start-non-interactive/self-exclusion-origin.sh
# Tests: skills/worktree-start/scripts/derive-worktree-name.sh, bin/check-private-repo-name.js
# Tags: worktree, start, private-repo, self-exclusion, origin-url, table-driven, security, TL2, scope:issue-specific
# B25 — D0a's self-exclusion classifier, driven by the ORIGIN remote identity.

# Why beyond B21d-B21k: there, local basename == origin repo segment in every allow
# fixture, so filtering by LOCAL basename would pass them all. D0a's premise is about
# the REMOTE ("already known to the remote's audience"), so keying it on a directory
# name disarms the gate.
# Discriminating rows here: local basename matches a cached private name while origin
# differs (must REJECT), the three fail-closed shapes (no origin, unparseable origin,
# broken filter), and ALLOW rows across HTTPS/SCP/ssh:// to exercise the URL parser.
# Part of the feature-worktree-start-non-interactive suite — see the dispatcher.

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"
setup_fixture

# The fixture "private" names. Both are already in slug shape so slugification cannot
# change them, and neither may ever appear in stdout or stderr.
B25_SELF='selfname-repo'
B25_OTHER='secret-thing'

D0A_MSG='the repository directory name failed the outbound scan'
B25_FILTER_MSG='self-exclusion filter failed'

B25_ROOT="$FIXTURE/b25"
B25_IDX=0
b25_trim() { printf '%s' "$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'; }

# name | origin URL ('-' = no origin remote at all) | checkout basename | declared cache | want rc
#
# The reject rows are the discriminators. In each, the checkout's own basename IS the
# cached private name while the origin resolves to something else (or to nothing at
# all) — so the only implementation that keeps them red is one that filters on the
# resolved origin name and fails closed when it cannot resolve one.
while IFS='|' read -r b25_name b25_origin b25_dir b25_cache b25_rc; do
    [[ -z "$b25_name" || "$b25_name" =~ ^[[:space:]]*# ]] && continue
    b25_name="$(b25_trim "$b25_name")"
    b25_origin="$(b25_trim "$b25_origin")"
    b25_dir="$(b25_trim "$b25_dir")"
    b25_cache="$(b25_trim "$b25_cache")"
    b25_rc="$(b25_trim "$b25_rc")"
    B25_IDX=$((B25_IDX + 1))

    # One repo per row: the origin remote is part of the input under test, so rows
    # must not share a checkout.
    b25_repo="$B25_ROOT/$B25_IDX/$b25_dir"
    mkdir -p "$b25_repo"
    git -C "$b25_repo" init -q >/dev/null 2>&1
    git -C "$b25_repo" config core.hooksPath /dev/null
    if [ "$b25_origin" != '-' ]; then
        git -C "$b25_repo" remote add origin "$b25_origin" >/dev/null 2>&1
    fi

    PRIVATE_REPO_NAMES_CACHE="$b25_cache"
    run_derive "B25/$b25_name" --intent "$ABSENT_INTENT" --headless work-on-thing \
        --repo-dir "$b25_repo"

    assert_eq "B25/$b25_name/rc" "$b25_rc" "$RC"

    if [ "$b25_rc" -eq 0 ]; then
        # ALLOW: the self-entry was filtered, so D0 emits the repo name and the run
        # completes normally. Both halves are asserted — an rc=0 that emitted nothing
        # would otherwise read as a pass.
        if [ "$(repo_name)" = "$b25_dir" ] \
            && printf '%s' "$(task_name)" | grep -qE "^work-on-thing-$TS_RE\$" \
            && [[ "$ERR" != *"$D0A_MSG"* ]]; then
            pass "B25/$b25_name/allow: the origin's own name is excluded — REPO_NAME=$b25_dir emitted, no D0 self-block"
        else
            fail "B25/$b25_name/allow: expected REPO_NAME=$b25_dir and TASK_NAME=work-on-thing-<ts> (rc=$RC, rn='$(repo_name)', tn='$(task_name)', err='$ERR')"
        fi
    else
        # REJECT: nothing may be emitted, and the refusal must be attributed to the D0
        # outbound scan rather than to some unrelated failure earlier in the script.
        if [ -z "$(task_name)" ] && [ -z "$(repo_name)" ] && [[ "$ERR" == *"$D0A_MSG"* ]]; then
            pass "B25/$b25_name/reject: the gate stays armed — rc=1 with the D0 scan-failure diagnostic and no emitted name"
        else
            fail "B25/$b25_name/reject: expected rc=1, no TASK_NAME/REPO_NAME, and the D0 scan-failure diagnostic (rc=$RC, out='$OUT', err='$ERR')"
        fi
    fi

    # No secret echo, on every row and in both directions: the diagnostic is a fixed
    # literal, so neither the matched private name nor the origin URL that produced it
    # may appear on either stream (rules test-design.md "Secret leakage").
    if [[ "$OUT" == *"$b25_cache"* || "$ERR" == *"$b25_cache"* ]] && [ "$b25_rc" -ne 0 ]; then
        fail "B25/$b25_name/leak: the matched private name reached stdout or stderr (out='$OUT', err='$ERR')"
    else
        pass "B25/$b25_name/leak: the refusal never interpolates the matched private name"
    fi
done <<'B25_TABLE'
# --- sanctioned ALLOW rows: this checkout's own origin, in all three URL spellings ---
allow-https            | https://github.com/acme-org/selfname-repo.git   | selfname-repo | selfname-repo | 0
allow-https-no-suffix  | https://github.com/acme-org/selfname-repo       | selfname-repo | selfname-repo | 0
allow-scp              | git@github.com:acme-org/selfname-repo.git       | selfname-repo | selfname-repo | 0
allow-ssh              | ssh://git@github.com/acme-org/selfname-repo.git | selfname-repo | selfname-repo | 0
allow-origin-case      | https://github.com/acme-org/SelfName-Repo.git   | selfname-repo | selfname-repo | 0
# --- REJECT: local basename collides with a cached private name, origin points elsewhere ---
reject-origin-differs-https | https://github.com/acme-org/other-repo.git | secret-thing  | secret-thing  | 1
reject-origin-differs-scp   | git@github.com:acme-org/other-repo.git     | secret-thing  | secret-thing  | 1
reject-origin-differs-ssh   | ssh://git@github.com/acme-org/other-repo   | secret-thing  | secret-thing  | 1
# --- REJECT: the origin identity cannot be established at all -> fail closed ---
reject-no-origin            | -                                          | secret-thing  | secret-thing  | 1
reject-origin-no-separator  | weirdremote                                | secret-thing  | secret-thing  | 1
reject-origin-trailing-slash| https://github.com/acme-org/               | secret-thing  | secret-thing  | 1
B25_TABLE

# --- B25/self-origin-still-rejects-other: the filter is one entry wide ----------
# The reject rows above all declare a single-entry cache, so a filter that threw the
# whole list away would still look red there for the wrong reason (empty list, but
# REPO_NAME==the only entry). This row declares both the origin's own name and an
# unrelated private name, with the checkout named after the unrelated one: the
# self-entry must go and the other must stay, so D0 still refuses.
B25_BOTH="$B25_ROOT/both/$B25_OTHER"
mkdir -p "$B25_BOTH"
git -C "$B25_BOTH" init -q >/dev/null 2>&1
git -C "$B25_BOTH" config core.hooksPath /dev/null
git -C "$B25_BOTH" remote add origin "https://github.com/acme-org/$B25_SELF.git" >/dev/null 2>&1
PRIVATE_REPO_NAMES_CACHE="$(printf '%s\n%s' "$B25_SELF" "$B25_OTHER")"
run_derive B25/both --intent "$ABSENT_INTENT" --headless work-on-thing --repo-dir "$B25_BOTH"
if [ "$RC" -eq 1 ] && [ -z "$(repo_name)" ] && [[ "$ERR" == *"$D0A_MSG"* ]]; then
    pass "B25/both: filtering the origin's own entry leaves every other private name armed — the colliding checkout still fails closed"
else
    fail "B25/both: expected rc=1 with the D0 scan-failure diagnostic (rc=$RC, out='$OUT', err='$ERR')"
fi
if [[ "$OUT" == *"$B25_OTHER"* || "$ERR" == *"$B25_OTHER"* ]]; then
    fail "B25/both/leak: the other private name reached stdout or stderr (out='$OUT', err='$ERR')"
else
    pass "B25/both/leak: the refusal never echoes the other private name"
fi

# --- B25/filter-fails: the filtering step itself failing must fail CLOSED -------
# D0a's documented contract on an awk failure is "keep the unfiltered list" — the
# same fail-closed outcome as the no-resolvable-origin branch — never adopt the
# partial output a broken pipeline left behind. A PATH shim that makes `awk` exit
# non-zero is the only way to reach that branch, since no cache content can break
# the one-liner. D0a runs before slugify(), so no later awk use is reached.
ensure_stubdir
cat > "$STUBDIR/awk" <<'AWKSTUB'
#!/bin/sh
# Stand-in awk: always fails, emitting nothing. Reproduces a broken/partial pipeline.
exit 1
AWKSTUB
chmod +x "$STUBDIR/awk"

B25_FILTER_REPO="$B25_ROOT/filterfail/$B25_SELF"
mkdir -p "$B25_FILTER_REPO"
git -C "$B25_FILTER_REPO" init -q >/dev/null 2>&1
git -C "$B25_FILTER_REPO" config core.hooksPath /dev/null
git -C "$B25_FILTER_REPO" remote add origin "https://github.com/acme-org/$B25_SELF.git" >/dev/null 2>&1

# Self-check first: without the shim this exact fixture is the sanctioned ALLOW case.
# Without it, a shim that silently failed to take effect would leave the assertion
# below indistinguishable from "the repo was rejected for some other reason".
PRIVATE_REPO_NAMES_CACHE="$B25_SELF"
run_derive B25/filter-ok --intent "$ABSENT_INTENT" --headless work-on-thing --repo-dir "$B25_FILTER_REPO"
if [ "$RC" -eq 0 ] && [ "$(repo_name)" = "$B25_SELF" ]; then
    pass "B25/filter-ok: with a working awk the same fixture is the sanctioned ALLOW case (the shim result below is real)"
else
    fail "B25/filter-ok: expected the unshimmed fixture to derive cleanly (rc=$RC, rn='$(repo_name)', err='$ERR')"
fi

B25_SAVED_PATH="$PATH"
PATH="$STUBDIR:$PATH"
export PATH
PRIVATE_REPO_NAMES_CACHE="$B25_SELF"
run_derive B25/filter-fails --intent "$ABSENT_INTENT" --headless work-on-thing --repo-dir "$B25_FILTER_REPO"
PATH="$B25_SAVED_PATH"
export PATH

if [ "$RC" -eq 1 ] && [ -z "$(task_name)" ] && [ -z "$(repo_name)" ]; then
    pass "B25/filter-fails: a failed self-exclusion filter falls back to the unfiltered list and refuses — never adopts the partial output"
else
    fail "B25/filter-fails: expected rc=1 with nothing emitted when the filter pipeline fails (rc=$RC, out='$OUT', err='$ERR')"
fi
if [[ "$ERR" == *"$B25_FILTER_MSG"* ]]; then
    pass "B25/filter-fails/attributed: the refusal is attributed to the filter failure, not silently conflated with a clean reject"
else
    fail "B25/filter-fails/attributed: expected the '$B25_FILTER_MSG' diagnostic on stderr (err='$ERR')"
fi
if [[ "$OUT" == *"$B25_SELF"* || "$ERR" == *"$B25_SELF"* ]]; then
    fail "B25/filter-fails/leak: the private name reached stdout or stderr (out='$OUT', err='$ERR')"
else
    pass "B25/filter-fails/leak: the fail-closed path never echoes the private name"
fi

report_shape self-exclusion-origin
finish
