"use strict";
// bin/lib/prompt-extraction/cli.js
// Single-decision engine for prompt-bloat detection (issue #1642).
// Entry point: bin/check-prompt-extraction.
//
// Exit codes: 0 clean/SKIPPED/advisory/all-mode, 1 blocking violations,
//             2 usage error, 3 infrastructure error.

const fs = require("fs");
const path = require("path");

const targets = require("./targets");
const { scanFences } = require("./fence-scanner");
const { scanProcedures } = require("./procedure-scanner");
const allowlistLib = require("./allowlist");

const KINDS = ["code-fence", "inline-procedure"];
const HEADER = "## Prompt Extraction Review";

// Composite map key: "<kind> <path>". `kind` is drawn from the closed KINDS set
// and contains no space, so splitting on the FIRST space is unambiguous even for
// paths that themselves contain spaces. Deliberately plain ASCII: an earlier
// revision used a raw NUL byte here, which made git classify this source file as
// binary and suppress its diff entirely.
const keyOf = (kind, p) => `${kind} ${p}`;
const splitKey = (key) => {
  const i = key.indexOf(" ");
  return [key.slice(0, i), key.slice(i + 1)];
};

const EXIT_OK = 0;
const EXIT_BLOCK = 1;
const EXIT_USAGE = 2;
const EXIT_INFRA = 3;

const out = [];
function emit(line) {
  out.push(line);
}
function finish(code) {
  if (out.length > 0) process.stdout.write(out.join("\n") + "\n");
  process.exit(code);
}
function usageError(message) {
  process.stderr.write(`check-prompt-extraction: ${message}\n`);
  process.exit(EXIT_USAGE);
}
function infraError(message) {
  process.stderr.write(`check-prompt-extraction: ${message}\n`);
  process.exit(EXIT_INFRA);
}

// ---------------------------------------------------------------- arg parsing
function parseArgs(argv) {
  const opts = {
    mode: null,
    baseRef: null,
    kind: "all",
    advisory: false,
    noAllowlist: false,
    writeAllowlist: false,
    allowlistTotal: false,
    allowlistFile: null,
  };
  const setMode = (m) => {
    if (opts.mode !== null) {
      usageError(`--${m} conflicts with --${opts.mode} (modes are mutually exclusive)`);
    }
    opts.mode = m;
  };

  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    switch (arg) {
      case "--all":
        setMode("all");
        break;
      case "--staged":
        setMode("staged");
        break;
      case "--base":
        setMode("base");
        if (i + 1 >= argv.length) usageError("--base requires a <ref> argument");
        opts.baseRef = argv[i + 1];
        i += 1;
        break;
      case "--kind":
        if (i + 1 >= argv.length) usageError("--kind requires an argument");
        opts.kind = argv[i + 1];
        i += 1;
        if (opts.kind !== "all" && !KINDS.includes(opts.kind)) {
          usageError(`unknown --kind '${opts.kind}' (expected code-fence|inline-procedure|all)`);
        }
        break;
      case "--advisory":
        opts.advisory = true;
        opts.noAllowlist = true;
        break;
      case "--no-allowlist":
        opts.noAllowlist = true;
        break;
      case "--write-allowlist":
        opts.writeAllowlist = true;
        break;
      case "--allowlist-total":
        opts.allowlistTotal = true;
        break;
      case "--allowlist-file":
        if (i + 1 >= argv.length) usageError("--allowlist-file requires a <path> argument");
        opts.allowlistFile = argv[i + 1];
        i += 1;
        break;
      default:
        usageError(`unknown argument '${arg}'`);
    }
  }

  if (opts.writeAllowlist) {
    if (opts.allowlistTotal) usageError("--write-allowlist cannot be combined with --allowlist-total");
    if (opts.mode !== null && opts.mode !== "all") {
      usageError("--write-allowlist is valid only with --all");
    }
    opts.mode = "all";
  }
  if (opts.mode === null && !opts.allowlistTotal) {
    opts.mode = "base";
    opts.baseRef = "origin/main";
  }
  return opts;
}

// ------------------------------------------------------------------ allowlist
function readAllowlistText(opts, repoRoot) {
  if (opts.allowlistFile !== null) {
    if (opts.allowlistFile === "-") {
      try {
        return fs.readFileSync(0, "utf8");
      } catch (_e) {
        return "";
      }
    }
    const abs = path.isAbsolute(opts.allowlistFile)
      ? opts.allowlistFile
      : path.join(repoRoot || process.cwd(), opts.allowlistFile);
    try {
      return fs.readFileSync(abs, "utf8");
    } catch (_e) {
      usageError(`--allowlist-file is not readable: ${opts.allowlistFile}`);
    }
  }
  if (!repoRoot) return null;
  return targets.readRepoAllowlist(repoRoot, opts.mode);
}

// ------------------------------------------------------------------- scanning
function scanFile(file, opts) {
  const lines = String(file.content).split(/\r?\n/);
  const wantFence = opts.kind === "all" || opts.kind === "code-fence";
  const wantProc = opts.kind === "all" || opts.kind === "inline-procedure";
  const emitNotes = wantFence && (opts.mode === "all" || opts.advisory);

  const violations = [];
  const notes = [];

  if (wantFence) {
    const r = scanFences(lines, { emitNotes });
    for (const v of r.violations) {
      violations.push({
        kind: "code-fence",
        path: file.path,
        line: v.line,
        text:
          `${file.path}:${v.line}: code fence of ${v.lineCount} lines ` +
          "(rules/prompt.md §1.5); move to skills/<name>/scripts/<verb>.sh",
      });
    }
    for (const n of r.notes) {
      notes.push(
        `NOTE: ${file.path}:${n.line}: indented code block of ${n.lineCount} lines ` +
          "(possible §1.5 workaround; see rules/prompt.md)"
      );
    }
  }
  if (wantProc) {
    const r = scanProcedures(lines);
    for (const v of r.violations) {
      violations.push({
        kind: "inline-procedure",
        path: file.path,
        line: v.line,
        text:
          `${file.path}:${v.line}: inline procedure of ${v.stepCount} steps in section ` +
          `"${v.sectionHeading}" (rules/prompt.md §1.3); move to bin/<tool>`,
      });
    }
  }
  return { violations, notes };
}

function countByKindPath(violations) {
  const counts = new Map();
  for (const v of violations) {
    const key = keyOf(v.kind, v.path);
    counts.set(key, (counts.get(key) || 0) + 1);
  }
  return counts;
}

// ----------------------------------------------------------------------- main
function main() {
  const opts = parseArgs(process.argv.slice(2));
  const repoRoot = targets.resolveRepoRoot(process.cwd());

  // --allowlist-total short-circuits every scan: it reports on the allowlist only.
  if (opts.allowlistTotal) {
    const text = readAllowlistText(opts, repoRoot);
    const entries = allowlistLib.parseAllowlist(text === null ? "" : text);
    const t = allowlistLib.computeTotal(entries);
    emit(`TOTAL ${t.total} WILDCARD ${t.wildcard} ENTRIES ${t.entries}`);
    finish(EXIT_OK);
  }

  if (!repoRoot) {
    if (opts.mode === "all") {
      infraError("not a git repository (--all needs a repo root)");
    }
    infraError("not a git repository (or git is unavailable)");
  }

  let files;
  if (opts.mode === "all") {
    files = targets.collectAll(repoRoot);
  } else if (opts.mode === "staged") {
    files = targets.collectStaged(repoRoot);
    // null = git ls-files or git cat-file failed. An empty scan set is [], never
    // null, so this can only be an infrastructure failure — never report clean.
    if (files === null) infraError("git diff --cached failed");
  } else {
    files = targets.collectBase(repoRoot, opts.baseRef);
    if (files === null) infraError(`base ref could not be resolved: ${opts.baseRef}`);
  }

  // Allowlist resolution. In --staged / --base an absent allowlist means the gate
  // does not apply to this repository at all (SKIPPED); --all treats it as empty
  // so that --write-allowlist can bootstrap the baseline.
  let entries = [];
  if (!opts.noAllowlist) {
    const text = readAllowlistText(opts, repoRoot);
    if (text === null) {
      if (opts.mode !== "all") {
        emit(`${HEADER}: SKIPPED — no ${targets.ALLOWLIST_NAME} in this repository`);
        finish(EXIT_OK);
      }
    } else {
      entries = allowlistLib.parseAllowlist(text);
    }
  }

  const allViolations = [];
  const allNotes = [];
  for (const f of files) {
    const r = scanFile(f, opts);
    allViolations.push(...r.violations);
    allNotes.push(...r.notes);
  }
  allViolations.sort((a, b) =>
    a.path === b.path ? a.line - b.line : a.path.localeCompare(b.path)
  );

  const counts = countByKindPath(allViolations);

  // --write-allowlist: freeze current debt, write, exit. Nothing else is reported.
  if (opts.writeAllowlist) {
    const rows = [];
    for (const [key, count] of counts) {
      const [kind, p] = splitKey(key);
      rows.push({ kind, path: p, count });
    }
    const dest = path.join(repoRoot, targets.ALLOWLIST_NAME);
    fs.writeFileSync(dest, allowlistLib.generateAllowlist(rows), "utf8");
    emit(`${HEADER}: PERFORMED (all-scan mode)`);
    emit(`Wrote ${targets.ALLOWLIST_NAME} with ${rows.length} entr${rows.length === 1 ? "y" : "ies"}.`);
    finish(EXIT_OK);
  }

  const modeSuffix =
    opts.mode === "all" ? " (all-scan mode)" : opts.mode === "staged" ? " (staged mode)" : "";
  emit(`${HEADER}: PERFORMED${modeSuffix}`);
  emit("");

  const prefix = opts.advisory ? "WARN:" : "HARD:";
  let blocking = 0;
  const reportedPaths = new Set();
  for (const v of allViolations) {
    if (!opts.noAllowlist) {
      const key = keyOf(v.kind, v.path);
      const m = allowlistLib.matchAllowlist(entries, v.kind, v.path, counts.get(key) || 0);
      if (m.allowed) continue;
    }
    blocking += 1;
    reportedPaths.add(v.path);
    emit(`${prefix} ${v.text}`);
  }

  // STALE: an allowlist entry that reserves more debt than actually exists.
  if (opts.mode === "all" && !opts.noAllowlist) {
    for (const e of entries) {
      if (e.count === "*") continue;
      const actual = counts.get(keyOf(e.kind, e.path)) || 0;
      if (actual < e.count) {
        emit(`STALE: ${e.kind} ${e.path} (allowlist has ${e.count}, found ${actual})`);
      }
    }
  }

  for (const n of allNotes) emit(n);

  if (blocking === 0) emit("No prompt extraction violations found.");

  if (opts.advisory || opts.mode === "all") finish(EXIT_OK);
  finish(blocking > 0 ? EXIT_BLOCK : EXIT_OK);
}

main();
