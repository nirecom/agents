// Shared bash command-parser engine extracted from hooks/block-dotenv.js.
// Generalizes the path-position tokenizer so multiple PreToolUse hooks can
// reuse the same invariants (quote-aware tokenization, substitution recursion,
// shell-wrapper recursion, redirect handling, TEXT_FLAGS / PATH_FLAGS / TEXT_CMDS
// semantics) while pluggable `isTargetPath` decides what counts as a hit.
"use strict";

// Redirect operators: the next token is the redirect target (a path).
// Matches: >, >>, 1>, 1>>, 2>, 2>>, &>, &>>, <, <<<
const REDIRECT_RE = /^(?:\d?>>?|&>>?|<<<|<)$/;

// Attached-redirect form: operator and path glued into one token
// (e.g. `echo x >~/.ssh/authorized_keys`, `cat <~/.ssh/id_rsa`, `cmd 2>~/.ssh/log`).
// Capture group is the path part after the operator.
const ATTACHED_REDIRECT_RE = /^(?:\d?>>?|&>>?|<<<|<)(.+)$/;

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

// Quote-aware tokenizer: respects "...", '...', $'...'. Returns UNQUOTED
// tokens (outer quotes stripped). Backslash-escapes inside double quotes are
// honored.
function tokenizeSegment(seg) {
  const tokens = [];
  let i = 0;
  const n = seg.length;
  while (i < n) {
    while (i < n && /\s/.test(seg[i])) i++;
    if (i >= n) break;
    let tok = "";
    while (i < n && !/\s/.test(seg[i])) {
      const ch = seg[i];
      if (ch === '"') {
        i++;
        while (i < n && seg[i] !== '"') {
          if (seg[i] === "\\" && i + 1 < n) { tok += seg[i + 1]; i += 2; }
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
    tokens.push(tok);
  }
  return tokens;
}

// Split cmd on UNQUOTED shell separators: && || ; | & ( )
function splitSegments(cmd) {
  const segs = [];
  let cur = "";
  let i = 0;
  const n = cmd.length;
  const flush = () => { const s = cur.trim(); if (s) segs.push(s); cur = ""; };
  while (i < n) {
    const ch = cmd[i];
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
      flush(); i += 2;
    } else if (ch === ";" || ch === "|" || ch === "&" || ch === "(" || ch === ")") {
      // ( ) split also isolates process-substitution bodies <(cmd) / >(cmd):
      // the inner cmd becomes its own segment and is tokenized normally, so
      // path-position checks still fire on its arguments.
      flush(); i += 1;
    } else {
      cur += ch; i++;
    }
  }
  flush();
  return segs;
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

// Recursively check a bash command string. Returns true iff ANY token in a
// path-bearing position matches `opts.isTargetPath`.
//
// Path-bearing positions:
//   - positional argv of a NON-textCmd command
//   - value of a PATH_FLAGS flag
//   - redirect target token (always — bypasses the textCmd exception)
//
// NOT checked:
//   - text-flag values (TEXT_FLAGS) — skipped by construction
//   - positionals of a textCmd (echo/printf) — but redirect targets in the
//     same segment ARE still checked (redirects bypass the textCmd exception)
//   - unknown flag tokens — only the flag itself skipped; the following
//     token is treated as a positional (false-negative prevention)
//
// opts:
//   isTargetPath: (string) => boolean          // REQUIRED
//   textFlags?: Set<string>
//   pathFlags?: Set<string>
//   textCmds?: Set<string>
//   shellBins?: Set<string>
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
  splitSegments,
  stripSubstitutions,
  extractSubstitutionContents,
  REDIRECT_RE,
};
