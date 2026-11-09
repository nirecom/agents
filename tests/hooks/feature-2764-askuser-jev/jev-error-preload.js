"use strict";
// Test-only preload (node --require) for the route "error" case of feature-2764-askuser-jev.js:
// judgeConversation still runs against the mock Jev, then its result throws on any property
// access, so decide fails only after Jev was called (the jev_called: true path).

const path = require("node:path");

const cp = require(path.join(__dirname, "..", "..", "..", "hooks", "lib", "jev", "conversation-point.js"));
const real = cp.judgeConversation;
cp.judgeConversation = async function judgeConversationThenThrow(...args) {
  await real.apply(this, args);
  return new Proxy({}, { get() { throw new Error("injected failure after judgeConversation"); } });
};
