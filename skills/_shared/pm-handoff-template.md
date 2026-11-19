# PM Handoff Template

The handoff a PM session hands to its session-downstream through `/resume-session --from <full session id>`.
The typed `/resume-session --from` lets the hook copy the PM tag, the assigned list, the theme and the issue sequence table; read them with `node "$AGENTS_MAIN_ROOT/bin/pm-state" show --session <sid>`.
Carry the conversation context only; never write the assigned list or the issue sequence table into the handoff, because the PM state owns both.

## Sections

Fill each section in a few lines; write `none` when empty.

- `Consultation` — what the user and the PM are still deciding: an open theme, candidate issues not yet added with `/pm-add`.
- `Instructions in flight` — messages sent to a workflow session whose ack or answer is still awaited: the destination session id and the `msg-id`.
- `User decisions` — decisions the user made in conversation that no artifact records yet, such as an order the user asked for.
- `Open questions` — questions carried forward to the session-downstream.
