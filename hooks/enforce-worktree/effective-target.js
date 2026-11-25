// hooks/enforce-worktree/effective-target.js
// #3147: entrypoint for judging a git write by where it really lands. Logic lives in effective-target/.

"use strict";

const { resolveEffectiveTarget } = require("./effective-target/resolve");
const { naturalIdentity } = require("./effective-target/natural-git");
const { removePruneArmsAllowed, branchDeleteVerdict, decideEffectiveTarget, OVERRIDE_LINE } = require("./effective-target/decide");

module.exports = { resolveEffectiveTarget, naturalIdentity, decideEffectiveTarget, removePruneArmsAllowed, branchDeleteVerdict, OVERRIDE_LINE };
