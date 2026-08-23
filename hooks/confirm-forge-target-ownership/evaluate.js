// Command-line evaluation for the forge-target-ownership guard: reads a command
// line the way the shell would and records, per segment, whether the forge target
// is proven. Entrypoint-private to confirm-forge-target-ownership.js.
"use strict";

const { parse } = require("../lib/command-ir");
const { commandBasename } = require("../lib/bash-write-patterns/segment-utils");
const {
  normalizeToLines,
  nestedBodyOf,
  mentionsForgeWrite,
  substitutionBodiesOf,
  hasAnsicSpan,
} = require("./nested-commands");
const { authCausesOfSegment } = require("./auth-context");
const { ghScopeOf, argvHidesForgeWrite, ansicPositionIssue, unrecognizedWrapperHead, ANSIC_ARG_INERT_HEADS } = require("./detect");

// Commands whose arguments are read as literal data, never as something they
// execute — a commit message, an echoed string, a grep pattern can spell out
// "gh issue create" without the segment doing anything of the kind. Reusing
// the audited ANSIC_ARG_INERT_HEADS set keeps this list in one place; git is
// added here only because its own arguments carry the same inert-text shape
// (commit -m, log --grep, ...), not because git as a whole is trusted.
const OPAQUE_HEAD_EXEMPT = new Set([...ANSIC_ARG_INERT_HEADS, "git"]);
const { proveOwned, ghLogin } = require("./prove-ownership");
const {
  resolveTarget,
  hostSelector,
  hostSelectorIsGithub,
  hostIsGithub,
  repoSelectors,
} = require("./resolve-target");
const { NO_AUTH_EFFECTS, lookupEnv, applyEnvEffects, applyAuthEffects } = require("./env-scope");
const {
  conditionalSeparators,
  segmentGuarantees,
  effectiveOf,
  relocatesCwd,
  headIsDynamic,
} = require("./segment-shape");

const GITHUB = "github.com";
const ENV_BLOCKING_ASSIGN_RE = /^(GH_|GITHUB_|HTTP_PROXY|HTTPS_PROXY|NO_PROXY)/;

function addCode(state, code) {
  if (state.codes.indexOf(code) === -1) state.codes.push(code);
}

function addTarget(state, text) {
  if (state.targets.indexOf(text) === -1) state.targets.push(text);
}

// The gh host in force for this segment. An observed-but-unreadable value is a
// distinct answer from an absent one: it proves a host was chosen and proves the
// guard cannot say which.
function hostVerdict(state, seg, effArgv, effArgvRaw) {
  const env = lookupEnv(state, seg, "GH_HOST");
  if (env.present && !env.readable) return { ok: false, why: "GH_HOST is set to a value the guard cannot read" };
  if (env.present && !hostIsGithub(env.value)) {
    return { ok: false, why: "GH_HOST points at " + String(env.value).trim() + ", which is not github.com" };
  }
  const sel = hostSelector(effArgv, effArgvRaw);
  if (!hostSelectorIsGithub(sel)) {
    return { ok: false, why: "--hostname does not resolve to github.com, so the target forge is not github.com" };
  }
  return { ok: true, host: GITHUB };
}

function evaluateClaimed(state, seg, claim, effArgv, effArgvRaw, authCauses) {
  if (state.authMutated || authCauses.segment.length > 0 || authCauses.persistent.length > 0) {
    addCode(state, "auth-context-change");
    return;
  }
  ghLogin(state.budget, state.ctx);
  const host = hostVerdict(state, seg, effArgv, effArgvRaw);
  if (!host.ok) { addTarget(state, host.why); return; }
  const selectors = repoSelectors(effArgv, effArgvRaw);
  const apiTarget = claim.kind === "api" ? claim.target : null;
  const ghRepo = selectors.length === 0 && !apiTarget ? lookupEnv(state, seg, "GH_REPO") : { present: false };
  const verdict = resolveTarget({
    selectors,
    rawText: typeof seg.rawText === "string" ? seg.rawText : "",
    apiTarget,
    apiInScope: claim.kind === "api" && !apiTarget,
    ghRepo,
    cwd: state.cwd,
    cwdAllowed: state.cwdAllowed && selectors.length === 0 && !apiTarget,
    budget: state.budget,
  });
  if (verdict.kind === "unresolved") { addTarget(state, verdict.why); return; }
  if (!proveOwned(verdict.ownerRepo, state.budget, state.ctx)) {
    addTarget(state, verdict.ownerRepo + " is not proven to be owned by the authenticated account");
  }
}

function evaluateSegment(state, seg, depth, guaranteed) {
  const authCauses = authCausesOfSegment(seg);
  // Only a segment normal control flow is bound to reach may write to the
  // persistent auth record; the rest are read for THIS decision only.
  const effects = guaranteed ? authCauses : NO_AUTH_EFFECTS;
  applyEnvEffects(state, seg, guaranteed);
  const eff = effectiveOf(seg);
  // An ANSI-C span anywhere up to and including the command word hides what runs
  // — the command itself, an inline assignment, a wrapper's own option. The same
  // span AFTER the command word is only fatal for a segment the guard cannot
  // otherwise resolve: a claimed gh write is resolved by its selectors, and a
  // tab inside an issue title is not a question about the target.
  if (eff.prefixRaw.some(hasAnsicSpan)) {
    addCode(state, "ansic-span");
    applyAuthEffects(state, effects);
    return;
  }
  if (relocatesCwd(seg)) {
    addTarget(state, "the command relocates its own working directory, so the target it resolves is not the one the guard can see");
    applyAuthEffects(state, effects);
    return;
  }
  if (headIsDynamic(eff)) {
    addTarget(state, "the command word is resolved at run time, so the guard cannot read what this segment executes");
    applyAuthEffects(state, effects);
    return;
  }
  const effCmd0 = eff.cmd0;
  const effArgv = eff.argv;
  const effArgvRaw = eff.argvRaw;
  const rawText = typeof seg.rawText === "string" ? seg.rawText : "";
  const sel = hostSelector(effArgv, effArgvRaw);
  if (commandBasename(effCmd0) === "gh" && !hostSelectorIsGithub(sel) && mentionsForgeWrite(rawText)) {
    addTarget(state, "--hostname does not resolve to github.com, so the target forge is not github.com");
    applyAuthEffects(state, effects);
    return;
  }
  const claim = ghScopeOf(effCmd0, effArgv, effArgvRaw, rawText);
  // A gh subcommand word that is not one gh itself defines is a user alias, and
  // an alias expands to whatever its owner put in it — including `issue create`
  // against another repository. The name proves nothing, so it resolves nothing.
  if (claim && claim.kind === "unrecognized-verb") {
    addTarget(state, "gh is invoked with a subcommand the guard does not recognize, so it may be an alias that expands to a forge write");
    applyAuthEffects(state, effects);
    return;
  }
  if (claim) {
    evaluateClaimed(state, seg, claim, effArgv, effArgvRaw, authCauses);
    applyAuthEffects(state, effects);
    return;
  }
  if (ansicPositionIssue(seg)) { addCode(state, "ansic-span"); applyAuthEffects(state, effects); return; }
  const body = nestedBodyOf(seg, depth);
  if (body.kind === "unresolved") addCode(state, body.reason);
  else if (body.kind === "resolved") evaluateBody(state, body.body, depth + 1, guaranteed);
  let argvScanCounted = false;
  if (body.kind === "none" && argvHidesForgeWrite(seg, effCmd0)) {
    addCode(state, "unrecognized-wrapper-head");
    argvScanCounted = true;
  }
  // A command word that is neither gh nor anything the guard models — a shell
  // alias, a function, a script — says nothing about what it runs. Silence is
  // not evidence of no forge write when the segment's own text still spells one
  // out, so the opaque head is read exactly like an unmodeled wrapper head.
  const opaqueHead = body.kind === "none" && !argvScanCounted &&
    commandBasename(effCmd0) !== "gh" && !OPAQUE_HEAD_EXEMPT.has(commandBasename(effCmd0));
  const wrapperHead = unrecognizedWrapperHead({ claimed: false, bodyState: body.kind, argvScanCounted, seg });
  if ((wrapperHead || opaqueHead) && mentionsForgeWrite(rawText)) {
    addCode(state, "unrecognized-wrapper-head");
  }
  applyAuthEffects(state, effects);
}

// A command substitution runs a command of its own, in the same shell, before the
// outer command does. It is evaluated even for a line that is already claimed —
// the outer target says nothing about what the inner one writes to.
function evaluateSubstitutions(state, line) {
  const subs = substitutionBodiesOf(line);
  for (const body of subs.bodies) {
    if (mentionsForgeWrite(body)) { addCode(state, "command-substitution-body"); return; }
  }
  if (subs.openers > subs.bodies.length && mentionsForgeWrite(line)) {
    addCode(state, "command-substitution-body");
  }
}

function evaluateLine(state, line, depth, guaranteed) {
  evaluateSubstitutions(state, line);
  let ir = null;
  try { ir = parse(line); } catch (_e) { ir = null; }
  if (!ir || ir.parseFailure) {
    if (mentionsForgeWrite(line)) addCode(state, "unmodeled-body-quoting");
    return;
  }
  const reached = guaranteed !== false;
  const segments = ir.segments || [];
  const perSegment = segmentGuarantees(ir, line);
  const conditional = perSegment ? false : conditionalSeparators(ir);
  for (let i = 0; i < segments.length; i++) {
    const own = perSegment ? perSegment[i] : (i === 0 || !conditional);
    evaluateSegment(state, segments[i], depth, reached && own);
  }
}

function evaluateBody(state, body, depth, guaranteed) {
  const outerCwd = state.cwdAllowed;
  state.cwdAllowed = false;
  const norm = normalizeToLines(body);
  if (!norm.ok && norm.reason) addCode(state, norm.reason);
  for (const line of norm.lines) evaluateLine(state, line, depth, guaranteed);
  state.cwdAllowed = outerCwd;
}

module.exports = {
  evaluateLine,
  evaluateBody,
  addCode,
  addTarget,
  GITHUB,
  ENV_BLOCKING_ASSIGN_RE,
};
