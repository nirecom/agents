"use strict";
// hooks/lib/worker-dispatch-registry.js
//
// SSOT (PURE DATA) for the plain-script worker dispatcher (#1643).
//
// Consumed by two independent entry points:
//   - hooks/enforce-worktree/main-worktree-allows/*  (guard side: worker-name enum only)
//   - bin/worker-dispatch/*                          (dispatcher side: full spec)
//
// HARD INVARIANT: this module requires NOTHING — not even a node builtin.
// The guard must be able to load it with zero transitive surface, and commit
// ordering requires it to be loadable before bin/worker-dispatch/ exists.
// tests/feature-1643-worker-dispatch-schema.sh asserts this by source scan.
//
// Entry shape:
//   name         worker-name enum member (argv[2] of the canonical form)
//   argSpec      argv positional types, declared per worker (never shared by
//                reference) so #1673's close-family can diverge without a rewrite
//   payloadSpec  field name -> capability type (see bin/worker-dispatch/capability.js)
//   binaries     the ONLY binaries this worker may execute
//   writeScopes  the ONLY scopes this worker may write into (empty = no writes)
//   renderer     stdout renderer: status-triple | status-triple-quoted | test-runner-yaml
//
// The renderer distinction between quoted and unquoted status triples is part of
// the output contract inherited from the agents/*.md workers this replaces —
// calling skills parse those bytes. Do not "normalize" it.

const WORKER_NAMES = [
  "test-runner",
  "worktree-copy",
  "worktree-backup",
  "doc-append",
  "issue-reconcile",
  "session-close-gate",
  // #1673 forge family, listed in delivery order.
  "commit-push",
  "issue-close-stage",
  "issue-close-finalize",
];

// Canonical argv shape shared by every worker today. Spread per entry so that a
// future worker can declare a different shape without mutating the others.
const STANDARD_ARG_SPEC = ["enum-worker", "anchor-main-root", "path-plansdir"];

// Every external command any worker may ever run. A worker's own `binaries.external`
// must be a subset of this list; bin/worker-dispatch/spawn.js enforces both layers.
const EXTERNAL_COMMANDS = ["git", "gh", "docker", "bash", "node", "uv"];

// Child-process env allowlist. AGENTS_CONFIG_DIR is NOT here on purpose: it is set
// explicitly from the resolved ACD anchor and never inherited.
//
// Credentials are NOT here either. GH_TOKEN / GITHUB_TOKEN are declared by the one
// worker that authenticates against GitHub (issue-reconcile). A global entry would
// hand them to every worker's children — including, via the family-worktree script
// anchor, code from the branch under review, which no one has read yet.
const CHILD_ENV_ALLOWLIST = [
  "PATH",
  "Path",
  "PATHEXT",
  "HOME",
  "USERPROFILE",
  "SYSTEMROOT",
  "SystemRoot",
  "COMSPEC",
  "ComSpec",
  "TEMP",
  "TMP",
  // Windows gh CLI needs APPDATA to locate its config dir (hosts.yml) even when
  // the OAuth token itself lives in the OS keyring rather than GH_TOKEN.
  "APPDATA",
];

// Write-scope tokens understood by bin/worker-dispatch/fsguard.js.
const WRITE_SCOPES = ["plans-dir", "family-worktree", "backup-dir", "main-root-docs"];

// Script-anchor tokens understood by bin/worker-dispatch/spawn.js. `acd` and
// `main-root` resolve into reviewed, merged code. `family-worktree` resolves into
// the payload's target worktree — unreviewed by definition — and is therefore
// reserved for workers whose purpose is to execute the branch under review.
const SCRIPT_ANCHORS = ["acd", "main-root", "family-worktree"];

const workers = {
  // -----------------------------------------------------------------------
  // Stage 1 canary. Side-effect-free by construction: writeScopes is EMPTY,
  // so fsguard.js refuses every write this worker could attempt.
  // -----------------------------------------------------------------------
  "test-runner": {
    name: "test-runner",
    argSpec: [...STANDARD_ARG_SPEC],
    payloadSpec: {
      cwd: { type: "family-worktree", required: true },
      // rel-path-arg[], not text[]: these become argv for tests/run-all.sh, which
      // word-splits each element and runs whatever `.sh` it lands on. As free text
      // an absolute path or a `../` climb selects a script outside the validated
      // family worktree — the one field that would contradict capability.js's rule
      // that a value which can name a file must be tied to an anchor.
      test_args: { type: "rel-path-arg[]", required: false, default: [], maxItems: 64 },
      // The ceiling bounds a runaway child, not a normal run. 3600 was below the
      // real cost of a full `--all` sweep with RUN_TL3=on (real `claude -p` seams),
      // so the only way to request one was a request the dispatcher would kill.
      timeout_seconds: { type: "int", required: false, default: 120, min: 1, max: 21600 },
    },
    binaries: {
      external: ["bash"],
      // family-worktree, not main-root: run-all.sh derives its test directory from
      // its own location, so a main-root anchor would run main's suite regardless
      // of `cwd` — verifying the wrong tree while reporting success.
      scripts: { runAll: { anchor: "family-worktree", rel: "tests/run-all.sh" } },
    },
    envPassthrough: [],
    writeScopes: [],
    renderer: "test-runner-yaml",
  },

  // -----------------------------------------------------------------------
  // Stage 2: the entries below declare their capability surface so the guard
  // enum, capability validation and renderer contract are in force regardless of
  // implementation status. Worker modules land one commit each per the delivery
  // plan; which names are live is answered ONLY by the MODULES table in
  // bin/worker-dispatch/registry.js — a name with no module there renders
  // `status: failed` through its declared renderer rather than crashing.
  // Fields are grounded in the existing agents/<worker>.md input contracts and in
  // the detail plan's capability table — do not invent additional fields here.
  // -----------------------------------------------------------------------
  "worktree-copy": {
    name: "worktree-copy",
    argSpec: [...STANDARD_ARG_SPEC],
    payloadSpec: {
      main_root: { type: "anchor-main-root", required: false },
      worktree_path: { type: "family-worktree", required: true },
      branch: { type: "branch", required: true },
      // Optional to match the agent contract this replaces: /worktree-start passes
      // an empty session id when it cannot resolve one, and the notes CLI degrades
      // by omitting the Session-ID line rather than failing.
      session_id: { type: "session-id", required: false },
      agents_config_dir: { type: "anchor-acd", required: false },
      artifact_dir: { type: "path-under-plansdir", required: false },
    },
    binaries: {
      external: ["git", "node"],
      scripts: {
        includeFilter: { anchor: "acd", rel: "bin/worktree-copy-include.js" },
        parseWorktrees: { anchor: "acd", rel: "bin/parse-worktrees" },
        writeNotes: { anchor: "acd", rel: "bin/worktree-write-notes.js" },
      },
    },
    envPassthrough: ["COPIED_JSON", "SIBLING_WORKTREES_JSON", "WORKTREE_BASE_DIR"],
    writeScopes: ["family-worktree", "plans-dir"],
    renderer: "status-triple",
  },

  "worktree-backup": {
    name: "worktree-backup",
    argSpec: [...STANDARD_ARG_SPEC],
    payloadSpec: {
      mode: { type: "enum:dry_run|execute", required: true },
      worktree_path: { type: "family-worktree", required: true },
      branch: { type: "branch", required: true },
      backup_dir: { type: "derived-backup-dir", required: false },
      docker_check: { type: "bool", required: false, default: true },
      session_id: { type: "session-id", required: false },
      artifact_dir: { type: "path-under-plansdir", required: false },
    },
    binaries: { external: ["git", "docker"], scripts: {} },
    envPassthrough: ["WORKTREE_BASE_DIR"],
    writeScopes: ["backup-dir", "plans-dir"],
    renderer: "status-triple-quoted",
  },

  "doc-append": {
    name: "doc-append",
    argSpec: [...STANDARD_ARG_SPEC],
    payloadSpec: {
      mode: { type: "enum:history|changelog|compose", required: true },
      cwd: { type: "family-worktree", required: true },
      category: { type: "text", required: false, max: 64 },
      subject: { type: "text", required: false, max: 300 },
      background: { type: "text", required: false },
      changes: { type: "text", required: false },
      commits: { type: "text", required: false, max: 2000 },
      test_gap: { type: "text", required: false },
      date: { type: "iso-date", required: false },
      notes_path: { type: "path-in-family", required: false },
      branch: { type: "branch", required: false },
      pr_number: { type: "text", required: false, max: 32 },
      merge_commit: { type: "text", required: false, max: 64 },
      pr_title: { type: "text", required: false, max: 300 },
      closes_issues_count: { type: "int", required: false, min: 0, max: 1000 },
      bootstrap: { type: "bool", required: false },
      session_id: { type: "session-id", required: false },
      artifact_dir: { type: "path-under-plansdir", required: false },
    },
    binaries: {
      external: ["uv", "bash"],
      scripts: {
        docAppend: { anchor: "acd", rel: "bin/doc-append.py" },
        composeEntry: { anchor: "acd", rel: "bin/compose-doc-append-entry" },
      },
    },
    envPassthrough: [],
    writeScopes: ["family-worktree", "plans-dir"],
    renderer: "status-triple-quoted",
  },

  "issue-reconcile": {
    name: "issue-reconcile",
    argSpec: [...STANDARD_ARG_SPEC],
    payloadSpec: {
      owner_repo: { type: "owner-repo", required: true },
      history_md_path: { type: "path-in-family", required: false },
      history_dir_path: { type: "path-in-family", required: false },
      limit: { type: "int", required: false, default: 1000, min: 1, max: 10000 },
      session_id: { type: "session-id", required: false },
      artifact_dir: { type: "path-under-plansdir", required: false },
    },
    binaries: { external: ["gh"], scripts: {} },
    // The only worker that talks to the GitHub API, and therefore the only one
    // whose children see a token.
    envPassthrough: ["GH_TOKEN", "GITHUB_TOKEN"],
    writeScopes: ["plans-dir"],
    renderer: "status-triple",
  },

  "session-close-gate": {
    name: "session-close-gate",
    argSpec: [...STANDARD_ARG_SPEC],
    payloadSpec: {
      session_id: { type: "session-id", required: true },
      plans_dir: { type: "path-under-plansdir", required: false },
      outcome_json_path: { type: "path-under-plansdir", required: false },
      artifact_dir: { type: "path-under-plansdir", required: false },
    },
    binaries: {
      external: ["node"],
      scripts: {
        report: { anchor: "acd", rel: "bin/supervisor-report" },
        writeAlert: { anchor: "acd", rel: "bin/supervisor-write-alert" },
        writeAudit: { anchor: "acd", rel: "bin/supervisor-write-audit" },
      },
    },
    envPassthrough: [],
    writeScopes: ["plans-dir"],
    renderer: "status-triple",
  },

  // -----------------------------------------------------------------------
  // Stage 3 (#1673): the three forge workers. Same declare-first rule as stage 2
  // — the capability surface is in force from the commit that declares it, and
  // the MODULES table in bin/worker-dispatch/registry.js decides which names have
  // an implementation yet.
  //
  // commit-push moves `git commit` / `git push` out of the Bash tool, which is
  // also where hooks/workflow-gate.js (a PreToolUse hook) used to see them. The
  // worker therefore drives that same gate as a child process, twice — once
  // before commit, once before push — and the five workflow env vars below are
  // what let the gate child resolve the SAME session state the hook would have.
  // Handing it the wrong state directory makes it approve everything, so the
  // worker sets all five explicitly via extraEnv rather than trusting
  // inheritance; declaring them here only makes that assignment legal.
  // -----------------------------------------------------------------------
  "commit-push": {
    name: "commit-push",
    argSpec: [...STANDARD_ARG_SPEC],
    payloadSpec: {
      commit_message: { type: "text", required: true, max: 8000 },
      branch: { type: "branch", required: true },
      // issue-ref[], not int[]: the values come from hooks/lib/parse-closes-issues.js,
      // the canonical `## Issues` parser, which returns { number, repo? } records —
      // and skills/commit-push/SKILL.md tells the caller to use exactly that parser.
      // An int[] schema made the documented call fail validation, and the obvious
      // workaround (map to bare numbers) silently dropped the repo half of each
      // issue's identity: two repositories' #42 became one `Closes #42`, applied by
      // GitHub to whichever repo the PR lives in. Every element becomes a closing
      // keyword and an `issue-close-pr-of` marker in a PR body GitHub acts on, so
      // the identity has to survive the boundary intact.
      closes_issues: { type: "issue-ref[]", required: false, default: [], maxItems: 32 },
      pr_body_template: { type: "text", required: false, max: 60000 },
      wip_mode: { type: "bool", required: false, default: false },
      enforce_worktree: { type: "enum:on|off", required: false, default: "on" },
      agents_config_dir: { type: "anchor-acd", required: false },
      artifact_dir: { type: "path-under-plansdir", required: false },
      // Deviation #3: the dispatcher can only accept a child cwd as a
      // family-validated explicit path.
      worktree_path: { type: "family-worktree", required: true },
      // Deviation #2: workflow-gate.js blocks a merge-shaped push outright when
      // it has no session id, so a missing value here is fail-closed by design.
      session_id: { type: "session-id", required: true },
    },
    binaries: {
      external: ["git", "gh", "bash", "node"],
      scripts: {
        unstagedCheck: { anchor: "acd", rel: "bin/check-unstaged-tracked.sh" },
        bootstrapProbe: { anchor: "acd", rel: "bin/probe-remote-bootstrap.sh" },
        isGithubRemote: { anchor: "acd", rel: "bin/is-github-dotcom-remote" },
        // The PR title and body used to reach GitHub through the Bash tool, where
        // hooks/scan-outbound.js (PreToolUse) read them first. A dispatched `gh`
        // child is not a Bash-tool command, so that hook no longer sees them and
        // the worker runs the same scanner itself before `gh pr create`.
        // acd for the same reason as workflowGate: the scanner that clears
        // outbound text must be the reviewed copy, not the branch's own.
        scanOutbound: { anchor: "acd", rel: "bin/scan-outbound.sh" },
        // acd, never family-worktree: the gate that authorizes a push must be
        // the reviewed, merged copy — not the one on the branch being pushed.
        workflowGate: { anchor: "acd", rel: "hooks/workflow-gate.js" },
      },
    },
    envPassthrough: [
      "GH_TOKEN",
      "GITHUB_TOKEN",
      "ENFORCE_WORKTREE",
      // The five the gate child needs to answer as the PreToolUse hook would:
      "CLAUDE_WORKFLOW_DIR",   // state-io's only state-directory variable
      "WORKFLOW_PLANS_DIR",    // detail-plan read for the scope-drift verdict
      "WORKFLOW_SESSION_ID",   // supervisor-state resolution fallback
      "CLAUDE_PROJECT_DIR",    // getCurrentContext()'s cwd resolution
      "DEFAULT_BRANCHES",      // merge-detect.js's protected-branch set
    ],
    writeScopes: ["family-worktree", "plans-dir"],
    renderer: "status-triple-quoted",
  },

  // -----------------------------------------------------------------------
  // ISSUE_CLOSE_SKILL contract (applies to both close-family entries below).
  //
  // hooks/enforce-issue-close.js inspects the HEAD of a Bash-tool command only.
  // A child process the dispatcher starts with spawnSync is not a command head,
  // so it was never in that hook's field of view — this is a structural fact,
  // not a new bypass.
  //
  // skills/issue-close-stage/scripts/run-stage-chain.sh and
  // skills/issue-close-finalize/scripts/run-finalize-terminal.sh each
  // `export ISSUE_CLOSE_SKILL=1` for themselves. The dispatcher therefore does
  // NOT need it in envPassthrough — and MUST NOT add it: passing it here would
  // hand the bypass to every child of these workers rather than to the two
  // scripts that opt into it. tests/feature-1673-{issue-close-stage,finalize}-
  // *-schema.sh assert its absence structurally.
  // -----------------------------------------------------------------------
  "issue-close-stage": {
    name: "issue-close-stage",
    argSpec: [...STANDARD_ARG_SPEC],
    payloadSpec: {
      issue_number: { type: "int", required: true, min: 1 },
      worktree_path: { type: "family-worktree", required: true },
      owner_repo: { type: "owner-repo", required: true },
      // Echo-only: accepted for readability, but only as the exact resolved ACD.
      agents_config_dir: { type: "anchor-acd", required: false },
      artifact_dir: { type: "path-under-plansdir", required: false },
      // repo-ref, not owner-repo: the stage chain's cross-repo argument keeps the
      // documented `<owner/repo>` OR bare `<repo>` form.
      issue_repo: { type: "repo-ref", required: false },
    },
    binaries: {
      external: ["bash", "gh"],
      scripts: {
        stageChain: { anchor: "acd", rel: "skills/issue-close-stage/scripts/run-stage-chain.sh" },
      },
    },
    envPassthrough: ["GH_TOKEN", "GITHUB_TOKEN"],
    writeScopes: ["plans-dir"],
    renderer: "status-triple-quoted",
  },

  // The payloadSpec is FLAT because capability.js has no notion of "required only
  // when phase=X". The per-phase required-field table lives in the worker
  // module's checkRequired (doc-append's mode check is the precedent):
  //   initial          issue_number, root_issue_number, owner_repo,
  //                    state_file_path, main_worktree_path
  //   loop_step        root_issue_number, owner_repo, state_file_path, g5_decision
  //   finalize_terminal root_issue_number, owner_repo, state_file_path,
  //                    session_id, outcome_file_path
  //
  // `merge_commit` is deliberately NOT a field: it comes out of run-initial.sh's
  // stdout and the worker writes it into the state file. It is never an input.
  "issue-close-finalize": {
    name: "issue-close-finalize",
    argSpec: [...STANDARD_ARG_SPEC],
    payloadSpec: {
      phase: { type: "enum:initial|loop_step|finalize_terminal", required: true },
      issue_number: { type: "int", required: false, min: 1 },
      root_issue_number: { type: "int", required: false, min: 1 },
      owner_repo: { type: "owner-repo", required: false },
      // Field-validation order matters for this type — see the note on
      // `state-file-for-session` in bin/worker-dispatch/capability.js.
      state_file_path: { type: "state-file-for-session", required: false },
      main_worktree_path: { type: "anchor-main-root", required: false },
      issue_repo: { type: "repo-ref", required: false },
      g5_decision: {
        type: "enum:accept|decline|llm_declined|recurse_done",
        required: false,
      },
      session_id: { type: "session-id", required: false },
      outcome_file_path: { type: "path-under-plansdir", required: false },
      agents_config_dir: { type: "anchor-acd", required: false },
      finalize_scripts_dir: { type: "derived-finalize-scripts-dir", required: false },
      artifact_dir: { type: "path-under-plansdir", required: false },
    },
    binaries: {
      external: ["bash", "node", "gh"],
      scripts: {
        runInitial: { anchor: "acd", rel: "skills/issue-close-finalize/scripts/run-initial.sh" },
        runLoopStep: { anchor: "acd", rel: "skills/issue-close-finalize/scripts/run-loop-step.js" },
        runTerminal: {
          anchor: "acd",
          rel: "skills/issue-close-finalize/scripts/run-finalize-terminal.sh",
        },
      },
    },
    // Both non-token names are derived from anchors and set explicitly via
    // extraEnv; declaring them here only makes that assignment legal.
    envPassthrough: ["GH_TOKEN", "GITHUB_TOKEN", "FINALIZE_SCRIPTS_DIR", "MAIN_WORKTREE_PATH"],
    writeScopes: ["plans-dir"],
    renderer: "status-triple-quoted",
  },
};

module.exports = {
  WORKER_NAMES,
  workers,
  EXTERNAL_COMMANDS,
  CHILD_ENV_ALLOWLIST,
  WRITE_SCOPES,
  SCRIPT_ANCHORS,
  STANDARD_ARG_SPEC,
};
