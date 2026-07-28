#!/usr/bin/env node
// Re-apply the `includeWorktrees` fix to the anthropic.claude-code VS Code extension,
// and optionally prune title-only stub session files from ~/.claude/projects.
//
// The extension ships a minified bundle whose session-list call hardcodes
// `includeWorktrees:!1`, so sessions whose cwd is inside a linked git worktree never
// appear in its session list. Flipping `!1` to `!0` is byte-length preserving. Every
// extension auto-upgrade overwrites the fix, so this tool re-applies it on demand.
// Safety posture: refuse rather than guess — the bundle is minified third-party code,
// so anything the classifier does not recognise verbatim is reported and left alone.
//
// This file is dispatch and re-export only; the implementation lives in the
// sibling modules of this directory.
'use strict';

const { main } = require('./cli');
const patch = require('./patch');
const prune = require('./prune');

if (require.main === module) {
  process.exit(main());
}

module.exports = {
  // The shipped patch path.
  classify: patch.classify,
  classifyValue: patch.classifyValue,
  resolveRoots: patch.resolveRoots,
  listExtensionDirs: patch.listExtensionDirs,
  CANDIDATE_ROOTS: patch.CANDIDATE_ROOTS,
  EXTENSION_DIR_PATTERN: patch.EXTENSION_DIR_PATTERN,
  // The prune path.
  classifySessionFile: prune.classifySessionFile,
  verifyCounterpart: prune.verifyCounterpart,
  isOwnTitleRecord: prune.isOwnTitleRecord,
  planPrune: prune.planPrune,
  planPruneRoots: prune.planPruneRoots,
  executePrunePlan: prune.executePrunePlan,
  pruneRoots: prune.pruneRoots,
  resolvePruneRoots: prune.resolvePruneRoots,
  listSessionFiles: prune.listSessionFiles,
  SESSION_FILE_PATTERN: prune.SESSION_FILE_PATTERN,
  DEFAULT_PROJECTS_ROOTS: prune.DEFAULT_PROJECTS_ROOTS,
};
