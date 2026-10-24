"use strict";
// bin/lib/test-language-parts/js-case-reader.js <file> — the js entry's case reader child.
// A line reader, not a parser: it reports the column-0 `caseBegin("<name>", "<target>");` ...
// `caseEnd();` pairs of tests/lib/harness.js and never runs or parses the file. Prints
//   FILE\t<state>\t<line>\t<reason>   and, when conforming, one
//   CASE\t<name>\t<target>\t<begin>\t<end>\t\t   per pair, in file order.
// The case enumeration lives in js-case-scan.js, shared with js-case-analyzer.js.
// Exit 1: unreadable file.

const { readLines, scanLines } = require("./js-case-scan");

function main(file) {
  const v = scanLines(readLines(file));
  const rows = [["FILE", v.state, v.line, v.reason].join("\t")];
  for (const c of v.cases) rows.push(["CASE", c.name, c.target, c.begin, c.end, "", ""].join("\t"));
  process.stdout.write(rows.join("\n") + "\n");
}

try {
  main(process.argv[2]);
} catch (err) {
  process.stderr.write(`js-case-reader: cannot read ${process.argv[2]}: ${err.code || err.message}\n`);
  process.exitCode = 1;
}
