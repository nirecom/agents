// Shared bash command-parser engine extracted from hooks/block-dotenv.js.
// Generalizes the path-position tokenizer so multiple PreToolUse hooks can
// reuse the same invariants (quote-aware tokenization, substitution recursion,
// shell-wrapper recursion, redirect handling, TEXT_FLAGS / PATH_FLAGS / TEXT_CMDS
// semantics) while pluggable `isTargetPath` decides what counts as a hit.
"use strict";

const { substitutionSpanEnds, spanEndAt } = require("./substitution-spans");

// Redirect operators: the next token is the redirect target (a path).
// Matches: >, >>, 1>, 1>>, 2>, 2>>, &>, &>>, <, <<<, >|, N>|, >&, N>&.
// `>|` and `>&FILE` must be recognized here or their `|`/`&` gets read as a
// segment SEPARATOR downstream, demoting the real write target into the next
// segment's cmd0 where no scanner looks for it. `>&` is admitted as a file
// redirect only when not followed by an fd number or `-`, so `>&1`/`2>&1`/
// `>&-` still take the fd-duplication route every downstream extractor expects.
const REDIRECT_OP_ALT = String.raw`\d?>\||\d?>&(?![\d-]+$)|\d?>>?|&>>?|<<<|<`;
const REDIRECT_RE = new RegExp(String.raw`^(?:${REDIRECT_OP_ALT})$`);

// Attached-redirect form: operator and path glued into one token
// (e.g. `echo x >~/.ssh/authorized_keys`, `cat <~/.ssh/id_rsa`, `cmd 2>~/.ssh/log`).
// Capture group is the path part after the operator.
const ATTACHED_REDIRECT_RE = new RegExp(String.raw`^(?:${REDIRECT_OP_ALT})(.+)$`);

// Strip trailing shell-redirect suffixes (fd-dup and file-redirect forms, attached
// or spaced, stacked) off a raw command string; quoted targets are kept.
// Basis: REDIRECT_RE/ATTACHED_REDIRECT_RE and the fd-dup lookahead below.
// Mechanical only — does not fail-close on shell chaining (predicate layer's
// `^...$` anchor + hasShellChaining reject chained commands elsewhere).
function stripTrailingRedirects(cmd) {
  if (typeof cmd !== "string") return cmd;
  let out = cmd.replace(/\s+$/, "");
  // fd-dup: `2>&1`, `>&2`, `1>&-`, `>&1`, `2>&-`
  const fdDup = /\s+\d*>&[\d-]+$/;
  // attached file-redirect: `>/dev/null`, `2>/dev/null`, `>>/file`, `&>/dev/null`
  const attached = /\s+(?:\d*>>?|&>>?)[^\s&|;()"']+$/;
  // separated file-redirect: `> /dev/null`, `2> /dev/null`, `>> /tmp/log`
  const separated = /\s+(?:\d*>>?|&>>?)\s+[^\s&|;()"']+$/;
  let prev;
  do {
    prev = out;
    out = out.replace(fdDup, "").replace(attached, "").replace(separated, "");
  } while (out !== prev);
  return out;
}

// Strip $(...) and `...` command substitutions and `<<EOF...EOF` heredoc
// bodies. These constructs carry message text, not paths — removing them
// before tokenization avoids treating message content as command tokens.
function stripSubstitutions(cmd) {
  let out = cmd;
  // $(...) — iterate to handle nested
  let prev;
  do { prev = out; out = out.replace(/\$\([^()]*\)/g, ""); } while (out !== prev);
  // `...` backtick command substitution
  out = out.replace(/`[^`]*`/g, "");
  // <<EOF ... EOF / <<-EOF ... EOF / <<'EOF' ... EOF / <<"EOF" ... EOF
  out = out.replace(/<<-?\s*['"]?(\w+)['"]?[\s\S]*?\n\s*\1\s*(?:\n|$)/g, "");
  return out;
}

// Quote-aware tokenizer CORE (respects "...", '...', $'...'); sole source for
// tokenizeSegment/tokenizeSegmentWithQuotes. Returns Array<{value, raw}>.
// opts.preserveSubstitutionSpans keeps a `$(...)`/backtick/`$((...))`/`${...}`
// span WHOLE so it can't be split by interior whitespace (fail-closed).
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
        // POSIX: inside "...", backslash escapes only $ ` " \ or newline (#2210).
        while (i < n && seg[i] !== '"') {
          // POSIX: `\<newline>` inside "..." is a line continuation — both
          // characters vanish, nothing is appended (#2210 C1).
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

// Quote-aware tokenizer: returns UNQUOTED tokens (outer quotes stripped).
function tokenizeSegment(seg, opts) {
  return tokenizeCore(seg, opts).map((t) => t.value);
}

// Quote-aware tokenizer variant that ALSO returns the pre-strip raw slice for
// each token. `value` stays byte-identical to tokenizeSegment output.
function tokenizeSegmentWithQuotes(seg, opts) {
  return tokenizeCore(seg, opts);
}

// Split cmd on UNQUOTED shell separators: && || ; | & ( ). Returns
// { segs, seps } — seps records the separator at each split point.
// opts.preserveSubstitutionSpans keeps a substitution span whole so its
// parens don't hit the separator branch (would evade detection).
// Must stay additive: command-ir's parse() appends these; shared-cmd-utils.js
// reads `ir.separators.length > 0` as "this command chains" — swallowing
// `(`/`)` here would empty that signal and turn a deny into an allow.
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
      // fd-dup lookahead (N>&M / N>&-) is handled in the digit branch below,
      // BEFORE it reaches here — this branch only sees ; | & ( ) itself.
      // ( ) split also isolates process-substitution bodies <(cmd) / >(cmd):
      // the inner cmd becomes its own segment and is tokenized normally, so
      // path-position checks still fire on its arguments.
      const sepStr = ch === ";" ? ";" : ch === "|" ? "|" : ch === "&" ? "&" : ch === "(" ? "(" : ")";
      seps.push(sepStr);
      flush(); i += 1;
    } else if (/\d/.test(ch)) {
      // Digit-prefixed redirect operator: N>& (fd-dup N>&M / N>&- AND the
      // file form N>&FILE) or N>| (noclobber override). Consume the OPERATOR
      // only — whatever follows keeps flowing through normal accumulation, so
      // `2>&1` still lands in one token exactly as before while `2>& FILE`
      // now survives as the operator token `2>&` plus its target.
      let j = i;
      while (j < n && /\d/.test(cmd[j])) j++;
      if (cmd[j] === ">" && (cmd[j + 1] === "&" || cmd[j + 1] === "|")) {
        cur += cmd.slice(i, j + 2);
        i = j + 2;
      } else {
        // Not a redirect operator — normal character accumulation
        cur += ch;
        i++;
      }
    } else if (ch === ">" && (cmd[i + 1] === "&" || cmd[i + 1] === "|")) {
      // `>&` / `>|` must be consumed as a two-character OPERATOR before the
      // separator branch above reads the `&` / `|` as a segment separator —
      // otherwise the write target demotes into the next segment's cmd0.
      cur += cmd.slice(i, i + 2);
      i += 2;
    } else {
      cur += ch; i++;
    }
  }
  flush();
  return { segs, seps };
}

// Split cmd on UNQUOTED shell separators: && || ; | & ( )
// Delegation wrapper around splitSegmentsWithSeparators for backward compatibility.
function splitSegments(cmd) {
  return splitSegmentsWithSeparators(cmd).segs;
}

// Extract bodies of $(...) and `...` command substitutions for recursive
// inspection. Substitutions execute as shell commands, so their contents must
// be analyzed even though stripSubstitutions removes them from tokenization.
function extractSubstitutionContents(cmd) {
  const out = [];
  const dollarParen = /\$\(([^()]*)\)/g;
  let m;
  while ((m = dollarParen.exec(cmd)) !== null) out.push(m[1]);
  const backtick = /`([^`]*)`/g;
  while ((m = backtick.exec(cmd)) !== null) out.push(m[1]);
  return out;
}

// Walk argv of one segment, applying redirect / TEXT_FLAGS / PATH_FLAGS /
// positional rules. Returns true iff any token in path position matches
// opts.isTargetPath.
function segmentMatches(segment, opts) {
  const isTargetPath = opts.isTargetPath;
  const textFlags = opts.textFlags || new Set();
  const pathFlags = opts.pathFlags || new Set();
  const textCmds = opts.textCmds || new Set();
  const shellBins = opts.shellBins || new Set();

  const tokens = tokenizeSegment(segment);
  if (tokens.length === 0) return false;

  // First pass: check redirect targets independent of cmd0 — `echo > .env`,
  // `printf "x" >> .env.production` must block even though echo/printf are
  // text-positional commands. Redirects are syntax-attached, not positional.
  // Handles both spaced (`> path`) and attached (`>path`) forms.
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

  // echo/printf: positional args are message text. Redirects already checked above.
  if (textCmds.has(cmdBase)) return false;

  // Shell wrapper recursion: `bash -c "<script>"`, `bash -lc "<script>"`,
  // `sh -ic "<script>"` etc. Combined short flags must also recurse.
  if (shellBins.has(cmdBase)) {
    let hasCFlag = false;
    let scriptIdx = -1;
    for (let k = 1; k < tokens.length; k++) {
      const tok = tokens[k];
      if (tok.startsWith("-")) {
        // Match `-c` exactly OR a combined short flag containing `c`
        // (e.g. -lc, -ic, -Oc) — bash's POSIX/login/interactive flag forms.
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
      // Already detected above; skip the target token to keep argv walking sane.
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

    // Attached `=` form: `--flag=value` / `-i=value`. Split and reclassify.
    if (t.startsWith("-") && t.includes("=")) {
      const eq = t.indexOf("=");
      const flagName = t.slice(0, eq);
      const flagValue = t.slice(eq + 1);
      if (textFlags.has(flagName)) continue; // text value
      if (pathFlags.has(flagName)) {
        if (isTargetPath(flagValue)) return true;
        continue;
      }
      // Unknown `--flag=value`: defense-in-depth, still check value as path.
      if (isTargetPath(flagValue)) return true;
      continue;
    }

    if (t.startsWith("-")) {
      continue; // unknown flag — skip the flag itself only
    }

    // Positional argument: check as a path
    if (isTargetPath(t)) return true;
  }

  return false;
}

// Recursively check a bash command string; true iff any token in a
// path-bearing position (positional argv of non-textCmd, PATH_FLAGS value,
// or redirect target) matches opts.isTargetPath. TEXT_FLAGS values and
// textCmd positionals are NOT checked (redirect targets still are); an
// unknown flag token skips only itself, so the next token is still checked.
// opts: isTargetPath (required), textFlags/pathFlags/textCmds/shellBins (Sets).
function checkBashCommand(command, opts) {
  if (!command) return false;
  // Recurse into command substitution bodies first (they execute as shell).
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
