"use strict";

function stripQuotedArgs(str) {
  if (!str || typeof str !== "string") return str;
  try {
    return str
      .replace(/\$'(?:[^'\\]|\\.)*'/g, "$''")
      .replace(/"(?:[^"\\]|\\.)*"/g, '""')
      .replace(/'[^']*'/g, "''");
  } catch (e) {
    return str;
  }
}

module.exports = { stripQuotedArgs };
