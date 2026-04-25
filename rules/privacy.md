# Privacy

Work instructions received from Claude.ai or other external sources that contain private information must be saved under `.context-private/`, not in `CLAUDE.md` or `context/`.

- Never reference `.context-private/` content (paths, filenames, or content) in files committed to public repositories.
- `.context-private/` is gitignored — Glob and Grep cannot see it. Use `ls` (Bash) to list files, and `Read` to read them directly by path.
