"use strict";
// DELIVERY_PATH_MISMATCH advisory line for next-step's verdict (#2527 3-10).
// Navigation follows the RECORDED delivery path, but the hooks enforce the LIVE
// one (ENFORCE_WORKTREE / repo exclusion / OFF markers). When the two disagree
// the model must learn it before running a release skill, so the verdict carries
// one line naming both values and the recovery. Absent when they agree, or when
// no path is recorded yet (the provisional value IS the live one).

const { resolveLiveDeliveryPath } = require("../../../../hooks/lib/delivery-path");

const RECOVERY = "WORKFLOW_RESET_FROM_branching_complete";

function deliveryPathNoteLine(profile, sid, repoDir) {
  try {
    if (!profile || !profile.sources || profile.sources.deliveryPath !== "recorded") return "";
    const recorded = profile.deliveryPath;
    const live = resolveLiveDeliveryPath(sid, repoDir);
    if (!recorded || !live || recorded === live) return "";
    return "DELIVERY_PATH_MISMATCH=recorded:" + recorded + " live:" + live +
      " hooks-enforce:live recover:" + RECOVERY;
  } catch (_) {
    return "";  // advisory only: a read failure never blocks the verdict
  }
}

module.exports = { deliveryPathNoteLine };
