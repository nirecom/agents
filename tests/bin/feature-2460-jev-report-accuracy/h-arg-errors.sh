#!/usr/bin/env bash
# Tests: bin/jev-report
# Tags: TL2, bin, jev, report, cli-args, usage-error, table-driven, scope:issue-specific, pwsh-not-required
# Fragment of tests/bin/feature-2460-jev-report-accuracy.sh, sourced by it after _lib.sh (not
# standalone): an unknown option or a value-taking option without its value exits 2 with the
# error and usage on stderr and prints no report on stdout.

echo "=== argument errors: exit 2, error + usage on stderr, empty stdout ==="
ARG_OUT="$FX/io/arg-error.out"
case_begin "r-arg-errors-exit-2-usage" "bin/jev-report"
while IFS='|' read -r name args bad; do
  [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
  name="${name//[[:space:]]/}"
  bad="${bad//[[:space:]]/}"
  read -ra ARGV_CASE <<< "$args"
  report "$ARG_OUT" "${ARGV_CASE[@]}"
  ERR_TXT="$(tr -d '\r' < "$FX/io/report.err" 2>/dev/null)"
  HAS_ERR=no; HAS_USAGE=no
  [[ "$ERR_TXT" == *"jev-report: unknown or incomplete argument: $bad"* ]] && HAS_ERR=yes
  [[ "$ERR_TXT" == *"usage: jev-report [--log <path>] [--point <name>] [--json] [--no-sweep]"* ]] && HAS_USAGE=yes
  check "$name: exit 2, error names $bad, usage on stderr, stdout empty" "2|yes|yes|0" \
    "$REP_RC|$HAS_ERR|$HAS_USAGE|$(wc -c < "$ARG_OUT" | tr -d ' ')"
done <<'TABLE'
unknown-option           | --bogus                | --bogus
unknown-short-option     | -x                     | -x
log-missing-value        | --log                  | --log
point-missing-value      | --point                | --point
point-missing-after-json | --json --point         | --point
log-missing-after-point  | --point complexity-judge --log | --log
TABLE
case_end
