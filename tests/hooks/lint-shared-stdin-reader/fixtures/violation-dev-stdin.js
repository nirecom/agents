"use strict";
// Fixture: the /dev/stdin path form of a private stdin read.
const fs = require("fs");
module.exports = () => fs.readFileSync('/dev/stdin', "utf8");
