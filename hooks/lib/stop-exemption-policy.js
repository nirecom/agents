"use strict";
// Correspondence table between exemption primitives and consumer policies
// (SSOT / declarative-only). This module makes no decisions — each consumer
// composes its own gate internally. Adding a condition: (1) define one
// primitive, (2) add one row here, (3) register it in the policy of every
// consumer whose column is true. Forgetting (3) is a silent asymmetry
// (CPR-ORTH violation) — tests cross-check this table against each consumer's
// actual implementation.
// Columns: c4 (Stop premature-stop guard), c2 (Stop scheduled-review guard),
// nextStep (bin/workflow/next-step recommendation), promptNotify (the
// UserPromptSubmit notifier hooks/user-prompt-submit-mechanism-check.js, #2169).
const EXEMPTION_MATRIX = Object.freeze({
  "workflow-off":      { c4: true,  c2: false, nextStep: true,  promptNotify: false },
  "next-step-paused":  { c4: true,  c2: false, nextStep: true,  promptNotify: false },
  // c2:true — C2 gates only the workflow_init-complete boundary; nextStep:false —
  // next-step correctly returns ACTION=invoke workflow-init pre-init, which is
  // the intended CLAUDE.md behavior. Only the Stop hook's forced nudge is silenced.
  // promptNotify:true (#2169) — a session that has not genuinely started the
  // workflow (isWorkflowStarted()===false) is the ordinary "no /workflow-init
  // yet" case, not a mechanism failure; a WI-10 lookahead dispatch marks
  // `research` in_progress in this state, and once that marker crosses the
  // 4h TTL the notifier must not keep re-injecting a stalled-mechanism message
  // into every prompt of a session workflow never actually owns.
  "pre-workflow-init": { c4: true,  c2: true,  nextStep: false, promptNotify: true  },
  // Covers write_code AND the #2013 delegated-step allowlist. nextStep:false —
  // a DELIBERATE difference from the retired TTL-marker row, on the same logic
  // as pre-workflow-init: next-step returning ACTION=invoke while the step runs
  // is correct guidance, so only the Stop hook's forced nudge is silenced.
  // c2:false — a long turn must not defer a scheduled supervisor review.
  // promptNotify:false (#2169) — deliberately OUT OF SCOPE: #2169 fixes only the
  // pre-workflow-init false positive. A genuinely-started session whose
  // allowlisted step overruns the TTL keeps being notified every prompt, same
  // as before this change (see intent.md Accepted Tradeoffs — re-notification
  // frequency for started sessions is unchanged by design).
  "step-in-flight": { c4: true, c2: false, nextStep: false, promptNotify: false },
  // promptNotify:false (#2169) — phase=next-step-output: this row only exists
  // once bin/workflow/next-step has spoken. The UserPromptSubmit notifier never
  // invokes next-step, so this primitive is structurally unreachable from it —
  // the same reason `delegated-reason` is unreachable from C2 (see
  // tests/feature-1794-stop-guard-exemptions/m-policy-matrix.sh M3-a comment).
  "delegated-reason":  { c4: true,  c2: false, nextStep: false, promptNotify: false },
});

module.exports = { EXEMPTION_MATRIX };
