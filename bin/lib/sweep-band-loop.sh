#!/usr/bin/env bash
#
# bin/lib/sweep-band-loop.sh — SSOT for band-index generation.
#
# Sourced by bin/sweep-issues.sh (and reusable by any sweep that pages a fixed
# total into fixed-size bands). Both functions share one validation contract:
# band_size is a positive integer, total_count a non-negative integer.
#
# Source-only: defines functions, runs nothing at load time.

# sweep_band_count <total_count> <band_size>
#   Prints ceil(total_count / band_size). total_count=0 prints 0.
sweep_band_count() {
  local total_count="${1-}" band_size="${2-}"
  if [[ ! "$band_size" =~ ^[1-9][0-9]*$ ]]; then
    printf 'ERROR: sweep_band_count: band_size must be a positive integer, got: %s\n' "$band_size" >&2
    return 2
  fi
  if [[ ! "$total_count" =~ ^(0|[1-9][0-9]*)$ ]]; then
    printf 'ERROR: sweep_band_count: total_count must be a non-negative integer, got: %s\n' "$total_count" >&2
    return 2
  fi
  printf '%s\n' "$(( (total_count + band_size - 1) / band_size ))"
}

# sweep_band_indices <total_count> <band_size>
#   Prints each 0-based band index (0..count-1), one per line. total_count=0
#   prints nothing.
sweep_band_indices() {
  local total_count="${1-}" band_size="${2-}"
  local count
  count="$(sweep_band_count "$total_count" "$band_size")" || return $?
  local i
  for (( i = 0; i < count; i++ )); do
    printf '%s\n' "$i"
  done
}
