// bin/lib/test-wrappers/node-reporter.mjs — node:test reporter for bin/lib/test-wrappers/node.js (#2501).
// One `<seq>\t<STATE>\t<case>\t<target>` record per test and `<STATE>: <case>` on stdout; a describe
// suite and the file-level event are not cases. Nested names are joined with " > ".
// With a --test-reporter-destination the records are appended to it directly (O_APPEND per write):
// node's own stream writes at its fd offset, which would overwrite whatever test code appended there,
// so a forged or malformed line would vanish instead of failing the file. Without one, they are yielded.
import { appendFileSync } from "node:fs";
import { resolve } from "node:path";

const target = process.env.RUN_ALL_NODE_TARGET || "";
const clean = (s) => String(s).replace(/[\t\r\n]/g, " ");
const DEST_FLAG = "--test-reporter-destination=";
const destArg = process.execArgv.find((a) => a.startsWith(DEST_FLAG));
const dest = destArg === undefined ? "" : destArg.slice(DEST_FLAG.length);

// The file itself shows up as a test named by its path (node reports a file with no test, or one
// that exits on its own, that way).
function isFileLevel(data) {
  if (!data.file || typeof data.name !== "string") return false;
  return data.name === data.file || resolve(data.name) === resolve(data.file);
}

export default async function* caseReporter(source) {
  const stack = [];
  let seq = 0;
  for await (const event of source) {
    const data = event.data || {};
    // node documents test:start, like test:pass / test:fail, as emitted in declaration order even
    // when suites run concurrently, so the stack holds the parents of the event being reported.
    if (event.type === "test:start") {
      stack.length = data.nesting;
      stack[data.nesting] = isFileLevel(data) ? null : data.name;
      continue;
    }
    if (event.type !== "test:pass" && event.type !== "test:fail") continue;
    if ((data.details && data.details.type === "suite") || isFileLevel(data)) continue;
    // A result whose own start is not the latest at its depth broke that order: its parents are
    // unknown, so it is reported bare as FAIL and fails the file instead of borrowing a parent.
    const ordered = stack[data.nesting] === data.name;
    const parents = ordered ? stack.slice(0, data.nesting).filter((n) => n !== null && n !== undefined) : [];
    const name = parents.concat(data.name).join(" > ");
    let state = event.type === "test:fail" ? "FAIL" : "PASS";
    // node counts a todo test as expected whether it passes or fails, and exits 0 either way.
    if (data.skip !== undefined && data.skip !== false) state = "SKIP";
    else if (data.todo !== undefined && data.todo !== false) state = "SKIP";
    if (!ordered) {
      state = "FAIL";
      process.exitCode = 1;
      process.stderr.write(`node-reporter: result reported out of declaration order: ${clean(data.name)}\n`);
    }
    seq += 1;
    process.stdout.write(`${state}: ${name}\n`);
    const record = `${seq}\t${state}\t${clean(name)}\t${clean(target)}\n`;
    if (dest === "") yield record;
    else appendFileSync(dest, record);
  }
}
