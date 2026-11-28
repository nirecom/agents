"use strict";
// --session-id mode and the normal (resolved-session) mode of bin/issue-close-write-outcome.js.
// --session-id writes the primary entry (with --issue-repo), stores --owner-repo as the bag's homeRepo,
// and adds each intent sibling as subsumed only when gh reports it CLOSED (#1889 / #3043).

const path = require("path");
const B = require("./bag");
const { normalizeHome, outcomeKey, refKey, refDisplay } = require(path.join(B.SCRIPT_CHECKOUT_ROOT, "hooks", "lib", "issue-identity"));

const SESSION_USAGE = "Usage: issue-close-write-outcome.js --session-id <id> --out-file <path> [--issue-repo <r>] [--owner-repo <r>] <N> <state> <historyEntry> <issueClosed> <sentinelsPosted> <wipCleared>\n";
const NORMAL_USAGE = "Usage: issue-close-write-outcome.js <N> <state> <historyEntry> <issueClosed> <sentinelsPosted> <wipCleared>\n";
const HOME_UNKNOWN = "issue-close-write-outcome: home repo unknown; #N and owner/repo#N are matched as written\n";
const REPO_FLAGS = { "--issue-repo": "issueRepo", "--owner-repo": "ownerRepo" };

const err = (msg) => {
  process.stderr.write(msg);
  return 1;
};

// parseFields(list) -> {issueNumber, fields} or null: <N> plus the five disposition values.
function parseFields(list) {
  const [n, state, historyEntry, issueClosed, sentinelsPosted, wipCleared] = list;
  if (!n || !state || !historyEntry || !issueClosed || !sentinelsPosted || !wipCleared) return null;
  return { n, fields: { state, historyEntry, issueClosed, sentinelsPosted, wipCleared } };
}

function addSiblings(bag, sessionId, primaryKey, home) {
  const { issueState } = require(path.join(B.SCRIPT_CHECKOUT_ROOT, "bin", "lib", "issue-state"));
  let siblings;
  try { siblings = B.getClosesIssues(sessionId, B.plansDirOrEmpty()); } catch (_) { return; }
  for (const ref of siblings) {
    if (!ref || !Number.isInteger(Number(ref.number))) continue;
    const key = refKey(ref, home);
    if (key === primaryKey || B.hasKey(bag, key, home)) continue;
    const state = issueState(ref, home);
    if (state === "OPEN") continue;
    if (state !== "CLOSED") {
      process.stderr.write(`issue-close-write-outcome: state check failed for ${refDisplay(ref, home)}; no entry written\n`);
      continue;
    }
    const entry = { issueNumber: Number(ref.number) };
    if (ref.repo) entry.issueRepo = String(ref.repo);
    for (const f of ["state", "historyEntry", "issueClosed", "sentinelsPosted", "wipCleared"]) entry[f] = "subsumed";
    B.upsertEntry(bag, entry, home);
  }
}

function runSessionId(args) {
  const sessionId = args[1];
  const outFile = args[3];
  if (!sessionId || args[2] !== "--out-file" || !outFile) return err(SESSION_USAGE);
  if (!/^[A-Za-z0-9_-]+$/.test(sessionId)) return err("issue-close-write-outcome: session-id must match [A-Za-z0-9_-]+\n");
  const opts = {};
  let i = 4;
  while (REPO_FLAGS[args[i]]) {
    if (args[i + 1] === undefined) return err(SESSION_USAGE);
    opts[REPO_FLAGS[args[i]]] = args[i + 1];
    i += 2;
  }
  const parsed = parseFields(args.slice(i));
  if (!parsed) return err(SESSION_USAGE);
  const issueNumber = parseInt(parsed.n, 10);
  if (isNaN(issueNumber)) return err("issue-close-write-outcome: <N> must be an integer\n");

  const bag = B.readBag(outFile);
  const given = normalizeHome(opts.ownerRepo);
  if (given) bag.homeRepo = given;
  const home = given || B.bagHome(bag);
  if (!home) process.stderr.write(HOME_UNKNOWN);
  const primary = { issueNumber };
  if (opts.issueRepo) primary.issueRepo = opts.issueRepo;
  Object.assign(primary, parsed.fields);
  B.upsertEntry(bag, primary, home);
  addSiblings(bag, sessionId, outcomeKey(primary, home), home);
  B.writeBag(outFile, bag);
  return 0;
}

function runNormal(args) {
  const parsed = parseFields(args);
  if (!parsed) return err(NORMAL_USAGE);
  const issueNumber = parseInt(parsed.n, 10);
  if (isNaN(issueNumber)) return err("issue-close-write-outcome: <N> must be an integer\n");
  const sessionId = B.resolveSessionId();
  if (!sessionId) {
    process.stderr.write("[issue-close-write-outcome] WARN: session id unresolved — outcome JSON not written\n");
    return 0;
  }
  try {
    const outFile = B.outcomePathFor(sessionId);
    const bag = B.readBag(outFile);
    B.upsertEntry(bag, Object.assign({ issueNumber }, parsed.fields), B.bagHome(bag));
    B.writeBag(outFile, bag);
  } catch (e) {
    process.stderr.write("[issue-close-finalize] WARN: outcome JSON write failed: " + e.message + "\n");
  }
  return 0;
}

module.exports = { runSessionId, runNormal, HOME_UNKNOWN };
