"use strict";
// Fixture: fd arguments that only resemble stdin (fd0, 10, stdout) are not stdin reads.
const fs = require("fs");
module.exports = (fd0) => {
  const buf = Buffer.alloc(16);
  const a = fs.readSync(fd0, buf, 0, buf.length, null);
  const b = fs.readSync(10, buf, 0, buf.length, null);
  const c = fs.readSync(process.stdout.fd, buf, 0, buf.length, null);
  return a + b + c;
};
