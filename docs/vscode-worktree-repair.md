# VS Code Worktree Repair

## Worktree session visibility

The `anthropic.claude-code` VS Code extension hardcodes `includeWorktrees:!1` in its
session-list call, so sessions whose cwd is inside a linked git worktree never appear in
the extension's session list — and every extension auto-upgrade overwrites a manual fix.

Run `bin/vscode-cc-repair/index.js` to re-apply the patch:

```sh
node bin/vscode-cc-repair/index.js           # apply for real (writes to disk)
node bin/vscode-cc-repair/index.js --dry-run # report without writing
```

The tool classifies each installed bundle and refuses rather than guessing when it sees a
shape it does not recognize. It writes `extension.js.bak` only when that file is absent —
a `.bak` left by an earlier run or an older version is preserved as-is, never refreshed.

Patching the on-disk bundle does not touch the running extension host. After a successful
patch, run VS Code's **Developer: Reload Window** before worktree sessions become visible.

## Stub session cleanup

`codes` runs stub session cleanup automatically after each session push. To run it manually:

```sh
node bin/vscode-cc-repair/index.js --prune-stub-sessions --dry-run  # preview
node bin/vscode-cc-repair/index.js --prune-stub-sessions            # apply
```

A stub is removed only when another copy of the same session carries a real transcript
record for it; anything else is reported and kept. Removed stubs are renamed to
`<uuid>.jsonl.bak` (never deleted outright), so they can be recovered by dropping the suffix.

`--prune-stub-sessions` is **destructive by default** — always run `--dry-run` first.
