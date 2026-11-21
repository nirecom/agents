// hooks/lib/prompt-invokes-skill.js
// Shared slash-command detection for UserPromptSubmit writers (off-emergency provenance, #2019
// finding approval). The <command-name>-wrapped form counts on any line; the bare `/skill` form
// only on the FIRST line — later lines may be prose or a fenced block, not an invocation.
"use strict";

const SKILL_NAME_RE = /^[A-Za-z0-9_-]+$/;

function skillInvocationRes(skill) {
  if (!SKILL_NAME_RE.test(String(skill))) throw new Error(`invalid skill name: ${JSON.stringify(skill)}`);
  const name = `(?:[A-Za-z0-9_-]+:)?${skill}(?![\\w-])`;
  return {
    wrapped: new RegExp(`^[ \\t]*<command-name>\\/${name}`, "m"),
    bare: new RegExp(`^[ \\t]*\\/${name}`),
  };
}

function promptInvokesSkill(prompt, skill) {
  if (typeof prompt !== "string") return false;
  const { wrapped, bare } = skillInvocationRes(skill);
  return wrapped.test(prompt) || bare.test(prompt);
}

module.exports = { skillInvocationRes, promptInvokesSkill };
