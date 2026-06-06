#!/bin/bash
# Surface the delivery plan from outline.md for make-detail-plan Step 2.
set -euo pipefail
cat <<'TEMPLATE'
Read outline.md Delivery plan section (or "Delivery plan:" field in Adopted approach).
- Present and substantive: emit one-paragraph summary prefixed "Delivery plan (from outline stage):".
- Absent or "(not provided)": emit "Delivery plan: (not surfaced from outline — detail-planner will draft fresh as the first section of detail.md)."
Plain text only — no AskUserQuestion, no pause. English terms only.
TEMPLATE
