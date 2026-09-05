'use strict';

// Spelling library for the permission allow rules covering agents' own internal commands.
//
// The permission engine matches an allow rule against the WHOLE command string, so one
// command issued two ways is two patterns and the second falls back to `ask`. WHICH commands
// are allow-targets is owned by install/settings-allow-commands.txt; the spellings that fact
// expands into are owned here. Rationale and dataflow:
// docs/architecture/claude-code/settings.md.
//
// Pure string and read-only-filesystem work: nothing in this module writes.

const fs = require('fs');
const path = require('path');

const DEFAULT_ROOT = path.resolve(__dirname, '..', '..');
const SSOT_REL = 'install/settings-allow-commands.txt';
const PATH_SSOT_REL = 'install/path-exposed-commands.txt';

class GenError extends Error {
    constructor(message) {
        super(message);
        this.name = 'GenError';
    }
}

const bail = (msg) => {
    throw new GenError(msg);
};

// THE TEMPLATE TABLE — the single canonical owner of every generated spelling. Both the
// renderer and the orphan matcher are derived from these same strings, so a template can
// never be written one way and recognised another.
//   <I> interpreter   <P> repo-relative path   <W> that path in Windows separators
//   <N> bare name   <R> this checkout's absolute root   <R2W> that root in Windows separators
// Twenty-four path spellings (plus six bare spellings for PATH-exposed commands) are emitted
// per admitted command.
const PATH_TEMPLATES_ARGV = [
    'Bash(<I> "$AGENTS_CONFIG_DIR/<P>" *)',
    'Bash(<I> <R>/<P> *)',
    'Bash(<I> <R2W>\\<W> *)',
    'Bash(<I> <P> *)',
    'Bash("$AGENTS_CONFIG_DIR/<P>" *)',
    'Bash(<R>/<P> *)',
    'Bash(bash -c \'<I> "$AGENTS_CONFIG_DIR/<P>" *\')',
    'Bash(bash -c \'cd "$AGENTS_CONFIG_DIR" && <I> "$AGENTS_CONFIG_DIR/<P>" *\')',
    'Bash(<I> "<R>/<P>" *)',
    'Bash(<I> "<R2W>\\<W>" *)',
    'Bash("<R>/<P>" *)',
    'Bash("<R2W>\\<W>" *)',
];

const BARE_TEMPLATES_ARGV = [
    'Bash(<N> *)',
    'Bash(bash -c \'<N> *\')',
    'Bash(bash -c \'cd "$AGENTS_CONFIG_DIR" && <N> *\')',
];

// A trailing ` *` demands the space in front of it, so an argument-bearing spelling never
// matches the argument-less invocation the model actually issues. Each family therefore ships
// as a PAIR, derived rather than retyped: an unpaired family added to the tables above stops
// the build here instead of shipping half a pair.
const dropArgWildcard = (template) => {
    if (template.endsWith(' *)')) return `${template.slice(0, -3)})`;
    if (template.endsWith(" *')")) return `${template.slice(0, -4)}')`;
    return bail(`template "${template}" has no trailing " *" to drop - ` +
        'every argument-bearing spelling must be paired with an argument-less twin');
};

const PATH_TEMPLATES = PATH_TEMPLATES_ARGV.flatMap((t) => [t, dropArgWildcard(t)]);
const BARE_TEMPLATES = BARE_TEMPLATES_ARGV.flatMap((t) => [t, dropArgWildcard(t)]);

const PLACEHOLDER_CLASS = {
    '<I>': '(?:bash|node)',
    '<W>': '[A-Za-z0-9._\\\\-]+',
    '<P>': '[A-Za-z0-9._/-]+',
    '<N>': '([A-Za-z0-9._-]+)',
};

const escapeRegex = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

// <R> is not a character class but a literal, so it is resolved from the caller's root rather
// than from PLACEHOLDER_CLASS. <R2W> is listed first: it must be consumed before <R> is.
const rootValues = (agentsRoot) => {
    const posix = String(agentsRoot).split('\\').join('/').replace(/\/+$/, '');
    return { '<R2W>': posix.split('/').join('\\'), '<R>': posix };
};

const render = (template, values) => {
    let out = template;
    for (const key of Object.keys(values)) out = out.split(key).join(values[key]);
    return out;
};

const templateRegex = (template, agentsRoot = DEFAULT_ROOT) => {
    let source = escapeRegex(template);
    const roots = rootValues(agentsRoot);
    for (const key of Object.keys(roots)) source = source.split(key).join(escapeRegex(roots[key]));
    for (const key of Object.keys(PLACEHOLDER_CLASS)) {
        source = source.split(key).join(PLACEHOLDER_CLASS[key]);
    }
    return new RegExp(`^${source}$`);
};

// Keyed by root for the same reason binNamesByRoot is: <R> resolves per call, so the matcher set
// can no longer be computed once at module load.
const matchersByRoot = new Map();

const matchersFor = (agentsRoot) => {
    const cached = matchersByRoot.get(agentsRoot);
    if (cached) return cached;
    const matchers = {
        path: PATH_TEMPLATES.map((t) => templateRegex(t, agentsRoot)),
        bare: BARE_TEMPLATES.map((t) => templateRegex(t, agentsRoot)),
    };
    matchersByRoot.set(agentsRoot, matchers);
    return matchers;
};

const pathRules = (agentsRoot, interpreter, rel) =>
    PATH_TEMPLATES.map((t) => render(t, {
        ...rootValues(agentsRoot),
        '<I>': interpreter,
        '<W>': rel.split('/').join('\\'),
        '<P>': rel,
    }));

const bareRules = (name) => BARE_TEMPLATES.map((t) => render(t, { '<N>': name }));

// Keyed by root: the same process now asks about a fixture tree and the real tree in turn, so
// a single cached Set would answer the second question with the first tree's answer.
const binNamesByRoot = new Map();

const commandNamesUnderBin = (agentsRoot) => {
    const cached = binNamesByRoot.get(agentsRoot);
    if (cached) return cached;
    const names = new Set();
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
            names.add(item.name);
            names.add(item.name.replace(/\.[^.]+$/, ''));
        }
    };
    walk(path.join(agentsRoot, 'bin'));
    binNamesByRoot.set(agentsRoot, names);
    return names;
};

// A bare rule names a command by basename alone, a namespace shared with every command on
// PATH, so shape alone cannot tell this generator's output from a hand-written `Bash(head *)`.
// Three conditions make the claim safe: the generator emits bare rules for this tree at all,
// the name carries the separator every command under bin/ uses, and no command of that name
// is left there. The last is also the LIMIT of orphan detection — see
// docs/architecture/claude-code/settings.md.
const isManagedBareName = (name, bareIsGenerated, agentsRoot) =>
    bareIsGenerated && /[-_.]/.test(name) && !commandNamesUnderBin(agentsRoot).has(name);

// Only a rule the generator itself could have produced is eligible to be called an orphan:
// a hand-written rule that no template can spell is nobody's drift. A rule bearing ANOTHER
// checkout's root is therefore an orphan here, deliberately: this root would never emit it.
const isGeneratedShaped = (rule, bareIsGenerated, agentsRoot = DEFAULT_ROOT) => {
    const matchers = matchersFor(agentsRoot);
    if (matchers.path.some((re) => re.test(rule))) return true;
    for (const re of matchers.bare) {
        const hit = re.exec(rule);
        if (hit) return isManagedBareName(hit[1], bareIsGenerated, agentsRoot);
    }
    return false;
};

const readListFile = (file, rel) => {
    let stat;
    try {
        stat = fs.statSync(file);
    } catch (e) {
        bail(`${rel} is missing (${e.code || e.message}) - fail-closed`);
    }
    if (!stat.isFile()) bail(`${rel} is not a readable file - fail-closed`);
    let raw;
    try {
        raw = fs.readFileSync(file, 'utf8');
    } catch (e) {
        bail(`${rel} could not be read (${e.code || e.message}) - fail-closed`);
    }
    return raw
        .split('\n')
        .map((line) => line.replace(/\s+$/, ''))
        .filter((line) => line.length > 0 && !/^\s*#/.test(line));
};

// The charset gate runs BEFORE any path is resolved on disk, deliberately: a hostile entry
// naming a file that really exists would otherwise sail past a check ordered the other way,
// and every entry is interpolated into twenty-four path rules, plus six more bare rules when
// it has a PATH shim, where a metacharacter WIDENS a rule
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

const resolveInterpreter = (agentsRoot, entry) => {
    const abs = path.join(agentsRoot, entry);
    let raw;
    try {
        if (!fs.statSync(abs).isFile()) bail(`${SSOT_REL}: entry "${entry}" is not a file`);
        raw = fs.readFileSync(abs, 'utf8');
    } catch (e) {
        if (e instanceof GenError) throw e;
        bail(`${SSOT_REL}: entry "${entry}" could not be read (${e.code || e.message})`);
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

// Deterministic order, stated once: every path spelling in SSOT file order and then template
// order, followed by the bare spellings in that same order.
const generatedAllowRules = ({ agentsRoot = DEFAULT_ROOT } = {}) => {
    const ssot = path.join(agentsRoot, 'install', 'settings-allow-commands.txt');
    const pathSsot = path.join(agentsRoot, 'install', 'path-exposed-commands.txt');
    const entries = readListFile(ssot, SSOT_REL);
    entries.forEach(validateEntry);
    const exposed = new Set(readListFile(pathSsot, PATH_SSOT_REL));
    const interpreters = entries.map((entry) => resolveInterpreter(agentsRoot, entry));
    const rules = [];
    let bareEmitted = false;
    entries.forEach((entry, i) => rules.push(...pathRules(agentsRoot, interpreters[i], entry)));
    entries.forEach((entry) => {
        const name = path.posix.basename(entry);
        if (!exposed.has(name)) return;
        bareEmitted = true;
        rules.push(...bareRules(name));
    });
    return { rules: [...new Set(rules)], bareEmitted };
};

module.exports = {
    GenError,
    DEFAULT_ROOT,
    SSOT_REL,
    PATH_SSOT_REL,
    PATH_TEMPLATES_ARGV,
    BARE_TEMPLATES_ARGV,
    PATH_TEMPLATES,
    BARE_TEMPLATES,
    dropArgWildcard,
    templateRegex,
    pathRules,
    bareRules,
    isGeneratedShaped,
    generatedAllowRules,
};
