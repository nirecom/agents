"use strict";
// present.js <sid> <stage> — writes the presentation receipt (#2729) the Stop hook would write for
// the owner-resolved plan, computed with the same libraries and env as confirm-checkpoint.js, so
// a CONFIRM echo in feature-2631-confirm-size.js reaches the size check and the dialog. Prints
// "written" or "skipped:<why>"; never fails the caller.

const path = require("path");
const ROOT = path.resolve(__dirname, "..", "..", "..");
const PR = require(path.join(ROOT, "hooks", "lib", "presentation-receipt"));
const PL = require(path.join(ROOT, "hooks", "lib", "plan-link"));
const { computeContentSha } = require(path.join(ROOT, "hooks", "workflow-state", "completion-approval"));
const { getWorkflowPlansDir } = require(path.join(ROOT, "hooks", "lib", "workflow-plans-dir"));

const [sid, stage] = process.argv.slice(2);
const absPath = PR.approvalArtifactPath(sid, stage);
if (!absPath) { console.log("skipped:no-owner-path"); process.exit(0); }
let link = null;
try { link = PL.receiptLinkOf(PL.linkForFile(absPath, { plansDir: getWorkflowPlansDir() })); } catch (_) { link = null; }
const contentSha = computeContentSha(absPath);
if (!link || !contentSha) { console.log("skipped:no-link-or-file"); process.exit(0); }
console.log(PR.writeReceipt(sid, stage, { absPath, link, contentSha, anchorUuid: "fixture" }) ? "written" : "skipped:write");
