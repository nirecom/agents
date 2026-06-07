"use strict";

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
//
// Safety constraints (#371 codex review HIGH findings):
//   1. Only strip heredocs preceded by `cat` — interpreter heredocs like
//      `bash <<EOF` execute their body and must not be stripped.
//   2. Preserve rest-of-line after the opener (e.g. `> out.txt` redirect on the
//      same line as `<<EOF`) so external redirects remain visible to scanning.
//   3. If the opener is unquoted AND the body contains `$(...)` or backticks,
//      do not strip — shell expansion would execute the inner commands.
//      Quoted openers (`<<'EOF'` / `<<"EOF"`) prevent expansion → safe.
function stripHeredocBody(str) {
  if (!str || typeof str !== "string") return str;
  try {
    return str.replace(
      /(\bcat\s*)(<<-?\s*(['"]?)(\w+)\3)([^\n]*)\n([\s\S]*?)\n\s*\4\s*(?:\n|$)/g,
      function (match, catPart, opener, quoteChar, _tagName, restOfLine, body) {
        const isQuoted = quoteChar === "'" || quoteChar === '"';
        if (!isQuoted && /\$\(|`/.test(body)) {
          return match;
        }
        return catPart + opener + restOfLine + "\n";
      }
    );
  } catch (e) {
    return str;
  }
}

// Strip values of inline --body / --title arguments (and short forms -b/-t)
// to neutralize write-pattern false positives in Group A gh commands and
// known-path dispatcher scripts. Both space-separated (--body "...") and
// equals-sign (--body="...") forms are stripped. --body-file is INTENTIONALLY
// EXCLUDED — it is a file path, not body text; stripping it would hide
// suspicious paths from the classifier.
//
// Safety guard (#514 HIGH): for DQ form only, do NOT strip when the body
// contains $(...) or backticks. Shell expands command substitution inside
// DQ before gh receives the argument, so stripping would hide executable
// content (e.g. `gh pr create --body "$(bash <<EOF\nrm -rf /\nEOF\n)"`).
// SQ form is safe — shell does not expand inside single quotes.
function stripInlineBodyArg(str) {
  if (!str || typeof str !== "string") return str;
  try {
    return str
      .replace(/(--(?:body|title)|-[bt])(?:\s+|=)"((?:[^"\\]|\\.)*)"/g, function (match, flag, body) {
        if (/\$\(|`/.test(body)) return match;
        return flag + ' ""';
      })
      .replace(/(--(?:body|title)|-[bt])(?:\s+|=)'[^']*'/g, "$1 ''");
  } catch (e) {
    return str;
  }
}

// Strip values of shell variable assignments: IDENTIFIER='...' and IDENTIFIER="...".
// Anchored to line-start or after whitespace/command-separator to avoid partial matches.
// keep in sync with bash-write-patterns.js classify() Group A re-strip block
function stripShellVarAssignment(str) {
  if (!str || typeof str !== "string") return str;
  try {
    return str
      .replace(/(^|[\s;|&])([A-Za-z_][A-Za-z0-9_]*=)'[^']*'/gms, "$1$2''")
      .replace(/(^|[\s;|&])([A-Za-z_][A-Za-z0-9_]*=)"(?:[^"\\]|\\.)*"/gm, '$1$2""');
  } catch (e) {
    return str;
  }
}

module.exports = { stripQuotedArgs, stripHeredocBody, stripInlineBodyArg, stripShellVarAssignment };
