"use strict";
const { loadDefaultEnv } = require("./load-env");

function getConvLangInjection() {
  loadDefaultEnv();
  const raw = process.env.CONV_LANG;
  if (typeof raw !== "string") return null;
  const normalized = raw.trim().toLowerCase();
  if (normalized.length === 0 || normalized === "english") return null;
  if (/[\x00-\x1f]/.test(normalized)) return null;
  return `Respond to the user in ${normalized}.`;
}

module.exports = { getConvLangInjection };
