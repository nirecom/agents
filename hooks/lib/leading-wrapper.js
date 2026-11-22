"use strict";
// stripLeadingWrappers(prompt) -> {ok:true, text} | {ok:false, reason, rest} (#2942).
// Claude Code may put wrappers before what the user typed: IDE context (removed) and a paste
// (<pasted_content ...> ... </pasted_content ...>, whose body is unwrapped). Every leading wrapper is
// processed in order. An unclosed wrapper or an unknown leading tag cannot be read safely, so the
// result is ok:false and callers decide which side to fail to; `rest` is the text where reading stopped.
// Tags in TERMINAL are prompt forms, not wrappers: reading stops there with ok:true and they stay in place
// (a <cross-session-message> body is never unwrapped).
// DEPENDENCY-FREE ON PURPOSE: hooks/lib/typed-slash-command.js and step-in-flight-policy.js require it.

const STRIP = new Set(["ide_opened_file", "ide_selection", "system-reminder"]);
const UNWRAP = "pasted_content";
const TERMINAL = new Set([
  "command-message", "command-name", "cross-session-message",
  "local-command-stdout", "local-command-stderr", "local-command-caveat",
  "bash-input", "bash-stdout", "bash-stderr",
]);
const OPEN_RE = /^<([A-Za-z][\w-]*)(\s[^>]*)?>/;
const ID_RE = /\bid="([^"]*)"/;

function fail(reason, rest) {
  return { ok: false, reason, rest };
}

function unwrapPasted(text, open) {
  const idm = ID_RE.exec(open[2] || "");
  const close = idm ? `</${UNWRAP} id="${idm[1]}">` : `</${UNWRAP}>`;
  const body = text.slice(open[0].length);
  const at = body.indexOf(close);
  if (at === -1) return { error: body.includes(`</${UNWRAP}`) ? "pasted-close-mismatch" : "pasted-unclosed" };
  return { text: body.slice(0, at).replace(/^\r?\n/, "") + body.slice(at + close.length) };
}

function stripLeadingWrappers(prompt) {
  if (typeof prompt !== "string") return fail("not-a-string", "");
  let text = prompt.replace(/^\s+/, "");
  for (let open = text.match(OPEN_RE); open; open = text.match(OPEN_RE)) {
    const kind = open[1];
    if (TERMINAL.has(kind)) break;
    if (kind === UNWRAP) {
      const u = unwrapPasted(text, open);
      if (u.error) return fail(u.error, text);
      text = u.text.replace(/^\s+/, "");
      continue;
    }
    if (!STRIP.has(kind)) return fail(`unknown-leading-tag:${kind}`, text);
    const close = `</${kind}>`;
    const at = text.indexOf(close, open[0].length);
    if (at === -1) return fail(`unclosed-leading-tag:${kind}`, text);
    text = text.slice(at + close.length).replace(/^\s+/, "");
  }
  return { ok: true, text };
}

module.exports = { stripLeadingWrappers };
