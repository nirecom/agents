"use strict";
// Correspondence table between exemption primitives and consumer policies
// (SSOT / declarative-only). This module makes no decisions — each consumer
// composes its own gate internally. Adding a condition: (1) define one
// primitive, (2) add one row here, (3) register it in the policy of every
// consumer whose column is true. Forgetting (3) is a silent asymmetry
// (CPR-ORTH violation) — tests cross-check this table against each consumer's
// actual implementation.
const EXEMPTION_MATRIX = Object.freeze({
  "workflow-off":      { c4: true,  c2: false, nextStep: true  },
  "next-step-paused":  { c4: true,  c2: false, nextStep: true  },
  // c2:true — C2 gates only the workflow_init-complete boundary; nextStep:false —
  // next-step correctly returns ACTION=invoke workflow-init pre-init, which is
  // the intended CLAUDE.md behavior. Only the Stop hook's forced nudge is silenced.
  "pre-workflow-init": { c4: true,  c2: true,  nextStep: false },
  // Covers write_code AND the #2013 delegated-step allowlist. nextStep:false —
  // a DELIBERATE difference from the retired TTL-marker row, on the same logic
  // as pre-workflow-init: next-step returning ACTION=invoke while the step runs
  // is correct guidance, so only the Stop hook's forced nudge is silenced.
  // c2:false — a long turn must not defer a scheduled supervisor review.
  "step-in-flight": { c4: true, c2: false, nextStep: false },
  "delegated-reason":  { c4: true,  c2: false, nextStep: false },
});

module.exports = { EXEMPTION_MATRIX };
