"use strict";
// State handoff record (#2652): the write entry, the state handoff reader and the --from renderer.
// Readers never open a state file or a legacy handoff.md themselves; they come through here.

const { appendStateHandoffRecord } = require("./state-handoff-record/write");
const { readStateHandoff } = require("./state-handoff-record/read");
const { renderStateHandoffForResume } = require("./state-handoff-record/render-resume");

module.exports = { appendStateHandoffRecord, readStateHandoff, renderStateHandoffForResume };
