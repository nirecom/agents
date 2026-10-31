"use strict";
// envClearLine part of the js entry (#2507 D7): 0 for a `delete process.env.NAME;` line naming one
// of the ERE's vars, 1 otherwise. One trailing CR is dropped first.
const { test, stripCr } = require("./match");

function envClearLine(names, line) {
  const re = `^[[:space:]]*delete[[:space:]]+process\\.env\\.(${names})[[:space:]]*;?[[:space:]]*$`;
  return test(re, stripCr(String(line))) ? 0 : 1;
}

module.exports = { envClearLine };
