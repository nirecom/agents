# Summarize an upstream transcript tail

Subagent brief used by `/resume-session` Step 4 when `transcript_tail.available` is `true`.

The CLI never reads the tail into this conversation — it writes a capped file and returns only the path, so the raw transcript stays out of the resuming session's context. Launch a `general-purpose` subagent with the brief below, substituting `<path>` with `transcript_tail.path`.

## Brief

Read `<path>`. It holds the last turns of an interrupted Claude Code session, one JSON object per line; the first line may be truncated — skip it if it does not parse.

Report, in at most 15 lines:

- What the session was working on, in one sentence.
- The last action it completed.
- Anything it recorded as blocked, deferred, or worked around.
- Any file paths, issue numbers, or branch names it named as still open.

Quote nothing verbatim beyond identifiers. Do not speculate about what should happen next.
