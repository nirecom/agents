#!/usr/bin/env bash
# probe-calibration.sh --cwd <dir> --session <sid>
# Decides whether /run-tests offers calibration (RNT-6a). Read-only: it reads line 1 of
# <cwd>/bin/test-lanes-status.sh, the never-ask record and the session marker, and prints
# six lines: decision= (ask|notice|none) reason= notice= source= max_jobs= os_match=.
# Exit: 0 always after a valid call; 2 usage error.

set -uo pipefail

# shellcheck source-path=SCRIPTDIR source=lib/calibration-offer.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/calibration-offer.sh"
co_parse_args 1 "$@"

emit() {
    printf 'decision=%s\nreason=%s\nnotice=%s\nsource=%s\nmax_jobs=%s\nos_match=%s\n' "$@"
    exit 0
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
    esac
done

os_match="na"
case "$source" in
    env|dotenv) emit none pinned "" "$source" "$max_jobs" "$os_match" ;;
    unknown) emit none status-unrecognized "" "$source" "$max_jobs" "$os_match" ;;
    measured)
        if [ -z "$measured_on" ]; then
            emit none calibrated "" "$source" "$max_jobs" yes
        fi
        os_match="no"
        reason="measured on $measured_on, now $now"
        notice_reason="$reason"
        notice_lead="this host's measured max jobs per host (${max_jobs:-unknown}) is stale for the current OS" ;;
    default)
        [ "$have_record" -eq 1 ] && [ -n "$record" ] || record="missing"
        reason="$record"
        notice_reason="record $record"
        notice_lead="this host runs tests at the default max jobs per host" ;;
esac

# A relative RUN_ALL_CACHE_DIR resolves against <cwd>, as it does for the status tool and run-all.
cd "$CO_CWD" 2>/dev/null || emit none status-unavailable "" unknown "" na
co_source_parallelism_lib || emit none offer-lib-unavailable "" "$source" "$max_jobs" "$os_match"
run_all_never_ask_active && emit none never-ask "" "$source" "$max_jobs" "$os_match"

notice="$(co_notice "$notice_lead" "$notice_reason")"
marker="$(co_marker_path "$CO_SID")" || emit notice "$reason" "$notice" "$source" "$max_jobs" "$os_match"
[ -f "$marker" ] && emit notice "$reason" "$notice" "$source" "$max_jobs" "$os_match"
emit ask "$reason" "$notice" "$source" "$max_jobs" "$os_match"
