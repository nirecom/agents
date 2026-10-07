"use strict";
// Artifact-prefix (WORKTREE_NOTES.md) resolution rows of adapter-probe.js (#2460). The body runs
// inside one function so it can take the probe's shared context (repo, A, safe, plansDir, prompt).
const fs = require("fs");
const path = require("path");

module.exports = function workspaceRows(ctx) {
const { repo, A, safe, plansDir, prompt } = ctx;

// Artifact prefix resolution: the Session-ID of <cwd>/WORKTREE_NOTES.md (that one file only)
// when it has any artifact, else the hook session id, else nothing. Every id here is unique
// to its row, so no row sees another's plan files.
const WS_ROOT = fs.mkdtempSync(path.join(require("os").tmpdir(), "jev2460-ws-"));
process.on("exit", () => { try { fs.rmSync(WS_ROOT, { recursive: true, force: true }); } catch (_e) { /* best effort */ } });
const NONE = "intent=absent outline=absent detail=absent";
function wsPlan(id, mark) {
  const f = (n) => path.join(plansDir, id + "-" + n + ".md");
  fs.mkdirSync(path.dirname(f("intent")), { recursive: true });
  for (const n of ["intent", "outline"]) fs.writeFileSync(f(n), "# " + n + "\n" + mark + "-" + n + "\n");
}
function wsCwd(name, notesSid) {
  const d = path.join(WS_ROOT, name);
  fs.mkdirSync(d, { recursive: true });
  if (notesSid !== null) fs.writeFileSync(path.join(d, "WORKTREE_NOTES.md"), "# Worktree Notes\n\nSession-ID: " + notesSid + "\n");
  return d;
}
// C12: a notes Session-ID counts only when its workflow state is bound to that very worktree.
// wsCwdBound gives the notes sid a state (under $WORKFLOW_STATE_DIR) whose session_worktree is <dir>.
const stateIo = require(path.join(repo, "hooks", "workflow-state", "state-io.js"));
function wsCwdBound(name, notesSid) {
  const d = wsCwd(name, notesSid);
  stateIo.markStep(notesSid, "workflow_init", "complete");
  stateIo.recordSessionWorktree(notesSid, d);
  return d;
}
const wsReq = (hookSid, cwd) => A.buildRequest({ toolInput: { prompt }, sessionId: hookSid, stage: "outline", cwd });
const wsHdr = (r) => (/artifacts: (intent=\S+ outline=\S+ detail=\S+)/.exec(String(r.state)) || [])[1];
const wsNone = (r) => wsHdr(r) === NONE && !/WS-[A-Z]+-MARK/.test(String(r.state));

// The hook sid holds a partial set (intent only), so a per-file mix would show in the header.
safe("ws-notes-sid-wins", () => {
  fs.writeFileSync(path.join(plansDir, "ws-a-hook-intent.md"), "# intent\nWS-HOOK-MARK-intent\n");
  wsPlan("ws-a-notes", "WS-NOTES-MARK");
  const r = wsReq("ws-a-hook", wsCwdBound("a", "ws-a-notes"));
  const s = String(r.state);
  return [wsHdr(r), s.includes("WS-HOOK-MARK-intent"), s.includes("WS-NOTES-MARK-intent"), r.input.sources.join(",")].join("|");
});
safe("ws-notes-empty-hook-read", () => {
  wsPlan("ws-h-hook", "WS-HOOK-MARK");
  const r = wsReq("ws-h-hook", wsCwd("h", "ws-h-notes"));
  const s = String(r.state);
  return [wsHdr(r), s.includes("WS-HOOK-MARK-intent"), s.includes("WS-HOOK-MARK-outline"), r.input.sources.join(",")].join("|");
});
// No usable notes sid (missing file, invalid id, bad cwd): the hook sid's plan is still read.
safe("ws-unusable-notes-hook-read", () => {
  wsPlan("ws-i-hook", "WS-HOOK-MARK");
  wsPlan("a..i", "WS-DOTDOT-MARK");
  const cases = [wsCwd("i-none", null), wsCwd("i-bad", "a..i"), ".", undefined];
  return cases.map((c) => {
    const s = String(wsReq("ws-i-hook", c).state);
    return s.includes("WS-HOOK-MARK-intent") && !s.includes("WS-DOTDOT-MARK");
  }).join(",");
});
// notesSessionId(cwd): the validated, normalized Session-ID of <cwd>/WORKTREE_NOTES.md whose
// state is bound to <cwd>, else null (binding edge cases: notes-bind-probe.js).
safe("notes-sid-direct", () => {
  if (typeof A.notesSessionId !== "function") return "NOT-EXPORTED";
  const ok = wsCwdBound("n-ok", "ws-n-notes");
  const rows = [ok, wsCwd("n-none", null), wsCwd("n-dots", "a..n"), wsCwd("n-slash", "x/n"), "relative/dir", undefined, null, 42];
  return rows.map((c) => String(A.notesSessionId(c))).join(",");
});
safe("notes-sid-posix-cwd", () => {
  if (process.platform !== "win32") return "SKIP-NOT-WIN32";
  if (typeof A.notesSessionId !== "function") return "NOT-EXPORTED";
  const m = /^([A-Za-z]):[\\/](.*)$/.exec(wsCwdBound("n-posix", "ws-np-notes"));
  if (!m) return "NO-DRIVE-LETTER";
  return String(A.notesSessionId("/" + m[1].toLowerCase() + "/" + m[2].replace(/\\/g, "/")));
});
safe("ws-notes-fallback", () => {
  wsPlan("ws-b-notes", "WS-NOTES-MARK");
  const r = wsReq("ws-b-hook", wsCwdBound("b", "ws-b-notes"));
  const s = String(r.state);
  return [wsHdr(r), s.includes("WS-NOTES-MARK-intent"), s.includes("WS-NOTES-MARK-outline"), r.input.sources.join(",")].join("|");
});
// win32 only: the cwd arrives in Git-Bash form (/c/...), which fs cannot open unnormalized.
safe("ws-posix-cwd", () => {
  if (process.platform !== "win32") return "SKIP-NOT-WIN32";
  wsPlan("ws-g-notes", "WS-NOTES-MARK");
  const d = wsCwdBound("g", "ws-g-notes");
  const m = /^([A-Za-z]):[\\/](.*)$/.exec(d);
  if (!m) return "NO-DRIVE-LETTER";
  const posix = "/" + m[1].toLowerCase() + "/" + m[2].replace(/\\/g, "/");
  const r = wsReq("ws-g-hook", posix);
  return [wsHdr(r), String(r.state).includes("WS-NOTES-MARK-intent")].join("|");
});
safe("ws-no-notes-file", () => wsNone(wsReq("ws-c-hook", wsCwd("c", null))));
// Plan files exist under every invalid id, so a reader that skips the id check would find them.
safe("ws-invalid-notes-sid", () => {
  const longId = "a".repeat(129);
  wsPlan("a..b", "WS-DOTDOT-MARK");
  wsPlan("x/y", "WS-SLASH-MARK");
  wsPlan(longId, "WS-LONG-MARK");
  return ["a..b", "x/y", longId].map((id, i) => wsNone(wsReq("ws-d-hook", wsCwd("d" + i, id)))).join(",");
});
safe("ws-bad-cwd", () => {
  wsPlan("ws-e-notes", "WS-NOTES-MARK");
  const here = wsCwd("e", "ws-e-notes");
  const saved = process.cwd();
  process.chdir(here);
  try {
    return [undefined, ".", 42, null].map((c) => wsNone(wsReq("ws-e-hook", c))).join(",");
  } finally { process.chdir(saved); }
});
safe("ws-notes-only-beside-cwd", () => {
  wsPlan("ws-f-parent", "WS-PARENT-MARK");
  wsPlan("ws-f-sibling", "WS-SIBLING-MARK");
  wsCwd("f", "ws-f-parent");
  wsCwd(path.join("f", "child"), null);
  wsCwd("f-sib", "ws-f-sibling");
  return [wsNone(wsReq("ws-f-hook", wsCwd(path.join("f", "child"), null))), wsNone(wsReq("ws-f-hook", wsCwd("f-other", null)))].join(",");
});
};
