# Project-Local Env Overrides

Why a second config layer exists, whose word it takes, and what it refuses.

## The problem it solves

Review-series codex prompts need the non-functional requirements of the project
being reviewed — its latency budget, its compatibility floor, the conventions a
reviewer would otherwise flag as violations. No single value in the operator's
global config can carry that: the requirement belongs to the repository under
review, and the reviewer visits many. `PROJECT_NFR` is therefore read from the
reviewed project's own root, not from the machine's config (#2223).

## The two layers

| Layer | File | Authored by | Trust |
|---|---|---|---|
| Global | `<AGENTS_CONFIG_DIR>/.env` | the operator of this machine | trusted |
| Local | `<reviewed project>/.env.local` | whoever wrote that repository | untrusted |

The local layer is untrusted on purpose. A reviewed project may be a third-party
clone, and nothing stops such a repository from committing an override file — so
the layer is designed for the case where the file is hostile, not merely
unfamiliar. It is not a general-purpose config surface.

`hooks/lib/local-env.js` is the pure resolver (blocklist plus `overlay()`);
`hooks/lib/load-env.js` wires it into `process.env` and into the
`readEffectiveEnvFile` read door. `hooks/lib/load-env.sh` deliberately has no
local layer at all — see "half-applied" below.

## Why a blocklist, not an allowlist

Everything the local file sets applies, except what the blocklist refuses.

An allowlist was the first design and was abandoned. It has to enumerate every
key a project might legitimately want before any project wants it, and the whole
premise of the feature is that projects differ — so the list would have grown
with every new use, and each growth would have been a change to this repository
made on behalf of a repository it does not own.

This diverges from the `.private-info-blocklist` / `.private-info-allowlist`
pair, which keeps both halves. The divergence is a consciously accepted
trade-off (CPR-ORTH), not an oversight: that pair filters outbound text the
operator authored, where an allowlist is a narrowing of the operator's own
material. Here the allowlist would be a standing promise about input this
repository does not write.

## What the blocklist refuses, and why

`ENV_ENTRY_BLOCKLIST_EXACT` and `ENV_ENTRY_BLOCKLIST_PREFIX` in
`hooks/lib/local-env.js` are the list itself; the per-key rationale lives beside
each entry there. Two criteria put a key on it:

1. **One machine, one policy.** Settings whose per-repository divergence breaks
   a contract this repository owns — the workflow-state root
   (`CLAUDE_WORKFLOW_DIR`, `WORKFLOW_PLANS_DIR`), the config directory this very
   layer resolves the global `.env` from (`AGENTS_CONFIG_DIR`), the worktree
   enforcement switches.
2. **Half-applied.** Keys whose consumers do not all read the same layer.
   `hooks/pre-commit` reads `ENFORCE_WORKTREE` through `load-env.sh`, which has
   no local overlay, while the Node reader of the same name does — a local
   override would silence one guard and leave its sibling armed. A split-brain
   guard is worse than either answer, so the local value is refused outright.

The `CODEX_` prefix is on the list for a reason worth naming: it covers
`CODEX_NFR_MAX_LINES` and `CODEX_NFR_MAX_BYTES`, the size caps on the very
`PROJECT_NFR` text the project supplies. A project that could raise its own cap
would have no cap.

Matching is case-folded to upper case. Windows environment variables are
case-insensitive, so a lower-cased key in the local file names the same slot as
its canonical spelling and must not slip past a same-cased check.
`isBlocklisted()` fails closed: a non-string or empty key is refused.

## The ordering guard

`applyLocalOverlayToProcessEnv` never overwrites a key that was already truthy
in `process.env` when loading began. The snapshot it compares against is taken
*before* the global layer is injected, so a local value outranks the global
`.env` — that is the point of the feature — while a value the caller actually
exported outranks both.

## Known limit

The blocklist's input domain is the local file's key space, not the global
`.env`'s. Entries were triaged against the keys `.env.example` documents, but a
key documented nowhere still reaches `process.env` from the local layer.
Process-runtime variables (`NODE_OPTIONS`, `BASH_ENV`, `LD_PRELOAD`,
`GIT_SSH_COMMAND`) and guard-decision tokens sit on that axis. That is a
security question about the layer's input domain rather than the
"does the agents repo's own contract survive" question this list was selected
for, and it is tracked separately (CPR-SC) — see issue #2223's discussion.

## Inspecting the layer

`bin/show-local-env-overrides [--repo-root <path>]` prints which keys the local
file got applied and which the blocklist refused. Key **names** only: the global
map may hold secrets and the local file comes from a directory this machine did
not necessarily author. Value printing is a separate door,
`bin/env-effective-kv`, which gates whole-map output behind `--allow-dump` for
exactly that reason.

It also warns, on stderr, when the inspected project tracks its own override
file in git — such a file arrives with every clone, which is precisely the case
the trust model above is written against. The runtime resolver deliberately does
not ask: every hook passes through it, and it must not spawn git. An on-demand
diagnostic can afford the one call, so that is where the question is asked.

Each project using this layer should therefore add the override file to its own
`.gitignore`, and to its `.worktreeinclude` when it uses one. In this repository
both are already done, so a linked worktree inherits the operator's own copy
rather than starting without one.
