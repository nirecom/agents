"use strict";
// hooks/lib/worker-dispatch-registry.js — SSOT (PURE DATA) for the plain-script worker dispatcher (#1643).
// Consumed by: hooks/enforce-worktree/main-worktree-allows/* (worker-name enum only) and bin/worker-dispatch/* (full spec).
// HARD INVARIANT: zero deps, not even a node builtin — must load before bin/worker-dispatch/ exists;
// tests/feature-1643-worker-dispatch-schema.sh asserts this by source scan.
// Entry shape: name / argSpec (per-worker, not shared by reference, so #1673's close-family can diverge) /
// payloadSpec (field -> capability type, see bin/worker-dispatch/capability.js) / binaries / writeScopes / renderer.
// renderer: status-triple | status-triple-quoted | test-runner-yaml — quoting is inherited from the
// agents/*.md workers this replaces and is parsed by callers; do not "normalize" it.

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
// Credentials are NOT here either. GH_TOKEN / GITHUB_TOKEN are declared per worker
// by each entry that authenticates against GitHub (issue-reconcile, commit-push,
// issue-close-stage, issue-close-finalize). A global entry would hand them to every
// worker's children — including, via the family-worktree script anchor, code from
// the branch under review, which no one has read yet.
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
  // --- Config-location vars --- admission requires BOTH: (1) var names WHERE a tool
  // reads its config, (2) that config is ALREADY reachable via a member admitted earlier.
  // XDG_CONFIG_HOME/APPDATA qualify; GIT_CONFIG_GLOBAL/SYSTEM and SSH_AUTH_SOCK (a live
  // signing oracle) do not — secrets go into the envPassthrough of the worker that needs
  // them, not here. Values are copied verbatim into a child with a different cwd, so a
  // RELATIVE value resolves elsewhere — callers must use absolute paths. Fenced in three
  // layers (structural: tests/feature-1643-worker-dispatch-schema.sh Group E; behavioural:
  // tests/feature-1643-worker-dispatch-script-anchor.sh Group G; real gh:
  // tests/TL3-worker-dispatch-child-env-gh-auth.sh) — add a member here => also add it to
  // CONFIG_PATH_VARS in the first two.

  // Windows gh CLI needs APPDATA to locate its config dir (hosts.yml) even when
  // the OAuth token itself lives in the OS keyring rather than GH_TOKEN.
  "APPDATA",
  // Windows OpenSSH.exe expands %ProgramData% internally for its default
  // ssh_known_hosts2 path; without it the native client exits 255 with no
  // output before attempting host-key or key auth, so git push/fetch over
  // ssh fails as "Could not read from remote repository" for every worker.
  "ProgramData",
  "PROGRAMDATA",
  // gh resolves its config dir in a fixed order: GH_CONFIG_DIR, then
  // XDG_CONFIG_HOME (<val>/gh, every OS), then APPDATA (<val>/GitHub CLI,
  // Windows). A parent that moved gh's config with either of the two
  // higher-priority vars and a child that inherits only APPDATA do not read the
  // same hosts.yml: the child silently lands in a different config dir and fails
  // auth exactly the way the missing APPDATA did. XDG_CONFIG_HOME is not
  // gh-specific — passing it also makes a child's git/uv read the same XDG tree
  // the parent does, which is the faithful behaviour, not a widening.
  // Both name a directory, never a secret, so they belong here rather than in
  // one worker's envPassthrough.
  "XDG_CONFIG_HOME",
  "GH_CONFIG_DIR",
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
      // Validated scalar becomes argv, never caller text. No default — omitted,
      // the suite's own `-j auto` applies.
      jobs: { type: "int", required: false, min: 1, max: 1024 },
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

  // Stage 3 (#1673): the three forge workers, same declare-first rule as stage 2 — the
  // capability surface is in force from the commit that declares it, ahead of MODULES
  // in bin/worker-dispatch/registry.js gaining an implementation. commit-push moves
  // `git commit`/`git push` out of the Bash tool (where hooks/workflow-gate.js used to
  // see them) and drives that same gate as a child process twice — before commit and
  // before push. The five workflow env vars below let the gate child resolve the SAME
  // session state the hook would have; the wrong state directory makes it approve
  // everything, so the worker sets all five explicitly via extraEnv rather than
  // trusting inheritance — declaring them here only makes that assignment legal.
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

  // ISSUE_CLOSE_SKILL contract (applies to both close-family entries below):
  // hooks/enforce-issue-close.js inspects the HEAD of a Bash-tool command only, and a
  // child process the dispatcher starts with spawnSync is not a command head — never in
  // that hook's field of view, a structural fact rather than a new bypass. skills/issue-
  // close-stage/scripts/run-stage-chain.sh and skills/issue-close-finalize/scripts/run-
  // finalize-terminal.sh each `export ISSUE_CLOSE_SKILL=1` for themselves, so the
  // dispatcher must NOT add it to envPassthrough — that would hand the bypass to every
  // child of these workers rather than the two scripts that opt into it.
  // tests/feature-1673-{issue-close-stage,finalize}-*-schema.sh assert its absence.
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
      external: ["bash", "gh", "git"],
      scripts: {
        stageChain: { anchor: "acd", rel: "skills/issue-close-stage/scripts/run-stage-chain.sh" },
      },
    },
    envPassthrough: ["GH_TOKEN", "GITHUB_TOKEN"],
    writeScopes: ["plans-dir"],
    renderer: "status-triple-quoted",
  },

  // payloadSpec is FLAT — capability.js has no "required only when phase=X" notion, so
  // the per-phase required-field table lives in the worker module's checkRequired
  // (doc-append's mode check is the precedent): initial needs issue_number,
  // root_issue_number, owner_repo, state_file_path, main_worktree_path; loop_step needs
  // root_issue_number, owner_repo, state_file_path, g5_decision; finalize_terminal needs
  // root_issue_number, owner_repo, state_file_path, session_id, outcome_file_path.
  // `merge_commit` is deliberately NOT a field: it comes out of run-initial.sh's stdout
  // and the worker writes it into the state file — never an input.
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
