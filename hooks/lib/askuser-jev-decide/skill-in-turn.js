"use strict";
// skill-in-turn.js — whether a Skill ran since the last real user prompt (#2764). A dialog raised
// inside a skill is the skill's own question, so it always reaches the user. Every doubt (no
// transcript, an unreadable file, any unparsable line, no real prompt) answers true.

const fs = require("fs");
const { isRealUserPrompt } = require("../transcript-reader");

const COMMAND_NAME = "<command-name>";

const itemsOf = (e) => {
  const c = e && e.message && e.message.content;
  return typeof c === "string" ? [{ type: "text", text: c }] : (Array.isArray(c) ? c : []);
};

// A Skill tool call, or a slash-command skill injection on a user-role entry.
function isSkillInvocation(e) {
  if (!e || typeof e !== "object") return false;
  if (e.type === "assistant") return itemsOf(e).some((it) => it && it.type === "tool_use" && it.name === "Skill");
  if (e.type !== "user") return false;
  return itemsOf(e).some((it) => it && it.type === "text" && typeof it.text === "string" && it.text.includes(COMMAND_NAME));
}

const isOpeningPrompt = (e) => isRealUserPrompt(e) && e.isSidechain !== true;

// skillInTurn(transcriptPath) -> false only when the transcript reads cleanly and no Skill was
// invoked at or after its last real user prompt.
function skillInTurn(transcriptPath) {
  if (typeof transcriptPath !== "string" || transcriptPath === "") return true;
  let entries;
  try {
    entries = fs.readFileSync(transcriptPath, "utf8").split("\n").filter((l) => l.trim() !== "").map((l) => JSON.parse(l));
  } catch (_e) {
    return true;
  }
  let start = -1;
  for (let i = entries.length - 1; i >= 0; i--) {
    if (isOpeningPrompt(entries[i])) { start = i; break; }
  }
  if (start < 0) return true;
  return entries.slice(start).some(isSkillInvocation);
}

module.exports = { skillInTurn };
