#!/usr/bin/env node
"use strict";
// UserPromptSubmit — provenance observation layer A (#1763).
//
// Mints a short-lived token when the turn that is starting is an explicit
// issue-creation request, and revokes any existing token when it is not. That
// revocation IS the turn-boundary binding: an authorization granted by one user
// turn cannot survive into the next one.
//
// It also refreshes <sid>.session-transcript on EVERY turn, so the consuming CLI
// (bin/github-issues/issue-provenance) can find the transcript even when the very
// first turn of a session is the request.
//
// Contract, in order of importance:
//   * stdout is always exactly "{}" and the exit code is always 0 — a hook on
//     UserPromptSubmit that throws would surface a stack trace to the user on an
//     unrelated turn.
//   * the marker filename comes from the payload's session_id, so it is validated
//     through hooks/lib/issue-provenance-keys.js and never used raw. A key that
//     does not pass is simply no key: nothing is written.
//   * transcript_path is only ever STORED, never opened here (the 5s budget), so
//     a device file or a 4 KB path costs nothing.

const fs = require("fs");
const path = require("path");

function emit() {
  try {
    process.stdout.write("{}");
  } catch (_e) {
    /* stdout gone — nothing left to do */
  }
  process.exit(0);
}

function readStdin() {
  try {
    return fs.readFileSync(0, "utf8");
  } catch (_e) {
    return "";
  }
}

function writeAtomic(target, contents) {
  const tmp = target + ".tmp";
  try {
    fs.mkdirSync(path.dirname(target), { recursive: true });
    fs.writeFileSync(tmp, contents, { mode: 0o600 });
    fs.renameSync(tmp, target);
  } catch (_e) {
    try { fs.unlinkSync(tmp); } catch (_e2) {}
  }
}

function main() {
  try {
    require("./lib/load-env").loadDefaultEnv();
  } catch (_e) {
    /* fail-open: .env is optional */
  }
  // `off` means "no turn may be treated as user-explicit". Returning here would be
  // fail-OPEN: a token minted while the switch was on would survive on disk and keep
  // authorizing later turns. So `off` still runs the revocation half of the loop —
  // it only suppresses minting and the transcript pointer.
  const disabled =
    String(process.env.ISSUE_PROVENANCE || "").trim().toLowerCase() === "off";

  let payload;
  try {
    payload = JSON.parse(readStdin());
  } catch (_e) {
    return;
  }
  if (!payload || typeof payload !== "object") return;

  const { provenanceKeys, provenancePaths } = require("./lib/issue-provenance-keys");
  const keys = provenanceKeys(payload.session_id);
  if (keys.length === 0) return;

  let layer = null;
  if (!disabled) {
    const prompt = typeof payload.prompt === "string" ? payload.prompt : "";
    const { issueRequestLayer } = require("./lib/issue-request-patterns");
    layer = issueRequestLayer(prompt);
  }
  const matched = layer !== null;

  const now = Date.now();
  for (const key of keys) {
    let paths;
    try {
      paths = provenancePaths(key);
    } catch (_e) {
      continue;
    }

    if (
      !disabled &&
      typeof payload.transcript_path === "string" &&
      payload.transcript_path
    ) {
      writeAtomic(paths.transcript, payload.transcript_path);
    }

    if (matched) {
      writeAtomic(
        paths.token,
        JSON.stringify({
          provenance: "user-explicit",
          target: "issue-create",
          match_layer: layer,
          session_id: key,
          minted_at: new Date(now).toISOString(),
          expires_at: new Date(now + 15 * 60 * 1000).toISOString(),
        })
      );
    } else {
      // Turn-boundary binding: any turn that is not itself a request revokes.
      // Also the `disabled` path — see the note above `const disabled`.
      try { fs.unlinkSync(paths.token); } catch (_e) {}
    }
  }
}

try {
  main();
} catch (_e) {
  /* every failure mode is the same failure mode: say nothing, change nothing */
}
emit();
