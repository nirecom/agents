"use strict";
// Fixture: the process.stdin.fd readFileSync form of a private stdin read.
const fs = require("fs");
module.exports = () => fs.readFileSync(process.stdin.fd, "utf8");
