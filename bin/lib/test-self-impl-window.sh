# shellcheck shell=bash
# bin/lib/test-self-impl-window.sh — tsi_report: the one window onto the caseEmbedRules self-impl op.
# Source only, after bin/lib/test-language-registry.sh and tlr_load.
# tsi_report <file> [<match-path>] — prints the op's `line<TAB>kind<TAB>detail` rows for <file>.
# <match-path> (default <file>) picks the registry entry, so a temp copy reads as the original.
# rc 0 answered; 3 no entry matches or the entry has no caseEmbedRules; 69 the part's runtime is
# not installed; 70 the part cannot be reached; any other rc is the part's own failure.
# Op contract: docs/architecture/claude-code/test-language-registry/case-embed-ops.md.

tsi_report() {
  local file="${1:?tsi_report: file required}" match="${2:-${1}}"
  tlr_match "$match" || return 3
  _tlr_get "$TLR_ID" caseEmbedRules.file || return 3
  tlr_call_part "$TLR_ID" caseEmbedRules self-impl "$file"
}
