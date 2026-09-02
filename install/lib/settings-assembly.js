'use strict';

// The expectation provider for ~/.claude/settings.json.
//
// One builder answers both questions asked of the deployed document: what the installer must
// write (install/lib/settings-deploy.js) and what a drift check must expect to find
// (hooks/lib/settings-drift.js). Two derivations of the same fact drift apart; one does not.
//
// This module is PURE with respect to the filesystem it reads: it returns a document and
// never persists one. The single writer is install/lib/settings-deploy.js.

const fs = require('fs');
const path = require('path');
const os = require('os');

const allowRules = require('./settings-allow-rules');

const { GenError } = allowRules;

const BASE_REL = 'settings.json';
const EXT_REL = 'settings-extension.json';

const bail = (msg) => {
    throw new GenError(msg);
};

// Schema-aware merge (avoids prototype pollution from generic deep-merge):
//   - hooks.*                          : arrays concatenated
//   - permissions.allow/deny/ask       : arrays concatenated
//   - permissions.additionalDirectories: arrays concatenated
//   - permissions (other keys)         : extension overrides base
//   - env, attribution                 : object-level override (extension keys win)
//   - all other top-level keys         : extension overrides base
function mergeSettings(base, ext) {
    const result = JSON.parse(JSON.stringify(base)); // deep clone base

    for (const key of Object.keys(ext)) {
        if (key === 'hooks') {
            if (!result.hooks) result.hooks = {};
            for (const event of Object.keys(ext.hooks)) {
                result.hooks[event] = (result.hooks[event] || []).concat(ext.hooks[event]);
            }

        } else if (key === 'permissions') {
            if (!result.permissions) result.permissions = {};
            const concatKeys = ['allow', 'deny', 'ask', 'additionalDirectories'];
            for (const pk of Object.keys(ext.permissions)) {
                if (concatKeys.includes(pk)) {
                    result.permissions[pk] = (result.permissions[pk] || []).concat(ext.permissions[pk]);
                } else {
                    result.permissions[pk] = ext.permissions[pk];
                }
            }

        } else if (key === 'env' || key === 'attribution') {
            result[key] = Object.assign({}, result[key] || {}, ext[key]);

        } else {
            result[key] = ext[key];
        }
    }

    return result;
}

const deployedSettingsPath = (homeDir) =>
    path.join(homeDir || os.homedir(), '.claude', 'settings.json');

const isPlainObject = (v) => typeof v === 'object' && v !== null && !Array.isArray(v);

const parseDoc = (raw, rel) => {
    let doc;
    try {
        doc = JSON.parse(raw);
    } catch (e) {
        bail(`${rel} is not valid JSON (${e.message})`);
    }
    if (!isPlainObject(doc)) bail(`${rel} is not a JSON object`);
    return doc;
};

// The base document is the repository's own settings.json. A merge built on a guess about its
// shape deploys a permission set nobody wrote, so each way it can be wrong is its own branch.
const readBase = (basePath) => {
    let raw;
    try {
        raw = fs.readFileSync(basePath, 'utf8');
    } catch (e) {
        bail(`${BASE_REL} could not be read (${e.code || e.message}) - it is never created from scratch`);
    }
    const doc = parseDoc(raw, BASE_REL);
    if (!isPlainObject(doc.permissions)) bail(`${BASE_REL} has no usable "permissions" object`);
    if (!Array.isArray(doc.permissions.allow)) {
        bail(`${BASE_REL}: permissions.allow is present but is not an array`);
    }
    return doc;
};

// A missing extension is normal — it is the developer's optional overlay. A PRESENT but broken
// one is not: merging it key-by-key over the wrong shape would half-apply it.
const readExtension = (extPath) => {
    if (!fs.existsSync(extPath)) return {};
    let raw;
    try {
        raw = fs.readFileSync(extPath, 'utf8');
    } catch (e) {
        bail(`${EXT_REL} could not be read (${e.code || e.message}) - fail-closed`);
    }
    const doc = parseDoc(raw, EXT_REL);
    if ('permissions' in doc && !isPlainObject(doc.permissions)) {
        bail(`${EXT_REL} has no usable "permissions" object`);
    }
    if ('hooks' in doc && !isPlainObject(doc.hooks)) {
        bail(`${EXT_REL} has no usable "hooks" object`);
    }
    return doc;
};

// The generated rules are collected separately from the merge so a spelling-layer failure is
// REPORTED rather than thrown: the deploy path turns it into a fail-closed error, while the
// drift path still gets the base + extension expectation it can legitimately check.
const buildAssembledSettings = ({ agentsRoot = allowRules.DEFAULT_ROOT } = {}) => {
    const settings = mergeSettings(
        readBase(path.join(agentsRoot, BASE_REL)),
        readExtension(path.join(agentsRoot, EXT_REL)));

    let generatedRules = [];
    let bareEmitted = false;
    let generatorError = '';
    try {
        const generated = allowRules.generatedAllowRules({ agentsRoot });
        generatedRules = generated.rules;
        bareEmitted = generated.bareEmitted;
    } catch (e) {
        generatorError = e.message || String(e);
    }

    if (!isPlainObject(settings.permissions)) settings.permissions = {};
    if (!Array.isArray(settings.permissions.allow)) settings.permissions.allow = [];
    const present = new Set(settings.permissions.allow);
    for (const rule of generatedRules) {
        if (present.has(rule)) continue;
        present.add(rule);
        settings.permissions.allow.push(rule);
    }

    return { settings, generatedRules, bareEmitted, generatorError };
};

module.exports = {
    GenError,
    BASE_REL,
    EXT_REL,
    mergeSettings,
    deployedSettingsPath,
    buildAssembledSettings,
};
