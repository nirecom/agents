# VS Code Worktree Repair

## Worktree session visibility

The `anthropic.claude-code` VS Code extension hardcodes `includeWorktrees:!1` in its
session-list call, so sessions whose cwd is inside a linked git worktree never appear in
the extension's session list — and every extension auto-upgrade overwrites a manual fix.

Launching VS Code with `codes` re-applies the patch automatically (`--prune-stub-sessions`,
best-effort; see `bin/codes-launch.sh` / `bin/codes-launch.ps1`). To run it by hand, use `bin/vscode-cc-repair/index.js`:

```sh
node bin/vscode-cc-repair/index.js           # apply for real (writes to disk)
node bin/vscode-cc-repair/index.js --dry-run # report without writing
```

The tool classifies each installed bundle and refuses rather than guessing when it sees a
shape it does not recognize. It writes `extension.js.bak` only when that file is absent —
a `.bak` left by an earlier run or an older version is preserved as-is, never refreshed.

### Patch site and refusal rules

The site is located by the `sessionListOptions(){return{` anchor. Only the single
`includeWorktrees:` directly in that object literal (depth 1) is flipped `!1` to `!0`; other
sites, such as the `includeWorktrees:!1` in `resolveSession` (2.1.300), are left alone.

| Situation | Result |
|-----------|--------|
| No anchor, but an `includeWorktrees` literal exists | refused, `reason=no-anchor` |
| No anchor and no literal | `absent` |
| More than one anchor | refused, `reason=multiple-anchors` |
| Anchor without the key | refused `reason=no-anchor-key` (`absent` when no literal exists) |
| Anchor not preceded by `{ } , ;` (or file start), method body not closed by `}` followed by `} , ;`, an identifier start, or file end, literal unscannable, or key not unique at depth 1 | refused, `reason=ambiguous-anchor` |

`--legacy-single-literal` opts into the pre-#2683 rule (exactly one boolean literal anywhere
in the bundle). It is an unsupported fallback, not the default, and applies consistently to the
initial classification, the race re-check, and the post-write verify.

Each per-directory report line carries ` anchor=<n> anchor-value=<v>` after `key=`, where
`<v>` is one of `falsy`, `truthy`, `dynamic`, `unsupported`, `unknown`, `none`, `ambiguous`,
or `-`. An unreadable extension root is reported as `failed  <root>  reason=root-unreadable`;
a candidate root counts as absent only on `ENOENT`/`ENOTDIR`, so any other stat error keeps it
and ends `failed` or refused instead of being skipped silently.

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

The prune is gated on the patch: when any extension directory ends `refused` or `failed`
(including an unreadable root), the prune pass is skipped even with `--dry-run`, the report
says `prune-skipped: the extension patch refused or failed — stub sessions left in place`, and
the exit code is 1. `absent` and `already` directories do not stop the prune.

`--prune-stub-sessions` is **destructive by default** — always run `--dry-run` first.
