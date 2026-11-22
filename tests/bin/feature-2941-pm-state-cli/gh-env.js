"use strict";
// In-process fake-gh environment of the #2941 forge tests (feature-2941-forge-issue-links.js,
// feature-2941-pm-state-ancestry.js, hooks/feature-2941-pm-writer): ./fake-gh.js first on this process's PATH, its log and map in
// a temp dir, restored by the caller's after(). No case markers.
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const P = require("../../lib/pm-state-fixture");

const KEYS = ["PATH", "PM_FAKE_GH_LOG", "PM_FAKE_GH_MAP", "PM_FAKE_GH_MODE", "PM_FAKE_GH_SLEEP_MS", "PM_FAKE_GH_SIDE",
  "PM_FAKE_GH_PM_STORE", "PM_FAKE_GH_EDIT_SLEEP_MS", "PM_FAKE_GH_EDIT_PID_FILE", "PM_FAKE_GH_EDIT_MODE"];

// ghEnv(prefix) -> {tmp, setMap(map), calls(), queries(), mode(m), sleep(ms), side(file, patch), restore(),
// pmStore(), setPmStore(obj), editSleep(ms), editMode(m), editPidFile}; side arms a one-shot write the next
// gh call makes to file's pm key (a race in the middle of a check); pmStore is the PM field values by item id.
function ghEnv(prefix) {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), prefix));
  const saved = {};
  for (const k of KEYS) saved[k] = process.env[k];
  const bin = path.join(tmp, "bin");
  fs.mkdirSync(bin);
  fs.writeFileSync(path.join(bin, "gh"), `#!/bin/bash\nexec node '${P.fwd(path.join(__dirname, "fake-gh.js"))}' "$@"\n`, { mode: 0o755 });
  const log = path.join(tmp, "gh.log");
  const mapFile = path.join(tmp, "map.json");
  fs.writeFileSync(log, "");
  fs.writeFileSync(mapFile, "{}");
  process.env.PATH = `${bin}${path.delimiter}${saved.PATH}`;
  process.env.PM_FAKE_GH_LOG = log;
  process.env.PM_FAKE_GH_MAP = mapFile;
  const sideFile = path.join(tmp, "side.json");
  process.env.PM_FAKE_GH_SIDE = sideFile;
  const storeFile = path.join(tmp, "pm-store.json");
  const editPidFile = path.join(tmp, "edit.pid");
  fs.writeFileSync(storeFile, "{}");
  process.env.PM_FAKE_GH_PM_STORE = storeFile;
  process.env.PM_FAKE_GH_EDIT_PID_FILE = editPidFile;
  const setEnv = (k, v) => { if (v === undefined || v === null) delete process.env[k]; else process.env[k] = String(v); };
  const lines = () => fs.readFileSync(log, "utf8").split("\n").filter(Boolean).map((l) => JSON.parse(l));
  return {
    tmp,
    setMap: (m) => fs.writeFileSync(mapFile, JSON.stringify(m)),
    calls: () => lines().length,
    queries: () => lines().map((a) => a.join(" ")),
    mode: (m) => setEnv("PM_FAKE_GH_MODE", m),
    sleep: (ms) => setEnv("PM_FAKE_GH_SLEEP_MS", ms),
    side: (file, patch) => fs.writeFileSync(sideFile, JSON.stringify({ file, patch })),
    sideArmed: () => fs.existsSync(sideFile),
    clearSide: () => fs.rmSync(sideFile, { force: true }),
    pmStore: () => JSON.parse(fs.readFileSync(storeFile, "utf8")),
    setPmStore: (obj) => fs.writeFileSync(storeFile, JSON.stringify(obj)),
    editSleep: (ms) => setEnv("PM_FAKE_GH_EDIT_SLEEP_MS", ms),
    editMode: (m) => setEnv("PM_FAKE_GH_EDIT_MODE", m),
    editPidFile,
    restore: () => {
      for (const k of KEYS) setEnv(k, saved[k]);
      fs.rmSync(tmp, { recursive: true, force: true });
    },
  };
}

module.exports = { ghEnv };
