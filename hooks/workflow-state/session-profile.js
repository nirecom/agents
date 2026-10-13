"use strict";
// Session profile (#2527): the three facts the step table is read against —
// deliverable type, project-management type and delivery path — each tagged with
// where it came from. A recorded state field always wins over the live config,
// so a config flip mid-session never changes which steps the session owes. The
// one override is the WORKFLOW_OFF marker, which forces pmType "off".
//
// sources.<fact>: "recorded" (state field) | "provisional" (default or live
// config, not yet fixed) | "marker" (session marker).

const { DELIVERABLE_TYPES, DEFAULT_DELIVERABLE_TYPE } = require("./step-table");

const SUPPORTED_PM_TYPES = Object.freeze(["waterfall"]);
const DEFAULT_PM_TYPE = "waterfall";

function resolveDeliverableType(state) {
  const v = state.deliverable_type;
  if (DELIVERABLE_TYPES.includes(v)) return { value: v, source: "recorded" };
  return { value: DEFAULT_DELIVERABLE_TYPE, source: "provisional" };
}

function resolvePmType(state, sid) {
  const { isWorkflowOff } = require("../lib/session-markers");
  if (isWorkflowOff(sid)) return { value: "off", source: "marker" };
  const v = state.project_management_type;
  if (SUPPORTED_PM_TYPES.includes(v)) return { value: v, source: "recorded" };
  if (v !== undefined && v !== null) {
    process.stderr.write(
      "session-profile: unsupported project_management_type " + JSON.stringify(v) +
      " — treated as " + DEFAULT_PM_TYPE + "\n"
    );
  }
  return { value: DEFAULT_PM_TYPE, source: "provisional" };
}

function resolveDeliveryPath(state, sid, repoDir) {
  const { DELIVERY_PATHS, resolveLiveDeliveryPath } = require("../lib/delivery-path");
  const v = state.delivery_path;
  if (DELIVERY_PATHS.includes(v)) return { value: v, source: "recorded" };
  return { value: resolveLiveDeliveryPath(sid, repoDir), source: "provisional" };
}

// AUTO_MERGE_PR (4-2) has its own source vocabulary: "recorded" | "recorded-fallback"
// (pinned while the config was unreadable) | "provisional" (live, readable) |
// "unreadable" (live, unreadable — reads as "on").
function resolveAutoMergePr(state, repoDir) {
  const v = state.auto_merge_pr;
  if (v === "on" || v === "off") {
    return { value: v, source: state.auto_merge_pr_source === "fallback" ? "recorded-fallback" : "recorded" };
  }
  const live = require("../lib/auto-merge-config").readAutoMergePr({ repoDir });
  return { value: live.value, source: live.readable ? "provisional" : "unreadable" };
}

// resolveSessionProfile(state, sid, { repoDir }) -> profile. Never throws: a
// missing state reads as "nothing recorded yet".
function resolveSessionProfile(state, sid, opts) {
  const s = state && typeof state === "object" ? state : {};
  const repoDir = (opts && opts.repoDir) || process.cwd();
  const d = resolveDeliverableType(s);
  const pm = resolvePmType(s, sid);
  const path = resolveDeliveryPath(s, sid, repoDir);
  const amp = resolveAutoMergePr(s, repoDir);
  return {
    deliverableType: d.value,
    pmType: pm.value,
    deliveryPath: path.value,
    autoMergePr: amp.value,
    sources: {
      deliverableType: d.source, pmType: pm.source, deliveryPath: path.source, autoMergePr: amp.source,
    },
  };
}

// The release-approval channel: the user merges on the web only for a PR delivery with
// AUTO_MERGE_PR off that is not a bootstrap push (a bootstrap push has no PR to merge).
// Every other combination is the user-verified dialog.
function releaseApprovalChannelOf(state, profile) {
  const s = state && typeof state === "object" ? state : {};
  const push = s.steps && s.steps.push_branch;
  const bootstrap = !!(push && push.decision === "bootstrap");
  if (profile && profile.deliveryPath === "pull_request" && profile.autoMergePr === "off" && !bootstrap) {
    return "web-merge";
  }
  return "user-verified-dialog";
}

module.exports = { resolveSessionProfile, releaseApprovalChannelOf, SUPPORTED_PM_TYPES, DEFAULT_PM_TYPE };
