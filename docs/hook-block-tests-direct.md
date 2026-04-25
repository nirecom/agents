# hook: block-tests-direct.js

PreToolUse hook that blocks direct writes to `tests/` directories from the main
conversation, enforcing the "write tests via `/write-tests`" rule mechanically.

## Purpose

The `test.md` rule "Do not write or edit test files directly in the main
conversation" is probabilistically violated by the model. This hook makes the
wrong path harder by returning `deny` for any `Write`, `Edit`, or `MultiEdit`
targeting a `tests/` path when the workflow `write_tests` step is still
`pending` and the call does not originate from a subagent.

This is a **quality nudge, not a security boundary**. The hook is fail-open:
any error path (missing state, corrupt JSON, no session, etc.) approves rather
than blocks.

## Behavior

| Condition | Decision |
|---|---|
| tool_name not in {Write, Edit, MultiEdit} | approve |
| file_path has no `tests/` directory component | approve |
| session_id unresolvable (no CLAUDE_ENV_FILE) | approve (fail-open) |
| workflow state missing or unreadable | approve (fail-open) |
| `steps.write_tests` key absent | approve (fail-open) |
| `write_tests.status` != "pending" (in_progress / complete / skipped) | approve |
| `agent_id` field present and non-empty | approve (subagent write) |
| All of the above conditions unmet | **block** with remediation message |

## Path matching

Uses **any-component** matching: any directory component (not the final
filename) in the normalized path must match one of the monitored names.

Examples:
- `tests/foo.sh` → block (starts with `tests/`)
- `foo/tests/bar.sh` → block (mid-path `tests/`)
- `integration-tests/foo.sh` → approve (`integration-tests` ≠ `tests`)
- `tests/` → approve (no filename component, length < 2 after split)

## Configuration

`CLAUDE_BLOCK_TESTS_DIR_NAMES` (env var, comma-separated): override the default
monitored directory names. Default: `tests`.

Example (project `.claude/settings.json`):
```json
{ "env": { "CLAUDE_BLOCK_TESTS_DIR_NAMES": "tests,spec,__tests__" } }
```

When set, only the names in this list are monitored. Setting it to `spec`
means `tests/` is no longer blocked.

## Known limitations

- Symlink and junction evasion: `fs.realpathSync` is not used. A symlink
  pointing into `tests/` from outside will not be detected.
- State inheritance: if a previous task left `write_tests=complete` on the
  same branch, the new session inherits that state and the hook approves.
- Echo spoofing: the main conversation can emit MARK_STEP sentinels to advance
  state. This hook does not prevent that path.

Both limitations are acceptable for a quality-nudge tool.

## Verified behavior (empirical)

Tested with Claude Code version: `claude-sonnet-4-6` (2026-04-21)

| Check | Result |
|---|---|
| `agent_id` in main conversation PreToolUse stdin | `(not present)` |
| `agent_id` in subagent (general-purpose) PreToolUse stdin | `af2dcae3964f1b2f8` |
| `agent_type` in subagent | `general-purpose` |
| Hook `deny` overrides `Write(**/tests/**)` allow rule | Yes — Write was blocked |

Conclusion: `agent_id` reliably distinguishes main from subagent in this
version. If Claude Code is upgraded, re-run the landing gate stub
(`block-tests-direct-stub.js`) to re-verify.
