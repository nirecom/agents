#!/usr/bin/env bash
# answer-calibration.sh <calibrate|defer|never-ask> --cwd <dir> --session <sid>
# Applies the user's RNT-6a answer. Every verb first appends answer=<verb> to the session
# marker; never-ask then writes this host's never-ask record, and calibrate runs
# <cwd>/bin/calibrate-test-parallelism.sh from <cwd> with RUN_CALIBRATION=1 and no arguments.
# Exit: 0 done; 1 a write failed; 2 usage error; 3 no calibrator under --cwd;
# otherwise the calibrator's own exit code.

set -uo pipefail

# shellcheck source-path=SCRIPTDIR source=lib/calibration-offer.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/calibration-offer.sh"

[ "$#" -ge 1 ] || co_usage_error "usage: answer-calibration.sh <calibrate|defer|never-ask> --cwd <dir> --session <sid>"
verb="$1"
shift
case "$verb" in
    calibrate|defer|never-ask) ;;
    *) co_usage_error "unknown verb: $verb (want calibrate, defer or never-ask)" ;;
esac
co_parse_args 1 "$@"

if ! co_marker_write "$CO_SID" "answer=$verb"; then
    printf '%s\n' "answer-calibration: cannot write the session marker (invalid session id or unwritable control dir)" >&2
    exit 1
fi

case "$verb" in
    defer) exit 0 ;;
    never-ask)
        # A relative RUN_ALL_CACHE_DIR resolves against --cwd, where run-all reads the record.
        if ! cd "$CO_CWD" 2>/dev/null || ! co_source_parallelism_lib || ! run_all_never_ask_write; then
            printf '%s\n' "answer-calibration: cannot write the never-ask record" >&2
            exit 1
        fi
        exit 0 ;;
esac

calibrator="$CO_CWD/bin/calibrate-test-parallelism.sh"
if [ ! -f "$calibrator" ]; then
    printf '%s\n' "answer-calibration: no bin/calibrate-test-parallelism.sh under --cwd" >&2
    exit 3
fi
export RUN_CALIBRATION=1
cd "$CO_CWD" || exit 3
bash "bin/calibrate-test-parallelism.sh"
exit $?
