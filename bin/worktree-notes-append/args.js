"use strict";

// Argument parsing, validation and mode resolution for
// bin/worktree-notes-append.js (split out per rules/coding/file-split.md).
// Mode is discriminated by --issue-number: present = Mode A (existing-issue
// promotion, section from --label); absent = Mode B (finding authoring,
// section from --section, --severity mandatory for BugsFound only).

const { parseArgs } = require("util");

// Input allowlist. Not shared with triage.js's or notes.js's section lists —
// this one adds ManualReminders since it needs a CLI edit path too, even
// though a reminder is never promoted to an issue.
const MODE_B_SECTIONS = ["BugsFound", "RelatedTasks", "NextTasks", "ManualReminders"];
const SEVERITY_VALUES = ["high", "low", "none"];

function err(msg) {
  process.stderr.write(`[worktree-notes-append] ${msg}\n`);
}

function parseCliArgs(argv) {
  try {
    const { values } = parseArgs({
      args: argv,
      options: {
        "notes-path": { type: "string" },
        "issue-number": { type: "string" },
        title: { type: "string" },
        label: { type: "string", multiple: true },
        section: { type: "string" },
        severity: { type: "string" },
        "skip-if-main": { type: "boolean" },
      },
      strict: true,
      allowPositionals: false,
    });
    return values;
  } catch (e) {
    err(`argument parse failed: ${e.message}`);
    return null;
  }
}

// Titles may never carry marker syntax: a forged or broken `<!-- ... -->`
// boundary would corrupt every downstream severity/promotion verdict.
function validateTitle(title) {
  if (typeof title !== "string" || title.length === 0) {
    err("missing --title");
    return false;
  }
  if (
    title.includes("<!--") ||
    title.includes("-->") ||
    title.includes("\n") ||
    title.includes("\r")
  ) {
    err("invalid title");
    return false;
  }
  return true;
}

// Returns { mode, notesPath, section, title, issueNumber, severity, skipIfMain }
// or null after emitting the reason on stderr (caller exits 2).
function resolveArgs(argv) {
  const args = parseCliArgs(argv);
  if (!args) return null;

  const notesPath = args["notes-path"];
  const issueNumberRaw = args["issue-number"];
  const sectionRaw = args.section;
  const severityRaw = args.severity;
  const labels = Array.isArray(args.label) ? args.label : [];
  const skipIfMain = Boolean(args["skip-if-main"]);
  const title = args.title;

  if (!notesPath) {
    err("missing --notes-path");
    return null;
  }
  if (!validateTitle(title)) return null;

  const modeA = issueNumberRaw !== undefined;

  if (modeA) {
    if (severityRaw !== undefined || sectionRaw !== undefined) {
      err("mode conflict: --severity/--section belong to the finding-authoring mode; drop --issue-number to use them");
      return null;
    }
    if (!issueNumberRaw || !/^\d+$/.test(String(issueNumberRaw))) {
      err(`invalid --issue-number: ${issueNumberRaw}`);
      return null;
    }
    return {
      mode: "A",
      notesPath,
      section: null,
      labels,
      title,
      issueNumber: parseInt(issueNumberRaw, 10),
      severity: null,
      skipIfMain,
    };
  }

  if (labels.length > 0) {
    err("mode conflict: --label is Mode A routing; the finding-authoring mode routes via --section");
    return null;
  }
  if (sectionRaw === undefined) {
    err(`missing --section (one of: ${MODE_B_SECTIONS.join(", ")})`);
    return null;
  }
  if (!MODE_B_SECTIONS.includes(sectionRaw)) {
    err(`invalid --section: ${sectionRaw} (one of: ${MODE_B_SECTIONS.join(", ")})`);
    return null;
  }
  // Severity is coupled to ## BugsFound only — the Final Report keeps
  // severity:high bodies verbatim, and only a bug body earns that.
  if (sectionRaw === "BugsFound") {
    if (severityRaw === undefined) {
      err(`--severity is required for --section BugsFound (one of: ${SEVERITY_VALUES.join(", ")})`);
      return null;
    }
    if (!SEVERITY_VALUES.includes(severityRaw)) {
      err(`invalid --severity: ${severityRaw} (one of: ${SEVERITY_VALUES.join(", ")})`);
      return null;
    }
  } else if (severityRaw !== undefined) {
    err(`--severity applies only to --section BugsFound, not ${sectionRaw}`);
    return null;
  }

  return {
    mode: "B",
    notesPath,
    section: sectionRaw,
    labels: [],
    title,
    issueNumber: null,
    severity: severityRaw === undefined ? null : severityRaw,
    skipIfMain,
  };
}

module.exports = { resolveArgs, MODE_B_SECTIONS, SEVERITY_VALUES };
