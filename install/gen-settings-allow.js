#!/usr/bin/env node
'use strict';

// Spelling generator for the permission allow rules covering agents' own internal commands.
//
// The permission engine matches an allow rule against the WHOLE command string, so one
// command issued two ways is two patterns and the second falls back to `ask`. WHICH commands
// are allow-targets is owned by install/settings-allow-commands.txt; the spellings that fact
// expands into are owned here. Rationale and dataflow:
// docs/architecture/claude-code/settings.md.
//
// Exit codes: 0 in sync, 1 a finding, 2 the generator could not do its job at all.

const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

const ROOT = path.dirname(__dirname);
const SSOT_REL = 'install/settings-allow-commands.txt';
const PATH_SSOT_REL = 'install/path-exposed-commands.txt';
const SETTINGS_REL = 'settings.json';
const SSOT = path.join(ROOT, 'install', 'settings-allow-commands.txt');
const PATH_SSOT = path.join(ROOT, 'install', 'path-exposed-commands.txt');
const SETTINGS = path.join(ROOT, 'settings.json');

const EXIT_OK = 0;
const EXIT_FINDING = 1;
const EXIT_ERROR = 2;

const USAGE = 'usage: node install/gen-settings-allow.js --check [--staged] | --write';

class GenError extends Error {}
const bail = (msg) => {
    throw new GenError(msg);
};

// THE TEMPLATE TABLE — the single canonical owner of every generated spelling. Both the
// renderer and the orphan matcher are derived from these same strings, so a template can
// never be written one way and recognised another.
//   <I> interpreter   <P> repo-relative path   <W> that path in Windows separators
//   <N> bare command name (PATH-exposed commands only)
const PATH_TEMPLATES = [
    // Closed-ended (no trailing wildcard): the bare, argument-less invocation form.
    // Without these, `bash "$AGENTS_CONFIG_DIR/bin/workflow-plans-dir"` matches no rule
    // and prompts — the very form rules/shell-commands.md tells the model to prefer.
    'Bash(<I> "$AGENTS_CONFIG_DIR/<P>")',
    'Bash(<I> <P>)',
    'Bash(<I> "$AGENTS_CONFIG_DIR/<P>" *)',
    'Bash(<I> */agents/<P> *)',
    'Bash(<I> *\\agents\\<W> *)',
    'Bash(<I> <P> *)',
    'Bash("$AGENTS_CONFIG_DIR/<P>" *)',
    'Bash(*/agents/<P> *)',
    'Bash(bash -c \'<I> "$AGENTS_CONFIG_DIR/<P>" *\')',
    'Bash(bash -c \'cd "$AGENTS_CONFIG_DIR" && <I> "$AGENTS_CONFIG_DIR/<P>" *\')',
];

const BARE_TEMPLATES = [
    'Bash(<N> *)',
    'Bash(bash -c \'<N> *\')',
    'Bash(bash -c \'cd "$AGENTS_CONFIG_DIR" && <N> *\')',
];

const PLACEHOLDER_CLASS = {
    '<I>': '(?:bash|node)',
    '<W>': '[A-Za-z0-9._\\\\-]+',
    '<P>': '[A-Za-z0-9._/-]+',
    '<N>': '([A-Za-z0-9._-]+)',
};

const render = (template, values) => {
    let out = template;
    for (const key of Object.keys(values)) out = out.split(key).join(values[key]);
    return out;
};

const templateRegex = (template) => {
    let source = template.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    for (const key of Object.keys(PLACEHOLDER_CLASS)) {
        source = source.split(key).join(PLACEHOLDER_CLASS[key]);
    }
    return new RegExp(`^${source}$`);
};

const PATH_MATCHERS = PATH_TEMPLATES.map(templateRegex);
const BARE_MATCHERS = BARE_TEMPLATES.map(templateRegex);

const pathRules = (interpreter, rel) =>
    PATH_TEMPLATES.map((t) =>
        render(t, { '<I>': interpreter, '<W>': rel.split('/').join('\\'), '<P>': rel }));

const bareRules = (name) => BARE_TEMPLATES.map((t) => render(t, { '<N>': name }));

let binNames = null;
const commandNamesUnderBin = () => {
    if (binNames) return binNames;
    binNames = new Set();
    const walk = (dir) => {
        let items;
        try {
            items = fs.readdirSync(dir, { withFileTypes: true });
        } catch (e) {
            return;
        }
        for (const item of items) {
            if (item.isDirectory()) {
                walk(path.join(dir, item.name));
                continue;
            }
            binNames.add(item.name);
            binNames.add(item.name.replace(/\.[^.]+$/, ''));
        }
    };
    walk(path.join(ROOT, 'bin'));
    return binNames;
};

// A bare rule names a command by basename alone, a namespace shared with every command on
// PATH, so shape alone cannot tell this generator's output from a hand-written `Bash(head *)`.
// Three conditions make the claim safe: the generator emits bare rules for this tree at all,
// the name carries the separator every command under bin/ uses, and no command of that name
// is left there. The last is also the LIMIT of orphan detection — see
// docs/architecture/claude-code/settings.md.
const isManagedBareName = (name, bareIsGenerated) =>
    bareIsGenerated && /[-_.]/.test(name) && !commandNamesUnderBin().has(name);

// Only a rule the generator itself could have produced is eligible to be called an orphan:
// a hand-written rule that no template can spell is nobody's drift.
const isGeneratedShaped = (rule, bareIsGenerated) => {
    if (PATH_MATCHERS.some((re) => re.test(rule))) return true;
    for (const re of BARE_MATCHERS) {
        const hit = re.exec(rule);
        if (hit) return isManagedBareName(hit[1], bareIsGenerated);
    }
    return false;
};

// --staged reads every generator input from the commit's staged index (`git show :<path>`)
// rather than the working tree, so a file edited-but-unstaged after `git add` cannot make the
// pre-commit drift gate pass a version of settings.json that differs from what actually gets
// committed. Plain --check (interactive/dev use) still reads the working tree.
const readGitStaged = (rel) => {
    try {
        return execFileSync('git', ['show', `:${rel.split(path.sep).join('/')}`], { cwd: ROOT, encoding: 'utf8' });
    } catch (e) {
        return null;
    }
};

const readListFile = (file, rel, staged) => {
    let raw;
    if (staged) {
        raw = readGitStaged(rel);
        if (raw === null) bail(`${rel} is not present in the staged index - fail-closed`);
    } else {
        let stat;
        try {
            stat = fs.statSync(file);
        } catch (e) {
            bail(`${rel} is missing (${e.code || e.message}) - fail-closed`);
        }
        if (!stat.isFile()) bail(`${rel} is not a readable file - fail-closed`);
        try {
            raw = fs.readFileSync(file, 'utf8');
        } catch (e) {
            bail(`${rel} could not be read (${e.code || e.message}) - fail-closed`);
        }
    }
    return raw
        .split('\n')
        .map((line) => line.replace(/\s+$/, ''))
        .filter((line) => line.length > 0 && !/^\s*#/.test(line));
};

// The charset gate runs BEFORE any path is resolved on disk, deliberately: a hostile entry
// naming a file that really exists would otherwise sail past a check ordered the other way,
// and every entry is interpolated into eleven rules, where a metacharacter WIDENS a rule
// rather than merely naming the wrong file.
const ENTRY_RE = /^[A-Za-z0-9._/-]+$/;

const validateEntry = (entry) => {
    if (entry.includes('..')) bail(`${SSOT_REL}: entry "${entry}" contains "..", which escapes the agents root`);
    if (entry.startsWith('/')) bail(`${SSOT_REL}: entry "${entry}" is an absolute path`);
    if (!ENTRY_RE.test(entry)) {
        bail(`${SSOT_REL}: entry "${entry}" is not a plain relative path ` +
            '(allowed: letters, digits, dot, underscore, hyphen, forward slash)');
    }
};

const resolveInterpreter = (entry, staged) => {
    let raw;
    if (staged) {
        raw = readGitStaged(entry);
        if (raw === null) bail(`${SSOT_REL}: entry "${entry}" is not present in the staged index`);
    } else {
        const abs = path.join(ROOT, entry);
        try {
            if (!fs.statSync(abs).isFile()) bail(`${SSOT_REL}: entry "${entry}" is not a file`);
            raw = fs.readFileSync(abs, 'utf8');
        } catch (e) {
            if (e instanceof GenError) throw e;
            bail(`${SSOT_REL}: entry "${entry}" could not be read (${e.code || e.message})`);
        }
    }
    const first = raw.split('\n', 1)[0].trim();
    if (!first.startsWith('#!')) {
        bail(`${SSOT_REL}: entry "${entry}" has no shebang, so its interpreter is unresolvable - fail-closed`);
    }
    const tokens = first.slice(2).trim().split(/\s+/).filter((t) => t.length > 0);
    const nameOf = (t) => path.posix.basename(t.split('\\').join('/'));
    let name = tokens.length > 0 ? nameOf(tokens[0]) : '';
    if (name === 'env') name = tokens.length > 1 ? nameOf(tokens[1]) : '';
    if (name !== 'bash' && name !== 'node') {
        bail(`${SSOT_REL}: entry "${entry}" resolves to interpreter "${name || '(none)'}", ` +
            'which is neither bash nor node - fail-closed');
    }
    return name;
};

const readSettings = (staged) => {
    let raw;
    if (staged) {
        raw = readGitStaged(SETTINGS_REL);
        if (raw === null) bail(`${SETTINGS_REL} is not present in the staged index - it is never created from scratch`);
    } else {
        try {
            raw = fs.readFileSync(SETTINGS, 'utf8');
        } catch (e) {
            bail(`${SETTINGS_REL} could not be read (${e.code || e.message}) - it is never created from scratch`);
        }
    }
    let doc;
    try {
        doc = JSON.parse(raw);
    } catch (e) {
        bail(`${SETTINGS_REL} is not valid JSON (${e.message})`);
    }
    if (typeof doc !== 'object' || doc === null || Array.isArray(doc)) {
        bail(`${SETTINGS_REL} is not a JSON object`);
    }
    const perms = doc.permissions;
    if (typeof perms !== 'object' || perms === null || Array.isArray(perms)) {
        bail(`${SETTINGS_REL} has no usable "permissions" object`);
    }
    if (!Array.isArray(perms.allow)) {
        bail(`${SETTINGS_REL}: permissions.allow is present but is not an array`);
    }
    return { raw, doc, allow: perms.allow };
};

// Deterministic order, stated once: every path spelling in SSOT file order and then template
// order, followed by the bare spellings in that same order.
const desiredRules = (staged) => {
    const entries = readListFile(SSOT, SSOT_REL, staged);
    entries.forEach(validateEntry);
    const exposed = new Set(readListFile(PATH_SSOT, PATH_SSOT_REL, staged));
    const interpreters = entries.map((entry) => resolveInterpreter(entry, staged));
    const rules = [];
    let bareEmitted = false;
    entries.forEach((entry, i) => rules.push(...pathRules(interpreters[i], entry)));
    entries.forEach((entry) => {
        const name = path.posix.basename(entry);
        if (!exposed.has(name)) return;
        bareEmitted = true;
        rules.push(...bareRules(name));
    });
    return { rules: [...new Set(rules)], bareEmitted };
};

const findings = (staged) => {
    const { rules: wanted, bareEmitted } = desiredRules(staged);
    const settings = readSettings(staged);
    const present = new Set(settings.allow);
    const wantedSet = new Set(wanted);
    return {
        settings,
        wanted,
        missing: wanted.filter((r) => !present.has(r)),
        orphaned: settings.allow.filter((r) => !wantedSet.has(r) && isGeneratedShaped(r, bareEmitted)),
    };
};

const reportCheck = ({ missing, orphaned }) => {
    if (missing.length > 0) {
        console.log(`Missing ${missing.length} allow rule(s) - append them with: ` +
            'node install/gen-settings-allow.js --write');
        missing.forEach((r) => console.log(`  ${r}`));
    }
    if (orphaned.length > 0) {
        console.log(`Orphaned ${orphaned.length} allow rule(s) - generated-shaped rules whose ` +
            `command is no longer listed in ${SSOT_REL}.`);
        console.log('  --write will not remove them: review it yourself and delete them by hand ' +
            'once the command is really gone.');
        orphaned.forEach((r) => console.log(`  ${r}`));
    }
    return missing.length > 0 || orphaned.length > 0 ? EXIT_FINDING : EXIT_OK;
};

// --write is append-only. The document is round-tripped through JSON.parse/stringify so key
// order, every unrelated setting and the escaping of every rule string stay the parser's
// responsibility and never this file's.
// --write reports orphans the same way --check does: it stays append-only (it never removes a
// rule from settings.json), so a caller reading only the exit code must not be told EXIT_OK
// while an orphaned generated-shaped rule silently remains effective.
const applyWrite = ({ settings, missing, orphaned }) => {
    settings.doc.permissions.allow.push(...missing);
    const out = `${JSON.stringify(settings.doc, null, 2)}\n`;
    if (out !== settings.raw) fs.writeFileSync(SETTINGS, out);
    if (orphaned.length > 0) {
        console.log(`Orphaned ${orphaned.length} allow rule(s) - generated-shaped rules whose ` +
            `command is no longer listed in ${SSOT_REL}.`);
        console.log('  --write does not remove them: review it yourself and delete them by hand ' +
            'once the command is really gone.');
        orphaned.forEach((r) => console.log(`  ${r}`));
    }
    return EXIT_OK;
};

const main = (argv) => {
    const mode = argv[0];
    const staged = argv.includes('--staged');
    if (mode !== '--check' && mode !== '--write') {
        process.stderr.write(`unrecognised mode "${mode || ''}"\n${USAGE}\n`);
        return EXIT_ERROR;
    }
    if (staged && mode !== '--check') {
        process.stderr.write(`--staged is only valid with --check\n${USAGE}\n`);
        return EXIT_ERROR;
    }
    if (argv.length !== (staged ? 2 : 1)) {
        process.stderr.write(`${USAGE}\n`);
        return EXIT_ERROR;
    }
    try {
        const found = findings(staged);
        return mode === '--check' ? reportCheck(found) : applyWrite(found);
    } catch (e) {
        if (e instanceof GenError) {
            process.stderr.write(`gen-settings-allow: ${e.message}\n`);
            return EXIT_ERROR;
        }
        throw e;
    }
};

process.exitCode = main(process.argv.slice(2));
