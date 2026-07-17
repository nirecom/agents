"use strict";
// hooks/lib/bash-write-targets/file-op.js
// Extended file-operation write detection (#1402 canary-7).
// Retires 11 WRITE_PATTERNS file-op entries: sed-inplace, perl-inplace, patch,
// touch, chmod, dd, rsync, tar-extract, unzip, gunzip, bunzip2.
// Flag-gated verbs (sed -i, perl -i, tar -x, dd of=) require explicit flags;
// unconditional verbs (touch, chmod, patch, unzip, rsync) always write.

const { resolveEffectiveCommand, resolveEffectiveArgv, commandBasename } = require("../bash-write-patterns/segment-utils");
const { expandRawToken, isUnresolvableToken } = require("./helpers");

const ASSIGN_RE = /^[A-Za-z_][A-Za-z0-9_]*=/;

// Return raw argv tokens after leading VAR=val env-prefix assignments and the
// command name. Mirrors resolveRawArgvAfterEnvPrefix from bash-write-targets.js.
function resolveRawArgvAfterEnvPrefix(seg) {
  if (!seg || !Array.isArray(seg.argv) || !Array.isArray(seg.argvRaw)) return [];
  const skipCmd = ASSIGN_RE.test(seg.cmd0 || "");
  if (!skipCmd) return seg.argvRaw.slice();
  const idx = seg.argv.findIndex((a) => !ASSIGN_RE.test(a));
  if (idx === -1) return [];
  return seg.argvRaw.slice(idx + 1);
}

// True when sed argv contains -i (in-place) in any of its common forms.
// Accepts: -i, -i.bak, -i '', --in-place, -si, -ei, -ni, etc.
function sedIsWrite(argv) {
  for (const tok of argv) {
    if (typeof tok !== "string") continue;
    if (tok === "--in-place") return true;
    // Short-flag: -i alone or combined (-si, -ei) or with extension (-i.bak, -i'')
    if (tok.startsWith("-") && !tok.startsWith("--")) {
      const rest = tok.slice(1);
      // Combined flags containing 'i': -si, -ei, -ni, etc.
      if (rest.length > 1 && rest.includes("i")) return true;
      // Standalone -i or -i<extension>
      if (rest[0] === "i") return true;
    }
  }
  return false;
}

// True when perl argv contains -i flag (in-place edit).
// Accepts: -i, -i.bak, -pi, -ni, -0i, -pi.bak, etc.
function perlIsWrite(argv) {
  for (const tok of argv) {
    if (typeof tok !== "string") continue;
    if (tok.startsWith("-") && !tok.startsWith("--")) {
      const rest = tok.slice(1);
      if (rest.includes("i")) return true;
    }
  }
  return false;
}

// True when tar argv contains -x / --extract flag.
// NOT write when: -t (list), -c (create), --list, --create.
function tarIsExtract(argv) {
  let hasExtract = false;
  for (const tok of argv) {
    if (typeof tok !== "string") continue;
    if (tok === "--extract") return true;
    if (tok === "--list" || tok === "--create") return false; // explicit non-extract modes
    if (tok.startsWith("-") && !tok.startsWith("--")) {
      const flags = tok.slice(1);
      if (flags.includes("x")) hasExtract = true;
      if (flags.includes("t") || flags.includes("c")) return false; // list/create beats extract
    }
  }
  return hasExtract;
}

// True when dd argv contains of=VALUE where VALUE is not /dev/null or empty.
function ddHasOutput(argv) {
  for (const tok of argv) {
    if (typeof tok !== "string") continue;
    const m = tok.match(/^of=(.*)$/);
    if (!m) continue;
    const val = m[1];
    if (val === "" || val === "/dev/null") return false;
    return true;
  }
  return false;
}

// True when gunzip/bunzip2 argv does NOT contain -l/--list or -t/--test flags.
function gunzipIsWrite(argv) {
  for (const tok of argv) {
    if (typeof tok !== "string") continue;
    if (tok === "--list" || tok === "--test") return false;
    if (tok.startsWith("-") && !tok.startsWith("--")) {
      const flags = tok.slice(1);
      if (flags.includes("l") || flags.includes("t")) return false;
    }
  }
  return true;
}

/**
 * isExtendedFileOpWriteIR: detect writes by touch/chmod/patch/unzip/gunzip/
 * bunzip2/rsync/sed-i/perl-i/tar-x/dd-of verbs.
 * @param {object} ir
 * @returns {boolean}
 */
function isExtendedFileOpWriteIR(ir) {
  if (!ir || ir.parseFailure === true) return false;
  if (!Array.isArray(ir.segments)) return false;
  for (const seg of ir.segments) {
    const effCmd = resolveEffectiveCommand(seg);
    if (effCmd == null) continue;
    const base = commandBasename(effCmd);
    if (base == null) continue;
    const argv = resolveEffectiveArgv(seg) || [];
    switch (base) {
      case "touch":
      case "chmod":
      case "patch":
      case "unzip":
      case "rsync":
        return true;
      case "gunzip":
      case "bunzip2":
        if (gunzipIsWrite(argv)) return true;
        break;
      case "sed":
        if (sedIsWrite(argv)) return true;
        break;
      case "perl":
        if (perlIsWrite(argv)) return true;
        break;
      case "tar":
        if (tarIsExtract(argv)) return true;
        break;
      case "dd":
        if (ddHasOutput(argv)) return true;
        break;
      default:
        break;
    }
  }
  return false;
}

/**
 * extractFileOpTargets: extract write target paths from extended file-op verbs.
 * Returns string[] (bare paths — caller wraps as {resolveVia:"ancestor"}),
 * [] for non-write or write-without-extractable-target, or null for fail-closed
 * (unresolvable token / fail-closed verb form).
 * @param {object} ir
 * @returns {string[]|null}
 */
function extractFileOpTargets(ir) {
  if (!ir || ir.parseFailure === true) return null;
  if (!Array.isArray(ir.segments)) return null;
  const results = [];
  for (const seg of ir.segments) {
    const effCmd = resolveEffectiveCommand(seg);
    if (effCmd == null) continue;
    const base = commandBasename(effCmd);
    if (base == null) continue;
    const argv = resolveEffectiveArgv(seg) || [];
    const argvRaw = resolveRawArgvAfterEnvPrefix(seg);
    // Check if this segment is a write for the relevant verb
    let isWrite = false;
    switch (base) {
      case "touch":
      case "chmod":
      case "patch":
      case "unzip":
      case "rsync":
        isWrite = true;
        break;
      case "gunzip":
      case "bunzip2":
        isWrite = gunzipIsWrite(argv);
        break;
      case "sed":
        isWrite = sedIsWrite(argv);
        break;
      case "perl":
        isWrite = perlIsWrite(argv);
        break;
      case "tar":
        isWrite = tarIsExtract(argv);
        break;
      case "dd":
        isWrite = ddHasOutput(argv);
        break;
      default:
        break;
    }
    if (!isWrite) continue;

    const targets = extractSegmentTargets(base, argv, argvRaw);
    if (targets === null) return null; // fail-closed
    for (const t of targets) results.push(t);
  }
  return results;
}

// Extract targets for a specific verb from a single segment's argv.
// Returns string[] or null (fail-closed).
function extractSegmentTargets(base, argv, argvRaw) {
  switch (base) {
    case "touch":
      return extractPositionals(argv, argvRaw, { skipFirst: 0 });

    case "chmod":
      // Skip first non-flag arg (mode)
      return extractPositionals(argv, argvRaw, { skipFirst: 1 });

    case "patch": {
      // if -o out present → [out]; else if explicit positional target → [target]; else null
      const oOut = extractFlagValue(argv, argvRaw, ["-o"]);
      if (oOut !== undefined) {
        if (oOut === null) return null; // unresolvable
        return [oOut];
      }
      const pos = extractPositionals(argv, argvRaw, { skipFirst: 0 });
      if (pos === null) return null;
      if (pos.length > 0) return [pos[0]];
      return null; // stdin-driven → fail-closed
    }

    case "unzip": {
      // if -d dest → [dest]; else null (CWD extraction → fail-closed)
      const dest = extractFlagValue(argv, argvRaw, ["-d"]);
      if (dest !== undefined) {
        if (dest === null) return null;
        return [dest];
      }
      return null; // CWD → fail-closed
    }

    case "gunzip":
    case "bunzip2":
      // positional args: the .gz/.bz2 files (in-place decompress)
      return extractPositionals(argv, argvRaw, { skipFirst: 0 });

    case "rsync": {
      // last positional is dest; if it contains ':' → remote, skip (return [])
      const pos = extractPositionals(argv, argvRaw, { skipFirst: 0, rsyncMode: true });
      if (pos === null) return null;
      if (pos.length === 0) return [];
      const dest = pos[pos.length - 1];
      if (dest.includes(":")) return []; // remote dest — skip
      return [dest];
    }

    case "sed":
      // trailing positionals after skipping -e/-f values and flags.
      // If no -e/-f is present, the first positional is the sed script (skip it).
      return extractSedPerlPositionals(argv, argvRaw, "sed");

    case "perl":
      // trailing positionals after skipping flags and their values.
      // The first positional (if no -e) is the perl script (skip it).
      return extractSedPerlPositionals(argv, argvRaw, "perl");

    case "tar": {
      // if -C dir/--directory=dir → [dir]; else null (CWD → fail-closed)
      const dir = extractFlagValue(argv, argvRaw, ["-C", "--directory"]);
      if (dir !== undefined) {
        if (dir === null) return null;
        return [dir];
      }
      return null; // CWD → fail-closed
    }

    case "dd": {
      // [of= value]
      for (let i = 0; i < argv.length; i++) {
        const tok = argv[i];
        if (typeof tok !== "string") continue;
        const m = tok.match(/^of=(.+)$/);
        if (!m) continue;
        const rawTok = argvRaw[i];
        if (rawTok !== undefined && isUnresolvableToken(rawTok)) return null;
        return [m[1]];
      }
      return [];
    }

    default:
      return [];
  }
}

// Extract a flag's value token from argv/argvRaw.
// flags: array of flag names (e.g. ["-o"], ["-d"], ["-C", "--directory"]).
// Returns: the resolved string value, null (fail-closed), or undefined (flag not found).
function extractFlagValue(argv, argvRaw, flags) {
  for (let i = 0; i < argv.length; i++) {
    const tok = argv[i];
    if (typeof tok !== "string") continue;
    // Attached form: --directory=val or -C=val
    for (const flag of flags) {
      if (tok.startsWith(flag + "=")) {
        const val = tok.slice(flag.length + 1);
        const rawTok = argvRaw[i];
        if (rawTok !== undefined && isUnresolvableToken(rawTok)) return null;
        return val;
      }
    }
    // Separate form: -d dest
    if (flags.includes(tok)) {
      const nextArgv = argv[i + 1];
      const nextRaw = argvRaw[i + 1];
      if (nextArgv === undefined) return undefined;
      if (typeof nextArgv !== "string") return null;
      if (nextRaw !== undefined && isUnresolvableToken(nextRaw)) return null;
      if (nextRaw !== undefined) {
        const expanded = expandRawToken(nextRaw);
        if (expanded === null) return null;
        return expanded;
      }
      return nextArgv;
    }
  }
  return undefined; // flag not found
}

// Extract positional (non-flag) argv tokens after skipping `skipFirst` non-flag args.
// rsyncMode: rsync has value-taking flags we skip.
function extractPositionals(argv, argvRaw, { skipFirst = 0, rsyncMode = false } = {}) {
  const RSYNC_VALUE_FLAGS = new Set([
    "-e", "--rsh", "--rsync-path", "--password-file", "--log-file",
    "--log-file-format", "--out-format", "--bwlimit", "--port",
    "--sockopts", "--checksum-seed", "--timeout", "--contimeout",
    "--max-size", "--min-size", "--exclude", "--include", "--filter",
    "--exclude-from", "--include-from", "--files-from",
    "--address", "--config", "--dparam", "--compare-dest",
    "--copy-dest", "--link-dest", "-T", "--temp-dir", "-y",
    "--fuzzy", "--partial-dir", "--modify-window", "--backup-dir",
    "--suffix",
  ]);
  const results = [];
  let skipped = 0;
  let i = 0;
  while (i < argv.length) {
    const tok = argv[i];
    if (typeof tok !== "string") { i++; continue; }
    if (tok === "--") { i++; break; } // end of flags
    if (tok.startsWith("-")) {
      // Skip flag and possibly its value
      if (rsyncMode) {
        const eq = tok.indexOf("=");
        if (eq !== -1) { i++; continue; } // attached value
        if (RSYNC_VALUE_FLAGS.has(tok)) { i += 2; continue; }
      }
      i++;
      continue;
    }
    // Positional token
    if (skipped < skipFirst) { skipped++; i++; continue; }
    const rawTok = argvRaw[i];
    if (rawTok !== undefined && isUnresolvableToken(rawTok)) return null;
    let resolved = tok;
    if (rawTok !== undefined) {
      const exp = expandRawToken(rawTok);
      if (exp === null) return null;
      resolved = exp;
    }
    results.push(resolved);
    i++;
  }
  // Also collect positionals after "--"
  while (i < argv.length) {
    const tok = argv[i];
    if (typeof tok !== "string") { i++; continue; }
    const rawTok = argvRaw[i];
    if (rawTok !== undefined && isUnresolvableToken(rawTok)) return null;
    let resolved = tok;
    if (rawTok !== undefined) {
      const exp = expandRawToken(rawTok);
      if (exp === null) return null;
      resolved = exp;
    }
    results.push(resolved);
    i++;
  }
  return results;
}

// Extract trailing positionals for sed / perl (skip -e/-f values for sed,
// skip flag values for perl).
// For sed: if no -e/-f was present, the first positional is the sed script — skip it.
// For perl: if no -e/-E/-f was present, the first positional is the perl script — skip it.
function extractSedPerlPositionals(argv, argvRaw, verb) {
  const SED_VALUE_FLAGS = new Set(["-e", "--expression", "-f", "--file"]);
  const PERL_VALUE_FLAGS = new Set([
    "-e", "-E", "-f", "-F", "-I", "-l", "-m", "-M",
    "-x",
  ]);
  const valueFlags = verb === "sed" ? SED_VALUE_FLAGS : PERL_VALUE_FLAGS;
  // Script-as-positional flags: if any of these are present, first positional is NOT the script
  const scriptFlags = verb === "sed"
    ? new Set(["-e", "--expression", "-f", "--file"])
    : new Set(["-e", "-E", "-f"]);
  const results = [];
  let hasScriptFlag = false;
  let i = 0;
  while (i < argv.length) {
    const tok = argv[i];
    if (typeof tok !== "string") { i++; continue; }
    if (tok === "--") { i++; break; }
    if (tok.startsWith("-")) {
      // Attached form: -e'script' or --expression=script
      const eq = tok.indexOf("=");
      if (eq !== -1) {
        const flagPart = tok.slice(0, eq);
        if (scriptFlags.has(flagPart)) hasScriptFlag = true;
        i++; continue;
      }
      // Check if token itself contains a value (e.g. -e'script', -eEXPR)
      const shortFlag = tok.length >= 2 ? tok.slice(0, 2) : tok;
      if (valueFlags.has(shortFlag) && tok.length > 2) {
        if (scriptFlags.has(shortFlag)) hasScriptFlag = true;
        i++; continue;
      } // attached val
      if (valueFlags.has(tok)) {
        if (scriptFlags.has(tok)) hasScriptFlag = true;
        i += 2; continue;
      } // separate val
      i++;
      continue;
    }
    // Positional
    const rawTok = argvRaw[i];
    if (rawTok !== undefined && isUnresolvableToken(rawTok)) return null;
    let resolved = tok;
    if (rawTok !== undefined) {
      const exp = expandRawToken(rawTok);
      if (exp === null) return null;
      resolved = exp;
    }
    results.push(resolved);
    i++;
  }
  while (i < argv.length) {
    const tok = argv[i];
    if (typeof tok !== "string") { i++; continue; }
    const rawTok = argvRaw[i];
    if (rawTok !== undefined && isUnresolvableToken(rawTok)) return null;
    let resolved = tok;
    if (rawTok !== undefined) {
      const exp = expandRawToken(rawTok);
      if (exp === null) return null;
      resolved = exp;
    }
    results.push(resolved);
    i++;
  }
  // If no script flag (-e/-f) was present, the first positional is the script — skip it.
  if (!hasScriptFlag && results.length > 0) {
    return results.slice(1);
  }
  return results;
}

module.exports = {
  isExtendedFileOpWriteIR,
  extractFileOpTargets,
  sedIsWrite,
  perlIsWrite,
  tarIsExtract,
  ddHasOutput,
  gunzipIsWrite,
};
