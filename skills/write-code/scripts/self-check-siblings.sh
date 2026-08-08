#!/usr/bin/env bash
# CPR-E2C ("Elevate to the Class") sibling-sweep self-check for write-code.
# Prints a checklist-style reminder: identify the symmetric class the just-made
# change belongs to, enumerate its siblings, and flag any left untreated.
# This is a process/prompt-support template, not a static analyzer.
#
# Usage: self-check-siblings.sh "<what changed>" ["<why it changed>"]
set -euo pipefail

CHANGE_DESC="${1:-<what changed — fill in>}"
CHANGE_REASON="${2:-<why it changed — fill in>}"

cat <<EOF
## CPR-E2C Sibling Sweep Self-Check

Change: $CHANGE_DESC
Reason: $CHANGE_REASON

1. Identify the class — what is the root/abstract parent this change belongs
   to? (e.g. "one skill among several sharing a call convention", "one CLI
   among a family with a shared contract")
2. Enumerate every symmetric sibling of the changed member.
3. For each sibling, confirm whether it received the same treatment:
   - [ ] Sibling: <name> — updated? yes / no / n-a (state the reason if n-a)
   - [ ] Sibling: <name> — updated? yes / no / n-a (state the reason if n-a)
4. Flag any sibling left behind — do not silently skip it. If a sibling is
   intentionally excluded, name the exception and its boundary explicitly
   (CPR-UNV) rather than letting it pass unmentioned.

Reference: rules/core-principles.md — CPR-E2C (Elevate to the Class) and
CPR-ORTH (Orthogonality).
EOF
