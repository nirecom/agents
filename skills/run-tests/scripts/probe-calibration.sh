#!/usr/bin/env bash
# probe-calibration.sh --cwd <dir> --session <sid>
# Decides whether /run-tests offers calibration (RNT-6a). Read-only: it reads line 1 of
# <cwd>/bin/test-lanes-status.sh and the session marker, and prints seven lines:
# decision= (ask|notice|none) reason= notice= source= max_jobs= os_match= estimate=.
# On ask only, estimate= is the calibrator's --dry-run cost in whole minutes (empty when
# the dry-run is unavailable); none and notice never launch it.
# Exit: 0 always after a valid call; 2 usage error.

set -uo pipefail

# shellcheck source-path=SCRIPTDIR source=lib/calibration-offer.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/calibration-offer.sh"
co_parse_args 1 "$@"

emit() {
    printf 'decision=%s\nreason=%s\nnotice=%s\nsource=%s\nmax_jobs=%s\nos_match=%s\nestimate=%s\n' \
        "$1" "$2" "$3" "$4" "$5" "$6" "${7:-}"
    exit 0
}

# dry_run_minutes — the first `plan: estimate_total_s=<n>` line of a --dry-run from <cwd>,
# rounded up to whole minutes; empty on any failure. Its stdout is data, never evaluated.
# Bounded (30s) so a stalled dry-run cannot hold the offer; with no bound available, no estimate.
dry_run_minutes() {
    local out rc l s="" bound=()
    [ -f "$CO_CWD/bin/calibrate-test-parallelism.sh" ] || return 0
    if [ -f "$CO_CWD/bin/run-with-timeout.sh" ]; then bound=(bash bin/run-with-timeout.sh 30)
    elif command -v timeout >/dev/null 2>&1; then bound=(timeout 30)
    else return 0
    fi
    out="$(cd "$CO_CWD" 2>/dev/null && "${bound[@]}" bash bin/calibrate-test-parallelism.sh --dry-run 2>/dev/null)"
    rc=$?
    [ "$rc" -eq 0 ] || return 0
    while IFS= read -r l || [ -n "$l" ]; do
        l="${l%$'\r'}"
        if [[ $l =~ ^plan:\ estimate_total_s=([0-9]{1,9})$ ]]; then s="${BASH_REMATCH[1]}"; break; fi
    done <<< "$out"
    [ -n "$s" ] || return 0
    printf '%s' "$(( (10#$s + 59) / 60 ))"
}

status_tool="$CO_CWD/bin/test-lanes-status.sh"
[ -f "$status_tool" ] || emit none no-lanes-status "" unknown "" na

status_out="$(cd "$CO_CWD" 2>/dev/null && bash "$status_tool" 2>/dev/null)"
status_rc=$?
[ "$status_rc" -eq 0 ] || emit none status-unavailable "" unknown "" na

line="${status_out%%$'\n'*}"
line="${line%$'\r'}"

max_jobs=""
source="unknown"
record=""
have_record=0
measured_on=""
now=""
mode=""
recalibrate=""
set -f
# shellcheck disable=SC2206  # word splitting with globbing off is the tokenizer
tokens=($line)
set +f
for tok in ${tokens[@]+"${tokens[@]}"}; do
    case "$tok" in
        max_jobs_per_host=*)
            v="${tok#max_jobs_per_host=}"
            [[ "$v" =~ ^[0-9]{1,4}$ ]] && max_jobs="$v" ;;
        source=*)
            v="${tok#source=}"
            case "$v" in env|dotenv|measured|default) source="$v" ;; esac ;;
        record=*) record="${tok#record=}"; have_record=1 ;;
        measured_on=*) measured_on="${tok#measured_on=}" ;;
        now=*) now="${tok#now=}" ;;
        mode=*) mode="${tok#mode=}" ;;
        recalibrate=*) recalibrate="${tok#recalibrate=}" ;;
    esac
done

os_match="na"
# AUTO_CONFIG_TEST_MAX_JOBS=off: the measured record is not used, so nothing is offered.
[ "$mode" = "off" ] && emit none auto-config-off "" "$source" "$max_jobs" "$os_match"
case "$source" in
    env|dotenv) emit none pinned "" "$source" "$max_jobs" "$os_match" ;;
    unknown) emit none status-unrecognized "" "$source" "$max_jobs" "$os_match" ;;
    measured)
        if [ -n "$measured_on" ]; then
            os_match="no"
            reason="measured on $measured_on, now $now"
            notice_lead="this host's measured max jobs per host (${max_jobs:-unknown}) is stale for the current OS"
        elif [ -n "$recalibrate" ]; then
            os_match="yes"
            reason="recalibrate $recalibrate"
            notice_lead="this host's measured max jobs per host (${max_jobs:-unknown}) should be measured again"
        else
            emit none calibrated "" "$source" "$max_jobs" yes
        fi
        notice_reason="$reason" ;;
    default)
        [ "$have_record" -eq 1 ] && [ -n "$record" ] || record="missing"
        reason="$record"
        notice_reason="record $record"
        notice_lead="this host runs tests at the default max jobs per host" ;;
esac

# A relative RUN_ALL_CACHE_DIR resolves against <cwd>, as it does for the status tool and run-all.
cd "$CO_CWD" 2>/dev/null || emit none status-unavailable "" unknown "" na
co_source_parallelism_lib || emit none offer-lib-unavailable "" "$source" "$max_jobs" "$os_match"

notice="$(co_notice "$notice_lead" "$notice_reason")"
marker="$(co_marker_path "$CO_SID")" || emit notice "$reason" "$notice" "$source" "$max_jobs" "$os_match"
[ -f "$marker" ] && emit notice "$reason" "$notice" "$source" "$max_jobs" "$os_match"
emit ask "$reason" "$notice" "$source" "$max_jobs" "$os_match" "$(dry_run_minutes)"
