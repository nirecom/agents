#!/usr/bin/env node
// Claude Code PreToolUse hook: confirm the OWNER of the repository a forge write
// is about to land in. Filing an issue in someone else's repository is a public,
// unretractable act, and `gh issue create` in the wrong working directory does
// it silently. So this guard asks one question — is the target proven to belong
// to the authenticated user? — and prompts on any answer but yes.
// Coverage boundary: the Bash / runInTerminal / runCommands payloads only. A gh
// call from another shell or the web UI never reaches here, so the guard treats
// an unreadable command as unresolved, never as safe — codes in reasons.js.

// It never BLOCKS: every decision is `ask`, and the hook always exits 0, because
// a guard that crashes the tool call it protects has failed twice.
"use strict";

require("./confirm-forge-target-ownership/run").run();
