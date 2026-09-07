# Comment-Block Size Gate

A long run of comment lines is easy to add and hard to notice in review, so it
is blocked at two points: an `Edit`/`Write`/`MultiEdit` that grows a comment block past the
threshold is rejected before it lands, and `git commit` blocks as a backstop for anything
that reaches the staging area another way.

A blank line or a lone no-op token (`;`, `:`, `{}`, `()`, `,`) bridges a comment block rather
than splitting it, so inserting one does not reset the count. A staged file is compared
against its committed version and flagged only when its comment blocks got longer, so an
already-long block never blocks an unrelated edit; a file with no committed version is
judged on its own contents. Neither check rewrites a file, and both fire only for this
repository even though the hook paths are configured globally.

Run `bin/review-comment-block-size --all` for the same report over the whole working tree.

Set `COMMENT_BLOCK_MAX_LINES` (default 10) to tune the threshold or `COMMENT_BLOCK_ENFORCE=off`
to disable the gate — see `.env.example`. Both settings are read only from the repository's
own `.env`; an ambient shell variable of the same name cannot raise the threshold or turn the
gate off, and neither `WORKFLOW_OFF` nor `WORKTREE_OFF` suspends it (see
[marker-bypass-contract.md](marker-bypass-contract.md)).
