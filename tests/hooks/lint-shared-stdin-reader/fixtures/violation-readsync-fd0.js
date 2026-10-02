"use strict";
// Fixture: the numeric fd-0 readSync form of a private stdin read.
const fs = require("fs");
module.exports = () => {
  const buf = Buffer.alloc(16);
  const n = fs.readSync(0, buf, 0, buf.length, null);
  return buf.toString("utf8", 0, n);
};
