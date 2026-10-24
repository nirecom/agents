"use strict";
// Driver for the stdio cases of tests/hooks/feature-2676-limited-child-process.js (TL2): arms the
// decision time limit as a hook entrypoint does, runs one real child through the wrapper, and
// writes a JSON record to <out path>. The record goes to a file, not stdout, because the test
// starts this driver with stdio "ignore": a grandchild holding an inherited pipe must not stall it.
// argv: <mode> <out path>; record: { mode, ask?, exit?, elapsedMs, result?, thrown?, driverError? }
const fs = require("fs");
const path = require("path");

const LIB = path.resolve(__dirname, "..", "..", "..", "hooks", "lib");
const [mode, outPath] = process.argv.slice(2);
const record = { mode };
const flush = () => fs.writeFileSync(outPath, JSON.stringify(record));
let startMs = Date.now();

let limit;
let limited;
try {
  limit = require(path.join(LIB, "decision-time-limit.js"));
  limited = require(path.join(LIB, "limited-child-process.js"));
} catch (err) {
  record.driverError = `module missing: ${err.message}`;
  flush();
  process.exit(3);
}
limit.armDecisionTimeLimit({
  hookName: "example-hook",
  write: (text) => { record.ask = String(text); },
  exit: (code) => {
    record.exit = code; record.elapsedMs = Date.now() - startMs;
    if (inspectAtAsk) record.atAsk = inspectAtAsk();
    flush(); process.exit(code);
  },
});
// inspectAtAsk: set by a mode that reports file state at the moment askAndExit runs.
let inspectAtAsk = null;

const node = process.execPath;
const ECHO = "let s='';process.stdin.setEncoding('utf8');process.stdin.on('data',(d)=>{s+=d;});"
  + "process.stdin.on('end',()=>{process.stdout.write(s);process.stderr.write('err-text');});";
const text = (value) => (Buffer.isBuffer(value) ? value.toString("utf8") : value);
const describe = (value) => ({ isBuffer: Buffer.isBuffer(value), type: value === null ? "null" : typeof value, text: text(value) });

// failSetup(fn): the temp dir for file stdio cannot be made; the driver itself never calls mkdtempSync.
function failSetup(fn) {
  fs.mkdtempSync = () => { throw Object.assign(new Error("EACCES: mkdtemp refused by the test"), { code: "EACCES" }); };
  return { returned: true, value: fn() };
}

const MODES = {
  // Without input the pipe-backed stall does not show on Windows (measured); with input it does.
  grandchild: () => {
    const result = limited.spawnSync("bash", ["-c", "sleep 30 & sleep 30"], { input: "x", encoding: "utf8" });
    return { status: result.status, error: result.error ? result.error.code : null };
  },
  "spawn-io": () => {
    const result = limited.spawnSync(node, ["-e", ECHO], { input: "hello-in", encoding: "utf8" });
    return {
      status: result.status, error: result.error ? result.error.code : null,
      stdout: result.stdout, stderr: result.stderr,
      output1: result.output ? result.output[1] : undefined, output2: result.output ? result.output[2] : undefined,
    };
  },
  "execfile-fail": () => {
    try {
      limited.execFileSync(node, ["-e", "process.stdout.write('out-text');process.stderr.write('err-text');process.exit(3)"],
        { encoding: "utf8" });
      return { threw: false };
    } catch (err) {
      return { threw: true, isError: err instanceof Error, status: err.status, stdout: text(err.stdout), stderr: text(err.stderr) };
    }
  },
  "exec-ok": () => {
    const command = `"${node}" -e "process.stdout.write('ok-text')"`;
    return { plain: describe(limited.execSync(command)), encoded: describe(limited.execSync(command, { encoding: "utf8" })) };
  },
  "setup-fail-spawnSync": () => failSetup(() => limited.spawnSync(node, ["-e", "0"], { encoding: "utf8" })),
  "setup-fail-execFileSync": () => failSetup(() => limited.execFileSync(node, ["-e", "0"], { encoding: "utf8" })),
  "setup-fail-execSync": () => failSetup(() => limited.execSync(`"${node}" -e "0"`, { encoding: "utf8" })),
  // The stdin file is written, then opening it fails: is the file holding the input already gone?
  "setup-fail-after-input": () => {
    const os = require("os");
    const sentinel = `secret-sentinel-${process.pid}-${Date.now()}`;
    const openSync = fs.openSync;
    let patched = true;
    // Only the read open fails: writeFileSync opens the same file with "w" and must succeed.
    fs.openSync = (file, flags, ...rest) => {
      if (patched && String(file).endsWith(".stdin") && flags === "r") {
        record.inputWritten = fs.statSync(file).size === Buffer.byteLength(sentinel);
        throw Object.assign(new Error("EMFILE: open refused by the test"), { code: "EMFILE" });
      }
      return openSync(file, flags, ...rest);
    };
    inspectAtAsk = () => {
      patched = false;
      const dirs = fs.readdirSync(os.tmpdir()).filter((name) => name.startsWith("limited-child-process-"));
      const holders = [];
      for (const dirName of dirs) {
        let names = [];
        try { names = fs.readdirSync(path.join(os.tmpdir(), dirName)); } catch { continue; }
        for (const name of names) {
          const file = path.join(os.tmpdir(), dirName, name);
          try { if (fs.readFileSync(file, "utf8").includes(sentinel)) holders.push(file); } catch { /* gone or unreadable */ }
        }
      }
      return { holders };
    };
    return { returned: true, value: limited.spawnSync(node, ["-e", "0"], { input: sentinel, encoding: "utf8" }) };
  },
  "ignore-stdout": () => {
    const result = limited.spawnSync(node, ["-e", "process.stdout.write('x');process.stderr.write('y')"],
      { stdio: ["pipe", "ignore", "pipe"], encoding: "utf8" });
    return { status: result.status, stdout: result.stdout, stderr: result.stderr, output1: result.output ? result.output[1] : undefined };
  },
};

startMs = Date.now();
try {
  record.result = MODES[mode]();
} catch (err) {
  record.thrown = { message: err.message, code: err.code };
}
record.elapsedMs = Date.now() - startMs;
flush();
