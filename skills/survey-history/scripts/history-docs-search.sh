#!/usr/bin/env bash
# History docs search procedure for survey-history (SH-4b).
set -euo pipefail
cat <<'TEMPLATE'
History docs entries since issue opened (follow progressive disclosure per skills/_shared/file-investigation.md):
      - Grep `docs/history.md` for date strings ≥ openedAt (format `YYYY-MM-DD`).
        Read the surrounding context (±5 lines) for each match.
      - If `docs/history/index.md` exists, grep it for the same date range to find archived
        entries. For each matching archive file listed in the index, read the relevant
        section of that file (e.g. `docs/history/2025-*.md`) to retrieve the full entry.
TEMPLATE
