"use strict";
// The test frontmatter check (#2507 D7; was bin/check-test-frontmatter.sh): dispatch only.

const { normalizeContent, checkContent, harnessSourced } = require("./frontmatter/content");
const { isSupportedTest, isTestEntrypoint, isFlatTest } = require("./frontmatter/rules");
const { stagedCheck } = require("./frontmatter/staged");
const { allCheck } = require("./frontmatter/all");

module.exports = { normalizeContent, checkContent, harnessSourced, isSupportedTest, isTestEntrypoint, isFlatTest, stagedCheck, allCheck };
