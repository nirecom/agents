"use strict";
// `next-step --advance` — this CLI's member of the forward-operation class.
// The transaction itself lives in ./advance-shared.js so all four members share
// one shape; next-step's only difference is that it names the target step
// explicitly (--step/--status) instead of deriving it from its own arguments.

const { runAdvance } = require("./advance-shared");
const { resolveRepoDir } = require("./repo-dir");

function runAdvanceCli(args) {
  runAdvance({
    session: args.session,
    binary: "next-step",
    step: args.advanceStep,
    status: args.advanceStatus,
    skipReason: args.skipReason,
    next: args.next === true,
    repoDir: resolveRepoDir(),
  });
}

module.exports = { runAdvanceCli };
