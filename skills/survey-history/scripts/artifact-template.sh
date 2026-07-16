#!/usr/bin/env bash
# Output format template for survey-history artifact (SH-6).
set -euo pipefail
cat <<'TEMPLATE'
## Survey history — changes since issue #<N> opened (<openedAt>)

## Verified Claims
- claim: <text from intent.md Background/Scope>
  verdict: holds | contradicted | indeterminate
  evidence: <commit hash / PR# / history entry, or "no matching history found">

## Candidate class members
- <member name>: <one-line description> (from: <commit-ref or history entry>)
  proposed triage: <MUST | OPTIONAL | NA> — <one-line rationale>

## Premise impact assessment
<one paragraph: describe contradictions found, or state "No premise contradictions detected.">
TEMPLATE
