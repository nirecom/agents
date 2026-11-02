"use strict";
// Driver for tests/hooks/feature-2849-decision-budget.js (TL2): arms the decision time limit the
// way a hook entrypoint does (the limit read from this process's own env), then runs one mode.
// argv: <mode> [arg]. stdout: JSON lines for the parent, or the ask the wrapper wrote.
//   limit                       -> {"remaining":n} then the ask of askAndExit("example check")
//   declared-hang <ms>          -> {"returned":...} from a hung child with failOpenOnTimeout + timeout
//   undeclared-hang <ms>        -> the same call without the declaration
//   code-size <hang|hard|ok> <repoDir> -> {"result":...} from checkCodeSizeHardLimit
const childProcess = require("child_process");
const path = require("path");

const REPO = path.resolve(__dirname, "..", "..", "..");
const LIB = path.join(REPO, "hooks", "lib");
const [mode, arg, extra] = process.argv.slice(2);
const SLEEP = "setTimeout(() => {}, 60000)";
const elapsedMs = () => Math.round(process.uptime() * 1000);
const emit = (obj) => process.stdout.write(JSON.stringify({ ...obj, elapsedMs: elapsedMs() }) + "\n");

// The bin/review-code-size child is swapped for a node child with the same options, so the
// gate's own timeout and the wrapper's cap act on a real process.
const FAKE_CODE_SIZE = {
  hang: SLEEP,
  hard: "process.stdout.write('## Code-size Review: PERFORMED (staged mode)\\n  HARD: bin/big.js — 600 lines total\\n'); process.exit(1)",
  ok: "process.stdout.write('## Code-size Review: PERFORMED (staged mode)\\n'); process.exit(0)",
};
function interceptCodeSize(kind) {
  const real = childProcess.spawnSync;
  childProcess.spawnSync = (command, args, options) => {
    if (Array.isArray(args) && args.some((a) => String(a).includes("review-code-size"))) {
      return real(process.execPath, ["-e", FAKE_CODE_SIZE[kind]], options);
    }
    return real(command, args, options);
  };
}

const limit = require(path.join(LIB, "decision-time-limit.js"));
const limited = require(path.join(LIB, "limited-child-process.js"));

if (mode === "code-size") interceptCodeSize(arg);
limit.armDecisionTimeLimit({ hookName: mode === "code-size" ? "workflow-gate" : "x-hook" });

if (mode === "limit") {
  emit({ remaining: limit.remainingDecisionMs() });
  limit.askAndExit("example check");
} else if (mode === "declared-hang" || mode === "undeclared-hang") {
  const options = { timeout: Number(arg), encoding: "utf8" };
  if (mode === "declared-hang") options.failOpenOnTimeout = true;
  const r = limited.spawnSync(process.execPath, ["-e", SLEEP], options);
  emit({ returned: { status: r.status, signal: r.signal || null, error: r.error ? r.error.code : null } });
} else if (mode === "code-size") {
  const { checkCodeSizeHardLimit } = require(path.join(REPO, "hooks", "workflow-gate", "code-size-gate.js"));
  emit({ result: checkCodeSizeHardLimit(extra) });
} else {
  process.stderr.write(`driver: unknown mode ${mode}\n`);
  process.exit(3);
}
