'use strict';

// The SINGLE writer of ~/.claude/settings.json.
//
// Both CLIs (install/assemble-settings.js and install/gen-settings-allow.js --write) come
// through here, so the deploy has one polarity rather than two that can disagree.
//
// FAIL-CLOSED: when the spelling layer could not produce the generated rules, the previous
// deployed file is strictly safer than a fresh one missing several hundred allow rules — a
// permission regression that reports success. So nothing is written at all.

const fs = require('fs');
const path = require('path');

const assembly = require('./settings-assembly');
const allowRules = require('./settings-allow-rules');

const { GenError } = assembly;

const realpathOr = (p) => {
    try {
        return fs.realpathSync(p);
    } catch (e) {
        return null;
    }
};

// win32 realpath answers in the on-disk casing, so a case difference is not a traversed link.
const samePath = (a, b) => (process.platform === 'win32'
    ? a.toLowerCase() === b.toLowerCase()
    : a === b);

const isInside = (candidate, root) => {
    if (candidate === null) return false;
    const rel = path.relative(root, candidate);
    return rel === '' || (!rel.startsWith('..') && !path.isAbsolute(rel));
};

// The axis is WHERE THE WRITE LANDS, not whether the target is a link: a write landing back inside
// the checkout would push the generated rules into the repository's own tracked settings.json - the
// state #2119 removes. Three outcomes. A leaf link landing inside, or not resolving at all, is
// DETACHED (both installers already delete such links as stale); one landing outside is somebody's
// deliberate arrangement and is WRITTEN THROUGH (CPR-UNV). A non-link leaf is decided by its parent,
// because ~/.claude may itself be a link into the checkout that a leaf-only check never sees - and
// there the answer is REFUSE, not detach: unlinking a directory link would orphan everything else
// under it, so the only safe move is the module's fail-closed one - write nothing, leave the
// previous deployment standing, and tell the operator to replace the link with a real directory.
const detachDecision = (outPath, agentsRoot) => {
    const root = realpathOr(agentsRoot) || path.resolve(agentsRoot);
    const dir = path.resolve(path.dirname(outPath));
    const dirReal = realpathOr(dir);
    let isLink = false;
    try {
        isLink = fs.lstatSync(outPath).isSymbolicLink();
    } catch (e) {
        isLink = false;
    }
    if (isLink) {
        const target = realpathOr(outPath);
        if (target === null) return { detach: true, reason: 'its target does not resolve' };
        if (isInside(target, root)) {
            return { detach: true, reason: `it resolves inside the agents checkout at ${root}` };
        }
        return { detach: false, reason: '' };
    }
    if (dirReal !== null && !samePath(dirReal, dir) && isInside(dirReal, root)) {
        return { detach: false, refuse: true, dirReal, root };
    }
    return { detach: false, reason: '' };
};

// Written IN PLACE rather than through a temp file and a rename so the detach decision above sits
// immediately in front of the one write, with nothing between deciding and doing.
const deployAssembledSettings = ({ agentsRoot = allowRules.DEFAULT_ROOT, homeDir } = {}) => {
    const built = assembly.buildAssembledSettings({ agentsRoot });
    if (built.generatorError) {
        throw new GenError(`generated allow rules are unavailable: ${built.generatorError} ` +
            '- nothing was deployed, so the previous settings.json is left untouched');
    }
    const outPath = assembly.deployedSettingsPath(homeDir);
    fs.mkdirSync(path.dirname(outPath), { recursive: true });
    const decision = detachDecision(outPath, agentsRoot);
    if (decision.refuse) {
        throw new GenError(`${path.dirname(outPath)} is a symlink resolving to ${decision.dirReal}, ` +
            `inside the agents checkout at ${decision.root} - deploying would write the generated ` +
            'allow rules into the repository\'s own tracked settings.json. Nothing was written, so ' +
            'the previous deployment stands; replace that directory link with a real directory ' +
            '(both installers already remove stale links of this kind) and deploy again');
    }
    if (decision.detach) {
        fs.unlinkSync(outPath);
        process.stderr.write(`settings-deploy: removed the symlink at ${outPath} because ` +
            `${decision.reason}; wrote a regular file there instead\n`);
    } else if (decision.reason) {
        process.stderr.write(`settings-deploy: ${outPath} - ${decision.reason}\n`);
    }
    fs.writeFileSync(outPath, `${JSON.stringify(built.settings, null, 2)}\n`, 'utf8');
    return { outPath, built };
};

module.exports = { GenError, deployAssembledSettings };
