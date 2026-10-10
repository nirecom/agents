'use strict';

// The SINGLE writer of ~/.claude/settings.json.
//
// install/assemble-settings.js comes through here, so the deploy has one polarity.

const fs = require('fs');
const os = require('os');
const path = require('path');

const assembly = require('./settings-assembly');

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

// Git Bash spells a drive as `/c/...`, which win32 fs calls do not resolve. Kept here rather than
// required from hooks/lib: install/lib must load on its own (its fixtures copy this directory alone).
const toNativePath = (p) => (process.platform === 'win32' && /^\/[a-zA-Z]\//.test(p)
    ? `${p[1].toUpperCase()}:${p.slice(2)}`
    : p);

const canonicalDir = (p) => {
    const abs = path.resolve(toNativePath(p));
    return realpathOr(abs) || abs;
};

// Node on win32 takes the home from USERPROFILE and never reads HOME, so a caller that re-points
// HOME alone still deploys into the real profile (#2561: a test overwrote the developer's own
// settings.json this way). With no explicit homeDir the two must name one directory, or nothing
// is written. An unset HOME is not a disagreement: the platform home is then the only answer.
const assertHomeAgreement = () => {
    const envHome = process.env.HOME;
    if (!envHome) return;
    const platformHome = os.homedir();
    if (samePath(canonicalDir(envHome), canonicalDir(platformHome))) return;
    throw new GenError(`HOME is ${envHome} but the platform home directory (os.homedir(), which ` +
        `on Windows comes from USERPROFILE) is ${platformHome} - two different directories, so ` +
        'the destination of settings.json is ambiguous. Nothing was written; point HOME and the ' +
        'platform home at the same directory, or pass homeDir explicitly, and deploy again');
};

// Written IN PLACE rather than through a temp file and a rename so the detach decision above sits
// immediately in front of the one write, with nothing between deciding and doing.
const deployAssembledSettings = ({ agentsRoot = assembly.DEFAULT_ROOT, homeDir } = {}) => {
    if (!homeDir) assertHomeAgreement();
    const built = assembly.buildAssembledSettings({ agentsRoot });
    const outPath = assembly.deployedSettingsPath(homeDir);
    fs.mkdirSync(path.dirname(outPath), { recursive: true });
    const decision = detachDecision(outPath, agentsRoot);
    if (decision.refuse) {
        throw new GenError(`${path.dirname(outPath)} is a symlink resolving to ${decision.dirReal}, ` +
            `inside the agents checkout at ${decision.root} - deploying would write the assembled ` +
            'settings into the repository\'s own tracked settings.json. Nothing was written, so ' +
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
