"use strict";
// envClearLine part of the pester entry (#2507 D7): 0 for a `Remove-Item Env:NAME` line (optional
// -Path, -ErrorAction SilentlyContinue, -Force), 1 otherwise. One trailing CR is dropped first.
const { test, stripCr } = require("./match");

function envClearLine(names, line) {
  const re = `^[[:space:]]*Remove-Item([[:space:]]+-Path)?[[:space:]]+Env:\\\\?(${names})([[:space:]]+(-ErrorAction[[:space:]]+SilentlyContinue|-Force))*[[:space:]]*$`;
  return test(re, stripCr(String(line))) ? 0 : 1;
}

module.exports = { envClearLine };
