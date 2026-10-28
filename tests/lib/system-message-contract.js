"use strict";
// tests/lib/system-message-contract.js
// The systemMessage contract of #2731 (detail S3): every line starts with a bracketed tag, and after
// the tag carries only facts — identifiers, paths, URLs, numbers, enum values, key=value pairs and
// quoted command strings — never "Click Allow" and never English prose: a run of 2 or more plain words,
// or a lone Capitalized word ("Retry"); a lone lowercase / ALL-CAPS word passes as an enum value.
// Explanations go to the model-facing path (reason / additionalContext), which starts with the
// CONV_LANG directive exactly once.
// JS: const C = require("../lib/system-message-contract");
// CLI (bash tests): node system-message-contract.js check <msg>   -> "OK" | "BAD:<problem> | ..."
//                   node system-message-contract.js prefix <text> [lang] -> "<count>:<starts|not-start>"

const DIRECTIVE_HEAD = "Respond to the user in ";

function directiveSentence(lang) {
  return `${DIRECTIVE_HEAD}${lang}.`;
}

// countDirective(text) — how many times the CONV_LANG directive head appears.
function countDirective(text) {
  return String(text || "").split(DIRECTIVE_HEAD).length - 1;
}

// prefixedOnce(text, lang) — starts with the directive sentence and carries the head exactly once.
function prefixedOnce(text, lang = "japanese") {
  const s = String(text || "");
  return s.startsWith(directiveSentence(lang)) && countDirective(s) === 1;
}

// Tokens that are facts by form, removed before the English-run scan.
function stripFacts(rest) {
  return rest
    .replace(/"[^"]*"/g, " ")
    .replace(/'[^']*'/g, " ")
    .replace(/https?:\/\/\S+/g, " ")
    .replace(/\S*=\S*/g, " ")
    .replace(/\S*[/\\]\S*/g, " ");
}

// A plain English word: letters only, at most one trailing punctuation mark.
const WORD = /^[A-Za-z]+[.,:;!?]?$/;

// Sentence-cased word ("Retry", "Run."): prose even alone, unlike an enum value ("block", "WARN").
const CAPITALIZED = /^[A-Z][a-z]+[.,:;!?]?$/;

// proseRuns(rest) -> { longest, capitalizedAlone } over the plain-word runs left after stripFacts.
function proseRuns(rest) {
  let longest = 0;
  let capitalizedAlone = false;
  let run = [];
  const flush = () => {
    if (run.length > longest) longest = run.length;
    if (run.length === 1 && CAPITALIZED.test(run[0])) capitalizedAlone = true;
    run = [];
  };
  for (const tok of stripFacts(rest).split(/\s+/).filter(Boolean)) {
    if (WORD.test(tok)) run.push(tok);
    else flush();
  }
  flush();
  return { longest, capitalizedAlone };
}

// systemMessageProblems(msg) — every contract break found; empty when the message conforms.
function systemMessageProblems(msg) {
  const problems = [];
  const text = String(msg == null ? "" : msg);
  if (text.trim() === "") return ["empty"];
  if (/Click Allow/.test(text)) problems.push("click-allow");
  if (text.includes(DIRECTIVE_HEAD)) problems.push("directive-in-system-message");
  text.split(/\r?\n/).forEach((line, i) => {
    const m = /^\[[^\]]+\]/.exec(line);
    if (!m) {
      problems.push(`line${i + 1}-untagged:${line.slice(0, 60)}`);
      return;
    }
    const { longest, capitalizedAlone } = proseRuns(line.slice(m[0].length));
    if (longest >= 2) problems.push(`line${i + 1}-english-run(${longest}):${line.slice(0, 80)}`);
    else if (capitalizedAlone) problems.push(`line${i + 1}-english-word:${line.slice(0, 80)}`);
  });
  return problems;
}

function assertSystemMessageContract(msg, label = "systemMessage") {
  const problems = systemMessageProblems(msg);
  if (problems.length) throw new Error(`${label} breaks the contract: ${problems.join(" | ")}\n---\n${msg}`);
}

module.exports = {
  DIRECTIVE_HEAD,
  directiveSentence,
  countDirective,
  prefixedOnce,
  systemMessageProblems,
  assertSystemMessageContract,
};

if (require.main === module) {
  const [cmd, text, lang] = process.argv.slice(2);
  if (cmd === "check") {
    const p = systemMessageProblems(text);
    process.stdout.write(p.length ? `BAD:${p.join(" | ")}` : "OK");
  } else if (cmd === "prefix") {
    const s = String(text || "");
    process.stdout.write(`${countDirective(s)}:${s.startsWith(directiveSentence(lang || "japanese")) ? "starts" : "not-start"}`);
  } else {
    process.stderr.write("usage: system-message-contract.js check <msg> | prefix <text> [lang]\n");
    process.exitCode = 2;
  }
}
