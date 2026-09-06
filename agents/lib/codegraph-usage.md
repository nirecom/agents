# CodeGraph usage policy

Shared by every agent whose `tools:` list carries `mcp__codegraph__codegraph_explore`.

## What it is

A Read-equivalent lookup over a pre-built index of the repository. One call returns the
verbatim, line-numbered source of the symbols it matched, the call paths between them,
and a summary of what depends on them.

## When to reach for it

Once before a Read/Grep sweep of unfamiliar code, to locate the symbols worth opening.
Once again before concluding, to check the blast radius of the code you are about to
change or review. Two calls answer most questions that would otherwise cost a dozen
Grep rounds.

## Always pass projectPath — the repo root holding the code under work

This is the parameter that decides which copy of the code you are told about. During
implementation that root is the linked worktree, never the main checkout. Pointing it at
main neither fails nor warns: the call succeeds silently and hands back main's source,
so a plan or a review built on it describes a branch nobody is working on.

## When the tool or the index is absent

The flag is off by default, so absence is normal rather than an error. A missing tool, a
missing index, or a result you cannot obtain means fall back to Read and Grep and carry
on — never block, never retry, never report it as a failure.

## Evidence discipline

Trust the source codegraph actually returned — don't re-verify it with grep.
Read a file when the response flags it — a staleness banner naming it, a "⚠ changed on disk after the last index sync" flag, or the rarer auto-sync-disabled banner, which freezes the whole index — and equally when the response never handed you its source: a pointer-only entry (path, symbol, line, no body), a section the response says it trimmed, or anything left unanswered once the explore budget ran out.
A file whose verbatim source came back unflagged is fresh — treat it as already Read.
