"use strict";
// envClearLine part of the pytest entry (#2507 D7): 0 for an `os.environ.pop("NAME", None)` line
// (either quote), 1 otherwise. One trailing CR is dropped first.
const { test, stripCr } = require("./match");

function envClearLine(names, line) {
  const re = `^[[:space:]]*os\\.environ\\.pop\\(("(${names})"|'(${names})'),[[:space:]]*None\\)[[:space:]]*$`;
  return test(re, stripCr(String(line))) ? 0 : 1;
}

module.exports = { envClearLine };
