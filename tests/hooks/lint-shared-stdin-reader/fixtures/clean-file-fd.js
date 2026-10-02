"use strict";
// Fixture: reading an opened FILE descriptor is not a stdin read.
const fs = require("fs");
module.exports = (p) => {
  const fd = fs.openSync(p, "r");
  const buf = Buffer.alloc(16);
  const n = fs.readSync(fd, buf, 0, buf.length, null);
  fs.closeSync(fd);
  return fs.readFileSync(p, "utf8") + buf.toString("utf8", 0, n);
};
