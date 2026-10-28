"use strict";
// Driver for tests/hooks/feature-2676-limited-child-process.js (TL2): arms the decision time
// limit the way a hook entrypoint does, then runs one real child through the wrapper.
// argv: <spawnSync|execSync|execFileSync> <original timeout ms, or "none">
// stdout: the wrapper's ask (when the limit cut the child), or one line
// "RETURNED <status|signal>" / "THREW <error code>" when control came back to the caller.
const path = require("path");

const LIB = path.resolve(__dirname, "..", "..", "..", "hooks", "lib");
const [fnName, timeoutArg] = process.argv.slice(2);
let limit;
let limited;
try {
  limit = require(path.join(LIB, "decision-time-limit.js"));
  limited = require(path.join(LIB, "limited-child-process.js"));
} catch (err) {
  process.stderr.write(`driver: module missing: ${err.message}\n`);
  process.exit(3);
}
limit.armDecisionTimeLimit({ hookName: "example-hook" });

const options = timeoutArg === "none" ? {} : { timeout: Number(timeoutArg) };
const SLEEP = "setTimeout(() => {}, 60000)";
try {
  if (fnName === "spawnSync") {
    const result = limited.spawnSync(process.execPath, ["-e", SLEEP], { ...options, encoding: "utf8" });
    process.stdout.write(`RETURNED ${result.error ? result.error.code : result.status}\n`);
  } else if (fnName === "execFileSync") {
    limited.execFileSync(process.execPath, ["-e", SLEEP], { ...options, stdio: "ignore" });
    process.stdout.write("RETURNED 0\n");
  } else {
    limited.execSync(`"${process.execPath}" -e "${SLEEP}"`, { ...options, stdio: "ignore" });
    process.stdout.write("RETURNED 0\n");
  }
} catch (err) {
  process.stdout.write(`THREW ${err.code}\n`);
}
