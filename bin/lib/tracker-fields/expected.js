"use strict";
// The Projects v2 fields a tracker board needs (#3135): the one table the board preparation
// (bin/github-issues/lib/ensure-project-ready.sh reads the names) and the tracker judge (judge.js) both read.
// Each entry: {name, dataType, options?}; options are the single-select option names the board must have.

const CONTENT_DATE = { name: "Content Date", dataType: "DATE" };
const STATUS = { name: "Status", dataType: "SINGLE_SELECT", options: ["Todo", "In Progress", "Done"] };
const SESSION_ID = { name: "session-id", dataType: "TEXT" };
const PM = { name: "pm", dataType: "TEXT" };

const EXPECTED_FIELDS = [CONTENT_DATE, STATUS, SESSION_ID, PM];

// CLI: `node expected.js --names` prints the names one per line in the order CONTENT_DATE, STATUS,
// SESSION_ID, PM (the shell preparation reads them positionally).
if (require.main === module && process.argv[2] === "--names") {
  process.stdout.write(`${[CONTENT_DATE, STATUS, SESSION_ID, PM].map((f) => f.name).join("\n")}\n`);
}

module.exports = { EXPECTED_FIELDS, CONTENT_DATE, STATUS, SESSION_ID, PM };
