"use strict";

const { extractRedirectTargets } = require("./bash-write-targets/redirect");
const { extractTeeTargets } = require("./bash-write-targets/tee");
const { extractPwshWriteTargets } = require("./bash-write-targets/pwsh");
const { extractCpMvDestination } = require("./bash-write-targets/cp-mv");
const { extractRmTargets } = require("./bash-write-targets/rm");
const { extractStagedFiles } = require("./bash-write-targets/staged");

module.exports = {
  extractRedirectTargets,
  extractTeeTargets,
  extractPwshWriteTargets,
  extractCpMvDestination,
  extractRmTargets,
  extractStagedFiles,
};
