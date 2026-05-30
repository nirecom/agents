#!/bin/bash
set -euo pipefail
: "${AGENTS_CONFIG_DIR:?AGENTS_CONFIG_DIR not set}"
: "${SESSION_ID:?SESSION_ID not set}"
: "${PLANS_DIR:?PLANS_DIR not set}"

exec "$AGENTS_CONFIG_DIR/skills/_shared/assemble-mandatory.sh" --source-kind outline \
  "$PLANS_DIR/$SESSION_ID-outline.md" \
  "$PLANS_DIR/drafts/$SESSION_ID-detail-draft.md" \
  "$PLANS_DIR/$SESSION_ID-detail.md"
