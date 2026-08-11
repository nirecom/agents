"use strict";

// Static checker for the on-demand rules-injection notation (C1..C5).
// Invoked only from bin/check-on-demand-rules.sh — see that file for the CLI
// contract and exit codes.
//
// argv: <mode> <root> <policyPath> [stagedPath...]
//   mode: "--all" | "--staged"
//
// WHY THIS IS A NODE MODULE AND WHY IT NEVER require()s THE POLICY
// ----------------------------------------------------------------
// hooks/lib/rules-injection-policy.js is a contributor-editable file that this
// checker reads on every pre-commit run. `require()`-ing it would execute
// whatever a pull request put in its module body, before review, with the
// reviewer's ambient privileges. So the policy is read as DATA: the source text
// is scanned for the four constant declarations and nothing else is evaluated.
// That is also why the policy file is required to keep every declaration a plain
// one-line literal.
//
// The reader itself is agents-owned code shared with the InstructionsLoaded
// audit hook — hooks/lib/rules-policy-reader.js. require()-ing THAT is correct:
// only the policy declaration file is untrusted.

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
          "listed in ON_DEMAND_FILES but its paths: is not exactly [\"" + token + "\"]",
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
        "annotated on-demand but absent from ON_DEMAND_FILES in the policy",
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
        "listed in ON_DEMAND_FILES but no such file exists under rules/",
      ]);
    }
  }

  // C3: the reserved glob is reserved precisely because nothing may ever match
  // it. A real file at that path turns every on-demand rule back on at once.
  if (token) {
    const reserved = path.join(root, ...token.split("/"));
    let exists = false;
    try {
      fs.lstatSync(reserved);
      exists = true;
    } catch (_) {
      exists = false;
    }
    if (exists) {
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

  const violations = [];
  // Both modes run the SAME tree-wide invariants. The notation contract is a
  // property of the tree, not of the changed files: a policy-only stage can
  // break a rule it never touched, and an orphan marker committed last week is
  // still a broken gate today.
  checkTree(root, policy, violations);
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
