// Shared bash command-parser engine for PreToolUse hooks: quote-aware
// tokenization, substitution/shell-wrapper recursion, redirect and flag rules.
"use strict";

const { substitutionSpanEnds, spanEndAt } = require("./substitution-spans");

// Redirect operators; the next token is the target path. `>|` and `>&FILE`
// belong here or their `|`/`&` reads as a segment separator downstream and the
// write target demotes into the next segment's cmd0. The `>&` lookahead keeps
// fd-duplication forms (`2>&1`, `>&-`) on their usual route.
const REDIRECT_OP_ALT = String.raw`\d?>\||\d?>&(?![\d-]+$)|\d?>>?|&>>?|<<<|<`;
const REDIRECT_RE = new RegExp(String.raw`^(?:${REDIRECT_OP_ALT})$`);

// Attached form (`cmd 2>~/.ssh/log`); capture group is the path.
const ATTACHED_REDIRECT_RE = new RegExp(String.raw`^(?:${REDIRECT_OP_ALT})(.+)$`);

// Strip trailing redirect suffixes (stacked, attached or spaced); quoted targets
// are kept. Mechanical only — chained commands are rejected by the caller.
function stripTrailingRedirects(cmd) {
  if (typeof cmd !== "string") return cmd;
  let out = cmd.replace(/\s+$/, "");
  const fdDup = /\s+\d*>&[\d-]+$/;
  const attached = /\s+(?:\d*>>?|&>>?)[^\s&|;()"']+$/;
  const separated = /\s+(?:\d*>>?|&>>?)\s+[^\s&|;()"']+$/;
  let prev;
  do {
    prev = out;
    out = out.replace(fdDup, "").replace(attached, "").replace(separated, "");
  } while (out !== prev);
  return out;
}

// Drop substitution and heredoc bodies: they carry message text, not paths, so
// tokenizing them would read message content as command tokens.
function stripSubstitutions(cmd) {
  let out = cmd;
  // iterate: the non-nesting pattern peels one level per pass
  let prev;
  do { prev = out; out = out.replace(/\$\([^()]*\)/g, ""); } while (out !== prev);
  out = out.replace(/`[^`]*`/g, "");
  out = out.replace(/<<-?\s*['"]?(\w+)['"]?[\s\S]*?\n\s*\1\s*(?:\n|$)/g, "");
  return out;
}

// Quote-aware tokenizer core; returns Array<{value, raw}>.
// opts.preserveSubstitutionSpans keeps a substitution span WHOLE so interior
// whitespace cannot split it (fail-closed).
function tokenizeCore(seg, opts) {
  const preserve = !!(opts && opts.preserveSubstitutionSpans);
  const ends = preserve ? substitutionSpanEnds(seg) : null;
  const tokens = [];
  let i = 0;
  const n = seg.length;
  while (i < n) {
    while (i < n && /\s/.test(seg[i])) i++;
    if (i >= n) break;
    const tokStart = i;
    let tok = "";
    while (i < n && !/\s/.test(seg[i])) {
      const ch = seg[i];
      if (preserve) {
        const spanEnd = spanEndAt(seg, i, ends);
        if (spanEnd > i) { tok += seg.slice(i, spanEnd); i = spanEnd; continue; }
      }
      if (ch === '"') {
        i++;
        // POSIX: inside "...", backslash escapes only $ ` " \ or newline, and
        // `\<newline>` is a line continuation — both characters vanish (#2210).
        while (i < n && seg[i] !== '"') {
          if (seg[i] === "\\" && seg[i + 1] === "\n") { i += 2; }
          else if (seg[i] === "\\" && i + 1 < n && /[$`"\\\n]/.test(seg[i + 1])) { tok += seg[i + 1]; i += 2; }
          else { tok += seg[i]; i++; }
        }
        if (i < n) i++;
      } else if (ch === "'") {
        i++;
        while (i < n && seg[i] !== "'") { tok += seg[i]; i++; }
        if (i < n) i++;
      } else if (ch === "$" && seg[i + 1] === "'") {
        i += 2;
        while (i < n && seg[i] !== "'") {
          if (seg[i] === "\\" && i + 1 < n) { tok += seg[i + 1]; i += 2; }
          else { tok += seg[i]; i++; }
        }
        if (i < n) i++;
      } else {
        tok += ch;
        i++;
      }
    }
    tokens.push({ value: tok, raw: seg.slice(tokStart, i) });
  }
  return tokens;
}

// Returns UNQUOTED tokens (outer quotes stripped).
function tokenizeSegment(seg, opts) {
  return tokenizeCore(seg, opts).map((t) => t.value);
}

// Same tokens plus each one's pre-strip raw slice; `value` stays byte-identical
// to tokenizeSegment output.
function tokenizeSegmentWithQuotes(seg, opts) {
  return tokenizeCore(seg, opts);
}

// Split cmd on UNQUOTED separators (&& || ; | & parens); seps records the
// separator at each split point. opts.preserveSubstitutionSpans keeps a
// substitution span whole so its parens don't reach the separator branch.
// Must stay additive: shared-cmd-utils.js reads `separators.length > 0` as
// "this command chains", so swallowing a separator turns a deny into an allow.
function splitSegmentsWithSeparators(cmd, opts) {
  const segs = [];
  const seps = [];
  const preserve = !!(opts && opts.preserveSubstitutionSpans);
  const spanEnds = preserve ? substitutionSpanEnds(cmd) : null;
  let cur = "";
  let i = 0;
  const n = cmd.length;
  const flush = () => { const s = cur.trim(); if (s) segs.push(s); cur = ""; };
  while (i < n) {
    const ch = cmd[i];
    if (preserve) {
      const spanEnd = spanEndAt(cmd, i, spanEnds);
      if (spanEnd > i) { cur += cmd.slice(i, spanEnd); i = spanEnd; continue; }
    }
    if (ch === '"') {
      cur += ch; i++;
      while (i < n && cmd[i] !== '"') {
        if (cmd[i] === "\\" && i + 1 < n) { cur += cmd[i] + cmd[i + 1]; i += 2; }
        else { cur += cmd[i]; i++; }
      }
      if (i < n) { cur += cmd[i]; i++; }
    } else if (ch === "'") {
      cur += ch; i++;
      while (i < n && cmd[i] !== "'") { cur += cmd[i]; i++; }
      if (i < n) { cur += cmd[i]; i++; }
    } else if (ch === "$" && cmd[i + 1] === "'") {
      cur += "$'"; i += 2;
      while (i < n && cmd[i] !== "'") {
        if (cmd[i] === "\\" && i + 1 < n) { cur += cmd[i] + cmd[i + 1]; i += 2; }
        else { cur += cmd[i]; i++; }
      }
      if (i < n) { cur += cmd[i]; i++; }
    } else if ((ch === "&" && cmd[i + 1] === "&") || (ch === "|" && cmd[i + 1] === "|")) {
      seps.push(ch === "&" ? "&&" : "||");
      flush(); i += 2;
    } else if (ch === ";" || ch === "|" || ch === "&" || ch === "(" || ch === ")") {
      // Splitting on parens also isolates process-substitution bodies, so the
      // inner command becomes its own segment and gets path-checked.
      const sepStr = ch === ";" ? ";" : ch === "|" ? "|" : ch === "&" ? "&" : ch === "(" ? "(" : ")";
      seps.push(sepStr);
      flush(); i += 1;
    } else if (/\d/.test(ch)) {
      // Digit-prefixed redirect operator (N>& / N>|): consume the OPERATOR only,
      // so `2>&1` still lands in one token while `2>& FILE` keeps its target.
      let j = i;
      while (j < n && /\d/.test(cmd[j])) j++;
      if (cmd[j] === ">" && (cmd[j + 1] === "&" || cmd[j + 1] === "|")) {
        cur += cmd.slice(i, j + 2);
        i = j + 2;
      } else {
        cur += ch;
        i++;
      }
    } else if (ch === ">" && (cmd[i + 1] === "&" || cmd[i + 1] === "|")) {
      // Two-character operator: otherwise the separator branch above eats the
      // `&`/`|` and the write target demotes into the next segment's cmd0.
      cur += cmd.slice(i, i + 2);
      i += 2;
    } else {
      cur += ch; i++;
    }
  }
  flush();
  return { segs, seps };
}

function splitSegments(cmd) {
  return splitSegmentsWithSeparators(cmd).segs;
}

// Substitution bodies execute as shell, so they still need inspection even
// though stripSubstitutions removes them from tokenization.
function extractSubstitutionContents(cmd) {
  const out = [];
  const dollarParen = /\$\(([^()]*)\)/g;
  let m;
  while ((m = dollarParen.exec(cmd)) !== null) out.push(m[1]);
  const backtick = /`([^`]*)`/g;
  while ((m = backtick.exec(cmd)) !== null) out.push(m[1]);
  return out;
}

// True iff any token in path position of this segment matches opts.isTargetPath.
function segmentMatches(segment, opts) {
  const isTargetPath = opts.isTargetPath;
  const textFlags = opts.textFlags || new Set();
  const pathFlags = opts.pathFlags || new Set();
  const textCmds = opts.textCmds || new Set();
  const shellBins = opts.shellBins || new Set();

  const tokens = tokenizeSegment(segment);
  if (tokens.length === 0) return false;

  // Redirect targets are checked independent of cmd0: `echo > .env` must block
  // even though echo's positionals are text.
  for (let k = 0; k < tokens.length; k++) {
    if (REDIRECT_RE.test(tokens[k])) {
      if (k + 1 < tokens.length && isTargetPath(tokens[k + 1])) return true;
      continue;
    }
    const attached = ATTACHED_REDIRECT_RE.exec(tokens[k]);
    if (attached && isTargetPath(attached[1])) return true;
  }

  const cmd0 = tokens[0];
  const cmdBase = cmd0.replace(/\\/g, "/").split("/").pop();

  // echo/printf: positionals are message text; redirects were checked above.
  if (textCmds.has(cmdBase)) return false;

  // Shell wrapper recursion: `bash -c "<script>"`, combined short flags too.
  if (shellBins.has(cmdBase)) {
    let hasCFlag = false;
    let scriptIdx = -1;
    for (let k = 1; k < tokens.length; k++) {
      const tok = tokens[k];
      if (tok.startsWith("-")) {
        // `-c` exactly, or a combined short flag containing it (`-lc`, `-ic`).
        if (tok === "-c" || /^-[a-zA-Z]*c[a-zA-Z]*$/.test(tok)) hasCFlag = true;
        continue;
      }
      scriptIdx = k;
      break;
    }
    if (hasCFlag && scriptIdx >= 0) {
      return checkBashCommand(tokens[scriptIdx], opts);
    }
    return false;
  }

  for (let k = 1; k < tokens.length; k++) {
    const t = tokens[k];

    if (REDIRECT_RE.test(t)) {
      // target already checked above
      k += 1;
      continue;
    }

    if (textFlags.has(t)) {
      k += 1; // skip the value: it's text
      continue;
    }

    if (pathFlags.has(t)) {
      const next = tokens[k + 1];
      if (next && isTargetPath(next)) return true;
      k += 1;
      continue;
    }

    // Attached `=` form: split and reclassify.
    if (t.startsWith("-") && t.includes("=")) {
      const eq = t.indexOf("=");
      const flagName = t.slice(0, eq);
      const flagValue = t.slice(eq + 1);
      if (textFlags.has(flagName)) continue; // text value
      if (pathFlags.has(flagName)) {
        if (isTargetPath(flagValue)) return true;
        continue;
      }
      // Unknown flag: defense-in-depth, still check the value as a path.
      if (isTargetPath(flagValue)) return true;
      continue;
    }

    if (t.startsWith("-")) {
      continue; // unknown flag — skip the flag itself only
    }

    if (isTargetPath(t)) return true;
  }

  return false;
}

// Recursively check a bash command string for a path-bearing token matching
// opts.isTargetPath. textFlags values and textCmd positionals are exempt;
// an unknown flag skips only itself, so the following token is still checked.
function checkBashCommand(command, opts) {
  if (!command) return false;
  // Substitution bodies execute as shell, so recurse before stripping them.
  for (const sub of extractSubstitutionContents(command)) {
    if (checkBashCommand(sub, opts)) return true;
  }
  const stripped = stripSubstitutions(command);
  const segs = splitSegments(stripped);
  return segs.some((seg) => segmentMatches(seg, opts));
}

module.exports = {
  checkBashCommand,
  tokenizeSegment,
  tokenizeSegmentWithQuotes,
  splitSegments,
  splitSegmentsWithSeparators,
  stripSubstitutions,
  extractSubstitutionContents,
  stripTrailingRedirects,
  REDIRECT_RE,
  ATTACHED_REDIRECT_RE,
};
