# File Investigation

## Progressive Disclosure

When researching why something is designed a certain way, follow this order
and stop as soon as the answer is clear:

1. **Read current files** — Read/Grep/Glob the relevant files first.
2. **git log** — If current state doesn't explain the why, check commit history.
3. **history.md** — If git log is insufficient, grep `docs/history.md` for keywords
   then read the surrounding context.
4. **history/ archives** — If history.md doesn't cover it (entry was rotated out),
   check `docs/history/index.md` then read the specific archive file.

Grep for keywords before reading full files to avoid loading unnecessary context.
