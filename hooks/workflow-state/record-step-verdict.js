"use strict";
// The single DECLARED-class writer for workflow step status (#1644).
//
// Why: markStep() has two kinds of caller. Class O (observed) callers each own an
// evidence predicate and record what the process itself saw. Class D (declared)
// callers record what somebody ASSERTED — a *_NOT_NEEDED sentinel, a --mark
// recovery call, a CLI --advance. Every Class D caller must apply the same
// prohibitions, the same approval invariant and the same A-4 co-write, so those
// rules are stated exactly once here and nowhere else.
//
// recordStepVerdict(sessionId, step, status, opts) -> { ok, code, message, already }
//   code 0  recorded (or already in that state — see `already`)
//   code 1  argument validation failure
//   code 2  record failure: write error, missing approval, or a step the
//           declaring path is forbidden to complete
//   code 3  skip refused by the skip-allowance policy
//
// This module decides from RECORDED FACTS only (state files + config files). It
// never reads model-authored plan prose.

const {
  VALID_STEPS,
  VALID_STATUSES,
  markStep,
  readState,
  appendEvents,
  recordSkipVerdict,
  getSkippableSteps,
} = require("../workflow-state");
const {
  APPROVAL_GATED_STEPS,
  UnapprovedCompletionError,
  confirmSentinelFor,
} = require("./completion-approval");
const { isSkipAllowedForCliPath } = require("./plan-skip-allowance");
const { validateSkipReason } = require("../workflow-mark/skip-reason");

// ---- exported discriminators ----------------------------------------------

// The ONLY discriminator for "which gate set applies". Closed enum; an unknown
// value throws rather than silently selecting the most permissive branch.
// Never persisted — `provenance` / `origin` are the persisted audit fields.
const GATES = ["sentinel", "advance", "mark", "reset", "recorded-verdict"];

// `origin` is a free-form AUDIT string. It tells a reader WHICH declaration route
// wrote a fact. It is never used to decide policy (that is what `gate` is for):
// a free string that every existing route already shares cannot carry authority.
const ADVANCE_ORIGINS = {
  "next-step": "next-step-advance",
  "record-skip-judgment": "record-skip-judgment-advance",
  "set-workflow-type": "set-workflow-type-advance",
  "record-complexity-and-skip": "record-complexity-and-skip-advance",
};

// The A-4 pass discriminator (#1286): a skip_reason carrying this prefix was
// authorized by a recorded orchestrator judgment, not by model-authored text.
// verdict.js imports it instead of re-spelling the literal.
const RECORDED_VERDICT_PREFIX = "recorded-verdict:";
const RECORDED_VERDICT_REASONS = {
  outline: RECORDED_VERDICT_PREFIX + " so_c1+so_c2 met",
  detail: RECORDED_VERDICT_PREFIX + " sd_c1+sd_c2+sd_c3 met",
};

// Steps a declaring caller may never complete. Each is guarded elsewhere by an
// ask-gated or evidence-carrying route; a declaration must not route around it.
const MANUAL_MARK_FORBIDDEN = ["user_verification", "review_tests", "docs"];

// The sentinel literal to name in the refusal diagnostic, per step.
const REPLACEMENT_SENTINEL = {
  user_verification: "WORKFLOW_USER_VERIFIED",
  review_tests: "WORKFLOW_WRITE_TESTS_NOT_NEEDED",
  docs: "(no skip path — stage docs/ or *.md changes)",
  clarify_intent: "WORKFLOW_CLARIFY_INTENT_NOT_NEEDED",
  review_security: "WORKFLOW_REVIEW_SECURITY_NOT_NEEDED",
  write_tests: "WORKFLOW_WRITE_TESTS_NOT_NEEDED",
  run_tests: "WORKFLOW_RUN_TESTS_NOT_NEEDED",
};

// Gates that own the *_NOT_NEEDED-equivalent side effects (#833 symmetric
// propagation, the workflow_init downstream reset). `mark` / `reset` /
// `recorded-verdict` deliberately keep their current, narrower behaviour so
// their stdout and side effects stay byte-identical to today.
const DECLARING_GATES = ["sentinel", "advance"];

// Steps whose OUTCOME axis a settled declaration also settles (#1665 / R4).
//
// WHY (CPR-WPH): `run_tests` carries a second axis, `run_outcome`, written by the
// PostToolUse hook from what it observed. Settling the STATUS without settling
// the OUTCOME leaves the two axes describing different runs — a `skipped` step
// keeping an older `run_outcome: "fail"` masks every downstream step forever.
//
// CPR-UNV: the general rule ("every sentinel/CLI-sourced status is `declared`")
// is the truer one, but it changes the audit semantics of every step and is out
// of scope for #1665. The exception is isolated behind this named constant
// rather than spread through the branch below; generalising it is a separate
// issue.
const DECLARED_OUTCOME_STEPS = ["run_tests"];

// ---- helpers ---------------------------------------------------------------

// `kind` lets a caller that owns its own user-facing wording (the sentinel
// handlers) rebuild its existing message from the same decision, without this
// module having to know that wording. `detail` carries the underlying error
// code / message those wordings interpolate.
function fail(code, message, kind, detail) {
  return { ok: false, code, message, already: false, kind: kind || "refused", detail: detail || "" };
}

function readStepEntry(sessionId, step) {
  try {
    const state = readState(sessionId);
    if (!state || !state.steps) return null;
    return state.steps[step] || null;
  } catch (_) {
    return null;
  }
}

// D1 defense (#1147 T0-A) + the SKIPPABLE_STEPS constraint, in one predicate.
// getSkippableSteps() removes write_tests / review_tests for BUGFIX sessions, so
// "BUGFIX sessions must write tests" is enforced on every declaring path — the
// sentinel door included — rather than only where someone remembered to check.
function checkSkippableConstraint(sessionId, step) {
  let skippable;
  try {
    skippable = getSkippableSteps(sessionId);
  } catch (_) {
    skippable = [];
  }
  if (!Array.isArray(skippable) || skippable.indexOf(step) === -1) {
    return fail(
      3,
      `record-step-verdict: ${step} cannot be skipped — it is outside this session's skippable steps.`,
      "not-skippable"
    );
  }
  return { ok: true, code: 0 };
}

// H2 hardening, generalized to every evidence read this module performs on the
// advance gate (not just the run_tests docs-only proof): resolve the repo root
// strictly from git's own view of the real process cwd — never from
// process.env — so a forged CLAUDE_PROJECT_DIR prefix on a model-issued Bash
// command (`CLAUDE_PROJECT_DIR=<forged-dir> node bin/workflow/next-step
// --advance ...`) cannot redirect an evidence check to a directory of the
// model's own choosing. Returns null (fail-closed for the caller) when the
// process is not inside a git work tree.
function resolveTrustedRepoDir() {
  try {
    const { execFileSync } = require("child_process");
    const out = execFileSync("git", ["rev-parse", "--show-toplevel"], {
      encoding: "utf8",
      timeout: 5000,
      stdio: ["pipe", "pipe", "pipe"],
    });
    const dir = out.trim();
    return dir || null;
  } catch (_) {
    return null;
  }
}

// Skip-allowance table (#1644) for the CLI forward operation. Applied only on the
// advance gate: the sentinel door's own approval routes (settings.json ask rules
// plus gate-plan-skip-sentinel.js) are what admit clarify_intent / review_security
// there, and the CLI has no equivalent of them.
function checkSkipAllowance(sessionId, step, opts) {
  switch (step) {
    // Human approval never gated these two: research is settings.json allow, and
    // cleanup's documented main path is an unconditional MARK_STEP sentinel.
    case "research":
    case "cleanup":
      return { ok: true, code: 0 };
    // Approval-gated pair, deliberately left unconditional on THIS gate.
    // KNOWN GAP (tracked as a follow-up, symmetric to plan-skip-allowance.js's
    // own documented MED-1 CONFIRM_TESTS/AGENTS_CONFIG_DIR boundary): the
    // comment this replaced claimed "the real safety device is the A-4 verdict
    // co-written below" — that is not true today. recordSkipVerdict() below
    // writes skip_verdict.verdict="pending", but no gate anywhere in this
    // codebase (workflow-gate.js's commit gate included) reads
    // hasSpeculativeSkipPending() to block progress on an unresolved pending
    // verdict, so the co-write is an audit annotation, not an enforcement
    // point. A prior pass in this session made this gate call
    // isSkipAllowedForCliPath(), matching the write_tests case below — that
    // change was reverted: the parity contract this session's own tests pin
    // (feature-1644-advance-transaction/projection.sh A7-skip / A14, and the
    // C3/C6 CLI-subprocess suites) exercises exactly this unconditional path
    // as their control/baseline across ~10+ cases, so tightening it here is a
    // coordinated CLI-door-vs-sentinel-door redesign, not a local fix. File a
    // follow-up issue instead of re-attempting the local patch.
    case "outline":
    case "detail":
      return { ok: true, code: 0 };
    case "write_tests":
      if (!isSkipAllowedForCliPath(sessionId, "write_tests")) {
        return fail(
          3,
          "record-step-verdict: write_tests skip refused — set CONFIRM_TESTS=off in the agents " +
            "config FILE (an inline environment prefix is not accepted), or ask the user and emit: " +
            `echo "<<${REPLACEMENT_SENTINEL.write_tests}: {reason}>>"`
        );
      }
      return { ok: true, code: 0 };
    // Docs-only is a machine-verifiable fact, so the CLI door can verify it for
    // itself — the same predicate the sentinel door checks, same single owner.
    case "run_tests": {
      let docsOnly = false;
      try {
        const { isDocsOnlyStaged } = require("../workflow-gate/staged-evidence");
        // H2 hardening: do NOT use opts.repoDir here. It flows from the CLI
        // door's resolveRepoDir() (bin/workflow/lib/next-step/repo-dir.js),
        // which trusts process.env.CLAUDE_PROJECT_DIR — a model-issued Bash
        // command can shadow that var as an inline prefix on the very command
        // that runs this check (`CLAUDE_PROJECT_DIR=<forged-dir> node
        // bin/workflow/next-step --advance ...`), pointing the docs-only proof
        // at a directory of the model's own choosing. Same trust boundary
        // already hardened for CONFIRM_* on this CLI door (see the header
        // comment in ./plan-skip-allowance.js): admissible input here is git's
        // own resolution of the real process cwd, never process.env.
        const trustedRepoDir = resolveTrustedRepoDir();
        docsOnly = trustedRepoDir !== null && isDocsOnlyStaged(trustedRepoDir) === true;
      } catch (_) {
        docsOnly = false;
      }
      if (!docsOnly) {
        return fail(
          3,
          "record-step-verdict: run_tests skip refused — the staged set is not human-facing " +
            "docs only. Run the tests, or stage a docs-only set and emit: " +
            `echo "<<${REPLACEMENT_SENTINEL.run_tests}: {reason}>>"`
        );
      }
      return { ok: true, code: 0 };
    }
    // No direct skip sentinel exists; review_tests only becomes skipped through
    // the #833 symmetric propagation from a write_tests skip.
    case "review_tests":
      return fail(
        3,
        "record-step-verdict: review_tests cannot be skipped directly — it follows write_tests. " +
          `Emit: echo "<<${REPLACEMENT_SENTINEL.review_tests}: {reason}>>"`
      );
    // No CLI-side equivalent of their ask-gated approval exists, so the skip is
    // simply not reproducible here. Name the sentinel the user must approve.
    case "clarify_intent":
    case "review_security":
      return fail(
        3,
        `record-step-verdict: ${step} skip refused — no CLI-side approval route exists. ` +
          `Ask the user and emit: echo "<<${REPLACEMENT_SENTINEL[step]}: {reason}>>"`
      );
    default:
      return fail(3, `record-step-verdict: ${step} skip refused — no declared-path skip route exists.`);
  }
}

// workflow_init completing signals a new workflow run on this session UUID. Reset
// all downstream steps to pending so stale state from a prior run cannot trigger
// next-step's inconsistency abort (#1068). Same batch shape as the RESET_FROM
// rollback (CPR-ORTH): an annotation tombstone plus a declared pending status per
// step, appended rather than rewritten. Top-level fields are never rebuilt.
function resetDownstreamOfWorkflowInit(sessionId) {
  if (!readState(sessionId)) return;
  appendEvents(sessionId, () => {
    const events = [];
    for (const s of VALID_STEPS) {
      if (s === "workflow_init") continue;
      events.push({
        kind: "step_annotations_cleared",
        step: s,
        provenance: "declared",
        origin: "workflow-init-downstream-reset",
      });
      events.push({
        kind: "step_status",
        step: s,
        status: "pending",
        provenance: "declared",
        origin: "workflow-init-downstream-reset",
      });
    }
    return events;
  });
}

// ---- the writer ------------------------------------------------------------

function recordStepVerdict(sessionId, step, status, opts = {}) {
  const gate = opts.gate;
  if (GATES.indexOf(gate) === -1) {
    throw new Error(
      "recordStepVerdict: unknown gate " + JSON.stringify(gate) +
        " — must be one of " + GATES.join(", ")
    );
  }
  const isAdvance = gate === "advance";

  if (!sessionId) {
    return fail(2, "record-step-verdict: could not resolve session id — nothing recorded.");
  }
  if (VALID_STEPS.indexOf(step) === -1) {
    return fail(1, `record-step-verdict: unknown step "${step}".`);
  }
  if (VALID_STATUSES.indexOf(status) === -1) {
    return fail(1, `record-step-verdict: unknown status "${status}".`);
  }
  // A forward operation settles a step by definition, and in_progress settles
  // nothing. Deliberately stricter than the MARK_STEP sentinel path.
  // Example of that asymmetry (#1665): write_code reaches in_progress only via
  // the MARK_STEP sentinel /write-code emits, never via --advance.
  if (isAdvance && status === "in_progress") {
    return fail(1, "record-step-verdict: --status in_progress is not a forward operation.");
  }

  // Idempotent repeat — ADVANCE GATE ONLY. Returning before the write is what
  // keeps a re-issued --advance from re-firing the workflow_init downstream reset
  // or overwriting an A-4 verdict that skip-verifier has since resolved.
  // The sentinel/mark/reset/recorded-verdict gates deliberately keep their
  // pre-#1644 re-write behaviour: re-emitting a NOT_NEEDED sentinel with a new
  // reason must still replace the recorded skip_reason (migration note 5).
  if (isAdvance) {
    const existing = readStepEntry(sessionId, step);
    if (existing && existing.status === status) {
      return { ok: true, code: 0, message: "", already: true };
    }
  }

  // --- gate set: declared completion -------------------------------------
  if (isAdvance && status === "complete") {
    if (MANUAL_MARK_FORBIDDEN.indexOf(step) !== -1) {
      return fail(
        2,
        `record-step-verdict: ${step} cannot be completed by a declaration. ` +
          `Use its own route: ${REPLACEMENT_SENTINEL[step]}`
      );
    }
    if (step === "write_tests") {
      let hasEvidence = false;
      try {
        const { hasCompletionEvidence } = require("./evidence-resolver");
        // H2 hardening, same reasoning as the run_tests docs-only proof above:
        // this block runs only on the advance gate (isAdvance), so opts.repoDir
        // is the CLI door's resolveRepoDir() output, which trusts a forgeable
        // CLAUDE_PROJECT_DIR. Use the trusted git-derived root instead — never
        // opts.repoDir — so a forged prefix cannot manufacture write_tests
        // completion evidence from an unrelated directory.
        const trustedRepoDir = resolveTrustedRepoDir();
        hasEvidence = trustedRepoDir !== null &&
          hasCompletionEvidence("write_tests", sessionId, { repoDir: trustedRepoDir }) === true;
      } catch (_) {
        hasEvidence = false;
      }
      if (!hasEvidence) {
        return fail(
          2,
          "record-step-verdict: write_tests cannot be completed without test evidence — " +
            "stage tests/ changes, or declare it not needed: " +
            `echo "<<${REPLACEMENT_SENTINEL.write_tests}: {reason}>>"`
        );
      }
    }
  }

  // --- gate set: declared skip -------------------------------------------
  let skipReason = opts.skipReason;
  if (status === "skipped" && DECLARING_GATES.indexOf(gate) !== -1) {
    // review_tests reaches here only through the #833 co-write below, which is
    // this module's own consequence of an already-permitted write_tests skip —
    // not a fresh declaration — so it is exempt from both checks.
    if (step !== "review_tests") {
      const skippable = checkSkippableConstraint(sessionId, step);
      if (!skippable.ok) return skippable;
    }
    if (isAdvance) {
      const v = validateSkipReason(skipReason);
      if (!v.ok) {
        return fail(1, "record-step-verdict: " + v.msg);
      }
      skipReason = v.reason;
      const allowance = checkSkipAllowance(sessionId, step, { repoDir: opts.repoDir });
      if (!allowance.ok) return allowance;
    }
  }

  const extraFields = {};
  if (typeof skipReason === "string" && skipReason !== "") extraFields.skip_reason = skipReason;
  if (opts.skipJudgment) extraFields.skip_judgment = opts.skipJudgment;

  // A SETTLED transition settles the outcome too; an UNSETTLED one leaves it
  // strictly alone: `pending` / `in_progress` carrying `run_outcome: "fail"` is
  // the very evidence the re-open rests on, and RNT-9's
  // WORKFLOW_MARK_STEP_run_tests_pending is a status-only idempotent
  // re-affirmation that must not erase what the hook observed.
  let declaredOutcome = false;
  if (DECLARED_OUTCOME_STEPS.indexOf(step) !== -1) {
    if (status === "complete") {
      // A claim, not a measurement — hence the pinned `declared` provenance,
      // which stays inside GENUINE_PROVENANCE so completion audits are unchanged.
      extraFields.run_outcome = "pass";
      declaredOutcome = true;
    } else if (status === "skipped") {
      extraFields.run_outcome = null;  // tombstone: no run, so no outcome
    }
  }

  const writeOpts = {};
  if (typeof opts.provenance === "string") writeOpts.provenance = opts.provenance;
  if (declaredOutcome) writeOpts.provenance = "declared";
  if (typeof opts.origin === "string") writeOpts.origin = opts.origin;

  try {
    markStep(sessionId, step, status, extraFields, writeOpts);
  } catch (e) {
    if (e instanceof UnapprovedCompletionError) {
      return fail(
        2,
        `record-step-verdict: ${step} NOT recorded — no user approval on record (${e.code}). ` +
          `Ask the user to approve, then emit: echo "<<${confirmSentinelFor(step)}: {summary}>>" ` +
          `(or verify CONFIRM_${step.toUpperCase()}=off in your config).`,
        "unapproved",
        e.code
      );
    }
    return fail(
      2,
      `record-step-verdict: failed to write state — ${e.message}. ${step} NOT recorded.`,
      "write-failed",
      e.message
    );
  }

  // --- co-written facts owned by the same writer --------------------------
  if (status === "skipped" && APPROVAL_GATED_STEPS.indexOf(step) !== -1) {
    // A-4 (#1681): a skip of an approval-gated step is speculative until
    // skip-verifier resolves it. Dropping this co-write is the single regression
    // that would make such a skip final without review.
    try {
      const source = typeof opts.skipVerdictSource === "string" && opts.skipVerdictSource !== ""
        ? opts.skipVerdictSource
        : (isAdvance ? "advance" : "sentinel");
      recordSkipVerdict(sessionId, step, "pending", source);
    } catch (_) { /* fail-open: the status write already landed */ }
  }

  if (
    status === "skipped" &&
    step === "write_tests" &&
    DECLARING_GATES.indexOf(gate) !== -1
  ) {
    // Symmetric skip propagation (#833): review_tests is paired with write_tests.
    // If there are no tests to write, there are no tests to review.
    try {
      markStepSymmetricReviewTests(sessionId, skipReason, writeOpts);
    } catch (_) { /* fail-open: write_tests is already recorded */ }
  }

  if (status === "complete" && step === "workflow_init" && DECLARING_GATES.indexOf(gate) !== -1) {
    try {
      resetDownstreamOfWorkflowInit(sessionId);
    } catch (e) {
      // The status write already landed; only the reset failed. Report it as a
      // successful record carrying a diagnostic, never as a failed record.
      return {
        ok: true,
        code: 0,
        message: "",
        already: false,
        kind: "downstream-reset-failed",
        detail: e.message,
      };
    }
  }

  return { ok: true, code: 0, message: "", already: false };
}

// Kept as its own function so the single-writer guard can see exactly one
// markStep call site in this module: this one re-enters recordStepVerdict rather
// than calling markStep a second time.
function markStepSymmetricReviewTests(sessionId, reason, writeOpts) {
  const res = recordStepVerdict(sessionId, "review_tests", "skipped", {
    gate: "sentinel",
    provenance: writeOpts.provenance,
    origin: writeOpts.origin,
    skipReason: `(symmetric: write_tests not needed) ${reason}`,
  });
  return res;
}

module.exports = {
  recordStepVerdict,
  GATES,
  ADVANCE_ORIGINS,
  RECORDED_VERDICT_PREFIX,
  RECORDED_VERDICT_REASONS,
  MANUAL_MARK_FORBIDDEN,
  REPLACEMENT_SENTINEL,
};
