#!/usr/bin/env bash
# ensure-board-card.sh <N>
# Idempotent: ensures issue #N has a Projects v2 board card with Content Date.
# Standalone: derives its own paths via BASH_SOURCE (no AGENTS_CONFIG_DIR dependency).
# Best-effort: warns and exits 0 on non-fatal gh failures.
# Exit codes: 0 success/non-fatal warn; 2 usage error.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/board-card.sh
. "$SCRIPT_DIR/lib/board-card.sh"
# shellcheck source=lib/resolve-project.sh
. "$SCRIPT_DIR/lib/resolve-project.sh"

usage() {
    cat >&2 <<'EOF'
Usage: ensure-board-card.sh <N>
  <N>: positive integer issue number.
Idempotent: when the issue already has a board card with Content Date set,
re-running is a no-op. Best-effort — warns and exits 0 on gh failures.
EOF
    exit 2
}

N="${1:-}"
[[ -z "$N" ]] && usage
[[ "$N" =~ ^[0-9]+$ ]] || usage

# Soft gh auth project-scope warn (mirror issue-create.sh).
if command -v gh >/dev/null 2>&1; then
    if ! gh auth status 2>&1 | grep -q "'project'"; then
        echo "warn: gh auth lacks 'project' scope — Projects v2 attach may fail." >&2
        echo "warn: Run 'gh auth refresh -s project' to add it (browser-based OAuth)." >&2
    fi
else
    echo "warn: gh CLI not found — ensure-board-card.sh skipping (exit 0)" >&2
    exit 0
fi

# Auto-resolve Projects v2 config from the git remote (#641). Internal env
# vars from the issue-create.sh call chain short-circuit GraphQL via the
# resolver's _ISSUE_CREATE_INTERNAL_* check. Resolver failure is non-fatal —
# warn and exit 0 (the caller's downstream work continues without a board
# card).
if ! resolve_project_for_repo; then
    echo "warn: ensure-board-card: Projects v2 auto-resolve failed for #$N — skipping (exit 0)" >&2
    exit 0
fi
OWNER="$RESOLVED_OWNER"
PROJECT_NUM="$RESOLVED_PROJECT_NUM"
PROJECT_ID="$RESOLVED_PROJECT_ID"
FIELD_ID="$RESOLVED_CONTENT_DATE_FIELD_ID"

# resolve_item_id reads $PROJECT_ID from caller scope — set above before use.

# 1. Resolve URL.
if ! URL=$(gh issue view "$N" --json url --jq '.url' 2>/dev/null); then
    echo "warn: gh issue view #$N failed — skipping (exit 0)" >&2
    exit 0
fi
URL=$(printf '%s' "$URL" | tr -d '\r' | head -1)
if [[ -z "$URL" ]]; then
    echo "warn: gh issue view returned empty URL for #$N — skipping (exit 0)" >&2
    exit 0
fi

# 2. Resolve existing item id.
item_id=$(resolve_item_id "$N") || item_id=""

# 3. If absent, add to project. Retry resolve_item_id on failure for concurrent-add race.
if [[ -z "$item_id" ]]; then
    if new_id=$(gh project item-add "$PROJECT_NUM" --owner "$OWNER" --url "$URL" \
            --format json --jq '.id' 2>/dev/null); then
        new_id=$(printf '%s' "$new_id" | tr -d '\r' | head -1)
        if [[ -n "$new_id" ]]; then
            item_id="$new_id"
        else
            # item-add succeeded but returned empty id — re-resolve.
            item_id=$(resolve_item_id "$N") || item_id=""
        fi
    else
        # item-add failed — retry resolve in case of concurrent-add race.
        item_id=$(resolve_item_id "$N") || item_id=""
    fi
    if [[ -z "$item_id" ]]; then
        echo "warn: ensure-board-card: item-add and refetch both empty for #$N — skipping (exit 0)" >&2
        exit 0
    fi
fi

# 4. Content Date — only attempt when the resolver found a Content Date field
#    in this project. Some projects intentionally lack the field; that is not
#    an error.
if [[ -n "$FIELD_ID" ]]; then
    if ! CREATED_DATE=$(gh issue view "$N" --json createdAt --jq '.createdAt[:10]' 2>/dev/null); then
        echo "warn: ensure-board-card: gh issue view createdAt failed for #$N — Content Date not set (exit 0)" >&2
        exit 0
    fi
    CREATED_DATE=$(printf '%s' "$CREATED_DATE" | tr -d '\r' | head -1)
    if [[ -z "$CREATED_DATE" ]]; then
        echo "warn: ensure-board-card: empty createdAt for #$N — Content Date not set (exit 0)" >&2
        exit 0
    fi

    # 5. Set Content Date.
    if ! gh project item-edit --id "$item_id" --field-id "$FIELD_ID" \
            --project-id "$PROJECT_ID" --date "$CREATED_DATE" >/dev/null 2>&1; then
        echo "warn: ensure-board-card: Content Date set failed for #$N (exit 0)" >&2
        exit 0
    fi
fi

exit 0
