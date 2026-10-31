"use strict";
// Which paths the frontmatter check covers (#2507 D7; ports _is_supported_test,
// _is_test_entrypoint and _is_flat_test of bin/check-test-frontmatter.sh).

const R = require("../registry");

// isSupportedTest(p) — the name matches a supported registry entry; that match, else null.
function isSupportedTest(p) {
  const m = R.match(p);
  return m && m.status === "supported" ? m : null;
}

// isTestEntrypoint(rel) — { hlPath, hlRe } of a tests/<file> or tests/<category>/<file> whose
// entry has a helperLibrary, else null.
function isTestEntrypoint(rel) {
  if (!rel.startsWith("tests/")) return null;
  const base = rel.slice("tests/".length);
  if (base.includes("/")) {
    const cat = base.slice(0, base.indexOf("/"));
    const rest = base.slice(base.indexOf("/") + 1);
    if (!R.CATEGORIES.includes(cat) || rest.includes("/")) return null;
  }
  const m = isSupportedTest(base);
  if (!m) return null;
  const hlPath = R.fieldValue(m.entry, "helperLibrary.path");
  const hlRe = R.fieldValue(m.entry, "helperLibrary.sourceRegex");
  return hlPath && hlRe ? { hlPath, hlRe } : null;
}

// isFlatTest(rel) — the match of a flat tests/<file> of a supported entry (run-all.sh exempt).
function isFlatTest(rel) {
  if (!rel.startsWith("tests/")) return null;
  const base = rel.slice("tests/".length);
  if (base.includes("/") || base === "run-all.sh") return null;
  return isSupportedTest(base);
}

module.exports = { isSupportedTest, isTestEntrypoint, isFlatTest };
