"use strict";
// hooks/lib/plan-schema.js — language-neutral SSOT for plan-artifact schema:
// canonical H2 heading names (per artifact type, in canonical order), the
// localized->canonical heading map, and query helpers. Every enforcer (the
// PLAN_LANG linter, the bash assembler via the CLI bridge, the sweep tool via
// direct require) reads canonical names, order and mappings from here so the
// three cannot drift apart. See docs plan #2228/#2338/#2339.

const ACCEPTED_TRADEOFFS_STAGES = Object.freeze(["intent", "outline", "detail"]);
const LEGACY_ACCEPTED_TRADEOFFS = "Accepted Tradeoffs";
// #2924: each stage writes only its own staged heading; the legacy one reads as intent.
function acceptedTradeoffsHeading(stage) {
  return ACCEPTED_TRADEOFFS_STAGES.includes(stage) ? `${LEGACY_ACCEPTED_TRADEOFFS} (${stage})` : null;
}

// Canonical H2 section names in canonical order, per artifact type. intent order
// follows skills/clarify-intent/reference/intent-md-schema.md "Section order";
// outline order is the #2228 importance-ordered schema; detail order follows the
// detail plan template.
const CANONICAL_SECTIONS = Object.freeze({
  intent: Object.freeze([
    "Issues",
    "Glossary",
    "Background/Motivation",
    "Scope",
    "Constraints",
    "Interview Log",
    "Class members",
    acceptedTradeoffsHeading("intent"),
    "worktrees",
  ]),
  outline: Object.freeze([
    "Issues",
    "Adopted approach",
    "Delivery plan",
    "Considered alternatives (rejected)",
    acceptedTradeoffsHeading("outline"),
    "Confirmed non-goals",
    "Reused existing utilities / building blocks",
  ]),
  detail: Object.freeze([
    "Delivery plan",
    "Background",
    "Files to modify",
    "Steps",
    "Risks & edge cases",
    acceptedTradeoffsHeading("detail"),
    "Out of scope",
  ]),
});

// Known localized (Japanese) heading variants -> canonical English name.
// japanese is the only non-English strict PLAN_LANG policy, so Japanese variants
// suffice. Best-effort backstop (per plan Step 1): detects known variants only;
// prose directives and the sweep tool are the primary defense.
const LOCALIZED_TO_CANONICAL = Object.freeze({
  // lang-check: ignore — the keys below are Japanese heading variants (functional data).
  "課題": "Issues",
  "イシュー": "Issues",
  "対象Issue": "Issues",
  "対象イシュー": "Issues",
  "採用アプローチ": "Adopted approach",
  "採用したアプローチ": "Adopted approach",
  "採択アプローチ": "Adopted approach",
  "納品プラン": "Delivery plan",
  "デリバリープラン": "Delivery plan",
  "納品計画": "Delivery plan",
  "検討した代替案（却下）": "Considered alternatives (rejected)",
  "検討した代替案(却下)": "Considered alternatives (rejected)",
  "検討した代替案": "Considered alternatives (rejected)",
  "却下した代替案": "Considered alternatives (rejected)",
  "受容したトレードオフ": "Accepted Tradeoffs",
  "許容したトレードオフ": "Accepted Tradeoffs",
  "受け入れたトレードオフ": "Accepted Tradeoffs",
  "確認済み非目標": "Confirmed non-goals",
  "確認済みの非目標": "Confirmed non-goals",
  "非目標": "Confirmed non-goals",
  "再利用する既存ユーティリティ / ビルディングブロック": "Reused existing utilities / building blocks",
  "再利用する既存ユーティリティ": "Reused existing utilities / building blocks",
  "再利用した既存ユーティリティ": "Reused existing utilities / building blocks",
  "背景": "Background",
  "背景・動機": "Background/Motivation",
  "背景/動機": "Background/Motivation",
  "背景と動機": "Background/Motivation",
  "スコープ": "Scope",
  "対象範囲": "Scope",
  "制約": "Constraints",
  "制約事項": "Constraints",
  "インタビューログ": "Interview Log",
  "変更するファイル": "Files to modify",
  "修正するファイル": "Files to modify",
  "変更対象ファイル": "Files to modify",
  "手順": "Steps",
  "ステップ": "Steps",
  "リスクとエッジケース": "Risks & edge cases",
  "リスク・エッジケース": "Risks & edge cases",
  "リスクおよびエッジケース": "Risks & edge cases",
  "スコープ外": "Out of scope",
  "対象外": "Out of scope",
  "範囲外": "Out of scope",
  "クラスメンバー": "Class members",
  "クラスメンバ": "Class members",
});

// Set of every canonical English literal across all artifact types, for O(1)
// "is this text already canonical" checks.
const CANONICAL_LITERALS = new Set();
for (const type of Object.keys(CANONICAL_SECTIONS)) {
  for (const name of CANONICAL_SECTIONS[type]) CANONICAL_LITERALS.add(name);
}
CANONICAL_LITERALS.add(LEGACY_ACCEPTED_TRADEOFFS);

const FIRST_BODY_SECTION = Object.freeze({
  outline: "Adopted approach",
  detail: "Delivery plan",
});

// Resolve an H2 heading to its canonical English name, or null when unknown.
// Accepts either the bare heading text or a full H2 line (leading `#` markers are
// stripped). A canonical English literal resolves to itself; a known localized
// variant resolves to its canonical name; anything else is null.
function canonicalizeHeading(text) {
  if (typeof text !== "string") return null;
  const trimmed = text.trim().replace(/^#+\s*/, "").trim();
  if (trimmed.length === 0) return null;
  if (CANONICAL_LITERALS.has(trimmed)) return trimmed;
  if (Object.prototype.hasOwnProperty.call(LOCALIZED_TO_CANONICAL, trimmed)) {
    return LOCALIZED_TO_CANONICAL[trimmed];
  }
  return null;
}

// First body section for an artifact type (the assemble hard-check target).
function firstBodySection(artifactType) {
  return FIRST_BODY_SECTION[artifactType] || null;
}

// Stage of an Accepted Tradeoffs heading (bare text or H2 line): the staged
// literal yields its stage, the legacy literal yields "intent", else null.
function acceptedTradeoffsStage(heading) {
  if (typeof heading !== "string") return null;
  const t = heading.trim().replace(/^#+\s*/, "").trim();
  if (t === LEGACY_ACCEPTED_TRADEOFFS) return "intent";
  for (const stage of ACCEPTED_TRADEOFFS_STAGES) {
    if (t === acceptedTradeoffsHeading(stage)) return stage;
  }
  return null;
}

module.exports = {
  CANONICAL_SECTIONS,
  LOCALIZED_TO_CANONICAL,
  ACCEPTED_TRADEOFFS_STAGES,
  LEGACY_ACCEPTED_TRADEOFFS,
  acceptedTradeoffsHeading,
  acceptedTradeoffsStage,
  canonicalizeHeading,
  firstBodySection,
};

if (require.main === module) {
  const args = process.argv.slice(2);
  const flag = args[0];
  if (flag === "--first-body-section") {
    const out = firstBodySection(args[1]);
    if (out === null) process.exit(1);
    process.stdout.write(out + "\n");
  } else if (flag === "--order") {
    const order = CANONICAL_SECTIONS[args[1]];
    if (!order) process.exit(1);
    process.stdout.write(JSON.stringify(order) + "\n");
  } else if (flag === "--localized-to-canonical") {
    process.stdout.write(JSON.stringify(LOCALIZED_TO_CANONICAL) + "\n");
  } else if (flag === "--accepted-tradeoffs-heading") {
    const out = acceptedTradeoffsHeading(args[1]);
    if (out === null) process.exit(1);
    process.stdout.write(out + "\n");
  } else if (flag === "--accepted-tradeoffs-headings") {
    const all = ACCEPTED_TRADEOFFS_STAGES.map(acceptedTradeoffsHeading).concat([LEGACY_ACCEPTED_TRADEOFFS]);
    process.stdout.write(all.join("\n") + "\n");
  } else {
    process.stderr.write("usage: plan-schema.js --first-body-section <type> | --order <type> | --localized-to-canonical | --accepted-tradeoffs-heading <stage> | --accepted-tradeoffs-headings\n");
    process.exit(2);
  }
}
