"use strict";
// FROZEN FIXTURE — verbatim copy of stripDqPreservingCmdSubst() and
// stripQuotedArgs() from hooks/lib/strip-quoted-args.js as of PR #1577
// (pre-#1569 quote-spans refactor). Do NOT edit. Used by
// tests/unit-quote-spans-differential.sh as the old-implementation side.
// Strip DQ literal content while preserving $(...) and `...` command-substitution
// regions. Inside a double-quoted span: literal text collapses to "", and each
// $(...) / `...` is captured then unwrapped by replacing the wrapper chars
// ($(, ), `) with spaces so inner tokens (rm/mv/tee/redirects/git push/...) are
// visible to command-position write-pattern regexes. Outside DQ spans, text
// passes through unchanged. \" / \\ / \` escapes within DQ are skipped.
// Returns the original string on any exception.
//
// Why unwrap rather than preserve verbatim: write-pattern regexes use
// (?:^|[\s;|&])<word>\b as the command-position anchor. The literal `$(` /
// `(` / `` ` `` are not in that anchor set, so preserving verbatim still hides
// inner writes like $(rm foo) and `rm foo` (#514 HIGH gap). Replacing the
// wrapper chars with spaces exposes them while remaining fail-safe (any
// unbalanced or quoted-inside content errs toward 'write' classification).
function stripDqPreservingCmdSubst(str) {
  try {
    let out = "";
    let i = 0;
    const n = str.length;
    while (i < n) {
      const ch = str[i];
      if (ch !== '"') {
        out += ch;
        i++;
        continue;
      }
      // Enter DQ span — find end, accumulating $(...) and `...` regions.
      const preserved = [];
      i++; // skip opening "
      while (i < n) {
        const c = str[i];
        if (c === "\\" && i + 1 < n) {
          // Escape — skip escaped char (drop both inside DQ literal)
          i += 2;
          continue;
        }
        if (c === '"') {
          i++; // consume closing "
          break;
        }
        if (c === "$" && i + 1 < n && str[i + 1] === "(") {
          // Capture $(...) with paren counter
          const start = i;
          i += 2;
          let depth = 1;
          while (i < n && depth > 0) {
            const cc = str[i];
            if (cc === "\\" && i + 1 < n) {
              i += 2;
              continue;
            }
            if (cc === "$" && i + 1 < n && str[i + 1] === "(") {
              depth++;
              i += 2;
              continue;
            }
            if (cc === ")") {
              depth--;
              i++;
              continue;
            }
            i++;
          }
          preserved.push(str.slice(start, i));
          continue;
        }
        if (c === "`") {
          // Capture `...` backtick command substitution (#514 HIGH — sibling
          // of $(...); shell executes both inside DQ).
          const start = i;
          i++; // skip opening `
          while (i < n) {
            const cc = str[i];
            if (cc === "\\" && i + 1 < n) {
              i += 2;
              continue;
            }
            if (cc === "`") {
              i++; // consume closing `
              break;
            }
            i++;
          }
          preserved.push(str.slice(start, i));
          continue;
        }
        // Literal char inside DQ — drop
        i++;
      }
      // Emit: literal collapses to "". Each preserved substitution is unwrapped
      // (wrapper chars → space) and surrounded by spaces so inner write tokens
      // sit at command-position boundaries.
      out += '""';
      for (const p of preserved) {
        const unwrapped = p.replace(/\$\(|\)|`/g, " ");
        out += " " + unwrapped + " ";
      }
    }
    return out;
  } catch (e) {
    return str;
  }
}

function stripQuotedArgs(str) {
  if (!str || typeof str !== "string") return str;
  try {
    return stripDqPreservingCmdSubst(
      str.replace(/\$'(?:[^'\\]|\\.)*'/g, "$''")
    ).replace(/'[^']*'/g, "''");
  } catch (e) {
    return str;
  }
}

// Strip heredoc bodies between the opening tag and closing tag, preserving the
// opener (so here-doc detection in classify() still fires) and a trailing newline.
// Supports <<TAG, <<-TAG, <<'TAG', <<"TAG" forms.

module.exports = { stripQuotedArgs, stripDqPreservingCmdSubst };
