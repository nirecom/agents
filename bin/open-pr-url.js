#!/usr/bin/env node
"use strict";
// bin/open-pr-url.js
//
// Stand-in for the half of hooks/pr-created-open.js that the dispatcher path
// loses (#1673 D2).
//
// That hook is a PostToolUse(Bash) hook: it fires because `gh pr create` was a
// TOOL invocation. Once the same call moves inside a worker child process it is
// no longer a tool invocation, so the hook never runs — the browser does not
// open and the URL never reaches the user. skills/commit-push/SKILL.md CP-2b
// calls this CLI to restore the reachable half.
//
// What is deliberately NOT restored: the hook's "Click Allow to proceed, Deny to
// abort." line. That wording belonged to a tool-permission dialog which, on the
// dispatcher path, no longer exists — the authorization happened at the
// worker-dispatch call. Printing it here would advertise a decision the user is
// not being offered. CP-2b instead requires the URL in the turn's final response.
//
// openInBrowser is REUSED from hooks/lib/open-external.js rather than reproduced
// (CPR-2): the platform table, the opt-out variable and the test mode stay in one
// place, so this CLI and the surviving hook can never drift.
//
// Fail-open, unconditionally. This runs after a successful push and a created
// PR; a cosmetic failure here must never turn that into a failed commit-push.

const { openInBrowser } = require("../hooks/lib/open-external");

// The same pattern hooks/pr-created-open.js matches with, anchored end to end:
// a trailing segment (`/files`), a non-numeric id, or a host that merely starts
// with `github.com` is not a PR URL this CLI will hand to a browser.
const PR_URL_RE = /^https?:\/\/github\.com\/[^/\s]+\/[^/\s]+\/pull\/\d+$/;

function main(argv) {
  const url = typeof argv[0] === "string" ? argv[0].trim() : "";
  if (url === "" || !PR_URL_RE.test(url)) return;

  openInBrowser(url);

  const n = /\/pull\/(\d+)$/.exec(url);
  process.stdout.write(`PR #${n[1]} created: ${url}\n`);
}

if (require.main === module) {
  try {
    main(process.argv.slice(2));
  } catch (_e) {
    // fail-open: never non-zero, never a stack trace on the caller's transcript
  }
  process.exit(0);
}

module.exports = { PR_URL_RE };
