# shellcheck shell=bash
# bin/lib/case-target-path-rule.sh — the case target path rule (#2712). Source only.
# ctp_target_path_valid <value> — rc 0 when <value> is a usable repo-relative target, rc 1 otherwise;
# no output. The rule's wording (SSOT, shared with the three reader children) is the
# "Case target path rule" section of docs/architecture/claude-code/test-language-registry.md.

_CTP_TOKEN_RE='^[A-Za-z0-9._/-]+$'

ctp_target_path_valid() {
  local v="$1"
  [[ "$v" =~ $_CTP_TOKEN_RE ]] || return 1
  [[ "$v" != /* && "$v" != ./* && "$v" != . ]] || return 1
  [[ "$v" != .. && "$v" != ../* && "$v" != */.. && "$v" != */../* ]] || return 1
  return 0
}
