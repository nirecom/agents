"use strict";

// Argument parsing, validation and mode resolution for
// bin/worktree-notes-append.js (split out per rules/coding/file-split.md).
// Mode is discriminated by --issue-number: present = Mode A (existing-issue
// promotion, section from --label); absent = Mode B (finding authoring,
// section from --section; --severity and --pr-scope mandatory for every section
// but ManualReminders, which takes no triage flag).

const { parseArgs } = require("util");
const { SEVERITIES, PR_SCOPES } = require("../../hooks/lib/worktree-notes-sections");

// Input allowlist. Not shared with triage.js's or notes.js's section lists —
// this one adds ManualReminders since it needs a CLI edit path too, even
// though a reminder is never promoted to an issue.
const MODE_B_SECTIONS = ["BugsFound", "RelatedTasks", "NextTasks", "ManualReminders"];
const TRIAGE_SECTIONS = ["BugsFound", "RelatedTasks", "NextTasks"];
const TRIAGE_FLAGS = ["severity", "pr-scope", "instance", "loc", "test-failure"];
const SEVERITY_VALUES = SEVERITIES;

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
        "pr-scope": { type: "string" },
        instance: { type: "string" },
        loc: { type: "string" },
        "test-failure": { type: "boolean" },
        "user-acknowledged": { type: "string" },
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

function validMarkerValue(v) {
  return typeof v === "string" && v.trim().length > 0 && !/<!--|-->|[\r\n]/.test(v);
}

// Returns { mode, notesPath, section, labels, title, issueNumber, triage, skipIfMain }
// or null after emitting the reason on stderr (caller exits 2).
function resolveArgs(argv) {
  const args = parseCliArgs(argv);
  if (!args) return null;
  if (args["user-acknowledged"] !== undefined) {
    err("--user-acknowledged is retired (#2019): pass --severity and --pr-scope instead; filing is decided by the triage rules");
    return null;
  }

  const notesPath = args["notes-path"];
  const issueNumberRaw = args["issue-number"];
  const sectionRaw = args.section;
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
    if (sectionRaw !== undefined || TRIAGE_FLAGS.some((f) => args[f] !== undefined)) {
      err(`mode conflict: --section/--${TRIAGE_FLAGS.join("/--")} belong to the finding-authoring mode; drop --issue-number to use them`);
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
      triage: null,
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
  const triage = TRIAGE_SECTIONS.includes(sectionRaw) ? resolveTriageFlags(args, sectionRaw) : null;
  if (TRIAGE_SECTIONS.includes(sectionRaw) && triage === null) return null;
  if (!TRIAGE_SECTIONS.includes(sectionRaw) && TRIAGE_FLAGS.some((f) => args[f] !== undefined)) {
    err(`--${TRIAGE_FLAGS.join("/--")} do not apply to --section ${sectionRaw}`);
    return null;
  }

  return {
    mode: "B",
    notesPath,
    section: sectionRaw,
    labels: [],
    title,
    issueNumber: null,
    triage,
    skipIfMain,
  };
}

// The triage fields a BugsFound/RelatedTasks/NextTasks entry carries (#2019); null after an error.
function resolveTriageFlags(args, section) {
  const severity = args.severity;
  const prScope = args["pr-scope"];
  const instance = args.instance;
  if (!SEVERITY_VALUES.includes(severity)) {
    err(`${severity === undefined ? "missing" : `invalid: ${severity};`} --severity is required for --section ${section} (one of: ${SEVERITY_VALUES.join(", ")})`);
    return null;
  }
  if (!PR_SCOPES.includes(prScope)) {
    err(`${prScope === undefined ? "missing" : `invalid: ${prScope};`} --pr-scope is required for --section ${section} (one of: ${PR_SCOPES.join(", ")})`);
    return null;
  }
  if (instance !== undefined && !validMarkerValue(instance)) {
    err("invalid --instance: one non-empty line without <!-- or -->");
    return null;
  }
  if (args.loc !== undefined && !validMarkerValue(args.loc)) {
    err("invalid --loc: one non-empty line without <!-- or -->");
    return null;
  }
  if (args["test-failure"] && instance === undefined) {
    err("--test-failure requires --instance (the failing test and how it fails)");
    return null;
  }
  return {
    severity, prScope,
    instance: instance === undefined ? null : instance,
    loc: args.loc === undefined ? null : args.loc,
    testFailure: Boolean(args["test-failure"]),
  };
}

module.exports = { resolveArgs, MODE_B_SECTIONS, SEVERITY_VALUES };
