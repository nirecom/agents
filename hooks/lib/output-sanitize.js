"use strict";
// output-sanitize.js — SSOT for neutralizing untrusted text that re-enters a
// Claude Code transcript.
//
// Under hooks/lib/ because the dispatcher is no longer the only writer of
// untrusted bytes: hooks/workflow-run-tests.js stores a raw command as state
// text, and an unredacted `<<WORKFLOW…` there is indistinguishable from a real
// sentinel — one substitution, one owner, so the boundaries cannot drift.
//
// bin/worker-dispatch/emit.js re-exports these as plain enumerable properties;
// a test scans that source, so the re-export must never become a getter.

const SENTINEL_REDACT_RE = /<<\s*WORKFLOW/gi;

const MAX_LINE = 500;

const TAB_CODE = 9;
const SPACE_CODE = 32;
const DEL_CODE = 127;

// Every C0 control (including CR/LF) and DEL becomes a space; TAB survives.
// Written as a code-point walk rather than a regex escape class so the source
// carries no literal control bytes of its own.
function collapseControl(input) {
  let out = "";
  for (const ch of input) {
    const code = ch.codePointAt(0);
    out += (code < SPACE_CODE && code !== TAB_CODE) || code === DEL_CODE ? " " : ch;
  }
  return out;
}

// The redaction step on its own, for a boundary that must keep the original
// whitespace and length — e.g. an artifact file the calling skill reads.
function redactSentinels(input) {
  return String(input === null || input === undefined ? "" : input).replace(
    SENTINEL_REDACT_RE,
    "<<_REDACTED_WORKFLOW",
  );
}

// Collapse + redact + length-cap, in that order: collapsing first denies a
// newline-split sentinel, redacting second catches what collapsing revealed.
function sanitizeLine(input, maxLen) {
  let out = input === null || input === undefined ? "" : String(input);
  out = collapseControl(out);
  out = out.replace(SENTINEL_REDACT_RE, "<<_REDACTED_WORKFLOW");
  const limit = typeof maxLen === "number" && maxLen > 0 ? maxLen : MAX_LINE;
  if (out.length > limit) out = `${out.slice(0, limit - 3)}...`;
  return out;
}

// --- credential redaction --------------------------------------------------
//
// A command line carries the caller's credentials as ordinary argument values,
// and anything copying it into durable state text copies those too. Sentinel
// and secret redaction stay separate functions because they answer different
// questions, and a caller that only renders output must not silently rewrite
// its payloads.
//
// Shapes are the vendor prefixes bin/scan-outbound.sh blocks; detection is
// shape-based, so a false positive costs characters and a miss costs a leak.
const SECRET_VALUE_PATTERNS = [
  // A PEM private key block. Matched whole — header, body and footer — so the
  // secret cannot survive as a fragment. `[\s\S]*?` spans the multi-line
  // spelling, the space-collapsed one (workflow-run-tests.js collapses control
  // bytes BEFORE redacting) and the `\n`-escaped one embedded in a JSON string.
  /-----BEGIN (?:[A-Z][A-Z ]*[A-Z] )?PRIVATE KEY-----[\s\S]*?-----END (?:[A-Z][A-Z ]*[A-Z] )?PRIVATE KEY-----/g,
  /sk-ant-(?:api|sid)[0-9]{2}-[A-Za-z0-9_-]{20,}/g, // Anthropic (before the generic sk- form)
  /sk-(?:proj-|svcacct-)?[A-Za-z0-9_-]{20,}/g, // OpenAI
  /AKIA[0-9A-Z]{16}/g, // AWS access key id
  /github_pat_[A-Za-z0-9_]{20,}/g, // GitHub fine-grained PAT (gh[pousr]_ cannot match it)
  /gh[pousr]_[A-Za-z0-9]{20,}/g, // GitHub token (classic short form)
  /xox[abposr]-[A-Za-z0-9-]{10,}/g, // Slack token
  /AIzaSy[A-Za-z0-9_-]{33}/g, // Google / GCP API key
  // URL-embedded credentials (`https://user:pass@host/…`): no option name and
  // no vendor prefix, so neither the assign form nor the shapes above see it.
  // Only the userinfo is replaced — scheme and host stay readable, because
  // attribution needs to say WHICH endpoint was elided.
  /(?<=:\/\/)[^/\s:@]+:[^/\s@]+(?=@)/g,
];

// `<name>=<value>` / `<name>: <value>` where <name> contains a secret-ish word.
// The name and its separator are kept (attribution needs to say WHICH option
// was elided); only the value is replaced.
// The optional `["']` before the separator admits the JSON object-key spelling
// (`"private_key_id": "…"`): without it the name's own CLOSING quote sits
// between the key and the colon, so every quoted key form missed entirely.
const SECRET_ASSIGN_RE =
  /((?:^|[\s"'`=(,{])-{0,2}[A-Za-z0-9_.-]*(?:token|secret|password|passwd|api[_-]?key|apikey|credential|auth|private[_-]?key)[A-Za-z0-9_.-]*["']?\s*[=:]\s*)("[^"]*"|'[^']*'|\S+)/gi;

// Space-separated option form: `--token X`, `-secret X`. Bare `auth` is
// deliberately ABSENT here: with no `[=:]` to anchor it, a substring match
// would eat the value after `--author "Name"`. It stays only in
// SECRET_ASSIGN_RE, where the mandatory separator bounds the false positives.
//
// `(?!-)` on the value keeps the two boundaries the option form has and the
// assign form does not: a trailing option with no value at all, and an option
// immediately followed by another option. Eating either would destroy the
// attribution the redaction exists to preserve.
const SECRET_OPTION_RE =
  /((?:^|[\s"'`(])-{1,2}[A-Za-z0-9_.-]*(?:token|secret|password|passwd|api[_-]?key|apikey|credential)[A-Za-z0-9_.-]*[ \t]+)("[^"]*"|'[^']*'|(?!-)\S+)/gi;

// `Authorization: Bearer <token>` and its family. This MUST run before
// SECRET_ASSIGN_RE: "auth" inside "Authorization" already satisfies that
// regex's alternation, and its value capture then stops at the first `\S+`
// after the separator — the literal scheme word. The result reads as redacted
// while carrying the credential intact, which is worse than a plain miss.
// Scoped to the Authorization family specifically: a header with no scheme word
// (`X-Api-Key: <token>`) is handled correctly by the generic pass already.
const AUTH_SCHEME_RE =
  /((?:Proxy-)?Authorization\s*:\s*(?:Bearer|Basic|Digest|Token)\s+)([^\s"']+)/gi;

const REDACTED = "<redacted>";

function redactSecrets(input) {
  let out = String(input === null || input === undefined ? "" : input);
  for (const re of SECRET_VALUE_PATTERNS) out = out.replace(re, REDACTED);
  out = out.replace(AUTH_SCHEME_RE, (_m, head) => `${head}${REDACTED}`);
  out = out.replace(SECRET_OPTION_RE, (_m, head) => `${head}${REDACTED}`);
  out = out.replace(SECRET_ASSIGN_RE, (_m, head) => `${head}${REDACTED}`);
  return out;
}

module.exports = {
  collapseControl,
  redactSentinels,
  redactSecrets,
  sanitizeLine,
  SENTINEL_REDACT_RE,
  MAX_LINE,
};
