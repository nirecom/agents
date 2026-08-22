"use strict";
// Extract scannable text from `gh` forge-write commands (issue/pr create|edit|close|comment|review;
// repo create|edit). `gh api` write commands also covered. `gh repo rename|archive|delete` excluded.

const { stripQuotedArgs, stripInlineBodyArg } = require("./strip-quoted-args");

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
// flag was named but carries no resolvable value. pflag short-option CLUSTERS
// count too (`-wR owner/repo`; an unproven prefix like `-eR` gives value: null).
function extractRepoSelectors(argv) {
  const out = [];
  if (!Array.isArray(argv)) return out;
  for (let i = 0; i < argv.length; i += 1) {
    const tok = argv[i];
    if (typeof tok !== "string") continue;
    if (tok === "--") break; // everything after is an operand, not a flag
    let form = null;
    let value;
    if (tok === "--repo" || tok === "-R") {
      form = tok === "-R" ? "short-separated" : "long-separated";
      const next = i + 1 < argv.length ? argv[i + 1] : null;
      if (typeof next === "string" && next !== "--" && next[0] !== "-") {
        value = next;
        i += 1;
      } else {
        value = null;
      }
    } else if (tok.startsWith("--repo=")) {
      form = "long-attached";
      value = tok.slice("--repo=".length);
    } else if (tok.startsWith("-R=")) {
      form = "short-equals";
      value = tok.slice("-R=".length);
    } else if (tok.startsWith("-R") && tok.length > 2) {
      form = "short-attached";
      value = tok.slice(2);
    } else {
      const cluster = clusterRepoFlag(tok, argv, i);
      if (cluster) {
        form = cluster.form;
        value = cluster.value;
        if (cluster.consumedNext) i += 1;
      }
    }
    if (form === null) continue;
    out.push({ index: form === "short-separated" || form === "long-separated"
      ? (value === null ? i : i - 1) : i, value, form });
  }
  return out;
}

// Short flags of gh's issue / pr / repo / api commands that provably take NO
// value, so pflag keeps walking the cluster past them. Deliberately tiny: a
// letter is listed only when it is boolean in EVERY one of those commands. `-d`
// (`--draft` on pr create but `--description` on repo create), `-f`
// (`--fill` vs gh api's `--field`), `-c`, `-s`, `-r`, `-h` and `-q` all take a
// value somewhere in that set, so none of them can be walked past.
const GH_BOOL_SHORT_FLAGS = new Set([
  "w", // --web
  "i", // --include (gh api)
]);

// pflag walks a short cluster character by character; when it reaches `R` the
// remainder of the token is the value (a leading `=` is dropped), and an `R` in
// last position takes the next argv token instead. But it only ever REACHES the
// `R` when every character before it is a flag that takes no value: a
// value-taking flag earlier in the cluster swallows the rest of the token as ITS
// value, so the `R` is data, not a selector. But "cannot prove the prefix" is
// not "no selector": dropping the token would leave the write to be judged
// against the cwd, the most trusting answer there is. So an unproven prefix
// reports the `R` with `value: null` — an unreadable selector, i.e. an ask.
function clusterRepoFlag(tok, argv, i) {
  if (typeof tok !== "string" || tok.length < 3 || tok[0] !== "-" || tok[1] === "-") return null;
  const at = tok.indexOf("R", 1);
  if (at < 0) return null;
  for (let k = 1; k < at; k += 1) {
    if (!GH_BOOL_SHORT_FLAGS.has(tok[k])) {
      return { form: "short-attached", value: null, consumedNext: false };
    }
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
