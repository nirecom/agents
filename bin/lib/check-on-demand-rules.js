"use strict";

// Static checker for the on-demand rules-injection notation (C1..C5) and for the MINIMIZED_UNCONDITIONAL escape-hatch
// class (the four MINIMIZED_* tokens). Invoked only from bin/check-on-demand-rules.sh — see that file for the CLI
// contract and exit codes. argv: <mode> <root> <policyPath> [stagedPath...] — mode: "--all" | "--staged".
// WHY THIS NEVER require()s THE POLICY: hooks/lib/rules-injection-policy.js is a contributor-editable file read on
// every pre-commit run; require()-ing it would execute whatever a PR put in its module body, before review, with the
// reviewer's ambient privileges. So it is read as DATA — the source text is scanned for plain one-line literals and
// nothing is evaluated. Its string VALUES get the same distrust: a declared path is reported, never resolved outside
// the root. The reader itself, hooks/lib/rules-policy-reader.js, IS require()d normally — it is agents-owned code
// shared with the InstructionsLoaded audit hook; only the policy declaration file is untrusted.

const fs = require("fs");
const path = require("path");

const { loadPolicyAsData } = require("../../hooks/lib/rules-policy-reader");

// --- rule file parsing ------------------------------------------------------

const FRONTMATTER_RE = /^---[ \t]*\r?\n(?:([\s\S]*?)\r?\n)?---[ \t]*(?:\r?\n|$)/;

function splitFrontmatter(text) {
  const body = text.charCodeAt(0) === 0xfeff ? text.slice(1) : text;
  const m = FRONTMATTER_RE.exec(body);
  if (!m) return { block: null, body };
  return { block: m[1] || "", body: body.slice(m[0].length) };
}

// Returns the `paths:` glob values, or null when the key is absent entirely.
function parsePathValues(block) {
  if (block === null) return null;
  const lines = block.split(/\r?\n/);
  const start = lines.findIndex((l) => /^paths:/.test(l));
  if (start === -1) return null;
  const values = [];
  for (let i = start + 1; i < lines.length; i += 1) {
    const item = /^\s+-\s*(.*)$/.exec(lines[i]);
    if (!item) break;
    let value = item[1].trim();
    const quoted = /^(["'])([\s\S]*)\1$/.exec(value);
    if (quoted) value = quoted[2];
    values.push(value);
  }
  return values;
}

function listRuleFiles(root) {
  const out = [];
  (function walk(dir) {
    let entries;
    try {
      entries = fs.readdirSync(dir, { withFileTypes: true });
    } catch (_) {
      return;
    }
    for (const entry of entries) {
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) walk(full);
      else if (entry.isFile() && entry.name.endsWith(".md")) out.push(full);
    }
  })(path.join(root, "rules"));
  return out.sort();
}

function toRel(root, full) {
  return path.relative(root, full).split(path.sep).join("/");
}

// --- checks -----------------------------------------------------------------

// A near-miss is any glob that is trying to be the reserved token and failing:
// `!!on-demand-only`, `on-demand-only`, `.on-demand-only/never_match`. Spotting
// it matters because such a glob silently MATCHES nothing while looking correct.
const NEAR_MISS_RE = /on[-_]demand[-_]only/i;

// Turns a declaration VALUE into a path inside `root`, or null when it refuses to be
// one. Absolute paths, `~`, and anything that resolves outside the root are refused
// rather than followed: the value comes from a contributor-editable file, and a checker
// that resolved it outside the tree would report ownership the tree does not have.
function resolveInRoot(root, value) {
  if (value === "" || value.startsWith("~")) return null;
  if (path.isAbsolute(value) || /^[A-Za-z]:[\\/]/.test(value)) return null;
  const full = path.resolve(root, value);
  const rel = path.relative(root, full);
  if (rel === "" || rel === ".." || rel.startsWith(".." + path.sep) || path.isAbsolute(rel)) {
    return null;
  }
  return full;
}

// lstat, NOT stat: `resolveInRoot` is purely lexical (path.resolve/path.relative never consult
// the filesystem), so a symlink sitting inside the root and pointing outside it would satisfy
// containment and then be FOLLOWED by stat. lstat is chosen over a realpath re-check because the
// question here is only "is this declared path a real file the repo owns" — a symlink never is,
// so refusing the link outright is both simpler and stricter than resolving it.
function isFileInRoot(root, value) {
  const full = resolveInRoot(root, value);
  if (full === null) return false;
  try {
    return fs.lstatSync(full).isFile();
  } catch (_) {
    return false;
  }
}

// Same containment + no-symlink-follow contract as isFileInRoot, for a path that may legitimately
// NOT exist (the reserved never-match token). Out-of-root reads as absent: a probe that cannot be
// contained has nothing to say about the checked tree.
function existsInRoot(root, value) {
  const full = resolveInRoot(root, value);
  if (full === null) return false;
  try {
    fs.lstatSync(full);
    return true;
  } catch (_) {
    return false;
  }
}

// The reader matches a constant NAME unanchored, so `X_ON_DEMAND_READERS` satisfies it as
// a substring. That is fine for a generic parser but not for a GATE: a policy whose real
// declaration is missing would then be graded against whatever same-suffixed constant
// happens to sit in the file, and every on-demand rule would read as registered. So the
// gate re-asserts the declaration is really there, anchored at the start of a line, and
// drops the readers when it is not — an empty table names every annotated rule as
// unregistered, which is the fail-closed direction.
const READERS_DECL_RE = /^\s*(?:const|let|var)\s+ON_DEMAND_READERS\s*=\s*\[/m;

function declaresReaders(policyPath) {
  try {
    return READERS_DECL_RE.test(fs.readFileSync(policyPath, "utf8"));
  } catch (_) {
    return false;
  }
}

// The declaration's own internal consistency, checked row by row. Division of labour:
// this file is the STATIC notation/declaration checker — whether a declared reader
// actually carries a Read step is a semantic question owned by
// tests/cc-on-demand-skill-ownership.sh, which walks the skills/ tree for it.
function checkReaderRows(root, policy, violations) {
  const rows = policy.ON_DEMAND_READERS || [];
  const unconditional = new Set(policy.EXPECTED_UNCONDITIONAL);

  // Deliberate asymmetry (CPR-UNV, with the exception named): a declared reader must
  // exist in EVERY root, because that is internal consistency of the declaration. The
  // CLAUDE.md pointer is different — CLAUDE.md is a property of THIS repo, not of an
  // arbitrary checked tree, so its check is skipped when the file is absent rather than
  // failing every tree that simply has no CLAUDE.md.
  let claudeMd = null;
  try {
    claudeMd = fs.readFileSync(path.join(root, "CLAUDE.md"), "utf8");
  } catch (_) {
    claudeMd = null;
  }

  for (const row of rows) {
    const rule = row.key;

    if (row.values === null) {
      violations.push([
        "MALFORMED_READER_ROW",
        rule,
        "reader row has no '|' separator, so it names no skill obliged to Read the rule",
      ]);
    } else if (row.values.length === 0) {
      violations.push([
        "MALFORMED_READER_ROW",
        rule,
        "reader row carries a separator but zero readers — nobody is obliged to Read the rule",
      ]);
    } else {
      for (const reader of row.values) {
        if (!isFileInRoot(root, reader)) {
          violations.push([
            "READER_TARGET_MISSING",
            rule,
            "declared reader '" + reader + "' is not a file inside the checked root",
          ]);
        }
      }
    }

    if (unconditional.has(rule)) {
      violations.push([
        "DUPLICATE_POLICY_ENTRY",
        rule,
        "declared in both ON_DEMAND_READERS and EXPECTED_UNCONDITIONAL",
      ]);
    }

    if (claudeMd !== null && !claudeMd.includes(rule)) {
      violations.push([
        "MISSING_ONDEMAND_POINTER",
        rule,
        "de-injected but CLAUDE.md never names it, so nothing points the model at it",
      ]);
    }
  }
}

// Same anchored re-assertion as READERS_DECL_RE, for the minimized class.
const MINIMIZED_DECL_RE = /^\s*(?:const|let|var)\s+MINIMIZED_UNCONDITIONAL\s*=\s*\[/m;

function declaresMinimized(policyPath) {
  try {
    return MINIMIZED_DECL_RE.test(fs.readFileSync(policyPath, "utf8"));
  } catch (_) {
    return false;
  }
}

// A ceiling nobody can act on must never read as "no ceiling": returns null for every
// spelling that is not a positive safe integer, and the caller fails closed on null.
function usableMaxBytes(raw) {
  if (typeof raw !== "string" || !/^[0-9]+$/.test(raw)) return null;
  const n = Number(raw);
  if (!Number.isSafeInteger(n) || n <= 0) return null;
  return n;
}

// The only key shape a minimized row may name: a `rules/`-rooted `.md` path, no `..` segment.
// The key is the one declaration value this checker READS from disk, so it is constrained BEFORE
// any resolve or read — an unconstrained key (`.env|rules/git.md`) would otherwise make a
// reviewer's pre-commit run open an arbitrary file and leak its size, and its content through the
// pointer check, into the violation text.
const MINIMIZED_KEY_RE = /^rules\/(?!.*(?:^|\/)\.\.(?:\/|$))[A-Za-z0-9._-]+(?:\/[A-Za-z0-9._-]+)*\.md$/;

// The minimized escape hatches: unconditional on purpose, so the only things holding
// them at their reduced size are this byte ceiling and the pointer at the moved
// procedure. `maxBytes` is already validated by the caller.
function checkMinimizedRows(root, policy, maxBytes, violations) {
  const rows = policy.MINIMIZED_UNCONDITIONAL || [];
  const unconditional = new Set(policy.EXPECTED_UNCONDITIONAL);
  const onDemand = new Set(policy.ON_DEMAND_FILES);

  for (const row of rows) {
    const rule = row.key;

    // Shape first, and the row is dropped on failure: nothing below may read a path this
    // checker has not already agreed is a rules file.
    if (!MINIMIZED_KEY_RE.test(rule)) {
      violations.push([
        "MALFORMED_MINIMIZED_KEY",
        rule,
        "minimized row key is not a 'rules/<name>.md' path — the row was not read",
      ]);
      continue;
    }

    if (!unconditional.has(rule) || onDemand.has(rule)) {
      violations.push([
        "MINIMIZED_NOT_UNCONDITIONAL",
        rule,
        "declared minimized but not an unconditional rule (absent from EXPECTED_UNCONDITIONAL, " +
          "or wired as an on-demand reader row) — an escape hatch that is de-injected is one " +
          "a stuck session cannot see",
      ]);
    }

    const pointer = row.values === null ? null : (row.values.join(",") || null);
    if (pointer === null) {
      violations.push([
        "MINIMIZED_POINTER_MISSING",
        rule,
        "minimized row declares no pointer, so the rule names nowhere the moved procedure lives",
      ]);
      continue;
    }

    let text = null;
    let bytes = null;
    const full = resolveInRoot(root, rule);
    if (full !== null) {
      try {
        const buf = fs.readFileSync(full);
        bytes = buf.length;
        text = buf.toString("utf8");
      } catch (_) {
        text = null;
      }
    }

    if (text === null) {
      violations.push([
        "MINIMIZED_POINTER_MISSING",
        rule,
        "declared minimized but the rule file cannot be read, so its pointer to '" +
          pointer +
          "' cannot be verified",
      ]);
    } else {
      // A skills/<n>/SKILL.md pointer is satisfied by the `/<n>` invocation form too —
      // that is how a prompt file tells a session to run it. Any other pointer (a doc or
      // a code SSOT) has no such form, so only the path itself satisfies it.
      const skill = /^skills\/([^/]+)\/SKILL\.md$/.exec(pointer);
      const named = text.includes(pointer) || (skill !== null && text.includes("/" + skill[1]));
      if (!named) {
        violations.push([
          "MINIMIZED_POINTER_MISSING",
          rule,
          "body names neither '" +
            pointer +
            "'" +
            (skill !== null ? " nor '/" + skill[1] + "'" : "") +
            " — the moved procedure is unreachable from the rule",
        ]);
      }
    }

    if (!isFileInRoot(root, pointer)) {
      violations.push([
        "MINIMIZED_POINTER_TARGET_MISSING",
        rule,
        "declared pointer '" + pointer + "' is not a file inside the checked root",
      ]);
    }

    // BYTES, not String.length: a JS length counts UTF-16 units, under which a
    // multibyte rule could reach roughly three times the agreed budget.
    if (bytes !== null && bytes > maxBytes) {
      violations.push([
        "MINIMIZED_RULE_TOO_LARGE",
        rule,
        "is " + bytes + " bytes, over the declared MINIMIZED_MAX_BYTES ceiling of " + maxBytes,
      ]);
    }
  }
}

function checkTree(root, policy, violations) {
  const token = policy.ON_DEMAND_TOKEN;
  const markerRe = policy.ON_DEMAND_MARKER_RE;
  const onDemand = new Set(policy.ON_DEMAND_FILES);
  const unconditional = new Set(policy.EXPECTED_UNCONDITIONAL);
  const seen = new Set();

  for (const full of listRuleFiles(root)) {
    const rel = toRel(root, full);
    seen.add(rel);
    let text;
    try {
      text = fs.readFileSync(full, "utf8");
    } catch (_) {
      continue;
    }
    const { block, body } = splitFrontmatter(text);
    const values = parsePathValues(block);
    const annotated = values !== null && values.length === 1 && values[0] === token;
    const carriesToken = values !== null && values.includes(token);
    // Searched in the BODY only: an HTML comment buried in the YAML block is
    // not part of the rendered document and must not count as annotation.
    const marked = markerRe ? markerRe.test(body) : false;

    for (const value of values || []) {
      if (value !== token && NEAR_MISS_RE.test(value)) {
        violations.push([
          "NONCANONICAL_ON_DEMAND_TOKEN",
          rel,
          "paths: glob '" + value + "' is a near-miss of the reserved token '" + token + "'",
        ]);
      }
    }

    if (onDemand.has(rel)) {
      if (!annotated) {
        violations.push([
          "INVALID_ON_DEMAND_PATHS",
          rel,
          "listed in ON_DEMAND_READERS but its paths: is not exactly [\"" + token + "\"]",
        ]);
      } else if (!marked) {
        violations.push([
          "MISSING_ON_DEMAND_MARKER",
          rel,
          "carries the reserved token but no on-demand marker comment in its body",
        ]);
      }
      continue;
    }

    if (carriesToken) {
      if (!annotated) {
        violations.push([
          "INVALID_ON_DEMAND_PATHS",
          rel,
          "mixes the reserved token with other globs; paths: must be exactly [\"" + token + "\"]",
        ]);
      } else if (!marked) {
        violations.push([
          "MISSING_ON_DEMAND_MARKER",
          rel,
          "carries the reserved token but no on-demand marker comment in its body",
        ]);
      }
      violations.push([
        "UNREGISTERED_ON_DEMAND_RULE",
        rel,
        "annotated on-demand but absent from ON_DEMAND_READERS in the policy",
      ]);
      continue;
    }

    if (marked) {
      violations.push([
        "ORPHAN_ON_DEMAND_MARKER",
        rel,
        "carries the on-demand marker comment without the reserved paths: token",
      ]);
    }
    if (values === null && !unconditional.has(rel)) {
      violations.push([
        "UNLISTED_UNCONDITIONAL_RULE",
        rel,
        "has no paths: frontmatter and is absent from EXPECTED_UNCONDITIONAL",
      ]);
    }
  }

  for (const rel of onDemand) {
    if (!seen.has(rel)) {
      violations.push([
        "INVALID_ON_DEMAND_PATHS",
        rel,
        "listed in ON_DEMAND_READERS but no such file exists under rules/",
      ]);
    }
  }

  // C3: the reserved glob is reserved precisely because nothing may ever match
  // it. A real file at that path turns every on-demand rule back on at once.
  if (token) {
    // Through the containment helper, never path.join: the token is a policy VALUE, so a `..`
    // segment in it would otherwise probe outside the checked root.
    if (existsInRoot(root, token)) {
      violations.push([
        "RESERVED_PATH_EXISTS",
        token,
        "the reserved never-match path exists in the worktree",
      ]);
    }
  }
}

// Staged arguments are attacker-influenced filenames. They are DATA: reported,
// never expanded or followed. A path that does not resolve inside the checked
// root is surfaced rather than skipped — a silently skipped path is a gate that
// has gone dark.
function checkStagedArgs(root, args, violations) {
  for (const arg of args) {
    if (arg === "") continue;
    let outside = false;
    if (arg.startsWith("~")) {
      outside = true;
    } else if (path.isAbsolute(arg) || /^[A-Za-z]:[\\/]/.test(arg)) {
      const rel = path.relative(root, path.resolve(arg));
      outside = rel === ".." || rel.startsWith(".." + path.sep) || path.isAbsolute(rel);
    } else if (arg.split(/[\\/]/).includes("..")) {
      outside = true;
    }
    if (outside) {
      violations.push([
        "OUT_OF_ROOT_STAGED_PATH",
        arg,
        "staged path does not resolve inside the checked root",
      ]);
    }
  }
}

// --- entry ------------------------------------------------------------------

function main() {
  const mode = process.argv[2];
  const root = process.argv[3];
  const policyPath = process.argv[4];
  const args = process.argv.slice(5);

  let policy;
  try {
    policy = loadPolicyAsData(policyPath);
  } catch (e) {
    process.stderr.write("check-on-demand-rules: cannot read policy file: " + policyPath + "\n");
    return 2;
  }
  if (!policy.ON_DEMAND_TOKEN || !policy.ON_DEMAND_MARKER_RE) {
    process.stderr.write(
      "check-on-demand-rules: policy file does not declare ON_DEMAND_TOKEN / " +
        "ON_DEMAND_MARKER_RE as plain literals: " +
        policyPath +
        "\n"
    );
    return 2;
  }

  if (!declaresReaders(policyPath)) {
    policy.ON_DEMAND_READERS = [];
    policy.ON_DEMAND_FILES = policy.ON_DEMAND_READERS;
  }

  const minimizedDeclared = declaresMinimized(policyPath) && policy.MINIMIZED_UNCONDITIONAL !== null;
  let maxBytes = null;
  if (minimizedDeclared) {
    maxBytes = usableMaxBytes(policy.MINIMIZED_MAX_BYTES);
    if (maxBytes === null) {
      process.stderr.write(
        "check-on-demand-rules: MINIMIZED_UNCONDITIONAL is declared but MINIMIZED_MAX_BYTES is not a " +
          "positive safe integer (got: " +
          JSON.stringify(policy.MINIMIZED_MAX_BYTES) +
          "): " +
          policyPath +
          "\n"
      );
      return 2;
    }
  }

  const violations = [];
  // Both modes run the SAME tree-wide invariants. The notation contract is a
  // property of the tree, not of the changed files: a policy-only stage can
  // break a rule it never touched, and an orphan marker committed last week is
  // still a broken gate today.
  checkTree(root, policy, violations);
  checkReaderRows(root, policy, violations);
  if (minimizedDeclared) {
    checkMinimizedRows(root, policy, maxBytes, violations);
  } else {
    // Fail CLOSED, symmetric with the readers path: skipping the minimized checks when the
    // declaration is absent or unparseable would let deleting (or merely breaking) one const
    // silently switch off the byte ceiling, the pointer check and the membership check while the
    // checker still exits 0. Missing declaration = violation, never = nothing to check.
    violations.push([
      "MINIMIZED_DECLARATION_MISSING",
      policyPath,
      "MINIMIZED_UNCONDITIONAL is absent or not a plain one-line array literal, so the minimized " +
        "escape-hatch checks (byte ceiling, pointer, unconditional membership) cannot run",
    ]);
  }
  if (mode === "--staged") checkStagedArgs(root, args, violations);

  if (violations.length === 0) return 0;
  // Written with fs.writeSync so nothing is lost to an async pipe flush when
  // process.exit() runs immediately after.
  const lines = violations.map(([token, subject, message]) => token + ": " + subject + " — " + message);
  lines.push(
    "",
    violations.length +
      " on-demand rules-injection violation(s). See docs/architecture/claude-code/rules-injection.md"
  );
  fs.writeSync(1, lines.join("\n") + "\n");
  return 1;
}

process.exit(main());
