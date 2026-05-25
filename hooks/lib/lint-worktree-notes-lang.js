"use strict";

// Detect CJK characters in enforced sections of WORKTREE_NOTES.md.
// Returns an array of {section, line, lineNumber} violation objects.

// Hiragana, Katakana, CJK Unified Ideographs, CJK Compatibility Ideographs,
// CJK Symbols/Punctuation, full-width forms.
const CJK_RE = /[　-鿿豈-﫿＀-￯]/u;

const SECTION_HISTORY = "History Notes";
const SECTION_CHANGELOG = "Changelog Notes";

function enforcementFor(section, config, isPrivateRepo) {
  if (section === SECTION_HISTORY) return config.history;
  if (section === SECTION_CHANGELOG) {
    return isPrivateRepo ? config.changelogPrivate : config.changelogPublic;
  }
  return "any";
}

// Walk the document and collect "- " bullets under each targeted `## <heading>`
// section. Only exact `## ` level matches — `### ` headings are NOT targeted.
function collectBullets(content, targetHeadings) {
  const lines = content.split(/\r?\n/);
  let currentSection = null;
  const bullets = [];
  for (let i = 0; i < lines.length; i += 1) {
    const line = lines[i];
    if (line.startsWith("## ")) {
      const heading = line.slice(3).trim();
      currentSection = targetHeadings.includes(heading) ? heading : null;
      continue;
    }
    // Any other `## ` or `### ` would terminate the previous section — handled
    // by the heading check above for `## ` (re-evaluates currentSection).
    // `### ` does not change `## `-level current section, so bullets under
    // a `### ` subsection still count as part of the enclosing `## ` section.
    if (currentSection === null) continue;
    if (!line.startsWith("- ")) continue;
    const bulletText = line.slice(2).trim();
    if (!bulletText || bulletText === "(none)") continue;
    bullets.push({
      section: currentSection,
      line: bulletText,
      lineNumber: i + 1,
    });
  }
  return bullets;
}

function lintWorktreeNotesLang(content, config, options) {
  const opts = options || {};
  const skipHistory = opts.skipHistory === true;
  const isPrivateRepo = opts.isPrivateRepo === true;

  const targetHeadings = [];
  if (!skipHistory) targetHeadings.push(SECTION_HISTORY);
  targetHeadings.push(SECTION_CHANGELOG);

  const bullets = collectBullets(content || "", targetHeadings);
  const violations = [];
  for (const b of bullets) {
    const policy = enforcementFor(b.section, config, isPrivateRepo);
    if (policy !== "english") continue;
    if (CJK_RE.test(b.line)) {
      violations.push({
        section: b.section,
        line: b.line,
        lineNumber: b.lineNumber,
      });
    }
  }
  return violations;
}

module.exports = { lintWorktreeNotesLang };
