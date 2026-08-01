"use strict";
// Deterministic "did the user ask for an issue to be CREATED?" classifier.
//
// Two callers run it over the same text: hooks/issue-provenance-mint.js
// (the live prompt, at turn boundary) and bin/github-issues/issue-provenance
// (Layer B — the re-scanned transcript line).
//
// Two matching layers, no LLM, no closed verb list:
//   Layer A  an explicit `/issue-create` slash invocation at line start.
//   Layer B  an issue noun co-occurring with a request modality on one line.
//
// The modality side is deliberately a set of *function words* (request grammar),
// never a verb enumeration: 起票/切る/生やす/積む and their English counterparts
// are unbounded, so enumerating them guarantees false negatives.
//
// DEFINITENESS is what separates "make me an issue" from "look at this issue".
// A verb list cannot do it (the verbs are unbounded in both directions), but
// determiners can: an issue that is being *referred to* is definite ("this issue",
// "the issue", "この課題") or numbered ("issue 123"), while an issue that does not
// exist yet cannot be either. Determiners are a closed grammatical class, so the
// test stays vocabulary-independent — and every rejection lowers privilege, which
// is the safe direction for the caller that consumes this.
//
// Preprocessing strips the regions where such a sentence is being *quoted*
// rather than *uttered*: fenced blocks, inline code spans, and `>` quote lines.
//
// COST: the scan runs on a hook with a 5s budget over text of unbounded length
// (a pasted log is a normal prompt), so the input is capped and every per-noun
// inspection is bounded to a fixed window — no unbounded slice per match.

// --- input bounds -----------------------------------------------------------

// Past this point the text is a paste, not a request. Cutting at a line boundary
// keeps the end-of-line anchors below meaning what they say.
const MAX_SCAN_CHARS = 20000;
// How far after an issue noun a request modality may still belong to it.
const JA_WINDOW = 80;
// How far before an issue noun a determiner may still govern it.
const DET_LOOKBEHIND = 40;

function capInput(text) {
  if (text.length <= MAX_SCAN_CHARS) return text;
  const cut = text.slice(0, MAX_SCAN_CHARS);
  const nl = cut.lastIndexOf("\n");
  return nl > 0 ? cut.slice(0, nl) : cut;
}

// --- preprocessing ----------------------------------------------------------

function stripNonUtterance(text) {
  let s = capInput(String(text));
  s = s.replace(/```[\s\S]*?```/g, "\n"); // fenced blocks (closed)
  s = s.replace(/```[\s\S]*$/g, "\n"); // unterminated trailing fence
  s = s.replace(/`[^`\n]*`/g, " "); // inline code spans
  return s
    .split(/\r?\n/)
    .filter(function (line) { return !/^\s*>/.test(line); })
    .join("\n");
}

// --- Layer A: slash command -------------------------------------------------

const SLASH_RE = /^\s*\/issue-create(\s|$)/;

// Git Bash (MSYS) rewrites a value that starts with `/` into a Windows path
// before handing it to a native binary, so `/issue-create foo` reaches node as
// `C:/Program Files/Git/issue-create foo`. Accept that shape only when the line
// STARTS with a drive-absolute path, so a mid-sentence mention such as
// "the /issue-create skill is documented here" is still not an invocation.
const MANGLED_SLASH_RE = /^\s*[A-Za-z]:[\\/](?:[^\r\n]*[\\/])?issue-create(\s|$)/;

// --- Layer B (ja) -----------------------------------------------------------

const JA_NOUN_RE =
  /(?:(?<![\w/-])(?:issue|ticket)(?![\w-]))|イシュー|課題|チケット|バグ票|不具合票/gi;

// The particle that belongs to the noun itself — skipped before the
// intervening-particle test below.
const JA_LEAD_PARTICLE_RE =
  /^(?:として|について|に関して|に対して|に際して|において|によって|に沿って|[をがはにでともへや])/;

// Request modality, split in two so the end-of-line anchors are only applied when
// the inspection window actually reaches the end of the line.
const JA_MODALITY_FREE = "(?:お願い|よろしく|してくれ|してほしい|しといて|せよ|しろ|しなさい|べき)";
const JA_MODALITY_EOL = "(?:たい$)|(?:[てで](?:ください|くれ|ほしい|おいて|といて)?$)";
const JA_MODALITY_RE = new RegExp(JA_MODALITY_FREE + "|" + JA_MODALITY_EOL);
const JA_MODALITY_TRUNCATED_RE = new RegExp(JA_MODALITY_FREE);

// A て that is the tail of a compound particle is not a request modality.
const JA_COMPOUND_TAILS = [
  "につい", "に関し", "に対し", "に際し", "におい", "によっ", "に沿っ", "とし",
];

// A further case particle between the noun and the modality means the noun is
// the topic of some other predicate, not the object of the request.
const JA_INTERVENING_RE = /[をがは]/;

// Demonstratives and anaphora: the noun they govern already exists.
const JA_DEFINITE_RE = /(?:この|その|あの|該当|当該|既存|上記|前述)(?:の)?$|(?:例|同|当)の$/;
// "課題 123" / "issue #12" — a number identifies an issue that has one.
const JA_NUMBERED_RE = /^[\s　]*(?:#|＃|No\.?|番)?[\s　]*[0-9０-９]/i;

function jaLineMatches(line) {
  JA_NOUN_RE.lastIndex = 0;
  let m;
  while ((m = JA_NOUN_RE.exec(line)) !== null) {
    const nounEnd = m.index + m[0].length;
    if (JA_DEFINITE_RE.test(line.slice(Math.max(0, m.index - DET_LOOKBEHIND), m.index))) continue;
    // Windowed, never `line.slice(nounEnd)`: the tail of a pasted log must not be
    // copied once per noun occurrence.
    const truncated = nounEnd + JA_WINDOW < line.length;
    const window = line.slice(nounEnd, nounEnd + JA_WINDOW);
    if (JA_NUMBERED_RE.test(window)) continue;
    let rest = window.replace(/^[\s　]+/, "");
    rest = rest.replace(JA_LEAD_PARTICLE_RE, "");
    const hit = (truncated ? JA_MODALITY_TRUNCATED_RE : JA_MODALITY_RE).exec(rest);
    if (!hit) continue;
    const prefix = rest.slice(0, hit.index);
    if (JA_INTERVENING_RE.test(prefix)) continue;
    if (/^[てで]/.test(hit[0]) &&
        JA_COMPOUND_TAILS.some(function (t) { return prefix.endsWith(t); })) continue;
    return true;
  }
  return false;
}

// --- Layer B (en) -----------------------------------------------------------

const EN_NOUN_RE = /(?<![\w/-])(?:issues?|tickets?)(?![\w-])/gi;
const EN_MODALITY_RE =
  /\b(?:please|can you|could you|would you|let'?s|need to|want to|should be)\b/i;

// Determiners and possessives that presuppose an existing referent. A closed
// grammatical class — never extended with verbs.
const EN_DEFINITE = new Set([
  "the", "this", "that", "these", "those", "said", "same", "above",
  "my", "your", "our", "their", "its", "his", "her",
  "existing", "current", "original", "previous", "latest", "linked", "related",
]);

// "issue 123" / "ticket #4" — a numbered reference is not a creation target.
const EN_NUMBERED_RE = /^[\s]*#?[\s]*\d/;

function enIndefiniteNoun(line, start, end) {
  if (EN_NUMBERED_RE.test(line.slice(end, end + 8))) return false;
  const before = line.slice(Math.max(0, start - DET_LOOKBEHIND), start).toLowerCase();
  const tokens = before.match(/[a-z']+/g);
  if (!tokens) return true;
  // Two tokens back covers "this open issue" as well as "this issue"; further
  // back the determiner is governing something else.
  return !tokens.slice(-2).some(function (t) { return EN_DEFINITE.has(t); });
}

// Sentence-initial imperative: the first token is a bare lowercase word that is
// not a function word. A closed *stop* set (function words), never a verb list.
const EN_STOPWORDS = new Set([
  "a", "an", "the", "this", "that", "these", "those", "it", "its", "i", "we",
  "you", "they", "he", "she", "his", "her", "my", "our", "your", "their",
  "in", "on", "at", "of", "for", "to", "from", "with", "by", "about", "as",
  "and", "but", "or", "so", "if", "when", "while", "then", "there", "here",
  "is", "are", "was", "were", "be", "been", "being", "am",
  "do", "does", "did", "done", "have", "has", "had",
  "can", "could", "would", "should", "will", "shall", "may", "might", "must",
  "what", "why", "how", "where", "who", "whom", "which", "whose",
  "no", "not", "some", "any", "all", "every", "each",
  "issue", "issues", "ticket", "tickets",
]);

function enImperative(line) {
  const m = line.match(/^[\s*+-]*([a-z][a-z']*)\b/);
  if (!m) return false;
  return !EN_STOPWORDS.has(m[1]);
}

function enLineMatches(line) {
  EN_NOUN_RE.lastIndex = 0;
  let m;
  let creatable = false;
  while ((m = EN_NOUN_RE.exec(line)) !== null) {
    if (enIndefiniteNoun(line, m.index, m.index + m[0].length)) { creatable = true; break; }
  }
  if (!creatable) return false;
  return EN_MODALITY_RE.test(line) || enImperative(line);
}

// --- public API -------------------------------------------------------------

/**
 * Which layer matched — the minting hook records it on the token so a later
 * audit can tell an explicit invocation from a natural-language request.
 * Slash wins over natural whenever both are present anywhere in the text.
 * @param {string} promptText raw user prompt (or transcript line text)
 * @returns {"slash"|"natural"|null}
 */
function issueRequestLayer(promptText) {
  if (typeof promptText !== "string" || promptText.length === 0) return null;
  const lines = stripNonUtterance(promptText).split(/\r?\n/);
  let natural = false;
  for (const line of lines) {
    if (!line.trim()) continue;
    if (SLASH_RE.test(line) || MANGLED_SLASH_RE.test(line)) return "slash";
    if (natural) continue;
    if (jaLineMatches(line) || enLineMatches(line)) natural = true;
  }
  return natural ? "natural" : null;
}

/**
 * @param {string} promptText raw user prompt (or transcript line text)
 * @returns {boolean} true when the text is an explicit issue-creation request
 */
function isIssueCreationRequest(promptText) {
  return issueRequestLayer(promptText) !== null;
}

module.exports = { isIssueCreationRequest, issueRequestLayer };
