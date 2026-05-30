"use strict";
// Shared helper: open a URL in the OS default browser (detached, non-blocking).
//
// Env opts:
//   SHOW_USER_VERIFIED_NO_BROWSER=1  — opt-out: skip browser open entirely
//   SHOW_USER_VERIFIED_NO_SPAWN=1    — test mode: write marker file instead of spawning
//   SHOW_USER_VERIFIED_MARKER_FILE   — path to write {cmd, args} JSON (test mode only)

const { spawnSync, spawn } = require("child_process");
const fs = require("fs");

function openInBrowser(url) {
  if (!url || typeof url !== "string") return;
  if (!/^https?:\/\//.test(url)) return;
  if (process.env.SHOW_USER_VERIFIED_NO_BROWSER === "1") return;

  let cmd, args;
  if (process.platform === "win32") {
    cmd = "explorer.exe";
    args = [url];
  } else if (process.platform === "darwin") {
    cmd = "open";
    args = [url];
  } else {
    cmd = "xdg-open";
    args = [url];
  }

  if (process.env.SHOW_USER_VERIFIED_NO_SPAWN === "1") {
    const markerFile = process.env.SHOW_USER_VERIFIED_MARKER_FILE;
    if (markerFile) {
      try {
        fs.writeFileSync(markerFile, JSON.stringify({ cmd, args }));
      } catch (_) {}
    }
    return;
  }

  try {
    const child = spawn(cmd, args, {
      stdio: "ignore",
      detached: true,
      windowsHide: true,
    });
    child.unref();
  } catch (_) {}
}

module.exports = { openInBrowser };
