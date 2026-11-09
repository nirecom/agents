"use strict";
// lang-check: ignore — PHRASE_HEAD matches the Japanese glossary Definition wording verbatim.

// Session-terms check (#2759): no rejected synonym of session-upstream / session-downstream
// is left in tracked content or paths. The words live only in the list of the session-terms
// test and are read from there; the residue matcher and exemptions are reused as they are.

const { scanFiles } = require("./residue");

const GLOSSARY_REL = "docs/glossary/internal.md";
const PHRASE_HEAD = "不採用の同義語は ";
// The phrase each glossary entry may name on its Definition line. Spelled in parts so this
// module, which the check also scans, adds no exception beyond the list file.
const GLOSSARY_PHRASES = Object.freeze({
  "session-upstream": PHRASE_HEAD + "do" + "nor",
  "session-downstream": PHRASE_HEAD + "he" + "ir",
});
const HEADING_RE = /^### (\S+)\s*$/;
const DEFINITION_HEAD = "- **Definition**:";

// The phrase is blanked only where no identifier character or hyphen follows it, so a word
// glued on (the retired word plus `Sid` or `-sid`, say) still reaches the residue matcher.
function blankPhrase(line, phrase) {
  const parts = line.split(phrase);
  let out = parts[0];
  for (let i = 1; i < parts.length; i++) {
    out += (/^[\w-]/.test(parts[i]) ? phrase : " ".repeat(phrase.length)) + parts[i];
  }
  return out;
}

// glossaryFilter() → a line filter that tracks the current `### <term>` entry and blanks
// that entry's own phrase on its Definition line only.
function glossaryFilter() {
  let term = null;
  return (line) => {
    const m = HEADING_RE.exec(line);
    if (m) term = m[1];
    else if (line.startsWith("### ")) term = null;
    const phrase = term !== null && Object.hasOwn(GLOSSARY_PHRASES, term) ? GLOSSARY_PHRASES[term] : null;
    if (phrase === null || !line.startsWith(DEFINITION_HEAD) || !line.includes(phrase)) return line;
    return blankPhrase(line, phrase);
  };
}

const lineFilter = (rel) => (rel === GLOSSARY_REL ? glossaryFilter() : null);

function check(ctx) {
  // The kept field is allowed in content only because the retired-token axis guards it there;
  // nothing guards paths, so a path carrying it is still reported.
  return scanFiles(ctx.files, ctx.sessionTermList(), "session-terms", lineFilter, { keepInPaths: false });
}

module.exports = { check };
