#!/usr/bin/env bash
# Create a task issue with the enforced type:task label and attach to Projects v2.
# Scope: task issues for the current repo only.
# Incidents and cross-project issues: use gh issue create directly.
#
# Usage:
#   issue-create.sh --title "<title>" (--body "<body>" | --body-file <path>)
#                   [--label <label>] [--assignee <user>] [--milestone <name>]
#
# Stdout: created issue URL (one line).
# Stderr: progress and warnings.

# -e is safe here: all gh invocations use `if !` blocks, which are exempt from errexit.
set -euo pipefail

TITLE=""
BODY=""
BODY_FILE=""
BODY_PROVIDED=0
EXTRA_LABELS=()
ASSIGNEE=""
MILESTONE=""
REPORTER_MODEL=""

while [ $# -gt 0 ]; do
    case "$1" in
        --title)      TITLE="${2:?--title requires value}"; shift 2 ;;
        --body)       [ $# -lt 2 ] && { echo "--body requires value" >&2; exit 2; }; BODY="$2"; BODY_PROVIDED=1; shift 2 ;;
        --body-file)  BODY_FILE="${2:?--body-file requires value}"; shift 2 ;;
        --label)
            val="${2:?--label requires value}"
            val_lower=$(printf '%s' "$val" | tr '[:upper:]' '[:lower:]')
            case "$val_lower" in
                type:*)
                    echo "Error: --label $val is not allowed; this skill enforces type:task." >&2
                    echo "For incident issues use: gh issue create --label \"type:incident\" directly." >&2
                    exit 2 ;;
            esac
            EXTRA_LABELS+=("$val"); shift 2 ;;
        --assignee)   ASSIGNEE="${2:?--assignee requires value}"; shift 2 ;;
        --milestone)  MILESTONE="${2:?--milestone requires value}"; shift 2 ;;
        --reporter-model) REPORTER_MODEL="${2:?--reporter-model requires value}"; shift 2 ;;
        -h|--help)
            sed -n '2,12p' "$0" >&2; exit 0 ;;
        *)
            echo "Error: unknown argument: $1" >&2; exit 2 ;;
    esac
done

if ! command -v gh >/dev/null 2>&1; then
    echo "Error: gh CLI not found" >&2; exit 1
fi

# Soft preflight: warn if `project` scope is absent. Non-fatal so issue creation
# still proceeds; only the Projects v2 attach step will fail (also non-fatal).
if ! gh auth status 2>&1 | grep -q "'project'"; then
    echo "warn: gh auth lacks 'project' scope — Projects v2 attach will fail." >&2
    echo "warn: Run 'gh auth refresh -s project' to add it (browser-based OAuth)." >&2
fi

# Phase 0a — label auto-repair (non-interactive). Only when AGENTS_CONFIG_DIR is
# set AND the remote is GitHub. Missing config or non-GitHub remote → warn+skip
# (backward compatible). Independent of the skill-layer Phase 0b project check.
if [ -n "${AGENTS_CONFIG_DIR:-}" ]; then
    _ic_is_github=1
    if command -v is-github-dotcom-remote >/dev/null 2>&1; then
        is-github-dotcom-remote >/dev/null 2>&1 || _ic_is_github=0
    elif [ -x "$AGENTS_CONFIG_DIR/bin/is-github-dotcom-remote" ]; then
        bash "$AGENTS_CONFIG_DIR/bin/is-github-dotcom-remote" >/dev/null 2>&1 || _ic_is_github=0
    fi
    if [ "$_ic_is_github" -eq 1 ]; then
        _ic_preflight_rc=0
        bash "$AGENTS_CONFIG_DIR/bin/github-issues/issue-create-preflight.sh" --check-labels \
            ${REPO_OVERRIDE:+--repo "$REPO_OVERRIDE"} || _ic_preflight_rc=$?
        if [ "$_ic_preflight_rc" -eq 1 ]; then
            # type:task absent → auto-sync labels before creating the issue.
            if ! bash "$AGENTS_CONFIG_DIR/bin/github-issues/sync-labels.sh" \
                    ${REPO_OVERRIDE:+--repo "$REPO_OVERRIDE"} \
                    "$AGENTS_CONFIG_DIR/.github/labels.yml"; then
                echo "Error: label sync failed — aborting issue creation" >&2
                exit 1
            fi
            echo "note: labels synced (type:task was missing)" >&2
        elif [ "$_ic_preflight_rc" -ge 2 ]; then
            # Preflight HARD failure (gh error) — fail closed, do NOT sync.
            echo "Error: label preflight hard-failed (rc=$_ic_preflight_rc) — aborting" >&2
            exit 1
        fi
        # rc=0 → type:task present; nothing to repair.
    else
        echo "warn: Phase 0a skipping label auto-repair (non-GitHub remote)" >&2
    fi
else
    echo "warn: AGENTS_CONFIG_DIR unset — Phase 0a skipping label auto-repair" >&2
fi

if [ -z "$TITLE" ]; then
    echo "Error: --title required" >&2; exit 2
fi
if [ "$BODY_PROVIDED" -eq 0 ] && [ -z "$BODY_FILE" ]; then
    echo "Error: --body or --body-file required" >&2; exit 2
fi
if [ "$BODY_PROVIDED" -eq 1 ] && [ -n "$BODY_FILE" ]; then
    echo "Error: --body and --body-file are mutually exclusive" >&2; exit 2
fi
if [ -n "$BODY_FILE" ] && [ ! -f "$BODY_FILE" ]; then
    echo "Error: --body-file not found: $BODY_FILE" >&2; exit 1
fi

# Schema validation (#443): canonical Background + Changes required at creation.
# ISSUE_CREATE_SKIP_SCHEMA=1 is an emergency escape hatch — sanctioned path is
# to add the missing fields. (type:* labels are rejected by the --label arg
# parser above; when type:incident becomes routable, swap the field list to
# "Cause" "Fix".)
if [ "${ISSUE_CREATE_SKIP_SCHEMA:-0}" != "1" ]; then
    # SSOT: shape regex lives in extract-field.sh — source rather than duplicate.
    # shellcheck source=lib/extract-field.sh
    . "$(dirname "$0")/lib/extract-field.sh"
    if [ -n "${BODY_FILE:-}" ]; then
        SCHEMA_BODY=$(cat "$BODY_FILE")
    else
        SCHEMA_BODY="${BODY:-}"
    fi
    MISSING=()
    for F in Background Changes; do
        [ -z "$(BODY="$SCHEMA_BODY" extract_field "$F")" ] && MISSING+=("$F")
    done
    if [ ${#MISSING[@]} -gt 0 ]; then
        # Loop join — "${arr[*]}" with IFS=', ' uses only the first char (bug).
        S=""; for F in "${MISSING[@]}"; do S="${S:+$S, }$F"; done
        echo "Error: missing canonical fields: $S" >&2
        echo "Hint: ISSUE_CREATE_SKIP_SCHEMA=1 bypasses (emergency only)." >&2
        exit 3
    fi
fi

# Map raw model name to reporter-model:* label.
# SSOT: case RHS labels must match .github/labels.yml reporter-model:* entries.
# Drift prevention: tests/fix-1579-reporter-model-keyword-scan.sh T15 verifies this.
# -w word-boundary: plural/gerund forms (hangs/hanging) intentionally not matched.
if [ -n "$REPORTER_MODEL" ]; then
    _rm_label=""
    case "$REPORTER_MODEL" in
        *fable*)    _rm_label="reporter-model:fable" ;;
        *opus*)     _rm_label="reporter-model:opus" ;;
        *sonnet*)   _rm_label="reporter-model:sonnet" ;;
        *ds4*|*deepseek*) _rm_label="reporter-model:ds4" ;;
        *devstral*) _rm_label="reporter-model:devstral" ;;
        *qwen*)     _rm_label="reporter-model:qwen-coder" ;;
    esac
    [ -n "$_rm_label" ] && EXTRA_LABELS+=("$_rm_label")
fi

# Keyword scan: force severity:high on confirmed-high signals.
# Conservative: 4 words only; no -i flag; -w word-boundary (plural/gerund intentionally excluded).
if [ -n "$TITLE" ]; then
    _scan_text="$TITLE"
    if [ -n "$BODY_FILE" ]; then
        _scan_text="$_scan_text $(cat "$BODY_FILE")"
    elif [ -n "$BODY" ]; then
        _scan_text="$_scan_text $BODY"
    fi
    if printf '%s' "$_scan_text" | grep -qwE 'abort|hang|security|leak'; then
        _new_labels=()
        for _l in "${EXTRA_LABELS[@]:-}"; do
            case "$_l" in severity:*) ;; *) _new_labels+=("$_l") ;; esac
        done
        _new_labels+=("severity:high")
        EXTRA_LABELS=("${_new_labels[@]}")
        echo "note: keyword scan matched — severity:high forced" >&2
    fi
fi

GH_ARGS=(issue create --title "$TITLE" --label "type:task")
if [ "$BODY_PROVIDED" -eq 1 ]; then
    GH_ARGS+=(--body "$BODY")
else
    GH_ARGS+=(--body-file "$BODY_FILE")
fi
for L in "${EXTRA_LABELS[@]:-}"; do
    [ -z "$L" ] && continue
    GH_ARGS+=(--label "$L")
done
[ -n "$ASSIGNEE" ]  && GH_ARGS+=(--assignee  "$ASSIGNEE")
[ -n "$MILESTONE" ] && GH_ARGS+=(--milestone "$MILESTONE")

# Auto-resolve Projects v2 config from git remote (#641). Lazy: runs only after
# schema validation passes so --help / arg-error paths skip the network call.
# Resolver failure is non-fatal — issue creation proceeds, Projects v2 attach is
# skipped with a warning when the resolver returns 1.
# shellcheck source=lib/resolve-project.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/resolve-project.sh"
RESOLVER_OK=0
if resolve_project_for_repo; then
    RESOLVER_OK=1
fi

echo "[issue-create] gh issue create --title '$TITLE' [body omitted]" >&2
if ! URL=$(MSYS_NO_PATHCONV=1 ISSUE_CREATE_SKILL=1 gh "${GH_ARGS[@]}"); then
    echo "Error: gh issue create failed" >&2; exit 1
fi
if [ -z "$URL" ]; then
    echo "Error: gh issue create returned no URL" >&2; exit 1
fi

# Normalize: gh prints the URL on the last line; strip Windows CR if present.
URL=$(printf '%s' "$URL" | tail -n 1 | tr -d '\r')
if ! printf '%s' "$URL" | grep -qE '^https://github\.com/.+/issues/[0-9]+$'; then
    echo "Error: unexpected output from gh issue create: $URL" >&2
    exit 1
fi

ISSUE_NUM=$(printf '%s' "$URL" | grep -oE '[0-9]+$')
# Pass resolved Projects v2 config to ensure-board-card.sh via the
# _ISSUE_CREATE_INTERNAL_* env vars (resolver short-circuit). Skip the call
# entirely when the resolver failed — no defaults exist any more, so
# attempting attach without resolved IDs would just error.
if [ "$RESOLVER_OK" -eq 1 ]; then
    if ! _ISSUE_CREATE_INTERNAL_OWNER="$RESOLVED_OWNER" \
         _ISSUE_CREATE_INTERNAL_PROJECT_NUM="$RESOLVED_PROJECT_NUM" \
         _ISSUE_CREATE_INTERNAL_PROJECT_ID="$RESOLVED_PROJECT_ID" \
         _ISSUE_CREATE_INTERNAL_FIELD_ID="$RESOLVED_CONTENT_DATE_FIELD_ID" \
         bash "$(cd "$(dirname "$0")" && pwd)/ensure-board-card.sh" "$ISSUE_NUM"; then
        echo "warn: ensure-board-card.sh failed for #$ISSUE_NUM (continuing)" >&2
    fi
else
    echo "warn: Projects v2 auto-resolve failed — skipping board-card attach for #$ISSUE_NUM" >&2
fi

printf '%s\n' "$URL"
