// hooks/block-clearance-token-write/placement-guard/bash-candidates.js
// Detection-direction helpers for the placement guard's Bash half (#2434 D7b):
// every spelling bash could turn one raw write target into, plus the
// interpreter-body judgement. Candidates are only ever ADDED (fail closed);
// read-only shapes stay approved so the guard does not over-block reads.
"use strict";

const { decodeAnsiCEscapes, expandBraces } = require("../../lib/basename-glob-normalize/brace-ansi-expand");
const { substituteAssignments } = require("../bash-target-context/substitute");
const {
  extractAllInterpreterBodies,
  interpreterKindOfWord,
  interpreterBodyIsRecognizedReadOnly,
  looksLikeInterpreterInvocation,
} = require("../interpreter-scan");

const ANSI_C_SPAN_RE = /\$'((?:\\.|[^'\\])*)'/g;

// `$'…'` is static quoting: decode it in place so `> $'<wf>/x'` is not read as `$<wf>/x`.
function decodeAnsiCSpans(text) {
  return String(text).replace(ANSI_C_SPAN_RE, (_m, body) => decodeAnsiCEscapes(body));
}

function foldText(text) {
  const t = String(text || "").replace(/\\+/g, "/");
  return process.platform === "win32" ? t.toLowerCase() : t;
}

// The spellings of the workflow dir a command text can carry: the folded
// absolute path, its MSYS `/c/...` form, and the env-var name itself.
function workflowDirSpellings(foldedWf) {
  if (!foldedWf) return [];
  const out = [foldedWf, "workflow_state_dir"];
  const m = /^([a-z]):\/(.*)$/i.exec(foldedWf);
  if (m) out.push(`/${m[1].toLowerCase()}/${m[2]}`);
  return out;
}

function mentionsWorkflowDir(text, foldedWf) {
  const t = foldText(text);
  const upper = String(text || "");
  return workflowDirSpellings(foldedWf).some((s) =>
    s === "workflow_state_dir" ? /WORKFLOW_STATE_DIR/.test(upper) : t.includes(s)
  );
}

// candidateTargets(raw, assignText) -> { list, overCap }: ANSI-C decoded, the
// command's own assignments substituted, then brace-expanded.
function candidateTargets(raw, assignText) {
  const decoded = decodeAnsiCSpans(raw);
  const sub = decoded.includes("$") ? substituteAssignments(decoded, assignText).text : decoded;
  const texts = sub === decoded ? [decoded] : [decoded, sub];
  const list = [];
  let overCap = false;
  for (const t of texts) {
    const b = expandBraces(t);
    if (b.overCap) overCap = true;
    for (const c of b.list) if (!list.includes(c)) list.push(c);
  }
  return { list, overCap };
}

// A language body naming the workflow dir is a write unless it is a read-only shape.
function languageBodyWrites(body, lang, foldedWf) {
  return mentionsWorkflowDir(body, foldedWf) && !interpreterBodyIsRecognizedReadOnly(body, lang || "");
}

// interpreterVerdict(segText, foldedWf, recurse): "control-dir" when an inline
// program body writes (or may write) under the workflow dir. Shell bodies are
// re-classified as command text by `recurse`; language bodies are a write
// unless they match a read-only shape of their own grammar.
function interpreterVerdict(segText, foldedWf, recurse) {
  if (!looksLikeInterpreterInvocation(segText)) return null;
  const { bodies, entries, flagCount } = extractAllInterpreterBodies(segText);
  for (const e of entries) {
    if (interpreterKindOfWord(e.lang || "") === "shell") {
      const k = recurse(e.body);
      if (k) return k;
      continue;
    }
    if (languageBodyWrites(e.body, e.lang, foldedWf)) return "control-dir";
  }
  // An unextractable body cannot be cleared once the segment names the workflow dir.
  if (flagCount > bodies.length && mentionsWorkflowDir(segText, foldedWf)) return "control-dir";
  return null;
}

module.exports = { candidateTargets, decodeAnsiCSpans, interpreterVerdict, languageBodyWrites, mentionsWorkflowDir };
