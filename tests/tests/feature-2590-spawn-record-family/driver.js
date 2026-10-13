"use strict";
// tests/tests/feature-2590-spawn-record-family/driver.js — loaded with the spawn-record preload
// (`node -r`) by tests/tests/feature-2590-spawn-record-family.sh. One call shape per run:
//   node -r <preload> driver.js <shape> [command string]
// SR_BASH is a bash that the shell forms run under (so `GH_TOKEN=x gh` means the same on every
// OS); SR_NODE is a node binary that is not a stub. Prints one marker line per observed event.

const cp = require("child_process");

const shape = process.argv[2];
const text = process.argv[3] || "";
const bash = process.env.SR_BASH;
const node = process.env.SR_NODE || process.execPath;
const say = (s) => process.stdout.write(`${s}\n`);

function onChild(child) {
  child.on("exit", (code) => say(`EXIT:${code}`));
  child.on("close", () => say("CLOSE"));
  if (child.stdout) child.stdout.on("data", (d) => say(`OUT:${String(d).trim()}`));
}

switch (shape) {
  // One harmless call through each of the six functions.
  case "spawn":
    onChild(cp.spawn(node, ["-e", "0"]));
    break;
  case "exec":
    cp.exec(`"${node}" -e 0`, { shell: bash }, () => say("CB"));
    break;
  case "execFile":
    cp.execFile(node, ["-e", "0"], () => say("CB"));
    break;
  case "execSync":
    cp.execSync(`"${node}" -e 0`, { shell: bash });
    say("DONE");
    break;
  case "execFileSync":
    cp.execFileSync(node, ["-e", "0"]);
    say("DONE");
    break;
  case "fork":
    onChild(cp.fork(__filename, ["noop"], { execArgv: [] }));
    break;
  case "noop":
    break;
  // Command strings run through bash; held ones must never start the PATH stub.
  case "exec-text":
    cp.exec(text, { shell: bash }, (err, out) => say(`CB:${err ? "err" : "ok"}:${String(out).trim()}`));
    break;
  case "execSync-text":
    say(`SYNC:${String(cp.execSync(text, { shell: bash })).trim()}`);
    break;
  case "spawn-shell-text":
    onChild(cp.spawn(text, { shell: bash }));
    break;
  // Argument-vector forms: the command word sits behind env and an assignment.
  case "spawn-env-argv":
    onChild(cp.spawn("env", ["X=1", "gh", "api", "repos/x/y"]));
    break;
  case "execFileSync-gh":
    say(`SYNC:${String(cp.execFileSync("gh", ["api", "repos/x/y"])).trim()}`);
    break;
  // A network CLI named by `text` through execFile, spawnSync and a forked child (which inherits
  // the preload through execArgv and calls execFile itself).
  case "execFile-net":
    cp.execFile(text, ["api", "repos/x/y"], (err) => say(`CB:${err ? "err" : "ok"}`));
    break;
  case "spawnSync-net":
    cp.spawnSync(text, ["api", "repos/x/y"]);
    say("DONE");
    break;
  case "fork-net":
    onChild(cp.fork(__filename, ["execFile-net", text]));
    break;
  case "spawnSync-node":
    cp.spawnSync(node, ["-e", "0"]);
    say("DONE");
    break;
  default:
    say(`UNKNOWN:${shape}`);
    process.exitCode = 2;
}
