"use strict";
// tests/hooks/feature-2768-plan-sync-turn-auth.js
// Tests: hooks/lib/plan-sync/commit-push.js, hooks/lib/plan-sync/remote-state.js, hooks/show-plan-link.js
// Tags: scope:issue-specific, TL2, plan-sync, auth-backoff
// #2768: an auth failure starts a timed backoff that keeps the network untouched and keeps the URL of
// published content. Dispatcher only; cases live in feature-2768-plan-sync-turn-commit/auth.js.

// TL3 gap (what this test does NOT catch), category: hook-registration
// - a real ssh agent's or forge's auth failure wording (an ssh stub stands in)
// - the wall-clock length of a real backoff (the clock is injected)
// - whether the model actually relays the breadcrumb (no live model is driven)

const { caseBegin, caseEnd, isolate } = require("../lib/harness");

const restore = isolate();
const F = require("../lib/plan-sync-turn-fixture");
const go = (name, fn) => F.guard(`${name}.${fn || "run"}`, () => require(`./feature-2768-plan-sync-turn-commit/${name}`)[fn || "run"](F));

try {
caseBegin("auth backoff", "hooks/lib/plan-sync/commit-push.js");
  go("auth");
caseEnd();
caseBegin("A8b redactText masks scp-form userinfo", "hooks/lib/plan-sync/remote-url.js");
  go("auth", "redact");
caseEnd();
} finally {
  F.finish();
  restore();
}
