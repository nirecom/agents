"use strict";
// hooks/bash-guard/git-deviant/options.js — git-style option scan shared by the git-deviant rules.
//
// Follows git's parse-options: `--` ends options, a short cluster (`-uf`) is one flag per
// letter, a value-taking short or long option consumes its value (so `-o -f` never reads as
// `-f`), and a long option abbreviates by unique prefix. An ambiguous abbreviation stays
// unknown: git itself refuses it, so it never runs.

function canonicalLongName(name, longNames) {
  if (longNames.includes(name)) return name;
  const candidates = longNames.filter((n) => n.startsWith(name));
  return candidates.length === 1 ? candidates[0] : name;
}

/**
 * @param {string[]} args the subcommand's own argv (after the subcommand word)
 * @param {{shortWithValue: Set<string>, longWithValue: Set<string>, longNames: string[]}} spec
 * @returns {{shortFlags: Set<string>, longFlags: {name: string, value: (string|undefined)}[],
 *            positionals: string[]}}
 */
function scanOptions(args, spec) {
  const shortFlags = new Set();
  const longFlags = [];
  const positionals = [];
  let i = 0;
  while (i < args.length) {
    const tok = String(args[i]);
    i += 1;
    if (tok === "--") {
      positionals.push(...args.slice(i).map(String));
      break;
    }
    if (tok.startsWith("--")) {
      const eq = tok.indexOf("=");
      const name = canonicalLongName(eq === -1 ? tok.slice(2) : tok.slice(2, eq), spec.longNames);
      let value = eq === -1 ? undefined : tok.slice(eq + 1);
      if (value === undefined && spec.longWithValue.has(name) && i < args.length) {
        value = String(args[i]);
        i += 1;
      }
      longFlags.push({ name, value });
      continue;
    }
    if (tok.length > 1 && tok[0] === "-") {
      for (let j = 1; j < tok.length; j++) {
        const ch = tok[j];
        if (!spec.shortWithValue.has(ch)) {
          shortFlags.add(ch);
          continue;
        }
        if (j === tok.length - 1 && i < args.length) i += 1;
        break;
      }
      continue;
    }
    positionals.push(tok);
  }
  return { shortFlags, longFlags, positionals };
}

const hasLong = (scan, name) => scan.longFlags.some((f) => f.name === name);

module.exports = { scanOptions, hasLong };
