#!/bin/bash
# tests/fix-1899-origin-repo-resolver/resolver-contract.sh
# Tests: bin/github-issues/lib/origin-repo.sh, bin/github-issues/lib/resolve-project.sh
# Tags: origin-resolution, github-issues, resolve-project, module-contract, TL2, scope:issue-specific
#
# Group C of the fix-1899-origin-repo-resolver split suite — the module-level
# contract of origin-repo.sh, independent of any single URL shape.
#
# Why: the resolver is SOURCED by several callers and invoked repeatedly within
# one skill run, so it must be side-effect free (same answer on every call),
# default its <dir> argument to the current working directory, and stay free of
# the two implementation choices #1899 rejected — shelling out to `sed` for
# extraction, and consulting `gh repo view` for identity.
#
# TL2 (real git fixtures, real bash). TL3 gap: no real GitHub API round-trip.
# Mitigated at WORKFLOW_USER_VERIFIED preflight (bin/check-verification-gate.sh).

set -u

# shellcheck source=_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

# ===========================================================================
# Group C — default dir, idempotency, and implementation constraints
# ===========================================================================
group_resolver_properties() {
    local dir a b out rc
    dir="$(mk_repo "idem" "https://github.com/owner/repo.git")"
    a="$(call_resolver "$dir")"
    b="$(call_resolver "$dir")"
    assert_eq "resolver/idempotent" "$a" "$b"
    assert_eq "resolver/idempotent-value" "0|owner/repo" "$a"

    # No <dir> argument -> resolves the current working directory.
    out=$(run_with_timeout 20 bash -c '
        set -u
        cd "$2" || exit 92
        [ -f "$1" ] || { printf "ERR:lib-missing"; exit 90; }
        . "$1"
        command -v resolve_origin_owner_repo >/dev/null 2>&1 || { printf "ERR:fn-missing"; exit 91; }
        resolve_origin_owner_repo
    ' _ "$ORIGIN_LIB" "$dir" 2>/dev/null)
    rc=$?
    assert_eq "resolver/default-dir-is-cwd" "0|owner/repo" "$rc|$out"

    if [ ! -f "$ORIGIN_LIB" ]; then
        fail "resolver/lib-present — $ORIGIN_LIB missing"
        fail "resolver/no-sed — cannot check, lib missing"
        fail "resolver/no-gh-repo-view — cannot check, lib missing"
        return
    fi
    pass "resolver/lib-present"
    # owner/repo extraction must use bash parameter expansion, not sed.
    if grep -qE '(^|[^a-zA-Z0-9_-])sed([^a-zA-Z0-9_-]|$)' "$ORIGIN_LIB"; then
        fail "resolver/no-sed — origin-repo.sh shells out to sed"
    else
        pass "resolver/no-sed"
    fi
    if grep -q 'gh repo view' "$ORIGIN_LIB"; then
        fail "resolver/no-gh-repo-view — origin-repo.sh still calls gh repo view"
    else
        pass "resolver/no-gh-repo-view"
    fi

    # Same constraint, applied to the other library #1899 repointed: identity in
    # resolve-project.sh must come from the origin remote, never from the API.
    # Group F in callers.sh proves it dynamically (no `gh repo view` reaches the
    # stub); this is the cheap static half, so a reintroduced call is caught even
    # if a future stub stops recording. Comment lines are stripped before the
    # match: resolve-project.sh's header still documents the historical
    # "gh repo view failed" rc=1 branch, and a stale doc string must not
    # masquerade as a live call.
    local resolve_project_lib
    resolve_project_lib="$AGENTS_DIR/bin/github-issues/lib/resolve-project.sh"
    if [ ! -f "$resolve_project_lib" ]; then
        fail "resolve-project/no-gh-repo-view — cannot check, $resolve_project_lib missing"
    elif grep -v '^[[:space:]]*#' "$resolve_project_lib" | grep -q 'gh repo view'; then
        fail "resolve-project/no-gh-repo-view — resolve-project.sh still calls gh repo view"
    else
        pass "resolve-project/no-gh-repo-view"
    fi
}

# ===========================================================================
# Group C2 — the ERROR side of the contract: every way the resolver can be
#   handed something that is not a resolvable github.com checkout.
#
#   Why this is its own group: resolve-origin.sh's table drives the resolver
#   through fixtures that are always REAL git repositories with a REAL origin
#   URL, so the failure modes that come from the ENVIRONMENT rather than from the
#   URL — a directory that is not a git repo, a directory that does not exist,
#   a repo with no HEAD — were never exercised. Each of them makes
#   `git remote get-url origin` itself fail, and the resolver must answer rc 1
#   with EMPTY stdout rather than printing a partial or stale value.
#
#   Every case additionally asserts that NO `gh` process was started. The
#   resolver is the layer #1899 introduced specifically so identity stops being
#   an API question; a future edit that "falls back to `gh repo view` when git
#   cannot answer" would restore the defect on exactly these paths, where it is
#   least likely to be noticed. A recording stub ahead of the real `gh` on PATH
#   makes that observable.
# ===========================================================================
mk_recording_gh() {
    local bindir="$TMP/gh-recorder"
    mkdir -p "$bindir"
    cat >"$bindir/gh" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "${GH_CALL_LOG:-/dev/null}"
# Answers with a plausible-but-WRONG identity: a resolver that ever consults it
# would not merely be logged, it would return this value.
echo "api-answer-owner/api-answer-repo"
exit 0
STUB
    chmod +x "$bindir/gh"
    printf '%s' "$bindir"
}

# call_resolver_guarded <dir> -> "<rc>|<stdout>" with a recording `gh` on PATH.
call_resolver_guarded() {
    local out rc
    out=$(PATH="$GH_RECORDER:$PATH" run_with_timeout 20 bash -c '
        set -u
        [ -f "$1" ] || { printf "ERR:lib-missing"; exit 90; }
        # shellcheck disable=SC1090
        . "$1"
        command -v resolve_origin_owner_repo >/dev/null 2>&1 || { printf "ERR:fn-missing"; exit 91; }
        resolve_origin_owner_repo "$2"
    ' _ "$ORIGIN_LIB" "$1" 2>/dev/null)
    rc=$?
    printf '%s|%s' "$rc" "$out"
}

group_resolver_guards() {
    GH_RECORDER="$(mk_recording_gh)"
    export GH_CALL_LOG="$TMP/gh-calls.log"
    : >"$GH_CALL_LOG"

    local dir

    # Not a git repository at all: `git remote get-url origin` exits non-zero, so
    # the resolver must stop at its first guard (rc 1), never continue with an
    # empty url into the host classifier.
    dir="$TMP/not-a-repo"
    rm -rf "$dir"; mkdir -p "$dir"
    assert_eq "guard/plain-directory-is-rc1" "1|" "$(call_resolver_guarded "$dir")"

    # A path that does not exist at all — the same rc, not a crash and not a
    # stdout leak of git's own error text.
    assert_eq "guard/nonexistent-directory-is-rc1" "1|" \
        "$(call_resolver_guarded "$TMP/definitely/not/here")"

    # A real repo with no origin remote and no commits (no HEAD): `git remote
    # get-url origin` fails for the remote, not for the HEAD, and rc 1 is the
    # answer either way.
    dir="$(mk_repo "guard-noorigin" "__NONE__")"
    assert_eq "guard/no-origin-remote-is-rc1" "1|" "$(call_resolver_guarded "$dir")"

    # origin exists but names a non-GitHub host -> rc 2, still empty stdout.
    dir="$(mk_repo "guard-nongithub" "https://gitlab.com/owner/repo.git")"
    assert_eq "guard/non-github-origin-is-rc2" "2|" "$(call_resolver_guarded "$dir")"

    # origin is a github.com URL whose path names no owner/repo -> rc 3.
    dir="$(mk_repo "guard-malformed" "https://github.com/onlyowner")"
    assert_eq "guard/malformed-github-origin-is-rc3" "3|" "$(call_resolver_guarded "$dir")"

    # CPR-UNV: a checkout path containing spaces is an ordinary path, not a
    # special case. An unquoted `git -C $dir` inside the resolver would word-split
    # it and answer rc 1 for a perfectly resolvable repository.
    dir="$(mk_repo "guard has spaces" "https://github.com/space-owner/space-repo.git")"
    assert_eq "guard/path-with-spaces-still-resolves" "0|space-owner/space-repo" \
        "$(call_resolver_guarded "$dir")"

    # The whole point of the group: none of the six calls above may have started
    # a `gh` process. The stub answers with an identity nobody asked for, so a
    # fallback would show up in the rc/stdout assertions too — this asserts the
    # ROUTE, which stays wrong even if a future fallback happens to guess right.
    if [ ! -s "$GH_CALL_LOG" ]; then
        pass "guard/no-gh-process-on-any-path"
    else
        fail "guard/no-gh-process-on-any-path — $(wc -l <"$GH_CALL_LOG") invocation(s): $(tr '\n' ';' <"$GH_CALL_LOG")"
    fi

    # Guard against a vacuous pass on the line above: prove the recorder WOULD
    # have recorded had anything invoked it.
    PATH="$GH_RECORDER:$PATH" gh repo view >/dev/null 2>&1 || true
    if [ -s "$GH_CALL_LOG" ]; then
        pass "guard/recorder-is-wired-up"
    else
        fail "guard/recorder-is-wired-up — the stub recorded nothing even when called directly"
    fi
    unset GH_CALL_LOG
}

# ===========================================================================
# Group C3 — the resolver reads `origin` EXACTLY ONCE, so the bytes it parses
#   and the bytes it classifies are provably the same bytes.
#
#   Why: resolve_origin_owner_repo() used to run `git -C "$dir" remote get-url
#   origin` itself (for the owner/repo parse) and then hand the DIRECTORY to
#   bin/is-github-dotcom-remote, which performed its OWN independent
#   `git -C "$DIR" remote get-url origin` to classify the host. Two subprocesses,
#   two reads, no guarantee they agree — a credential helper, an `insteadOf`
#   rewrite, or an interleaved `git remote set-url` can make the second answer
#   differ from the first, and the owner/repo that reaches
#   `gh api repos/<owner>/<repo>` would then be one no host check ever validated
#   (#1899). The resolver now reads once and passes the value on via the
#   classifier's `--url` mode, which closes that window structurally.
#
#   The stub below is stateful: it counts `remote get-url origin` invocations and
#   would answer a 2nd call DIFFERENTLY from the 1st, delegating every other git
#   subcommand to the real binary. A second read is therefore not merely counted,
#   it is loaded — if one ever reappears it changes the answer, so these cases
#   fail loudly rather than drifting.
# ===========================================================================

# mk_stateful_git -> echoes a bindir holding a `git` that answers
#   `remote get-url origin` from $GIT_URL_1 (first call) and $GIT_URL_2
#   (every later call, which post-fix must never occur), counting calls in
#   $GIT_CALL_COUNT.
mk_stateful_git() {
    local bindir="$TMP/git-stateful"
    local realgit
    realgit="$(command -v git)"
    mkdir -p "$bindir"
    cat >"$bindir/git" <<STUB
#!/bin/bash
REAL_GIT="$realgit"
STUB
    cat >>"$bindir/git" <<'STUB'
if [ "${1:-}" = "-C" ] && [ "${3:-}" = "remote" ] && [ "${4:-}" = "get-url" ] && [ "${5:-}" = "origin" ]; then
    n=0
    [ -f "${GIT_CALL_COUNT:-/dev/null}" ] && n="$(cat "$GIT_CALL_COUNT")"
    n=$((n + 1))
    printf '%s' "$n" > "$GIT_CALL_COUNT"
    if [ "$n" = "1" ]; then printf '%s\n' "$GIT_URL_1"; else printf '%s\n' "$GIT_URL_2"; fi
    exit 0
fi
exec "$REAL_GIT" "$@"
STUB
    chmod +x "$bindir/git"
    printf '%s' "$bindir"
}

# call_resolver_diverging <dir> <url-for-1st-read> <url-for-2nd-read>
#   -> "<rc>|<stdout>" (the stateful git stub AND the recording `gh` from Group
#   C2 are both first on PATH, so every case here also observes whether any `gh`
#   process was started — the resolver must never consult the API for identity.)
call_resolver_diverging() {
    local out rc
    printf '' >"$GIT_CALL_COUNT"
    out=$(PATH="$GIT_STATEFUL:$GH_RECORDER:$PATH" GIT_URL_1="$2" GIT_URL_2="$3" \
        GIT_CALL_COUNT="$GIT_CALL_COUNT" run_with_timeout 20 bash -c '
        set -u
        [ -f "$1" ] || { printf "ERR:lib-missing"; exit 90; }
        # shellcheck disable=SC1090
        . "$1"
        command -v resolve_origin_owner_repo >/dev/null 2>&1 || { printf "ERR:fn-missing"; exit 91; }
        resolve_origin_owner_repo "$2"
    ' _ "$ORIGIN_LIB" "$1" 2>/dev/null)
    rc=$?
    printf '%s|%s' "$rc" "$out"
}

group_resolver_divergent_reads() {
    GIT_STATEFUL="$(mk_stateful_git)"
    GIT_CALL_COUNT="$TMP/git-origin-calls"
    printf '' >"$GIT_CALL_COUNT"
    # Group C2 builds the recorder; rebuild unconditionally so this group also
    # runs correctly when someone executes it in isolation.
    GH_RECORDER="$(mk_recording_gh)"
    export GH_CALL_LOG="$TMP/gh-calls-diverge.log"
    : >"$GH_CALL_LOG"

    local dir got

    # assert_single_read <case> — the invariant this whole group exists for.
    assert_single_read() {
        assert_eq "diverge/$1/reads-origin-exactly-once" "1" "$(cat "$GIT_CALL_COUNT")"
    }
    # assert_no_gh <case> — identity must never come from the API.
    assert_no_gh() {
        if [ ! -s "$GH_CALL_LOG" ]; then
            pass "diverge/$1/zero-gh-calls"
        else
            fail "diverge/$1/zero-gh-calls — $(tr '\n' ';' <"$GH_CALL_LOG")"
        fi
        : >"$GH_CALL_LOG"
    }

    dir="$(mk_repo "diverging" "https://github.com/owner/repo.git")"

    # Baseline: prove the stub is actually intercepting, and that the resolver
    # still answers normally through it. Without this, the assertions below could
    # pass for the wrong reason (a stub that never fired).
    assert_eq "diverge/stub-transparent-when-both-agree" "0|owner/repo" \
        "$(call_resolver_diverging "$dir" \
            "https://github.com/owner/repo.git" "https://github.com/owner/repo.git")"
    # The single-read invariant, measured on the happy path: one `remote get-url
    # origin` for the whole resolve. Two would mean the classifier went back to
    # reading the remote itself, reopening the #1899 divergence window even when
    # both reads happen to agree.
    assert_single_read "both-agree"
    assert_no_gh "both-agree"

    # Case A — the (only) read is a github.com URL; the stub stands ready to hand
    # a DIFFERENT, non-github URL to any second reader. There is no second
    # reader, so the second URL can influence nothing: the resolver classifies
    # and parses the same bytes and answers rc 0 with that URL's owner/repo.
    # Pre-fix this returned rc 2, because the host classifier's independent read
    # saw the gitlab URL — that rc 2 was the symptom, not the contract.
    assert_eq "diverge/second-url-cannot-veto-the-read-value" "0|owner/repo" \
        "$(call_resolver_diverging "$dir" \
            "https://github.com/owner/repo.git" "https://gitlab.com/attacker/repo.git")"
    assert_single_read "second-url-cannot-veto-the-read-value"
    assert_no_gh "second-url-cannot-veto-the-read-value"

    # Case B — the mirror, and the security-relevant arm. The (only) read is NOT
    # a github.com URL, while a github.com URL waits for a second reader that no
    # longer exists. Pre-fix the classifier's own read saw the github.com URL and
    # approved, so the resolver returned rc 0 with "attacker/repo" — an
    # owner/repo no host check had ever validated, bound for
    # `gh api repos/<owner>/<repo>` under the caller's token. Post-fix the one
    # URL that was read is the one that is classified, so this fails CLOSED:
    # rc 2, empty stdout, nothing asked of the API.
    got="$(call_resolver_diverging "$dir" \
        "https://gitlab.com/attacker/repo.git" "https://github.com/owner/repo.git")"
    assert_eq "diverge/single-read-fails-closed-on-non-github" "2|" "$got"
    assert_single_read "single-read-fails-closed-on-non-github"
    assert_no_gh "single-read-fails-closed-on-non-github"
    # Stated independently of the exact rc: whatever comes back must never be the
    # owner/repo of the URL only a SECOND read could have seen — that would mean
    # a URL the resolver never parsed had silently become the identity.
    case "$got" in
        *owner/repo*) fail "diverge/second-read-url-is-not-the-identity — got=$got" ;;
        *) pass "diverge/second-read-url-is-not-the-identity" ;;
    esac

    # Anti-vacuous control for assert_single_read: prove the counter WOULD have
    # reached 2 had a second read happened. Two direct reads through the stub
    # must count 2 and must return the two DIFFERENT urls, which is also what
    # makes Cases A and B loaded rather than merely counted.
    printf '' >"$GIT_CALL_COUNT"
    local probe1 probe2
    probe1=$(PATH="$GIT_STATEFUL:$PATH" GIT_URL_1="url-one" GIT_URL_2="url-two" \
        GIT_CALL_COUNT="$GIT_CALL_COUNT" git -C "$dir" remote get-url origin)
    probe2=$(PATH="$GIT_STATEFUL:$PATH" GIT_URL_1="url-one" GIT_URL_2="url-two" \
        GIT_CALL_COUNT="$GIT_CALL_COUNT" git -C "$dir" remote get-url origin)
    assert_eq "diverge/counter-would-see-a-second-read" "2|url-one|url-two" \
        "$(cat "$GIT_CALL_COUNT")|$probe1|$probe2"

    unset GH_CALL_LOG
}

group_resolver_properties
group_resolver_guards
group_resolver_divergent_reads

finish
