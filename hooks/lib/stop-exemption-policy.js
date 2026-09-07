"use strict";
// Correspondence table between exemption primitives and consumer policies
// (SSOT / declarative-only). Adding a condition: (1) define one primitive,
// (2) add one row here, (3) register it in every consumer whose column is
// true — tests cross-check this table against each consumer's implementation.
// Columns: c4 (Stop premature-stop guard), c2 (Stop scheduled-review guard),
// nextStep (bin/workflow/next-step recommendation), promptNotify (the
// UserPromptSubmit notifier hooks/user-prompt-submit-mechanism-check.js, #2169).
const EXEMPTION_MATRIX = Object.freeze({
  "workflow-off":      { c4: true,  c2: false, nextStep: true,  promptNotify: false },
  "next-step-paused":  { c4: true,  c2: false, nextStep: true,  promptNotify: false },
  // nextStep:false — next-step's own ACTION=invoke workflow-init guidance is
  // correct pre-init; only the Stop hook's forced nudge is silenced.
  // promptNotify:true (#2169) — a session lacking /workflow-init is the
  // ordinary not-yet-started case, not a mechanism failure.
  "pre-workflow-init": { c4: true,  c2: true,  nextStep: false, promptNotify: true  },
  // Covers write_code and the #2013 delegated-step allowlist.
  // promptNotify:false — out of #2169's scope: a started session's allowlisted
  // step overrunning its TTL still gets notified every prompt, unchanged.
  "step-in-flight": { c4: true, c2: false, nextStep: false, promptNotify: false },
  // promptNotify:false — this primitive only exists once next-step has spoken;
  // the UserPromptSubmit notifier never invokes next-step, so it can't occur.
  "delegated-reason":  { c4: true,  c2: false, nextStep: false, promptNotify: false },
});

module.exports = { EXEMPTION_MATRIX };
