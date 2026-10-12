#!/usr/bin/env bash
#
# bin/lib/sweep-numeric.sh
#
# SSOT for the numeric operand validation of the /sweep family scripts
# (SWEEP_AGE_DAYS, --min-age-hours, --timeout-seconds). A value that passes is
# safe for bash arithmetic: no leading zero (bash reads it as octal) and no
# product with <multiplier> that wraps 64-bit signed arithmetic.
#
# Source-only; not executable.

readonly SWEEP_NUMERIC_INT64_MAX=9223372036854775807

# sweep_validate_uint <name> <value> <min> <multiplier> <exit_code>
# Returns when <value> is accepted; otherwise prints one `ERROR: <name> ...` line
# on stderr and exits <exit_code>. A malformed min/multiplier/exit_code is the
# caller's bug and exits 2.
sweep_validate_uint() {
  local name="${1:-}" value="${2:-}" min="${3:-}" multiplier="${4:-}" code="${5:-}"
  if [[ ! "$min" =~ ^(0|[1-9][0-9]{0,17})$ ]] || [[ ! "$multiplier" =~ ^[1-9][0-9]{0,17}$ ]] \
     || [[ ! "$code" =~ ^(0|[1-9][0-9]{0,2})$ ]]; then
    printf 'ERROR: sweep_validate_uint: bad caller arguments (min=%s multiplier=%s exit_code=%s)\n' \
      "$min" "$multiplier" "$code" >&2
    exit 2
  fi
  if [[ ! "$value" =~ ^[0-9]+$ ]]; then
    printf 'ERROR: %s must be a non-negative integer (got: %s)\n' "$name" "$value" >&2
    exit "$code"
  fi
  if [[ "${#value}" -ge 2 && "$value" == 0* ]]; then
    printf 'ERROR: %s must not have a leading zero (bash reads it as octal) (got: %s)\n' "$name" "$value" >&2
    exit "$code"
  fi
  if [[ "${#value}" -ge 19 ]]; then
    printf 'ERROR: %s is too large (got: %s)\n' "$name" "$value" >&2
    exit "$code"
  fi
  if (( value < min )); then
    printf 'ERROR: %s must be at least %s (got: %s)\n' "$name" "$min" "$value" >&2
    exit "$code"
  fi
  local safe_max=$(( SWEEP_NUMERIC_INT64_MAX / multiplier ))
  if (( value > safe_max )); then
    printf 'ERROR: %s must be at most %s (got: %s)\n' "$name" "$safe_max" "$value" >&2
    exit "$code"
  fi
}
