<!--
Template for the user-local instruction channel.

To use it, copy this file and save the copy as user-instructions.md in the same
directory (the agents checkout root). user-instructions.md is gitignored, so it
stays on your machine.

The content of user-instructions.md is injected into the SessionStart context and
the post-compaction context, under the [user-instructions] header line. The
injected text is capped at 4096 bytes (UTF-8); anything longer is truncated and
marked.

HTML comment parts (like this block) are not injected: they are removed before
the cap is applied, and an unclosed comment opener drops everything after it.
A verbatim copy of this file therefore injects nothing. Write your instructions
outside the comment.
-->
