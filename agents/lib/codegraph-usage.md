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

Output from this tool is a lead, not evidence. Any agent recording a file:line in an
artifact must re-open that location with Read and confirm the line before citing it —
the index can lag the working tree by a write or two.
