#!/usr/bin/env bash
# Derive the worktree task name and branch type deterministically.
#
# Usage: derive-worktree-name.sh [--intent <path>] [--headless <label>] [--repo-dir <dir>]
#
# stdout (success, exactly three lines):
#   TASK_NAME=<name>
#   BRANCH_TYPE=<feature|fix|refactor|docs|chore>
#   REPO_NAME=<validated last path component of the worktree path>
#
# exit: 0 success / 1 no naming source or validation failure / 64 usage error
#
# `set -e` is deliberately NOT used: the fallback branches rely on catching
# non-zero exits from optional helpers.
set -u

INTENT_ARG=""
HEADLESS_LABEL=""
REPO_DIR=""

while [ $# -gt 0 ]; do
    case "$1" in
        --intent)
            [ $# -ge 2 ] || { printf 'derive-worktree-name: --intent requires a value\n' >&2; exit 64; }
            INTENT_ARG="$2"; shift 2 ;;
        --headless)
            [ $# -ge 2 ] || { printf 'derive-worktree-name: --headless requires a value\n' >&2; exit 64; }
            HEADLESS_LABEL="$2"; shift 2 ;;
        --repo-dir)
            [ $# -ge 2 ] || { printf 'derive-worktree-name: --repo-dir requires a value\n' >&2; exit 64; }
            REPO_DIR="$2"; shift 2 ;;
        *)
            printf 'derive-worktree-name: unrecognized argument; accepted flags are --intent, --headless, --repo-dir\n' >&2; exit 64 ;;
    esac
done

if [ -z "${AGENTS_CONFIG_DIR:-}" ]; then
    printf 'derive-worktree-name: AGENTS_CONFIG_DIR is unset\n' >&2
    exit 64
fi

# --- private-repo-name cache (one gh round-trip per run) ---------------------
# scan_clean() runs check-private-repo-name.js up to several times per run (D0,
# D2, and D6's fallback cascade), and each call would otherwise re-issue the
# same `gh repo list --visibility private` query. Resolve the list once here and
# keep it in plain (non-exported) shell variables, handing it to its one
# consumer over stdin at the scan_clean() call site instead: the complete list of
# the user's private repository names must not sit in the environment of this
# script and of every process it spawns thereafter (node, git, bash, the
# scan-outbound.sh subprocess, ...), where process-inspection interfaces can read
# it and it is inherited far beyond the single consumer that needs it.
# PRIVATE_REPO_NAMES_CACHE_SET=1 means "the list is authoritative", so an empty
# PRIVATE_REPO_NAMES_CACHE means "confirmed no private repos" rather than
# "unknown" — the lister fails open to empty, matching the checker's own
# fail-open contract, so a lookup failure degrades to "clean" exactly as it
# already did per-call.
# Do NOT rename these two variables. INBOUND, they are still the env-var contract
# the test suite uses to insulate itself from live `gh` calls
# (tests/feature-worktree-start-non-interactive/helpers.sh exports both INTO this
# script, and this script still reads both) — that contract is unchanged. Only
# the OUTBOUND propagation changed: neither variable is exported onward, so do
# not re-add an `export` here. Exporting only one of the pair would be worse
# than exporting both: a
# child seeing PRIVATE_REPO_NAMES_CACHE_SET=1 without the list would read
# "authoritative empty list" and fail OPEN on every candidate, silently disabling
# the gate. A caller that has already declared the list keeps it — populating it
# here unconditionally would re-introduce the very gh call that contract exists
# to avoid.
if [ "${PRIVATE_REPO_NAMES_CACHE_SET:-}" != "1" ]; then
    PRIVATE_REPO_NAMES_CACHE="$(node "$AGENTS_CONFIG_DIR/bin/list-private-repo-names.js" 2>/dev/null)"
    PRIVATE_REPO_NAMES_CACHE_SET=1
fi

[ -n "$REPO_DIR" ] || REPO_DIR="$(git rev-parse --show-toplevel 2>/dev/null)"
[ -n "$REPO_DIR" ] || REPO_DIR="$PWD"

# --- D3: slugify ------------------------------------------------------------
# 1. ASCII case fold, 2. non-[a-z0-9] runs -> '-' (LC_ALL=C makes multibyte
# characters byte-level so they collapse away), 3. first 5 tokens, 4. cap 40.
# Every stage is locale-sensitive, so the whole pipeline runs in one LC_ALL=C
# subshell (same pattern as D5) rather than pinning individual stages.
slugify() {
    (
        export LC_ALL=C
        printf '%s' "$1" \
            | tr 'A-Z' 'a-z' \
            | sed -e 's/[^a-z0-9]\{1,\}/-/g' -e 's/^-//' -e 's/-$//' \
            | awk -F- '{ s=""; c=0; for (i = 1; i <= NF && c < 5; i++) { if ($i != "") { s = (c == 0 ? $i : s "-" $i); c++ } } print s }' \
            | cut -c1-40 \
            | sed -e 's/-$//'
    )
}

# --- D3a: outbound-scan gate ------------------------------------------------
# Human-authored title/label text becomes a public branch name, so it must pass
# the same private-info scan as any other outbound content. Exit 0 = clean;
# any non-zero (hard violation, warning, or scanner unavailable) fails closed.
# bin/scan-outbound.sh only checks the two static allowlist/blocklist files, so
# it is also checked against the live private-repo-name list (same matching
# logic as hooks/scan-outbound.js's dynamic WARN) since a git push never
# re-scans branch names — a bare private repo name could otherwise leak into
# one. That check fails open on lookup failure, matching its own contract.
# The private-name list travels over stdin, not the environment, so it never
# reaches any spawned process's environment at all (see the cache block above).
# The candidate still travels as argv in both commands, which is what leaves each
# pipeline's stdin free: scan-outbound.sh consumes the candidate from the first
# printf, and the checker consumes the list from the second — the two pipelines
# are independent. PRIVATE_REPO_NAMES_STDIN=1 is a one-shot prefix assignment on
# the checker invocation alone, deliberately not an export.
#
# $1 = candidate. $2 = the name list to check it against; omit it to use the
# script-level cache. The default is `${2-...}` (unset-only), never `${2:-...}`:
# a caller that passes an EMPTY list means "authoritative empty list — nothing to
# match against", and a `:-` default would silently swap in the full cache and
# check against the very entries the caller had just excluded. The list is
# expanded inline rather than parked in a helper variable: POSIX sh has no
# `local`, so any such variable would be a global outliving the call.
scan_clean() {
    printf '%s\n' "$1" | bash "$AGENTS_CONFIG_DIR/bin/scan-outbound.sh" --stdin worktree-name >/dev/null 2>&1 || return 1
    printf '%s\n' "${2-${PRIVATE_REPO_NAMES_CACHE:-}}" | PRIVATE_REPO_NAMES_STDIN=1 node "$AGENTS_CONFIG_DIR/bin/check-private-repo-name.js" "$1" >/dev/null 2>&1
}

# --- D3a2: path-component guard ---------------------------------------------
# A name that becomes a filesystem path component (and later a branch name)
# must not carry separators or traversal. Bracket-class matching is
# locale-sensitive, so pin it to C like slugify() and D5 do.
# The leading-character rule matches D5's TASK_NAME rule (CPR-ORTH): both are
# path-component validators, so a leading '.', '-', or '_' is rejected here too
# (dotfile / option-lookalike names).
safe_component() {
    (
        export LC_ALL=C
        case "$1" in
            ''|.|..) exit 1 ;;
            *[!a-zA-Z0-9._-]*) exit 1 ;;
        esac
        case "$1" in
            [a-zA-Z0-9]*) ;;
            *) exit 1 ;;
        esac
        # The value becomes a directory name. Windows silently strips/collapses
        # a trailing dot from a path component, so reject it outright before
        # any further reserved-name check (a trailing dot is never valid here,
        # regardless of what precedes it).
        case "$1" in
            *.)
                printf 'safe_component: the value ends with a trailing dot, which Windows collapses/rejects; rejecting it\n' >&2
                exit 1 ;;
        esac
        # The Windows reserved device names are shape-valid above yet cannot
        # exist as a path component -- including with an extension, since
        # CON.txt/NUL.log/COM1.git all resolve to the same reserved device.
        # Same guard TASK_NAME gets at D5 (CPR-ORTH). Match the pre-extension
        # stem only (case-insensitive): 'console' and 'nul-fix' are fine.
        case "$(printf '%s' "$1" | tr 'A-Z' 'a-z')" in
            con|prn|aux|nul|com[1-9]|lpt[1-9]|con.*|prn.*|aux.*|nul.*|com[1-9].*|lpt[1-9].*)
                printf 'safe_component: the value is a Windows-reserved device name (with or without an extension); rejecting it\n' >&2
                exit 1 ;;
        esac
    )
}

# --- D3b: collision disambiguator -------------------------------------------
# Non-descriptive fallback slugs repeat across sessions; suffix them with a UTC
# timestamp. The session id is deliberately NOT used: it would correlate a
# local session with a public branch name. Second granularity is sufficient —
# worktree creation is never a tight loop.
# An empty result would yield a trailing-hyphen name that D5 accepts, so every
# call site must abort when the captured value is empty (`exit` inside the
# command substitution would only leave its subshell).
disambiguator() {
    printf '%s' "$(date -u +%Y%m%d%H%M%S)"
}

# --- D3c: word-boundary keyword match ---------------------------------------
# Unanchored substring globs false-positive: "prefix" contains "fix",
# "documentary" contains "docs", "choreography" contains "chore". Match only
# when the keyword is flanked by something other than [a-z0-9]. Bracket-class
# matching is locale-sensitive, so pin grep to C like slugify() and D5 do.
# A bare whole-word match is too strict for real titles ("Fixes the parser",
# "Bugs everywhere", "Refactoring the prompts"), so a bounded English
# inflection suffix is accepted between the keyword and the right boundary.
# The suffix list is closed on purpose: an open `[a-z]*` would restore exactly
# the false positives above.
# $1 = '|'-alternated lowercase keywords, $2 = already-lowercased text.
title_has_word() {
    printf '%s\n' "$2" | LC_ALL=C grep -qE "(^|[^a-z0-9])($1)(es|ed|ing|s)?([^a-z0-9]|\$)"
}

# --- D0: repo-name path component ------------------------------------------
# `<repo-name>` is the last component of the worktree path, so it needs the same
# codified validation TASK_NAME gets at D5 (CPR-ORTH) — and the caller must read
# it from here rather than infer it (CPR-SSOT). Prefer the git toplevel basename;
# --repo-dir may point at a non-repo directory, so fall back to its own basename.
# REPO_NAME is emitted on stdout, so it passes the same outbound scan as every
# other emitted value (CPR-ORTH) and fails closed on a scan failure — a value
# that failed the scan is never echoed raw, here or in the diagnostic.
# The fallback says why it fired (same pattern as D4): a silent switch of the
# naming source is invisible in the emitted name. Fixed literal — git's own
# error text may carry private info.
REPO_NAME="$(basename -- "$(git -C "$REPO_DIR" rev-parse --show-toplevel 2>/dev/null)" 2>/dev/null)"
if [ -z "$REPO_NAME" ]; then
    printf "derive-worktree-name: could not resolve a git toplevel for --repo-dir; falling back to the directory's own basename\n" >&2
    REPO_NAME="$(basename -- "$REPO_DIR" 2>/dev/null)"
fi
if ! safe_component "$REPO_NAME"; then
    printf 'derive-worktree-name: the repository directory name is unusable as a path component; refusing to emit it; the checkout directory name must start with [a-zA-Z0-9] and otherwise match [a-zA-Z0-9._-] with no other characters — rename the checkout directory or pass --repo-dir pointing at a differently-named copy\n' >&2
    exit 1
fi

# --- D0a: exclude this checkout's own remote identity from the private gate --
# Whenever the repo this worktree belongs to is itself private, its own name is
# necessarily in PRIVATE_REPO_NAMES_CACHE, so a scan_clean() call on that name
# self-matches and fails closed -- unconditionally, on every invocation, making
# /worktree-start permanently unusable in any private repo. That one name is
# not a leak: it is already known to everyone with access to this repo's own
# remote, and it is the one name that cannot leak *into* this repo.
# That premise is about the REMOTE identity, so the exclusion is keyed on it.
# REPO_NAME is only the local checkout directory's basename -- a user-chosen
# name that can collide with an unrelated private repo (a public repo cloned
# into, or --repo-dir pointed at, a directory named after a private one).
# Keying on it would silently disarm the gate for that name across the run.
# Remote parsing mirrors hooks/lib/is-private-repo.js extractRepoId(): the last
# `owner/repo` pair with an optional trailing `.git`. The `.git` suffix is
# stripped first because POSIX ERE has no lazy quantifier, so a greedy
# last-pair match cannot exclude it the way that regex's `[^/]+?` does.
# The bare repo segment is what the filter compares: the consumer
# (bin/check-private-repo-name.js findPrivateName()) matches on the last
# `/`-delimited segment, and cache lines arrive in both `repo` and `owner/repo`
# form, so normalizing the same way is what stops an owner-qualified
# self-entry from surviving and self-blocking anyway.
# Accepted residual: bare-name matching also drops a *different* owner's
# private repo that happens to share the bare name (filtering `myorg/repo`
# removes `otherorg/repo` from these scoped calls too). Inherent rather than
# fixable here -- the consumer only ever matches bare names, so an
# owner-qualified filter could not tighten what the gate actually enforces.
# No resolvable `origin` (a repo before its first push, a local-only repo, a
# --repo-dir that is not a repo at all) leaves the "already known to the
# remote's audience" premise unestablished, so the filter is skipped entirely
# and the cache stays whole -- fail closed. Tradeoff: the self-block described
# above can still occur, but only in that one case.
# Scope: the filtered list lives in its own variable, is never exported, and is
# never assigned over the script-level cache. It reaches the checker only by
# being passed as scan_clean()'s second argument, at the two call sites that
# check this repo's own name (D0 immediately below, and D2's repo-name
# fallback) — so it is scoped to those two calls without ever entering any
# process's environment.
# TITLE and TASK_NAME keep seeing the unfiltered list: task names are shared
# across repos (rules/worktree.md), so one derived here and later reused by
# hand in a different repo must still be caught there.
SELF_EXCLUDED_PRIVATE_NAMES="${PRIVATE_REPO_NAMES_CACHE:-}"
if [ "${PRIVATE_REPO_NAMES_CACHE_SET:-}" = "1" ] && [ -n "${PRIVATE_REPO_NAMES_CACHE:-}" ]; then
    SELF_REMOTE_URL="$(git -C "$REPO_DIR" remote get-url origin 2>/dev/null | tr -d '\r' | head -1)"
    SELF_REMOTE_NAME="$(
        export LC_ALL=C
        printf '%s\n' "${SELF_REMOTE_URL%.git}" \
            | sed -n -E 's#^.*[/:][^/]+/([^/]+)$#\1#p' \
            | tr 'A-Z' 'a-z'
    )"
    if [ -n "$SELF_REMOTE_NAME" ]; then
        # ENVIRON, not `awk -v repo=...`: -v assignment applies awk's own
        # backslash-escape processing to the value, and SELF_REMOTE_NAME is
        # derived from a git remote URL -- not fully trusted input (see the
        # "adversarial remote URLs" note above). ENVIRON values are not
        # subject to that processing. Exported only inside this subshell, so
        # it never leaks into the caller's environment (same one-shot scope
        # as LC_ALL=C below).
        FILTERED_PRIVATE_NAMES="$(
            export LC_ALL=C REPO_SELF_NAME="$SELF_REMOTE_NAME"
            printf '%s\n' "$PRIVATE_REPO_NAMES_CACHE" \
                | awk '{ line = tolower($0); n = split(line, parts, "/"); bare = parts[n]; if (bare != ENVIRON["REPO_SELF_NAME"]) print }'
        )"
        # A failed/partial awk run must not silently adopt truncated output --
        # this list gates whether the repo's own name passes the private-name
        # scan, and this file's invariant throughout is fail CLOSED on
        # uncertainty. On failure, SELF_EXCLUDED_PRIVATE_NAMES simply keeps
        # its unfiltered default from above (same fail-closed outcome as the
        # "no resolvable origin" branch already documented above).
        if [ $? -eq 0 ]; then
            SELF_EXCLUDED_PRIVATE_NAMES="$FILTERED_PRIVATE_NAMES"
        else
            printf 'derive-worktree-name: self-exclusion filter failed; falling back to the unfiltered private-name list (fail closed)\n' >&2
        fi
    fi
fi

# Passed as scan_clean()'s second argument, not as an environment override: the
# list is scoped to this one call by being an argument, so every other
# scan_clean() call still sees the full private-name list (see the Scope note in
# D0a) and no child process's environment ever carries either list.
if ! scan_clean "$REPO_NAME" "$SELF_EXCLUDED_PRIVATE_NAMES"; then
    printf 'derive-worktree-name: the repository directory name failed the outbound scan; refusing to emit it\n' >&2
    exit 1
fi

# --- D1: resolve intent.md --------------------------------------------------
INTENT=""
INTENT_PATH="$INTENT_ARG"
if [ -z "$INTENT_PATH" ]; then
    PLANS_DIR="$(bash "$AGENTS_CONFIG_DIR/bin/workflow-plans-dir" 2>/dev/null)" \
        || PLANS_DIR="${WORKFLOW_PLANS_DIR:-$HOME/.workflow-plans}"
    [ -n "$PLANS_DIR" ] || PLANS_DIR="${WORKFLOW_PLANS_DIR:-$HOME/.workflow-plans}"
    SID="$(bash "$AGENTS_CONFIG_DIR/bin/resolve-session-id" 2>/dev/null)" || SID=""
    if [ -n "$SID" ]; then
        INTENT_PATH="$PLANS_DIR/$SID-intent.md"
    fi
fi
if [ -n "$INTENT_PATH" ] && [ -r "$INTENT_PATH" ]; then
    INTENT="$INTENT_PATH"
fi

# --- D2: determine the naming source ----------------------------------------
TITLE=""
ISSUE=""
ISSUE_REPO=""
TASK_NAME=""

if [ -n "$INTENT" ]; then
    TITLE="$(sed -n 's/^\*\*Title:\*\*[[:space:]]*//p' -- "$INTENT" | head -1)"
    ISSUE_JSON="$(node "$AGENTS_CONFIG_DIR/bin/parse-closes-issues" "$INTENT" 2>/dev/null)" || ISSUE_JSON="[]"
    [ -n "$ISSUE_JSON" ] || ISSUE_JSON="[]"
    ISSUE="$(printf '%s' "$ISSUE_JSON" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{process.stdout.write(String(JSON.parse(s)[0]?.number??""))}catch(e){}})' 2>/dev/null)"
    case "$ISSUE" in
        ''|*[!0-9]*) ISSUE="" ;;
    esac
    ISSUE_REPO="$(printf '%s' "$ISSUE_JSON" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{process.stdout.write(String(JSON.parse(s)[0]?.repo??""))}catch(e){}})' 2>/dev/null)"

    if [ -n "$TITLE" ] && ! scan_clean "$TITLE"; then
        printf 'derive-worktree-name: intent title failed the outbound scan; using a non-descriptive name instead\n' >&2
        TITLE=""
    fi

    SLUG="$(slugify "$TITLE")"
    if [ -z "$SLUG" ]; then
        # REPO_NAME is already resolved and path-component-validated at D0.
        # As a fallback slug it also becomes a public branch name and can carry
        # private info (hostnames, client names), so it passes the same gate as
        # TITLE. A value that failed the scan is never echoed raw.
        # Same value, same self-excluded list passed the same way as D0
        # (CPR-ORTH) — this call checks this repo's own name, not third-party
        # text. It gates only whether the fallback slug may be *built*; the
        # composed TASK_NAME is still re-scanned at D6 with no second argument,
        # i.e. against the unfiltered cache, which is where a task name
        # embedding the repo's own name is caught.
        if scan_clean "$REPO_NAME" "$SELF_EXCLUDED_PRIVATE_NAMES"; then
            SLUG="$(slugify "$REPO_NAME")"
            printf "derive-worktree-name: title yielded no ASCII slug; falling back to repo name '%s'\n" "$REPO_NAME" >&2
        else
            printf 'derive-worktree-name: title yielded no ASCII slug and the repo name failed the outbound scan; using a non-descriptive name instead\n' >&2
            SLUG=""
        fi
        [ -n "$SLUG" ] || SLUG="worktree"
        # The repo name repeats across sessions; only an issue number makes it
        # unique, so add a per-session suffix when there is none.
        if [ -z "$ISSUE" ]; then
            DISAMBIG="$(disambiguator)"
            [ -n "$DISAMBIG" ] || { printf 'derive-worktree-name: failed to generate a timestamp disambiguator\n' >&2; exit 1; }
            SLUG="${SLUG}-${DISAMBIG}"
        fi
    fi

    if [ -n "$ISSUE" ]; then
        TASK_NAME="${ISSUE}-${SLUG}"
    else
        # NON_GITHUB: no issue reference — the one isolated naming exception.
        TASK_NAME="$SLUG"
    fi
elif [ -n "$HEADLESS_LABEL" ]; then
    TITLE="$HEADLESS_LABEL"
    ISSUE=""
    if scan_clean "$HEADLESS_LABEL"; then
        SLUG="$(slugify "$HEADLESS_LABEL")"
        [ -n "$SLUG" ] || SLUG="worktree"
    else
        printf 'derive-worktree-name: --headless label failed the outbound scan; using a non-descriptive name instead\n' >&2
        SLUG="worktree"
        TITLE=""
    fi
    DISAMBIG="$(disambiguator)"
    [ -n "$DISAMBIG" ] || { printf 'derive-worktree-name: failed to generate a timestamp disambiguator\n' >&2; exit 1; }
    TASK_NAME="${SLUG}-${DISAMBIG}"
else
    # The intent path is derived from the session id, so its basename is never
    # echoed: a raw session id must not leak into a diagnostic that can be
    # captured into logs or reports (same rule as disambiguator()).
    printf 'derive-worktree-name: no readable intent.md and no --headless <label>; cannot derive a task name\n' >&2
    exit 1
fi

# --- D4: branch-type inference ----------------------------------------------
BRANCH_TYPE=""

if [ -n "$ISSUE" ] && [ -z "$ISSUE_REPO" ] && command -v gh >/dev/null 2>&1; then
    bash "$AGENTS_CONFIG_DIR/bin/is-github-dotcom-remote" "$REPO_DIR" >/dev/null 2>&1
    REMOTE_RC=$?
    if [ "$REMOTE_RC" -eq 0 ]; then
        LABELS="$(cd "$REPO_DIR" && bash "$AGENTS_CONFIG_DIR/bin/run-with-timeout.sh" 20 gh issue view "$ISSUE" --json labels --jq '.labels[].name' 2>/dev/null)"
        GH_RC=$?
        # "the lookup failed" and "the issue carries no incident label" both fall
        # through to keyword inference; only the diagnostic tells them apart.
        # Fixed literal: gh's own output may carry private info.
        if [ "$GH_RC" -ne 0 ] || [ -z "$LABELS" ]; then
            printf 'derive-worktree-name: the gh issue label lookup failed or returned nothing; falling back to keyword-based branch-type inference\n' >&2
        fi
        if printf '%s\n' "$LABELS" | grep -qxF 'type:incident'; then
            BRANCH_TYPE="fix"
        fi
    fi
fi

if [ -z "$BRANCH_TYPE" ]; then
    TITLE_LC="$(printf '%s' "$TITLE" | LC_ALL=C tr 'A-Z' 'a-z')"
    # English-only keyword matching by design (CPR-UNV): non-English or
    # non-matching titles fall through to BRANCH_TYPE=feature. Full i18n is out
    # of scope — see issue #1925.
    # Closed compounds ("bugfix", "hotfix") are listed explicitly: neither the
    # left nor the right boundary falls between their two halves.
    if title_has_word 'bugfix|hotfix|fix|bug' "$TITLE_LC"; then
        BRANCH_TYPE="fix"
    elif title_has_word 'refactor' "$TITLE_LC"; then
        BRANCH_TYPE="refactor"
    elif title_has_word 'docs|documentation|document' "$TITLE_LC"; then
        BRANCH_TYPE="docs"
    elif title_has_word 'chore' "$TITLE_LC"; then
        BRANCH_TYPE="chore"
    else
        BRANCH_TYPE="feature"
    fi
fi

# --- D5: output validation --------------------------------------------------
# Bracket-class matching is locale-sensitive; pin it to C like slugify() does.
# A value that failed validation is never interpolated into the diagnostic:
# the same invariant D6 states ("never echo the blocked value") applies here,
# since the rejected text is derived from human-authored title material.
(
    export LC_ALL=C
    case "$TASK_NAME" in
        [a-zA-Z0-9]*) ;;
        *)
            printf 'derive-worktree-name: the derived task name does not start with [a-zA-Z0-9]; refusing to emit it\n' >&2
            exit 1 ;;
    esac
    case "$TASK_NAME" in
        *[!a-zA-Z0-9_-]*)
            printf 'derive-worktree-name: the derived task name contains characters outside [a-zA-Z0-9_-]; refusing to emit it\n' >&2
            exit 1 ;;
    esac
    # TASK_NAME becomes a directory name, and the Windows reserved device names
    # are shape-valid above yet cannot exist as a path component. Exact match
    # only (case-insensitive): 'console' and 'nul-fix' are perfectly fine.
    case "$(printf '%s' "$TASK_NAME" | tr 'A-Z' 'a-z')" in
        con|prn|aux|nul|com[1-9]|lpt[1-9])
            printf 'derive-worktree-name: the derived task name is a Windows-reserved device name; refusing to emit it\n' >&2
            exit 1 ;;
    esac
) || exit 1
case "$BRANCH_TYPE" in
    feature|fix|refactor|docs|chore) ;;
    *)
        # Unreachable: BRANCH_TYPE is only ever assigned from this closed set at
        # D4. Fixed literal for consistency with the TASK_NAME checks above,
        # which never interpolate a failed value either.
        printf 'derive-worktree-name: derived branch type is not one of feature|fix|refactor|docs|chore\n' >&2
        exit 1 ;;
esac

# --- D6: outbound-scan gate on the emitted name -----------------------------
# Slugification joins lowercased tokens with hyphens, so it can synthesize a
# blocklisted token that the raw source text never literally contained. Scan
# the final value too; on failure emit a safe non-descriptive name instead and
# never echo the blocked value.
if ! scan_clean "$TASK_NAME"; then
    printf 'derive-worktree-name: derived task name failed the outbound scan; using a non-descriptive name instead\n' >&2
    DISAMBIG="$(disambiguator)"
    [ -n "$DISAMBIG" ] || { printf 'derive-worktree-name: failed to generate a timestamp disambiguator\n' >&2; exit 1; }
    # Built only from digits, a literal, and a UTC timestamp — always D5-valid.
    TASK_NAME="${ISSUE:+${ISSUE}-}worktree-${DISAMBIG}"
    # Re-scan rather than assert: the rebuilt value still embeds $ISSUE. A
    # second failure should be unreachable (ISSUE is digit-validated at D2 and
    # DISAMBIG is a numeric UTC timestamp), so fail safe by dropping the issue
    # prefix entirely instead of adding another fallback tier.
    if ! scan_clean "$TASK_NAME"; then
        TASK_NAME="worktree-${DISAMBIG}"
        # Losing the issue prefix costs the caller its traceability, so say so.
        printf 'derive-worktree-name: the issue-prefixed fallback name also failed the outbound scan; dropping the issue prefix (task name no longer traceable to an issue)\n' >&2
        # This last tier is deliberately NOT scanned. It is built only from the
        # literal 'worktree-' and a numeric UTC timestamp, so it carries no
        # caller-, title-, or remote-derived text — there is nothing in it a
        # private-name or blocklist match could legitimately be about, and any
        # match here would necessarily be an over-match on the bare token
        # 'worktree' (or on the digits), not a real leak. The narrower invariant
        # that now governs this path is "a name is ALWAYS constructible", and it
        # outranks the older "every emitted name passed the scan": the only
        # outcome a scan can produce at this tier is refusing to emit any name at
        # all, which breaks unconditional auto-naming outright.
    fi
fi

printf 'TASK_NAME=%s\n' "$TASK_NAME"
printf 'BRANCH_TYPE=%s\n' "$BRANCH_TYPE"
printf 'REPO_NAME=%s\n' "$REPO_NAME"
