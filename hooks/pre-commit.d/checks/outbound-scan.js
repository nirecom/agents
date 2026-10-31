"use strict";
// outbound-scan check (#2507 D5/D6): private information in the staged blobs blocks the commit.
// Implementation: ./outbound-scan/staged.js (scan, output) and ./outbound-scan/binary.js (skip).

module.exports = require("./outbound-scan/staged");
