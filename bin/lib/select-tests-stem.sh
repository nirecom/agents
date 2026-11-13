#!/usr/bin/env bash
# bin/lib/select-tests-stem.sh — the select-tests stem rules (changed source path -> test-name stems).
# Sourced library; shared by bin/select-tests.sh and the sweep-tests --embed-cases churn order.
# Every arm yields the last name part of the path (#2757): SKILL.md -> its dir name, else the
# basename without its last extension; skills/*/scripts/* also yields its area first.
# sts_stems_of_path <path>    fills STS_STEMS (reset each call; skill names — the area and the
#                             SKILL.md dir — are kept at any length, other stems need 3+ chars).
# sts_name_key <test-path>    prints the test's matching key: its basename without the extension.
# sts_name_key_into <path>    the same key into STS_KEY, without a subshell.
# sts_name_matches <key> <stem>  exit 0 when <key> contains <stem> as a literal substring.

STS_STEMS=()
STS_KEY=""

sts_stems_of_path() {
  local sts_path="$1" sts_stem="" sts_area
  STS_STEMS=()
  [[ -z "$sts_path" ]] && return 0
  case "$sts_path" in
    skills/*/SKILL.md)
      sts_stem="${sts_path%/SKILL.md}"
      STS_STEMS+=("${sts_stem##*/}")
      return 0
      ;;
    skills/*/scripts/*)
      sts_area="${sts_path#skills/}"
      sts_area="${sts_area%%/*}"
      STS_STEMS+=("$sts_area")
      sts_name_key_into "$sts_path"
      sts_stem="$STS_KEY"
      ;;
    agents/*.md | hooks/*.js | bin/*)
      sts_name_key_into "$sts_path"
      sts_stem="$STS_KEY"
      ;;
    *)
      return 0
      ;;
  esac
  [[ ${#sts_stem} -lt 3 ]] && return 0
  STS_STEMS+=("$sts_stem")
  return 0
}

sts_name_key_into() {
  STS_KEY="${1##*/}"
  STS_KEY="${STS_KEY%.*}"
}

sts_name_key() {
  sts_name_key_into "$1"
  printf '%s' "$STS_KEY"
}

sts_name_matches() {
  [[ "$1" == *"$2"* ]]
}
