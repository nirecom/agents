#!/usr/bin/env node
"use strict";
// PreToolUse (Bash|runInTerminal|runCommands): protect the <user> block of GitHub issues.
// Every gh issue write (gh issue create|edit|comment|delete, gh api REST issue endpoints and the
// GraphQL issue mutations) is checked by bin/user-block-guard; logic lives in protect-user-block/.
require("./protect-user-block/run").main();
