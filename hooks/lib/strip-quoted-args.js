"use strict";

function stripQuotedArgs(str) {
  if (!str || typeof str !== "string") return str;
  try {
    return str
      .replace(/\$'(?:[^'\\]|\\.)*'/g, "$''")
      .replace(/"(?:[^"\\]|\\.)*"/g, '""')
      .replace(/'[^']*'/g, "''");
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
function stripInlineBodyArg(str) {
  if (!str || typeof str !== "string") return str;
  try {
    return str
      .replace(/(--(?:body|title)|-[bt])(?:\s+|=)"(?:[^"\\]|\\.)*"/g, '$1 ""')
      .replace(/(--(?:body|title)|-[bt])(?:\s+|=)'[^']*'/g, "$1 ''");
  } catch (e) {
    return str;
  }
}

module.exports = { stripQuotedArgs, stripHeredocBody, stripInlineBodyArg };
