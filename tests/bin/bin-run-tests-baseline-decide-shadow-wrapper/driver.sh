#!/usr/bin/env bash
# tests/bin/bin-run-tests-baseline-decide-shadow-wrapper/driver.sh
# Tests: bin/lib/run-tests-baseline-decide-shadow.sh
# Tags: run-tests, baseline, decide-shadow, helpers, scope:common, pwsh-not-required, TL2
# The child bash of ws_drive: bash driver.sh <wt-branch> <wt-base> <work-dir> <snippet>.
# Sources the exec lib (including the timeout lib) as the CLI does; the snippet loads the shadow lib through drv_install /
# drv_load_shadow. The snippet decides when to install, so before and after wrapping are compared in one process.
# Output is only `KEY ...` lines, read by the parent (cases.sh).

set -uo pipefail
DRV_ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck source=/dev/null
. "$DRV_ROOT_DIR/bin/lib/run-tests-baseline-exec.sh" || { echo "DRV_ERR cannot source the exec lib"; exit 98; }
DRV_SHADOW_LIB="$DRV_ROOT_DIR/bin/lib/run-tests-baseline-decide-shadow.sh"

WT_BRANCH="$1" WT_BASE="$2" WORK="$3"
DRV_REL="tests/bin/x.sh"

# drv_call <mode> <wt> <logdir> — calls rtb_exec_one once with stub launcher result <mode> and puts
# the return code, RTB_EXEC_* and RTB_EXEC_SEQ into DRV_SNAP on one line. The caller sets SEQ.
drv_call() {
  local rc=0
  WS_STUB_MODE="$1"
  rtb_exec_one "$2" "$DRV_REL" 20 "$3" || rc=$?
  DRV_SNAP="rc=$rc RC=${RTB_EXEC_RC} TO=${RTB_EXEC_TIMEDOUT} UNS=${RTB_EXEC_UNSUPPORTED} DEC=${RTB_EXEC_DECOY} ST=${RTB_EXEC_STATE} UNR=${RTB_EXEC_UNRUNNABLE} SEQ=${RTB_EXEC_SEQ}"
}

# drv_load_shadow — only sources the shadow lib and calls rtb_decide_shadow_install (the lib owns the kill switch check).
drv_load_shadow() {
  [ -f "$DRV_SHADOW_LIB" ] || { echo "DRV_INSTALL_ERR shadow lib absent: bin/lib/run-tests-baseline-decide-shadow.sh"; return 1; }
  # shellcheck source=/dev/null
  . "$DRV_SHADOW_LIB" || { echo "DRV_INSTALL_ERR shadow lib failed to source"; return 1; }
  declare -F rtb_decide_shadow_install >/dev/null 2>&1 || { echo "DRV_INSTALL_ERR rtb_decide_shadow_install undefined"; return 1; }
  rtb_decide_shadow_install || { echo "DRV_INSTALL_ERR rtb_decide_shadow_install returned non-zero"; return 1; }
}

# drv_install — the install with the kill switch on. Fails if rtb_exec_one_unwrapped is not defined.
drv_install() {
  drv_load_shadow || return 1
  declare -F rtb_exec_one_unwrapped >/dev/null 2>&1 || { echo "DRV_INSTALL_ERR rtb_exec_one_unwrapped undefined after install"; return 1; }
}

eval "$4"
