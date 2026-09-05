#!/usr/bin/env node
'use strict';

// Drift checker and deployer for the permission allow rules covering agents' own commands.
//
// The CLI over three modules: install/settings-allow-commands.txt names the commands,
// install/lib/settings-allow-rules.js owns their spellings, install/lib/settings-assembly.js
// builds the document and install/lib/settings-deploy.js writes it. The generated rules never
// live in the repository's settings.json — they are injected into ~/.claude/settings.json at
// deploy time, which is the document --check inspects.
// Rationale and dataflow: docs/architecture/claude-code/settings.md.
//
// Exit codes: 0 in sync, 1 a finding, 2 the generator could not do its job at all.

const fs = require('fs');
const path = require('path');

const allowRules = require('./lib/settings-allow-rules');
const assembly = require('./lib/settings-assembly');
const settingsDeploy = require('./lib/settings-deploy');

const { GenError, SSOT_REL, isGeneratedShaped } = allowRules;

const ROOT = path.dirname(__dirname);

const EXIT_OK = 0;
const EXIT_FINDING = 1;
const EXIT_ERROR = 2;

const USAGE = 'usage: node install/gen-settings-allow.js --check | --write';

const bail = (msg) => {
    throw new GenError(msg);
};

// The four shape branches the base document has always had, RETARGETED at the deployed one:
// that is the document the permission engine actually reads, and comparing the generated set
// against a document of the wrong shape would name every spelling as drift.
const readDeployed = () => {
    const file = assembly.deployedSettingsPath();
    let raw;
    try {
        raw = fs.readFileSync(file, 'utf8');
    } catch (e) {
        bail(`${file} could not be read (${e.code || e.message}) - ` +
            'nothing is deployed yet: run "node install/assemble-settings.js"');
    }
    let doc;
    try {
        doc = JSON.parse(raw);
    } catch (e) {
        bail(`${file} is not valid JSON (${e.message})`);
    }
    if (typeof doc !== 'object' || doc === null || Array.isArray(doc)) {
        bail(`${file} is not a JSON object`);
    }
    const perms = doc.permissions;
    if (typeof perms !== 'object' || perms === null || Array.isArray(perms)) {
        bail(`${file} has no usable "permissions" object`);
    }
    if (!Array.isArray(perms.allow)) {
        bail(`${file}: permissions.allow is present but is not an array`);
    }
    return { file, allow: perms.allow };
};

const orphansIn = (allow, generatedRules, bareEmitted) => {
    const wanted = new Set(generatedRules);
    return allow.filter((r) => !wanted.has(r) && isGeneratedShaped(r, bareEmitted, ROOT));
};

const reportOrphans = (orphaned) => {
    if (orphaned.length === 0) return;
    console.log(`Orphaned ${orphaned.length} allow rule(s) - generated-shaped rules whose ` +
        `command is no longer listed in ${SSOT_REL}.`);
    console.log('  The deploy will not remove them: review it yourself and delete them by hand ' +
        'once the command is really gone.');
    orphaned.forEach((r) => console.log(`  ${r}`));
};

// The expectation is built before the deployed file is read, so a broken input is reported as
// "the generator could not do its job" rather than as drift against a healthy deployment.
const runCheck = () => {
    const built = assembly.buildAssembledSettings({ agentsRoot: ROOT });
    if (built.generatorError) bail(built.generatorError);
    const deployed = readDeployed();
    const present = new Set(deployed.allow);
    const missing = built.generatedRules.filter((r) => !present.has(r));
    const orphaned = orphansIn(deployed.allow, built.generatedRules, built.bareEmitted);
    if (missing.length > 0) {
        console.log(`Missing ${missing.length} allow rule(s) from ${deployed.file} - ` +
            'redeploy them with: node install/gen-settings-allow.js --write');
        missing.forEach((r) => console.log(`  ${r}`));
    }
    reportOrphans(orphaned);
    return missing.length > 0 || orphaned.length > 0 ? EXIT_FINDING : EXIT_OK;
};

// The deploy is append-only with respect to hand-written rules: an orphan is REPORTED and left
// in place, because deciding a command is really gone is a human's call.
const runWrite = () => {
    const { outPath, built } = settingsDeploy.deployAssembledSettings({ agentsRoot: ROOT });
    console.log(`Deployed: ${outPath}`);
    reportOrphans(orphansIn(
        built.settings.permissions.allow, built.generatedRules, built.bareEmitted));
    return EXIT_OK;
};

const errText = (e) => {
    if (e instanceof GenError) return e.message;
    const code = e && e.code ? `${e.code}: ` : '';
    return `${code}${e && e.message ? e.message : String(e)}`;
};

const main = (argv) => {
    const mode = argv[0];
    if (mode !== '--check' && mode !== '--write') {
        process.stderr.write(`unrecognised mode "${mode || ''}"\n${USAGE}\n`);
        return EXIT_ERROR;
    }
    if (argv.length !== 1) {
        process.stderr.write(`${USAGE}\n`);
        return EXIT_ERROR;
    }
    try {
        return mode === '--check' ? runCheck() : runWrite();
    } catch (e) {
        process.stderr.write(`gen-settings-allow: ${errText(e)}\n`);
        return EXIT_ERROR;
    }
};

process.exitCode = main(process.argv.slice(2));
