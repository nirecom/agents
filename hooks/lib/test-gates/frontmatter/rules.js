"use strict";
// Which paths the frontmatter check covers (#2507 D7; ports _is_supported_test,
// _is_test_entrypoint and _is_flat_test of bin/check-test-frontmatter.sh). Placement follows the
// repo's .agents.json tests section (#2473); without a root, or for an uninitialized repo, the
// legacy layout of registry.layoutFor applies.

const R = require("../registry");

// isSupportedTest(p) — the name matches a supported registry entry; that match, else null.
function isSupportedTest(p) {
  const m = R.match(p);
  return m && m.status === "supported" ? m : null;
}

const baseOf = (rel) => rel.slice(rel.lastIndexOf("/") + 1);

// isTestEntrypoint(rel, root) — { hlPath, hlRe, hlShared } of a <dir>/<file> or <dir>/<category>/<file>
// whose entry has a helperLibrary, else null. hlShared: its sharedSourceRegex, or undefined.
function isTestEntrypoint(rel, root) {
  const p = R.placementOf(root, rel);
  if (p.kind !== "category" && p.kind !== "flat") return null;
  const m = isSupportedTest(baseOf(rel));
  if (!m) return null;
  const hlPath = R.fieldValue(m.entry, "helperLibrary.path");
  const hlRe = R.fieldValue(m.entry, "helperLibrary.sourceRegex");
  const hlShared = R.fieldValue(m.entry, "helperLibrary.sharedSourceRegex");
  return hlPath && hlRe ? { hlPath, hlRe, hlShared } : null;
}

// isFlatTest(rel, root) — the match of a flat <dir>/<file> of a supported entry, in a repo whose
// categorization is not flat (run-all.sh exempt).
function isFlatTest(rel, root) {
  const l = R.layoutFor(root);
  if (l.categorization === "flat") return null;
  if (R.placementOf(root, rel).kind !== "flat") return null;
  return isSupportedTest(baseOf(rel));
}

const within = (tok, cover) => tok === cover || tok.startsWith(`${cover}/`);

// coversMismatch(f, rel, root, testsLine) — the TEST_CATEGORY_MISMATCH WARN of a by-target category
// test none of whose `# Tests:` tokens lies within its category's covers, else null. Never blocks.
function coversMismatch(f, rel, root, testsLine) {
  const l = R.layoutFor(root);
  if (!l.initialized || l.categorization !== "by-target") return null;
  const p = R.placementOf(root, rel);
  if (p.kind !== "category") return null;
  const cat = l.categories.find((c) => c.dir === p.category);
  const covers = (cat && cat.covers) || [];
  const csv = testsLine ? testsLine.slice(testsLine.indexOf("Tests:") + "Tests:".length) : "";
  const toks = csv.split(",").map((t) => t.trim().replace(/^\.\//, "")).filter(Boolean);
  if (!toks.length || toks.some((t) => covers.some((c) => within(t, c)))) return null;
  return `WARN: ${f}: no Tests: target lies within the covers of category ${p.category} (${covers.join(", ")}); move it to the category of its target code=TEST_CATEGORY_MISMATCH`;
}

module.exports = { isSupportedTest, isTestEntrypoint, isFlatTest, coversMismatch };
