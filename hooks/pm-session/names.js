"use strict";
// The typed slash commands the PM writer acts on (#2941). A leaf, so the title hook can still tell a PM
// command apart when the writer itself fails to load or throws (#2942 fail-safe).

const NAMES = Object.freeze(["pm-init", "pm-add", "pm-remove", "pm-rename", "resume-session", "wf-init", "workflow-init"]);

module.exports = { NAMES };
