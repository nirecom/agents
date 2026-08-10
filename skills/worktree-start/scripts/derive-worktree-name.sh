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
# hand it down through the environment instead.
# PRIVATE_REPO_NAMES_CACHE_SET=1 means "the list is authoritative", so an empty
# PRIVATE_REPO_NAMES_CACHE means "confirmed no private repos" rather than
# "unknown" — the lister fails open to empty, matching the checker's own
# fail-open contract, so a lookup failure degrades to "clean" exactly as it
# already did per-call.
# Do NOT rename these two variables: they are also the env-var contract the
# test suite uses to insulate itself from live `gh` calls
# (tests/feature-worktree-start-non-interactive/helpers.sh). A caller that has
# already declared the list keeps it — populating it here unconditionally would
# re-introduce the very gh call that contract exists to avoid.
if [ "${PRIVATE_REPO_NAMES_CACHE_SET:-}" != "1" ]; then
    PRIVATE_REPO_NAMES_CACHE="$(node "$AGENTS_CONFIG_DIR/bin/list-private-repo-names.js" 2>/dev/null)"
    export PRIVATE_REPO_NAMES_CACHE
    export PRIVATE_REPO_NAMES_CACHE_SET=1
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
scan_clean() {
    printf '%s\n' "$1" | bash "$AGENTS_CONFIG_DIR/bin/scan-outbound.sh" --stdin worktree-name >/dev/null 2>&1 \
        && node "$AGENTS_CONFIG_DIR/bin/check-private-repo-name.js" "$1" >/dev/null 2>&1
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
        # The value becomes a directory name, and the Windows reserved device
        # names are shape-valid above yet cannot exist as a path component.
        # Same guard TASK_NAME gets at D5 (CPR-ORTH). Exact match only
        # (case-insensitive): 'console' and 'nul-fix' are perfectly fine.
        case "$(printf '%s' "$1" | tr 'A-Z' 'a-z')" in
            con|prn|aux|nul|com[1-9]|lpt[1-9])
                printf 'safe_component: the value is a Windows-reserved device name; rejecting it\n' >&2
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
REPO_NAME="$(basename "$(git -C "$REPO_DIR" rev-parse --show-toplevel 2>/dev/null)" 2>/dev/null)"
if [ -z "$REPO_NAME" ]; then
    printf "derive-worktree-name: could not resolve a git toplevel for --repo-dir; falling back to the directory's own basename\n" >&2
    REPO_NAME="$(basename "$REPO_DIR" 2>/dev/null)"
fi
if ! safe_component "$REPO_NAME"; then
    printf 'derive-worktree-name: the repository directory name is unusable as a path component; refusing to emit it; the checkout directory name must start with [a-zA-Z0-9] and otherwise match [a-zA-Z0-9._-] with no other characters — rename the checkout directory or pass --repo-dir pointing at a differently-named copy\n' >&2
    exit 1
fi
if ! scan_clean "$REPO_NAME"; then
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
        if scan_clean "$REPO_NAME"; then
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
        # Scanned like every other emitted value rather than asserted clean:
        # "every emitted name passed the scan" must hold on every path.
        if ! scan_clean "$TASK_NAME"; then
            printf 'derive-worktree-name: the non-descriptive fallback name failed the outbound scan; refusing to emit a name\n' >&2
            exit 1
        fi
    fi
fi

printf 'TASK_NAME=%s\n' "$TASK_NAME"
printf 'BRANCH_TYPE=%s\n' "$BRANCH_TYPE"
printf 'REPO_NAME=%s\n' "$REPO_NAME"
