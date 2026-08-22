#!/usr/bin/env node
// Claude Code PreToolUse hook: confirm the OWNER of the repository a forge write
// is about to land in. Filing an issue in someone else's repository is a public,
// unretractable act, and `gh issue create` in the wrong working directory does
// it silently. So this guard asks one question — is the target proven to belong
// to the authenticated user? — and prompts on any answer but yes.
// Coverage boundary: the Bash / runInTerminal / runCommands payloads only. A gh
// call from another shell or the web UI never reaches here, so the guard treats
// an unreadable command as unresolved, never as safe — codes in reasons.js.

// It never BLOCKS: every decision is `ask`, and the hook always exits 0, because
// a guard that crashes the tool call it protects has failed twice.
"use strict";

const fs = require("fs");
const { isCommandTool, commandListOf } = require("./lib/tool-command-text");
const { parse } = require("./lib/command-ir");
const segmentUtils = require("./lib/bash-write-patterns/segment-utils");
const { commandBasename, ASSIGN_RE } = segmentUtils;
const { reasonText, REASON_CODES } = require("./confirm-forge-target-ownership/reasons");
const { createBudget } = require("./confirm-forge-target-ownership/budget");
const {
  normalizeToLines,
  nestedBodyOf,
  mentionsForgeWrite,
  substitutionBodiesOf,
  hasAnsicSpan,
} = require("./confirm-forge-target-ownership/nested-commands");
const { ghEnvOfSegment, loadSessionGhEnv, saveSessionGhEnv } = require("./confirm-forge-target-ownership/gh-env-state");
const { authCausesOfSegment, loadDirty, saveDirty } = require("./confirm-forge-target-ownership/auth-context");
const { ghScopeOf, argvHidesForgeWrite, ansicPositionIssue, unrecognizedWrapperHead } = require("./confirm-forge-target-ownership/detect");
const { proveOwned, ghLogin } = require("./confirm-forge-target-ownership/prove-ownership");
const {
  resolveTarget,
  hostSelector,
  hostSelectorIsGithub,
  hostIsGithub,
  repoSelectors,
} = require("./confirm-forge-target-ownership/resolve-target");

const GITHUB = "github.com";
const ENV_BLOCKING_ASSIGN_RE = /^(GH_|GITHUB_|HTTP_PROXY|HTTPS_PROXY|NO_PROXY)/;
const DYNAMIC_TEXT_RE = /\$\(|`|\$\{|\$[A-Za-z_]/;

function readStdin() {
  const chunks = [];
  const buf = Buffer.alloc(4096);
  try {
    for (;;) {
      const n = fs.readSync(0, buf, 0, buf.length);
      if (n === 0) break;
      // Buffer.from COPIES: buf is reused by the next read, and a view onto it
      // would be overwritten, silently truncating any payload past 4096 bytes.
      chunks.push(Buffer.from(buf.subarray(0, n)));
    }
  } catch (_e) {
    // EOF or no stdin attached
  }
  return Buffer.concat(chunks).toString("utf8");
}

// DECIDED unwinds to the single exit point instead of calling process.exit, so
// the decision is written exactly once and the process still ends normally. An
// early process.exit would also silence anything appended after this module's
// own code, which is how the mutation harness proves it can observe the hook.
const DECIDED = { decided: true };
let answered = false;

function answer(json) {
  if (!answered) {
    answered = true;
    process.stdout.write(json);
  }
  throw DECIDED;
}

function passThrough() {
  answer("{}");
}

function emit(state) {
  const parts = [];
  for (const code of REASON_CODES) {
    if (state.codes.indexOf(code) !== -1) parts.push(reasonText(code));
  }
  for (const ask of state.targets) parts.push(ask);
  if (parts.length === 0) passThrough();
  const reason = "Confirm the forge target before this write: " + parts.join("; ") + ".";
  answer(JSON.stringify({
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "ask",
      permissionDecisionReason: reason,
    },
  }));
}

function addCode(state, code) {
  if (state.codes.indexOf(code) === -1) state.codes.push(code);
}

function addTarget(state, text) {
  if (state.targets.indexOf(text) === -1) state.targets.push(text);
}

// The env value that gh would actually see for one name, highest rank first.
// Rank 1-2 are written by this very command line; ranks 3-4 are ambient and are
// therefore reconciled against the checkout before they can stand alone.
function lookupEnv(state, seg, name) {
  if (state.envReleased[name]) return { present: false, value: null, readable: true, rank: 0 };
  const local = state.segmentEnv[name];
  if (local) return { present: true, value: local.value, readable: local.readable, rank: 2 };
  const invocation = state.invocationEnv[name];
  if (invocation) return { present: true, value: invocation.value, readable: invocation.readable, rank: 2 };
  const session = state.sessionEnv[name];
  if (session) return { present: true, value: session.value, readable: session.readable !== false, rank: 3 };
  const ambient = process.env[name];
  if (typeof ambient === "string" && ambient !== "") {
    return { present: true, value: ambient, readable: true, rank: 4 };
  }
  return { present: false, value: null, readable: true, rank: 0 };
}

// A segment behind `&&` / `||` may never run, so — exactly as with its auth
// effects — its env effects are SYNTAX, not history. Recording them anyway lets
// `false && export GH_REPO=owner/repo` name a target the shell never set, and
// `true || unset GH_REPO` forget one it never released. Only effects that
// OUTLIVE the segment are gated: the per-segment scope is still filled for a
// branch that may not run, because the guard still reads that segment and has
// to read it the way the shell would if it did run.
function applyEnvEffects(state, seg, guaranteed) {
  const effects = ghEnvOfSegment(seg);
  state.segmentEnv = {};
  for (const set of effects.sets) {
    if (set.persist && !guaranteed) continue;
    const entry = { value: set.value, readable: set.readable, setAt: Date.now() };
    if (set.persist) state.invocationEnv[set.name] = entry;
    else state.segmentEnv[set.name] = entry;
    if (guaranteed) delete state.envReleased[set.name];
  }
  if (!guaranteed) return effects;
  // An unset does not merely forget what this command line set — it has to MASK
  // the session record and the ambient environment too, or the guard keeps
  // resolving against a variable that gh will no longer see.
  for (const name of effects.unsets) {
    delete state.invocationEnv[name];
    delete state.segmentEnv[name];
    state.envReleased[name] = true;
  }
  return effects;
}

// A segment behind `&&` / `||` may never run, so its auth effects are SYNTAX,
// not history. Recording them anyway lets `false && unset GH_TOKEN` clear the
// dirty flag for a token that is still set.
const NO_AUTH_EFFECTS = { segment: [], persistent: [], releases: [] };

function conditionalSeparators(ir) {
  const seps = Array.isArray(ir && ir.separators) ? ir.separators : [];
  return seps.some((s) => typeof s === "string" && (s.indexOf("&&") !== -1 || s.indexOf("||") !== -1));
}

function applyAuthEffects(state, causes) {
  for (const cause of causes.persistent) {
    if (state.dirty.indexOf(cause) === -1) state.dirty.push(cause);
  }
  for (const release of causes.releases) {
    const at = state.dirty.indexOf(release);
    if (at !== -1) state.dirty.splice(at, 1);
  }
  if (causes.persistent.length > 0) state.authMutated = true;
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

// The command this segment actually runs, with inline assignments stripped and
// wrappers peeled by the SHARED peeler (CPR-SSOT) — a private copy here would
// drift from the one every other write-scanning hook trusts. `argvRaw` is
// realigned by length: the peel only ever returns a suffix of the original argv.
function effectiveOf(seg) {
  const argv = Array.isArray(seg.argv) ? seg.argv : [];
  const argvRaw = Array.isArray(seg.argvRaw) ? seg.argvRaw : argv;
  let head = seg.cmd0;
  let rest = argv;
  if (typeof head === "string" && ASSIGN_RE.test(head)) {
    const idx = argv.findIndex((a) => typeof a !== "string" || !ASSIGN_RE.test(a));
    if (idx === -1) return { cmd0: null, argv: [], argvRaw: [] };
    head = argv[idx];
    rest = argv.slice(idx + 1);
  }
  const peeled = segmentUtils.peelWrappers(head, rest);
  const effArgv = Array.isArray(peeled.argv) ? peeled.argv : [];
  const consumed = argv.length - effArgv.length;
  const cmd0Raw = typeof seg.cmd0Raw === "string" ? seg.cmd0Raw : seg.cmd0;
  return {
    cmd0: peeled.cmd0,
    argv: effArgv,
    argvRaw: argvRaw.slice(consumed),
    prefixRaw: [cmd0Raw].concat(argvRaw.slice(0, consumed)),
  };
}

// `env -C dir` runs the command somewhere other than tool_input.cwd, so nothing
// the guard resolves from the working directory describes what gh will see. It
// is a LOCATION problem, never an auth one — the two get separate reasons.
function relocatesCwd(seg) {
  const argv = Array.isArray(seg.argv) ? seg.argv : [];
  const tokens = [seg.cmd0].concat(argv);
  if (!tokens.some((t) => commandBasename(t) === "env")) return false;
  return argv.some((t) => typeof t === "string" && (t === "-C" || t === "--chdir" || t.indexOf("--chdir=") === 0));
}

// The command word decides everything downstream, so a command word that is
// only known at run time — a variable, a substitution — is not "no gh write
// here", it is a write the guard cannot read.
function headIsDynamic(eff) {
  const prefixRaw = Array.isArray(eff.prefixRaw) ? eff.prefixRaw : [];
  const headRaw = prefixRaw.length > 0 ? prefixRaw[prefixRaw.length - 1] : null;
  for (const word of [eff.cmd0, headRaw]) {
    if (typeof word === "string" && DYNAMIC_TEXT_RE.test(word)) return true;
  }
  return false;
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
  if (unrecognizedWrapperHead({ claimed: false, bodyState: body.kind, argvScanCounted, seg }) && mentionsForgeWrite(rawText)) {
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
  const conditional = conditionalSeparators(ir);
  const segments = ir.segments || [];
  for (let i = 0; i < segments.length; i++) {
    evaluateSegment(state, segments[i], depth, reached && (i === 0 || !conditional));
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

// The working directory only tells the truth about the target when this command
// line does nothing that could move it or redirect gh elsewhere. Anything dynamic
// — a `cd`, a second command, a substitution, a GH_*/proxy assignment — and the
// implicit target stops being knowable from `tool_input.cwd`.
function cwdIsAuthoritative(input, commands, lines) {
  if (!Array.isArray(commands) || commands.length !== 1) return false;
  if (!Array.isArray(lines) || lines.length !== 1) return false;
  const cwd = input.tool_input && input.tool_input.cwd;
  if (typeof cwd !== "string" || cwd === "") return false;
  const line = lines[0];
  if (DYNAMIC_TEXT_RE.test(line)) return false;
  let ir = null;
  try { ir = parse(line); } catch (_e) { ir = null; }
  if (!ir || ir.parseFailure || ir.kind !== "simple") return false;
  if (!Array.isArray(ir.segments) || ir.segments.length !== 1) return false;
  if (Array.isArray(ir.separators) && ir.separators.length > 0) return false;
  const seg = ir.segments[0];
  let head = seg.cmd0;
  const argv = Array.isArray(seg.argv) ? seg.argv : [];
  let i = 0;
  while (typeof head === "string" && ASSIGN_RE.test(head)) {
    const eq = head.indexOf("=");
    if (ENV_BLOCKING_ASSIGN_RE.test(head.slice(0, eq))) return false;
    if (i >= argv.length) return false;
    head = argv[i];
    i += 1;
  }
  return commandBasename(head) === "gh";
}

function main() {
  const raw = readStdin();
  if (!raw || !raw.trim()) passThrough();
  let input = null;
  try { input = JSON.parse(raw); } catch (_e) { passThrough(); }
  if (!input || typeof input !== "object") passThrough();
  if (!isCommandTool(input.tool_name)) passThrough();
  const commands = commandListOf(input.tool_name, input.tool_input);
  if (commands.length === 0) passThrough();
  const sid = typeof input.session_id === "string" ? input.session_id : null;
  const state = {
    codes: [],
    targets: [],
    budget: createBudget(),
    ctx: { sid, host: GITHUB },
    cwd: input.tool_input && typeof input.tool_input.cwd === "string" ? input.tool_input.cwd : null,
    sessionEnv: loadSessionGhEnv(sid),
    invocationEnv: {},
    segmentEnv: {},
    envReleased: {},
    dirty: loadDirty(sid),
    authMutated: false,
    cwdAllowed: false,
  };
  state.authMutated = state.dirty.length > 0;
  const normalized = commands.map((c) => normalizeToLines(c));
  const allLines = [];
  for (const norm of normalized) {
    if (!norm.ok && norm.reason) addCode(state, norm.reason);
    for (const line of norm.lines) allLines.push(line);
  }
  state.cwdAllowed = cwdIsAuthoritative(input, commands, allLines);
  for (const line of allLines) evaluateLine(state, line, 0, true);
  if (saveDirty(sid, state.dirty).failed) {
    addTarget(state, "the guard could not record this command line's auth change, so the identity the next command acts as cannot be trusted for this write");
  }
  const released = Object.keys(state.envReleased);
  if (Object.keys(state.invocationEnv).length > 0 || released.length > 0) {
    const merged = Object.assign({}, state.sessionEnv, state.invocationEnv);
    for (const name of released) {
      if (!state.invocationEnv[name]) delete merged[name];
    }
    // A persist that was ATTEMPTED and failed cannot be shrugged off here: the
    // decision below is allowed to be cheap only because the target it resolved
    // is remembered for the rest of the session. If it was not written, this
    // invocation has to ask rather than close on a state that does not exist.
    if (saveSessionGhEnv(sid, merged).failed) {
      addTarget(state, "the guard could not record this command line's GH_REPO/GH_HOST change, so the target it resolved cannot be trusted for this write");
    }
  }
  emit(state);
}

try {
  main();
} catch (e) {
  if (e !== DECIDED && !answered) {
    answered = true;
    process.stdout.write(JSON.stringify({
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "ask",
        permissionDecisionReason: "Confirm the forge target before this write: the guard could not evaluate this command.",
      },
    }));
  }
}
