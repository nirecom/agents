'use strict';

// Recovers the probe half of #2132's P2 (tests/feature-2132-prompt-issuance/judge-probe.js,
// deleted with that suite by #2262). The sweep next door is a HEURISTIC over prompt text: it
// can say a converted site now carries `bash` in execution position, but not whether the real
// permission-presentation guard lets that whole command line through. This asks the module.
// Sole consumer: tests/prompt-bash-node-calling-convention/legacy-p2p3-coverage.sh.
// Contract: argv[2] is the agents root, argv[3] the command string; stdout is one line -- the
// verdict, or a <...> sentinel so a moved or broken judge fails attributably instead of
// scoring every row `allow` for the wrong reason.

const fs = require('fs');
const path = require('path');

const agentsRoot = process.argv[2];
const command = process.argv[3];
if (!agentsRoot || typeof command !== 'string') {
    process.stderr.write('usage: judge-verdict-probe.js <agentsRoot> <command>\n');
    process.exit(2);
}

const judgeRel = 'hooks/bash-guard/judge.js';
const judgePath = path.join(agentsRoot, 'hooks', 'bash-guard', 'judge.js');
const sentinel = (text) => {
    process.stdout.write(text + '\n');
    process.exit(0);
};

if (!fs.existsSync(judgePath)) sentinel('<MISSING:' + judgeRel + '>');

let judgeBashCommand;
try {
    ({ judgeBashCommand } = require(judgePath));
} catch (e) {
    sentinel('<REQUIRE-THREW>');
}
if (typeof judgeBashCommand !== 'function') sentinel('<NOT-EXPORTED>');

// The envelope is the REAL PreToolUse payload, never a bare string or a {command} object:
// judgeBashCommand short-circuits to allow on tool_name !== "Bash", so a probe that guessed
// the shape wrong would report `allow` for every command including the deny control.
let result;
try {
    result = judgeBashCommand({ tool_name: 'Bash', tool_input: { command } });
} catch (e) {
    sentinel('<JUDGE-THREW>');
}
sentinel(result && typeof result.verdict === 'string' ? result.verdict : '<BAD-SHAPE>');
