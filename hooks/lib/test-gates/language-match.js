"use strict";
// The test-language match check (#2507 D7; was bin/lib/test-language-match.sh): dispatch only.

const { langException } = require("./language-match/exception");
const { pair } = require("./language-match/pairing");
const { caseAddition, caseAddition3way, codeLines } = require("./language-match/case-addition");
const { judge } = require("./language-match/judge");
const { judgeMulti } = require("./language-match/multi-baseline");
const { check } = require("./language-match/check");

module.exports = { langException, pair, caseAddition, caseAddition3way, codeLines, judge, judgeMulti, check };
