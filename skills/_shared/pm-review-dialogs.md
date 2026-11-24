# PM review dialogs

The user dialogs of `skills/_shared/pm-pre-pr-contact.md` `## Review request`; each ID is classified in `hooks/lib/askuser-dialog-levels.json`.

- RR-4, second "no answer": AskUserQuestion (`metadata.source=pm-review.no-answer`) with the two choices RR-4 lists.
- RR-6, round cap reached: AskUserQuestion (`metadata.source=pm-review.cap-reached`) with the last findings and the two choices RR-6 lists.
- `/get-release-approval` GA-1 PM review, the forge did not confirm the PR the last request named: AskUserQuestion (`metadata.source=pm-review.pr-unconfirmed`); `hooks/workflow-gate/user-verified-pm-review.js` prints the choices.
