#!/usr/bin/env bash
# Derive the worktree task name and branch type deterministically.
# Usage: derive-worktree-name.sh [--intent <path>] [--headless <label>] [--repo-dir <dir>]
# stdout: TASK_NAME=<name> / BRANCH_TYPE=<feature|fix|refactor|docs|chore> / REPO_NAME=<validated last path component>
# exit: 0 success / 1 no naming source or validation failure / 64 usage error
# set -e not used: fallback branches catch non-zero exits from optional helpers.
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

# --- private-repo-name cache (one gh round-trip per run) --------------------
# Resolved once; handed to scan_clean()'s consumer via stdin, never exported —
# the full private-repo-name list must not sit in every spawned process's env.
# PRIVATE_REPO_NAMES_CACHE_SET=1 means the list is authoritative (empty = "no
# private repos", not "unknown"); a lookup failure fails open to empty.
# Do NOT rename these two variables: tests/feature-worktree-start-non-interactive/helpers.sh
# still exports both INTO this script (inbound contract, unchanged). Never
# re-add `export` here for the outbound side — see hooks/lib/is-private-repo.js
# for why exporting only one of the pair is worse than exporting neither.
if [ "${PRIVATE_REPO_NAMES_CACHE_SET:-}" != "1" ]; then
    PRIVATE_REPO_NAMES_CACHE="$(node "$AGENTS_CONFIG_DIR/bin/list-private-repo-names.js" 2>/dev/null)"
    PRIVATE_REPO_NAMES_CACHE_SET=1
fi

[ -n "$REPO_DIR" ] || REPO_DIR="$(git rev-parse --show-toplevel 2>/dev/null)"
[ -n "$REPO_DIR" ] || REPO_DIR="$PWD"

# --- D3: slugify --------------------------------------------------------
# Lowercase -> non-[a-z0-9] runs to '-' -> first 5 tokens -> cap 40 chars.
# Runs in one LC_ALL=C subshell (locale-sensitive throughout).
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

# --- D3a: outbound-scan gate ---------------------------------------------
# Candidate text must pass the same private-info scan as any outbound
# content, plus the live private-repo-name list (same matching as
# hooks/scan-outbound.js's dynamic WARN, since branch names skip that scan
# on push). Exit 0 = clean; any non-zero fails closed.
#
# $1 = candidate. $2 = name list to check against (default: script-level
# cache). Use `${2-...}`, not `${2:-...}` — a caller-supplied empty list
# means "checked, nothing to match", and must not fall back to the cache.
scan_clean() {
    printf '%s\n' "$1" | bash "$AGENTS_CONFIG_DIR/bin/scan-outbound.sh" --stdin worktree-name >/dev/null 2>&1 || return 1
    printf '%s\n' "${2-${PRIVATE_REPO_NAMES_CACHE:-}}" | PRIVATE_REPO_NAMES_STDIN=1 node "$AGENTS_CONFIG_DIR/bin/check-private-repo-name.js" "$1" >/dev/null 2>&1
}

# --- D3a2: path-component guard ------------------------------------------
# Rejects separators/traversal and (CPR-ORTH with D5) a leading '.', '-', '_'.
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
        # Windows collapses/strips a trailing dot from a path component.
        case "$1" in
            *.)
                printf 'safe_component: the value ends with a trailing dot, which Windows collapses/rejects; rejecting it\n' >&2
                exit 1 ;;
        esac
        # Windows reserved device names, with or without an extension
        # (CON.txt/NUL.log/COM1.git all resolve to the reserved device).
        # Match the pre-extension stem only, case-insensitive.
        case "$(printf '%s' "$1" | tr 'A-Z' 'a-z')" in
            con|prn|aux|nul|com[1-9]|lpt[1-9]|con.*|prn.*|aux.*|nul.*|com[1-9].*|lpt[1-9].*)
                printf 'safe_component: the value is a Windows-reserved device name (with or without an extension); rejecting it\n' >&2
                exit 1 ;;
        esac
    )
}

# --- D3b: collision disambiguator ----------------------------------------
# UTC timestamp suffix for non-descriptive fallback slugs. Not the session
# id (would correlate a local session with a public branch name).
disambiguator() {
    printf '%s' "$(date -u +%Y%m%d%H%M%S)"
}

# --- D3c: word-boundary keyword match -------------------------------------
# Unanchored substring globs false-positive ("prefix" contains "fix"), so
# match only when flanked by non-[a-z0-9], with a closed set of inflection
# suffixes ("Fixes", "Refactoring") — an open `[a-z]*` would restore the
# false positives above.
# $1 = '|'-alternated lowercase keywords, $2 = already-lowercased text.
title_has_word() {
    printf '%s\n' "$2" | LC_ALL=C grep -qE "(^|[^a-z0-9])($1)(es|ed|ing|s)?([^a-z0-9]|\$)"
}

# --- D0: repo-name path component ----------------------------------------
# Last component of the worktree path; gets the same validation TASK_NAME
# gets at D5 (CPR-ORTH). Prefers the git toplevel basename; --repo-dir may
# point at a non-repo directory, so falls back to its own basename.
# Emitted on stdout, so it passes the same outbound scan as any other
# emitted value — a value that fails the scan is never echoed raw.
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
# When this repo is itself private, its own name is in PRIVATE_REPO_NAMES_CACHE,
# so scanning REPO_NAME against it would self-match and fail closed on every
# invocation. That one name is not a leak — everyone with access to this
# repo's own remote already knows it. Keyed on the REMOTE identity (parsed
# like hooks/lib/is-private-repo.js extractRepoId()), not REPO_NAME, since
# the local checkout directory name is user-chosen and can collide with an
# unrelated private repo. No resolvable origin -> filter skipped, fail closed
# (the "already known to the remote's audience" premise doesn't hold).
# Bare-name matching (matches the consumer's own matching) also drops a
# different owner's private repo sharing the same bare name — accepted,
# inherent residual.
# Scope: filtered list lives in its own variable, never exported, never
# assigned over the script-level cache — passed only as scan_clean()'s
# second argument at the two callsites checking this repo's own name (D0,
# D2's repo-name fallback). TITLE/TASK_NAME keep seeing the unfiltered list
# (task names are shared across repos — rules/worktree.md).
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
        # ENVIRON, not `awk -v repo=...`: -v applies awk's backslash-escape
        # processing to untrusted remote-URL-derived input; ENVIRON does not.
        # Exported only inside this subshell.
        FILTERED_PRIVATE_NAMES="$(
            export LC_ALL=C REPO_SELF_NAME="$SELF_REMOTE_NAME"
            printf '%s\n' "$PRIVATE_REPO_NAMES_CACHE" \
                | awk '{ line = tolower($0); n = split(line, parts, "/"); bare = parts[n]; if (bare != ENVIRON["REPO_SELF_NAME"]) print }'
        )"
        # Fail closed on a failed/partial awk run: keep the unfiltered default.
        if [ $? -eq 0 ]; then
            SELF_EXCLUDED_PRIVATE_NAMES="$FILTERED_PRIVATE_NAMES"
        else
            printf 'derive-worktree-name: self-exclusion filter failed; falling back to the unfiltered private-name list (fail closed)\n' >&2
        fi
    fi
fi

# Passed as scan_clean()'s second argument (call-scoped) — see the Scope
# note in D0a.
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
        # REPO_NAME (validated at D0) as fallback slug also becomes a public
        # branch name, so it passes the same gate as TITLE (same self-excluded
        # list as D0, CPR-ORTH). TASK_NAME is still re-scanned unfiltered at D6.
        if scan_clean "$REPO_NAME" "$SELF_EXCLUDED_PRIVATE_NAMES"; then
            SLUG="$(slugify "$REPO_NAME")"
            printf "derive-worktree-name: title yielded no ASCII slug; falling back to repo name '%s'\n" "$REPO_NAME" >&2
        else
            printf 'derive-worktree-name: title yielded no ASCII slug and the repo name failed the outbound scan; using a non-descriptive name instead\n' >&2
            SLUG=""
        fi
        [ -n "$SLUG" ] || SLUG="worktree"
        # Repo name repeats across sessions; add a disambiguator when there's no issue number.
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
    # Intent path derives from the session id — never echo it (session id must not leak into a diagnostic).
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
        # Lookup failure and "no incident label" both fall through to keyword
        # inference; only the diagnostic tells them apart. Fixed literal:
        # gh's own output may carry private info.
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
    # English-only by design (CPR-UNV); non-matching titles fall through to
    # "feature". Full i18n out of scope — see issue #1925.
    # Closed compounds ("bugfix", "hotfix") listed explicitly.
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
# Bracket-class matching is locale-sensitive; pin to C like slugify(). A
# value that fails validation is never interpolated into the diagnostic.
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
    # TASK_NAME becomes a directory name — Windows reserved device names are
    # shape-valid above but cannot exist as a path component. Exact match
    # only, case-insensitive ('console', 'nul-fix' are fine).
    case "$(printf '%s' "$TASK_NAME" | tr 'A-Z' 'a-z')" in
        con|prn|aux|nul|com[1-9]|lpt[1-9])
            printf 'derive-worktree-name: the derived task name is a Windows-reserved device name; refusing to emit it\n' >&2
            exit 1 ;;
    esac
) || exit 1
case "$BRANCH_TYPE" in
    feature|fix|refactor|docs|chore) ;;
    *)
        # Unreachable: BRANCH_TYPE is only ever assigned from this closed set at D4.
        printf 'derive-worktree-name: derived branch type is not one of feature|fix|refactor|docs|chore\n' >&2
        exit 1 ;;
esac

# --- D6: outbound-scan gate on the emitted name -----------------------------
# Slugification can synthesize a blocklisted token the raw source text
# never literally contained, so the final value is scanned too. On failure,
# emit a safe non-descriptive name instead and never echo the blocked value.
if ! scan_clean "$TASK_NAME"; then
    printf 'derive-worktree-name: derived task name failed the outbound scan; using a non-descriptive name instead\n' >&2
    DISAMBIG="$(disambiguator)"
    [ -n "$DISAMBIG" ] || { printf 'derive-worktree-name: failed to generate a timestamp disambiguator\n' >&2; exit 1; }
    # Built only from a literal, an optional digit-validated issue number,
    # and a numeric UTC timestamp — always D5-valid.
    TASK_NAME="${ISSUE:+${ISSUE}-}worktree-${DISAMBIG}"
    if ! scan_clean "$TASK_NAME"; then
        TASK_NAME="worktree-${DISAMBIG}"
        printf 'derive-worktree-name: the issue-prefixed fallback name also failed the outbound scan; dropping the issue prefix (task name no longer traceable to an issue)\n' >&2
        # This last tier is deliberately NOT scanned: it carries no caller-,
        # title-, or remote-derived text, so a match here would necessarily
        # be an over-match on the literal 'worktree' or the digits, never a
        # real leak. "A name is ALWAYS constructible" outranks "every
        # emitted name passed the scan" at this one tier — the only outcome
        # a scan could produce here is refusing to emit any name at all.
    fi
fi

printf 'TASK_NAME=%s\n' "$TASK_NAME"
printf 'BRANCH_TYPE=%s\n' "$BRANCH_TYPE"
printf 'REPO_NAME=%s\n' "$REPO_NAME"
