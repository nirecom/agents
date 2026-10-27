#!/usr/bin/env bash
# bin/lib/concern-ledger/defang-fences.sh — the one owner of prompt-fence defanging (sourced, not executed).
# Untrusted text (a diff, prior concerns, a plan, context) must not forge the DIFF,
# PRIOR CONCERNS, PLAN or CONTEXT START/END fences. A forgery that differs only in case, inner
# whitespace, underscore or full-width brackets would still read as a fence to a model, so
# every such variant becomes "(<words>)" — no bracket left, hence a second pass is a no-op.
# Sourced by bin/review-code-codex, bin/review-plan-codex and bin/lib/concern-ledger/core.sh (CPR-SSOT).

# The full-width brackets U+FF3B / U+FF3D, built from bytes so this file stays ASCII.
_DF_FW_OPEN="$(printf '\357\274\273')"
_DF_FW_CLOSE="$(printf '\357\274\275')"

# One sed -E substitution; callers that run their own sed loop splice it in with -e.
# Case-insensitive by explicit classes, not the GNU-only I flag (CPR-UNV).
DEFANG_FENCE_SED_EXPR="s/(\\[|${_DF_FW_OPEN})[[:space:]]*([Dd][Ii][Ff][Ff]|[Pp][Rr][Ii][Oo][Rr][[:space:]_]+[Cc][Oo][Nn][Cc][Ee][Rr][Nn][Ss]|[Pp][Ll][Aa][Nn]|[Cc][Oo][Nn][Tt][Ee][Xx][Tt])([[:space:]_]+)([Ss][Tt][Aa][Rr][Tt]|[Ee][Nn][Dd])[[:space:]]*(\\]|${_DF_FW_CLOSE})/(\\2\\3\\4)/g"

# defang_fences — stdin -> stdout.
defang_fences() {
    sed -E -e "$DEFANG_FENCE_SED_EXPR"
}
