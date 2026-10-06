#!/usr/bin/env bash
# bin/lib/select-tests-stem.sh — the select-tests stem rules (changed source path -> test-name stems).
# Sourced library; shared by bin/select-tests.sh and the sweep-tests --embed-cases churn order.
# sts_stems_of_path <path>    fills STS_STEMS (reset each call; skills-area stem first, kept at any length).
# sts_name_matches <base> <stem>  exit 0 when <base> contains <stem> as a literal substring.

STS_STEMS=()

sts_stems_of_path() {
  local sts_path="$1" sts_stem="" sts_area sts_file
  STS_STEMS=()
  [[ -z "$sts_path" ]] && return 0
  case "$sts_path" in
    skills/*/SKILL.md)
      sts_stem="${sts_path#skills/}"
      sts_stem="${sts_stem%/SKILL.md}"
      ;;
    skills/*/scripts/*)
      sts_area="${sts_path#skills/}"
      sts_area="${sts_area%%/*}"
      sts_file="${sts_path##*/}"
      sts_stem="${sts_file%.*}"
      STS_STEMS+=("$sts_area")
      ;;
    agents/*.md)
      sts_stem="${sts_path#agents/}"
      sts_stem="${sts_stem%.md}"
      ;;
    hooks/*.js)
      sts_stem="${sts_path#hooks/}"
      sts_stem="${sts_stem%.*}"
      ;;
    bin/*)
      sts_stem="${sts_path#bin/}"
      sts_stem="${sts_stem%.*}"
      sts_stem="${sts_stem##*/}"
      ;;
    *)
      return 0
      ;;
  esac
  [[ ${#sts_stem} -lt 3 ]] && return 0
  STS_STEMS+=("$sts_stem")
  return 0
}

sts_name_matches() {
  [[ "$1" == *"$2"* ]]
}
