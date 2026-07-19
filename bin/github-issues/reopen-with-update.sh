#!/bin/bash
# reopen-with-update.sh <ISSUE_NUMBER>
#
# Idempotent 3-point reopen flow for /issue-create reopen verdict:
#   1. gh issue reopen (fatal if fails)
#   2. body banner refresh  (WARN+continue on fail)
#   3. reopen-log comment PATCH or create  (WARN+continue on fail)
#   4. status:regressed label  (WARN+continue on fail)

set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "Error: usage: reopen-with-update.sh <ISSUE_NUMBER>" >&2
    exit 2
fi

ISSUE_NUMBER="$1"

# M3: anchored digits-only guard — FIRST EXECUTABLE STATEMENT
if ! printf '%s' "$ISSUE_NUMBER" | grep -qE '^[0-9]+$'; then
    echo "Error: ISSUE_NUMBER must be digits only (got: ${ISSUE_NUMBER})" >&2
    exit 2
fi

if ! command -v gh >/dev/null 2>&1; then
    echo "Error: gh CLI not found" >&2
    exit 1
fi

# M4: temp file setup (early, before any operation)
BODY_TMPFILE="$(mktemp)"
chmod 600 "$BODY_TMPFILE"
trap 'rm -f "$BODY_TMPFILE"' EXIT

# M2: Determine and validate REPO_SLUG
REPO_SLUG="$(MSYS_NO_PATHCONV=1 gh repo view --json nameWithOwner --jq .nameWithOwner | tr -d '\r')"
if ! printf '%s' "$REPO_SLUG" | grep -qE '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$'; then
    echo "Error: could not determine valid REPO_SLUG (got: '${REPO_SLUG}')" >&2
    exit 1
fi

# H1: session hash — never write raw CLAUDE_SESSION_ID to issue body
if command -v sha256sum >/dev/null 2>&1; then
    SESSION_HASH=$(printf '%s' "${CLAUDE_SESSION_ID:-unknown}" | sha256sum | cut -c1-8)
else
    SESSION_HASH=$(printf '%s' "${CLAUDE_SESSION_ID:-unknown}" | shasum -a 256 | cut -c1-8)
fi
# fallback if still empty (e.g., both commands absent)
SESSION_HASH="${SESSION_HASH:-unknown}"

# Step 1 — gh issue reopen (fatal)
if ! MSYS_NO_PATHCONV=1 gh issue reopen "$ISSUE_NUMBER" >/dev/null; then
    echo "Error: gh issue reopen ${ISSUE_NUMBER} failed" >&2
    exit 1
fi

# Step 2 — body banner refresh (WARN+continue on fail)

# Fetch current body
BODY="$(gh issue view "$ISSUE_NUMBER" --json body --jq .body 2>/dev/null)" || BODY=""

# Count existing banners for reopen count
REOPEN_COUNT=$(printf '%s' "$BODY" | grep -c '<!-- BEGIN reopen-banner -->' || true)
REOPEN_COUNT=$(( REOPEN_COUNT + 1 ))

# UTC datetime
DATETIME="$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null)" || DATETIME="unknown"

# Build banner block content
BANNER_CONTENT="**Reopened** (count: ${REOPEN_COUNT}) — ${DATETIME} — session: ${SESSION_HASH}"
BANNER_BLOCK="<!-- BEGIN reopen-banner -->
${BANNER_CONTENT}
<!-- END reopen-banner -->"

# M1: use perl with replacement text in env var — body passed via stdin, never interpolated into program
REPL="$BANNER_BLOCK"
export REPL

if printf '%s' "$BODY" | grep -q '<!-- BEGIN reopen-banner -->'; then
    # Replace existing banner block
    NEW_BODY=$(printf '%s' "$BODY" | perl -0pe 's/<!-- BEGIN reopen-banner -->.*?<!-- END reopen-banner -->/$ENV{REPL}/s')
else
    # Insert banner at top
    NEW_BODY="${BANNER_BLOCK}

${BODY}"
fi

unset REPL

# M4: write to temp file and update
printf '%s' "$NEW_BODY" > "$BODY_TMPFILE"
if ! ISSUE_CLOSE_SKILL=1 gh issue edit "$ISSUE_NUMBER" --body-file "$BODY_TMPFILE" >/dev/null 2>&1; then
    echo "WARN: body banner update failed for #${ISSUE_NUMBER}" >&2
fi

# Step 3 — reopen-log comment PATCH or create (WARN+continue on fail)

# Find existing reopen-log comment ID via REST API
# Use --jq '.' to match the mock arm pattern (requires space+arg after /comments);
# parse the returned JSON array with python3 so the ID is extracted reliably whether
# the caller is real gh (jq identity pass-through) or the test mock (raw JSON array).
COMMENTS_JSON="$(MSYS_NO_PATHCONV=1 gh api "repos/${REPO_SLUG}/issues/${ISSUE_NUMBER}/comments" --jq '.' 2>/dev/null)" || COMMENTS_JSON="[]"
# Parse with node (python3 is a Windows Store stub on this host and unavailable)
COMMENT_ID="$(printf '%s\n' "$COMMENTS_JSON" | node -e \
    "var d='';process.stdin.on('data',function(c){d+=c;});process.stdin.on('end',function(){try{var cs=JSON.parse(d);var c=cs.find(function(x){return x.body&&x.body.indexOf('<!-- reopen-log -->')>=0;});process.stdout.write(c?String(c.id):'');}catch(e){}});" 2>/dev/null)" \
    || COMMENT_ID=""

# M2: validate COMMENT_ID is digits-only before PATCH path
if [ -n "$COMMENT_ID" ] && ! printf '%s' "$COMMENT_ID" | grep -qE '^[0-9]+$'; then
    echo "WARN: invalid COMMENT_ID '${COMMENT_ID}' — will create new comment" >&2
    COMMENT_ID=""
fi

LOG_ENTRY="- (count ${REOPEN_COUNT}) ${DATETIME} — session: ${SESSION_HASH}"

if [ -n "$COMMENT_ID" ]; then
    # Fetch existing comment body and append log entry
    OLD_COMMENT="$(MSYS_NO_PATHCONV=1 gh api "repos/${REPO_SLUG}/issues/comments/${COMMENT_ID}" \
        --jq .body 2>/dev/null)" || OLD_COMMENT="<!-- reopen-log -->
### Reopen Log"
    NEW_COMMENT="${OLD_COMMENT}
${LOG_ENTRY}"
    if ! MSYS_NO_PATHCONV=1 gh api -X PATCH \
            "repos/${REPO_SLUG}/issues/comments/${COMMENT_ID}" \
            -f "body=${NEW_COMMENT}" >/dev/null 2>&1; then
        echo "WARN: reopen-log comment PATCH failed for #${ISSUE_NUMBER}" >&2
    fi
else
    # Create new reopen-log comment
    NEW_COMMENT="<!-- reopen-log -->
### Reopen Log
${LOG_ENTRY}"
    if ! gh issue comment "$ISSUE_NUMBER" --body "$NEW_COMMENT" >/dev/null 2>&1; then
        echo "WARN: reopen-log comment creation failed for #${ISSUE_NUMBER}" >&2
    fi
fi

# Step 4 — status:regressed label (WARN+continue on fail)
if ! gh issue edit "$ISSUE_NUMBER" --add-label "status:regressed" >/dev/null 2>&1; then
    echo "WARN: status:regressed label add failed for #${ISSUE_NUMBER} (label may not exist yet — run sync-labels.sh)" >&2
fi
