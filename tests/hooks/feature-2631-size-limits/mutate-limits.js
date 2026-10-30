"use strict";
// SSOT-propagation fixture of the #2631 tests: rewrites LIMITS[kind] of a copied
// hooks/lib/size-limits.js so a consumer holding its own copy of the numbers disagrees with it.
// JS: limitsTree(dir, kind, warn, hard) copies hooks/ bin/ rules/ into dir, then rewrites.
// CLI (bash tests): node mutate-limits.js <tree> <kind> <warn> <hard> rewrites in place; exit 0
// only when the rewritten module reports the new numbers and judge() follows them.

const fs = require("fs");
const path = require("path");

const ROOT = path.resolve(__dirname, "..", "..", "..");

function rewrite(tree, kind, warn, hard) {
  const file = path.join(tree, "hooks", "lib", "size-limits.js");
  if (!fs.existsSync(file)) return `missing ${file}`;
  const before = (require(file).LIMITS || {})[kind];
  if (!before) return `no LIMITS.${kind} in ${file}`;
  const src = fs.readFileSync(file, "utf8");
  const decl = src.search(/\bLIMITS\s*=/);
  const key = new RegExp(`["']?\\b${kind}["']?\\s*:`, "g");
  key.lastIndex = Math.max(0, decl === -1 ? src.indexOf("LIMITS") : decl);
  const m = key.exec(src);
  if (!m) return `no "${kind}:" entry after LIMITS in ${file}`;
  const rest = src.slice(m.index);
  const close = rest.search(/[}\])]/);
  if (close === -1) return `unterminated LIMITS.${kind} entry`;
  const seg = rest.slice(0, close + 1)
    .replace(new RegExp(`\\b${before.warn}\\b`), "\u0000W").replace(new RegExp(`\\b${before.hard}\\b`), "\u0000H")
    .replace("\u0000W", String(warn)).replace("\u0000H", String(hard));
  fs.writeFileSync(file, src.slice(0, m.index) + seg + rest.slice(close + 1));
  delete require.cache[require.resolve(file)];
  const L = require(file);
  const got = (L.LIMITS || {})[kind] || {};
  if (got.warn !== warn || got.hard !== hard) return `LIMITS.${kind} = ${JSON.stringify(got)} after the rewrite`;
  const v = (n) => (L.judge(kind, 0, n) || {}).verdict;
  if (v(hard + 1) !== "hard" || v(hard) !== "warn" || v(warn) !== "ok") return `judge() does not follow LIMITS.${kind}`;
  return "";
}

// limitsTree(dir, kind, warn, hard) -> { ok, detail, hook } — hook: the copied block-post-edit-size.js.
function limitsTree(dir, kind, warn, hard) {
  let detail;
  try {
    for (const d of ["hooks", "bin", "rules"]) fs.cpSync(path.join(ROOT, d), path.join(dir, d), { recursive: true });
    detail = rewrite(dir, kind, warn, hard);
  } catch (e) {
    detail = (e && (e.code ? e.code + " " : "") + e.message) || String(e);
  }
  return { ok: detail === "", detail, hook: path.join(dir, "hooks", "block-post-edit-size.js") };
}

module.exports = { limitsTree, rewrite };

if (require.main === module) {
  const [tree, kind, warn, hard] = process.argv.slice(2);
  let detail;
  try { detail = rewrite(path.resolve(tree), kind, Number(warn), Number(hard)); } catch (e) { detail = (e && e.message) || String(e); }
  if (detail) { process.stderr.write(`mutate-limits: ${detail}\n`); process.exit(1); }
}
