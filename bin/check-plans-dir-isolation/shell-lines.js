"use strict";

// Static shell line model for the isolation classifier: never runs the file.
// Yields logical lines (backslash continuations and multi-line quotes joined) with
// `code` (quoted text blanked, same length as `text`), the heredoc/comment status,
// and `fnStart` — the header line of the outermost function body enclosing it.

const HEREDOC_RE = /^<<(-?)\s*(\\?)(['"]?)([A-Za-z_][\w-]*)\3/;
const FN_HEADER_RE = /(?:^|[\s;&|])(?:function\s+[A-Za-z_][\w:.-]*\s*(?:\(\s*\))?|[A-Za-z_][\w:.-]*\s*\(\s*\))\s*(?:\{|$)/;
const OPEN_BRACE_RE = /(^|[\s;&|)])\{(?=\s|$)/g;
const CLOSE_BRACE_RE = /(^|[\s;&])\}(?=[\s;&|)>]|$)/g;

// inDouble(c, next, nest) → "close" when c ends the outer double quote, "pair" when c
// and next open a `$(`, else null — after updating `nest`, the quotes and substitutions
// opened inside the outer quote, so a quote inside `"$(f 'a "b')"` never ends it early.
function inDouble(c, next, nest) {
  const top = nest[nest.length - 1];
  if (top === "'") {
    if (c === "'") nest.pop();
  } else if (top === undefined || top === '"') {
    if (c === '"') return top === undefined ? "close" : (nest.pop(), null);
    if (c === "$" && next === "(") return (nest.push("$("), "pair");
    if (c === "`") nest.push("`");
  } else if (c === "'" || c === '"') {
    nest.push(c);
  } else if (c === "(") {
    nest.push("(");
  } else if (c === ")" && (top === "(" || top === "$(")) {
    nest.pop();
  } else if (c === "`") {
    if (top === "`") nest.pop();
    else nest.push("`");
  }
  return null;
}

// lexLine(raw, state) → { code, cut, heredocs }. `state.quote` (and `state.nest`, the
// substitutions open inside a double quote) and `state.arith` carry across lines.
function lexLine(raw, state) {
  let code = "";
  let cut = raw.length;
  const heredocs = [];
  if (!state.nest) state.nest = [];
  if (!state.arith) state.arith = 0;
  for (let j = 0; j < raw.length; j++) {
    const c = raw[j];
    if (state.quote === "'") {
      if (c === "'") state.quote = null;
      code += c === "'" ? c : "_";
    } else if (state.quote === '"') {
      if (c === "\\" && state.nest[state.nest.length - 1] !== "'") {
        code += "_".repeat(Math.min(2, raw.length - j));
        j++;
        continue;
      }
      const step = inDouble(c, raw[j + 1], state.nest);
      if (step === "close") {
        state.quote = null;
        code += c;
      } else if (step === "pair") {
        code += "__";
        j++;
      } else {
        code += "_";
      }
    } else if (c === "\\") {
      code += raw.slice(j, j + 2);
      j++;
    } else if (c === "'" || c === '"') {
      state.quote = c;
      code += c;
    } else if (c === "#" && (j === 0 || /[\s;&|(]/.test(raw[j - 1]))) {
      cut = j;
      break;
    } else if (c === "(" && (state.arith > 0 || (raw[j + 1] === "(" && (j === 0 || /[$\s;&|(]/.test(raw[j - 1]))))) {
      // `$((` / command-position `((` open arithmetic; `state.arith` counts its parens
      state.arith++;
      code += c;
    } else if (c === ")" && state.arith > 0) {
      state.arith--;
      code += c;
    } else if (state.arith > 0) {
      // inside arithmetic `<<` is a shift, never a heredoc opener
      code += c;
    } else if (raw.startsWith("<<<", j)) {
      // here-string: consume all three so `<<` is not re-read as a heredoc opener
      code += "<<<";
      j += 2;
    } else if (c === "<" && raw[j + 1] === "<") {
      const m = HEREDOC_RE.exec(raw.slice(j));
      if (m) {
        heredocs.push({ term: m[4], strip: m[1] === "-" });
        code += m[0];
        j += m[0].length - 1;
      } else {
        code += c;
      }
    } else {
      code += c;
    }
  }
  return { code: code.slice(0, cut), cut, heredocs };
}

// execView(raw, stack) → raw with quoted literal text blanked (same length), except the
// bodies of $( … ) / ` … ` opened inside a double quote, which stay visible:
// `"$(bash x)"` executes, `echo "run: bash x"` does not. `stack` carries across lines.
function execView(raw, stack) {
  let out = "";
  for (let j = 0; j < raw.length; j++) {
    const c = raw[j];
    const top = stack[stack.length - 1];
    if (top === "'") {
      if (c === "'") stack.pop();
      out += c === "'" ? c : "_";
    } else if (top === '"') {
      if (c === "\\") { out += "_".repeat(Math.min(2, raw.length - j)); j++; continue; }
      if (c === '"') { stack.pop(); out += c; }
      else if (c === "$" && raw[j + 1] === "(") { stack.push("$("); out += "$("; j++; }
      else if (c === "`") { stack.push("`"); out += c; }
      else out += "_";
    } else if (c === "\\") {
      out += raw.slice(j, j + 2);
      j++;
    } else if (c === "'" || c === '"') {
      stack.push(c);
      out += c;
    } else {
      if (top !== undefined && c === "(") stack.push("(");
      else if (c === ")" && (top === "(" || top === "$(")) stack.pop();
      else if (c === "`" && top === "`") stack.pop();
      out += c;
    }
  }
  return out;
}

// trackBraces(code, frames, lineNo, pending) — updates the open-brace frame stack and
// returns the header line of the first function body opened on this line (or null).
function trackBraces(code, frames, lineNo, pending) {
  let opened = null;
  if (FN_HEADER_RE.test(code)) pending.fn = lineNo;
  const events = [];
  let m;
  OPEN_BRACE_RE.lastIndex = 0;
  while ((m = OPEN_BRACE_RE.exec(code)) !== null) events.push({ at: m.index + m[1].length, open: true });
  CLOSE_BRACE_RE.lastIndex = 0;
  while ((m = CLOSE_BRACE_RE.exec(code)) !== null) events.push({ at: m.index + m[1].length, open: false });
  events.sort((a, b) => a.at - b.at);
  for (const e of events) {
    if (e.open) {
      if (pending.fn !== null && opened === null) opened = pending.fn;
      frames.push({ fn: pending.fn });
      pending.fn = null;
    } else if (frames.length > 0) {
      frames.pop();
    }
  }
  return opened;
}

function outermostFn(frames) {
  for (const f of frames) if (f.fn !== null) return f.fn;
  return null;
}

// parseShell(text) → logical lines:
//   { line, text, code, execCode, comment, heredoc, inString, fnStart }
function parseShell(text) {
  const physical = String(text).split("\n").map((l) => l.replace(/\r$/, ""));
  const state = { quote: null };
  const execStack = [];
  const frames = [];
  const pending = { fn: null };
  const queue = [];
  let heredoc = null;
  const out = [];
  let cur = null;
  physical.forEach((raw, i) => {
    const no = i + 1;
    if (heredoc) {
      const probe = heredoc.strip ? raw.replace(/^\t+/, "") : raw;
      if (probe === heredoc.term || probe.trim() === heredoc.term) heredoc = queue.shift() || null;
      out.push({ line: no, text: raw, code: "", execCode: "", comment: false, heredoc: true, inString: false, fnStart: outermostFn(frames) });
      return;
    }
    const inString = state.quote !== null;
    const fnBefore = outermostFn(frames);
    const lx = lexLine(raw, state);
    const opened = inString ? null : trackBraces(lx.code, frames, no, pending);
    let fnStart = fnBefore;
    if (fnStart === null) fnStart = opened !== null ? opened : (pending.fn === no ? no : null);
    const textPart = raw.slice(0, lx.cut);
    const execCode = execView(textPart, execStack);
    if (cur) {
      cur.text += "\n" + textPart;
      cur.code += "\n" + lx.code;
      cur.execCode += "\n" + execCode;
    } else {
      cur = {
        line: no, text: textPart, code: lx.code, execCode, heredoc: false, inString, fnStart,
        comment: raw.trim().startsWith("#") && lx.code.trim() === "",
      };
    }
    queue.push(...lx.heredocs);
    const continues = state.quote !== null || /\\$/.test(textPart);
    if (!continues) {
      out.push(cur);
      cur = null;
      execStack.length = 0; // the two lexers never disagree past a logical line
      if (!heredoc && queue.length > 0) heredoc = queue.shift();
    }
  });
  if (cur) out.push(cur);
  return out;
}

module.exports = { parseShell };
