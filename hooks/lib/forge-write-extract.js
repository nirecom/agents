"use strict";
// Extract scannable text from `gh` forge-write commands (issue/pr create|edit|close|comment|review;
// repo create|edit). `gh api` write commands also covered. `gh repo rename|archive|delete` excluded.

const { stripQuotedArgs, stripInlineBodyArg } = require("./strip-quoted-args");
const { vocabularyFor } = require("./gh-flag-vocab");

// `new` is GitHub CLI's own built-in alias for `create` on both `pr` and
// `issue`: the two spellings run the SAME command, so a vocabulary that knows
// only `create` hands `gh issue new` a free pass past every caller of this
// regex — including the outbound secret scan. edit/close/comment/review have no
// such alias and are left spelled exactly as gh spells them.
const FORGE_SCAN_TARGET_REGEX =
  /\bgh\b\s+(?:pr\s+(?:create|new|edit|close|comment|review)|issue\s+(?:create|new|edit|close|comment))\b/;

const GH_API_WRITE_REGEX =
  /\bgh\b\s+api\b.*?(?:-X\s+(?:POST|PATCH|PUT|DELETE)|--method(?:\s+|=)(?:POST|PATCH|PUT|DELETE))/i;

const GH_REPO_WRITE_REGEX = /\bgh\b\s+repo\s+(?:create|edit)\b/;

function isForgeScanTarget(command) {
  if (typeof command !== "string" || command.length === 0) return false;
  return FORGE_SCAN_TARGET_REGEX.test(command) || GH_API_WRITE_REGEX.test(command) || GH_REPO_WRITE_REGEX.test(command);
}

function isRepoWriteTarget(command) {
  return typeof command === "string" && command.length > 0 && GH_REPO_WRITE_REGEX.test(command);
}

// Extract --body / --title quoted values (single or double quoted).
// Supports: --body "val", --body 'val', --body="val", --body='val', --body=val
function extractFlagQuoted(command, flag, out) {
  // Space-separated quoted: --body "val" or --body 'val'
  const reSpace = new RegExp(`--${flag}\\s+(["'])([\\s\\S]*?)\\1`, "g");
  let m;
  while ((m = reSpace.exec(command)) !== null) {
    out.push(m[2]);
  }
  // Equals-quoted: --body="val" or --body='val'
  const reEqQuoted = new RegExp(`--${flag}=(["'])([\\s\\S]*?)\\1`, "g");
  while ((m = reEqQuoted.exec(command)) !== null) {
    out.push(m[2]);
  }
  // Equals-unquoted: --body=val (until whitespace)
  const reEqUnquoted = new RegExp(`--${flag}=([^\\s"'][^\\s]*)`, "g");
  while ((m = reEqUnquoted.exec(command)) !== null) {
    out.push(m[1]);
  }
}

// Extract --flag <value> where value is a single unquoted token (not starting with -- or a quote).
function extractFlagUnquoted(command, flag, out) {
  const re = new RegExp(`--${flag}\\s+(?!["']|--)(\\S+)`, "g");
  let m;
  while ((m = re.exec(command)) !== null) {
    out.push(m[1]);
  }
}

// Extract --body-file <path> (next whitespace-delimited token, unquoted).
function extractBodyFile(command, out) {
  const re = /--body-file\s+(\S+)/g;
  let m;
  while ((m = re.exec(command)) !== null) {
    out.push(m[1]);
  }
}

// Extract heredoc content with arbitrary delimiter: <<EOF, <<'EOF', <<"EOF", <<-EOF, etc.
function extractHeredocs(command, out) {
  const re = /<<-?\s*['"]?([A-Za-z_][A-Za-z0-9_]*)['"]?\s*\n([\s\S]*?)\n[ \t]*\1\b/g;
  let m;
  while ((m = re.exec(command)) !== null) {
    out.push(m[2]);
  }
}

// Extract -f / -F / --field key=value payloads and --input @file paths from gh api write commands.
function extractApiFieldTexts(command, inline, filePaths) {
  // -f key=val, -F key=val, --field key=val — capture the value after =
  const reField = /(?:^|\s)(?:-f|-F|--field)\s+[^=\s]+=(\S+)/g;
  let m;
  while ((m = reField.exec(command)) !== null) {
    inline.push(m[1]);
  }
  // --input @file — capture file path (strip leading @)
  const reInput = /--input\s+@(\S+)/g;
  while ((m = reInput.exec(command)) !== null) {
    filePaths.push(m[1]);
  }
}

function extractTexts(command) {
  const inline = [];
  const filePaths = [];
  if (typeof command !== "string" || command.length === 0) {
    return { inline, filePaths };
  }
  if (GH_API_WRITE_REGEX.test(command)) {
    extractApiFieldTexts(command, inline, filePaths);
    return { inline, filePaths };
  }
  extractFlagQuoted(command, "body", inline);
  extractFlagQuoted(command, "title", inline);
  extractFlagUnquoted(command, "body", inline);
  extractFlagUnquoted(command, "title", inline);
  extractBodyFile(command, filePaths);
  extractHeredocs(command, inline);
  extractFlagQuoted(command, "description", inline);
  extractFlagUnquoted(command, "description", inline);
  extractFlagQuoted(command, "homepage", inline);
  extractFlagUnquoted(command, "homepage", inline);
  return { inline, filePaths };
}

// Validate owner/repo shape: alphanumeric/dot/dash/underscore on both sides of /
const REPO_SHAPE_RE = /^[\w.-]+\/[\w.-]+$/;

// Extract the --repo / -R flag value from a gh command.
// Returns owner/repo string or null if absent/invalid.
// Uses extractFlagQuoted/extractFlagUnquoted for --repo (long form only).
// For -R short form: uses stripQuotedArgs to avoid false positives from quoted body content.
function extractRepoFlag(command) {
  if (typeof command !== "string" || command.length === 0) return null;

  // Long form: --repo "val", --repo=val, --repo val
  // Strip only --body/--title argument VALUES (where untrusted smuggling lands, e.g.
  // --body "see --repo attacker/evil"), leaving a real --repo flag value intact — so a
  // smuggled --repo inside a body/title is neutralized but a legitimate quoted --repo
  // "owner/repo" still extracts correctly. (stripQuotedArgs would also blank the real value.)
  {
    const stripped = stripInlineBodyArg(command);
    const candidates = [];
    extractFlagQuoted(stripped, "repo", candidates);
    extractFlagUnquoted(stripped, "repo", candidates);
    for (const c of candidates) {
      const v = c.trim();
      if (REPO_SHAPE_RE.test(v)) return v;
    }
  }

  // Short form: -R (not handled by extractFlagQuoted/extractFlagUnquoted since those prefix --)
  // Use stripQuotedArgs to neutralize quoted content so we only match real -R flags.
  {
    const stripped = stripQuotedArgs(command);
    // Check if -R or -R= appears in the stripped command (outside quotes)
    const hasShortFlag = /(?:^|[\s;|&])-R(?:[\s=]|$)/.test(stripped);
    if (hasShortFlag) {
      // -R=owner/repo (equals form, no space)
      const eqMatch = command.match(/(?:^|[\s;|&])-R=(\S+)/);
      if (eqMatch) {
        const v = eqMatch[1].replace(/^["']|["']$/g, "");
        if (REPO_SHAPE_RE.test(v)) return v;
      }
      // -R "owner/repo" or -R owner/repo (space form — search original command)
      // Find -R followed by a value in the original command string
      const spaceMatch = command.match(/(?:^|[\s;|&])-R\s+(["']?)([^\s"']+)\1/);
      if (spaceMatch) {
        const v = spaceMatch[2];
        if (REPO_SHAPE_RE.test(v)) return v;
      }
    }
  }

  return null;
}

// ---------------------------------------------------------------------------
// #2053 additive exports. Both work on TOKENIZED argv / structured flag records
// rather than on raw command strings: extractRepoFlag above is a string-level
// heuristic and keeps its (recorded) `-Rowner/repo` blind spot, while the
// ownership guard needs every selector occurrence, including the attached form.
// ---------------------------------------------------------------------------

// Every `--repo` / `-R` occurrence in argv, left to right, as
// [{ index, value, form }]; `index` is the FLAG token, `value: null` means the
// flag was named but carries no resolvable value. Short CLUSTERS count too, and
// a token gh reads as some OTHER flag's VALUE is no selector at all.
function extractRepoSelectors(argv) {
  const out = [];
  if (!Array.isArray(argv)) return out;
  const vocab = vocabularyFor(argv);
  let pending = null; // what the PREVIOUS flag does with this token
  for (let i = 0; i < argv.length; i += 1) {
    const tok = argv[i];
    if (typeof tok !== "string") { pending = null; continue; }
    // A known value-taking flag consumes this token whatever it spells: it is
    // gh's title, body or jq expression, never a target.
    if (pending === "value") { pending = null; continue; }
    const unknownPrefix = pending === "maybe";
    pending = null;
    if (tok === "--") break; // everything after is an operand, not a flag
    const sel = repoSelectorAt(tok, argv, i, vocab);
    if (sel) {
      // With an unplaceable flag in front, whether gh reads this token as that
      // flag's value or as a selector of its own is unknowable — and either
      // answer taken silently resolves the wrong repository. Report it named
      // but unreadable, which is an ask.
      out.push({ index: i, value: unknownPrefix ? null : sel.value, form: sel.form });
      if (!unknownPrefix && sel.consumedNext) i += 1;
      continue;
    }
    if (tok === "" || tok[0] !== "-" || tok === "-") continue; // an operand
    pending = pendingAfterFlag(tok, vocab);
  }
  return out;
}

// What the flag token `tok` does to the token that FOLLOWS it: consume it as a
// value, leave it alone, or "maybe" — a flag the vocabulary cannot place, whose
// arity the guard must not assume in either direction.
function pendingAfterFlag(tok, vocab) {
  if (tok[1] === "-") {
    if (tok.indexOf("=") > 0) return null; // --name=value is self-contained
    if (vocab.longValue.has(tok)) return "value";
    return vocab.longBool.has(tok) ? null : "maybe";
  }
  // pflag walks a short cluster character by character; the first value-taking
  // character takes the REST of the token, and reaches the next argv token only
  // when it sits last.
  for (let k = 1; k < tok.length; k += 1) {
    const last = k === tok.length - 1;
    if (vocab.shortValue.has(tok[k])) return last ? "value" : null;
    if (!vocab.shortBool.has(tok[k])) return last ? "maybe" : null;
  }
  return null;
}

// The five spellings of a repo selector, plus the cluster form. Returns null
// when the token names no selector at all.
function repoSelectorAt(tok, argv, i, vocab) {
  if (tok === "--repo" || tok === "-R") {
    const form = tok === "-R" ? "short-separated" : "long-separated";
    const next = i + 1 < argv.length ? argv[i + 1] : null;
    if (typeof next === "string" && next !== "--" && next[0] !== "-") {
      return { form, value: next, consumedNext: true };
    }
    return { form, value: null, consumedNext: false };
  }
  if (tok.startsWith("--repo=")) {
    return { form: "long-attached", value: tok.slice("--repo=".length), consumedNext: false };
  }
  if (tok.startsWith("-R=")) {
    return { form: "short-equals", value: tok.slice("-R=".length), consumedNext: false };
  }
  if (tok.startsWith("-R") && tok.length > 2) {
    return { form: "short-attached", value: tok.slice(2), consumedNext: false };
  }
  return clusterRepoFlag(tok, argv, i, vocab);
}

// pflag only ever REACHES an `R` inside a cluster when every character before it
// takes no value: a value-taking one swallows the rest of the token as ITS
// value, so the `R` is data. A character the vocabulary cannot place proves
// neither, and dropping the token would leave the write judged against the cwd
// — the most trusting answer there is — so it reports `value: null`, an ask.
function clusterRepoFlag(tok, argv, i, vocab) {
  if (typeof tok !== "string" || tok.length < 3 || tok[0] !== "-" || tok[1] === "-") return null;
  const at = tok.indexOf("R", 1);
  if (at < 0) return null;
  for (let k = 1; k < at; k += 1) {
    if (vocab.shortBool.has(tok[k])) continue;
    if (vocab.shortValue.has(tok[k])) return null; // the R is that flag's value
    return { form: "short-attached", value: null, consumedNext: false };
  }
  const rest = tok.slice(at + 1);
  if (rest !== "") {
    const equals = rest[0] === "=";
    return { form: equals ? "short-equals" : "short-attached", value: equals ? rest.slice(1) : rest, consumedNext: false };
  }
  const next = i + 1 < argv.length ? argv[i + 1] : null;
  if (typeof next === "string" && next !== "--" && next[0] !== "-") {
    return { form: "short-separated", value: next, consumedNext: true };
  }
  return { form: "short-separated", value: null, consumedNext: false };
}

const API_METHOD_FLAGS = new Set(["-X", "--method"]);
const API_PAYLOAD_FLAGS = new Set(["-f", "-F", "--field", "--raw-field", "--input"]);
const API_READ_METHOD_RE = /^(?:GET|HEAD)$/i;

// Effective write classification for `gh api`, from scanned flag records
// ([{ flag, value }] in command order).
//   1. an explicit -X/--method wins; the LAST occurrence is effective (pflag
//      keeps the last value of a repeated flag). GET/HEAD are reads; every
//      other spelling is treated as a write (fail-closed on `-X FROBNICATE`).
//   2. with no readable method, any payload flag implies POST.
//   3. otherwise it is a read.
function isGhApiWriteFromFlags(flags) {
  if (!Array.isArray(flags)) return false;
  let method = null;
  let hasPayload = false;
  for (const f of flags) {
    if (!f || typeof f.flag !== "string") continue;
    if (API_METHOD_FLAGS.has(f.flag)) method = typeof f.value === "string" ? f.value : null;
    else if (API_PAYLOAD_FLAGS.has(f.flag)) hasPayload = true;
  }
  if (method !== null) return !API_READ_METHOD_RE.test(method.trim());
  return hasPayload;
}

module.exports = { isForgeScanTarget, isRepoWriteTarget, extractTexts, extractRepoFlag, extractRepoSelectors, isGhApiWriteFromFlags, GH_API_WRITE_REGEX, GH_REPO_WRITE_REGEX };
