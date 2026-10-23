"use strict";
// hooks/bash-guard/git-deviant/forms.js — the git-deviant form registry (#2617), the SSOT for
// its reason codes and guidance. The guidance is fixed text: a deny never quotes the command
// back, since a branch or path argument can carry anything.

const pushGuidance = (formId) =>
  `Blocked for security reasons: deviant git push form (${formId}). ` +
  "Switch to `git push -u origin HEAD` for an ordinary push. When history must be replaced, " +
  "use the explicit lease `git push --force-with-lease=<branch>:<sha> origin <branch>`, " +
  "taking <sha> with `git rev-parse origin/<branch>` right before the push.";

const form = (code, message) => Object.freeze({ code, message });

const GIT_DEVIANT_FORMS = Object.freeze({
  "push-force": form("BG-GIT-PUSH-FORCE", pushGuidance("push-force")),
  "push-plus-refspec": form("BG-GIT-PUSH-PLUS-REFSPEC", pushGuidance("push-plus-refspec")),
  "push-delete": form("BG-GIT-PUSH-DELETE", pushGuidance("push-delete")),
  "push-matching-refspec": form("BG-GIT-PUSH-MATCHING-REFSPEC", pushGuidance("push-matching-refspec")),
  "push-mirror": form("BG-GIT-PUSH-MIRROR", pushGuidance("push-mirror")),
  "push-lease-implicit": form(
    "BG-GIT-PUSH-LEASE-IMPLICIT",
    "Blocked for security reasons: implicit --force-with-lease (push-lease-implicit). " +
      "The lease must name the expected remote tip explicitly as <branch>:<40-hex sha>: " +
      "`git push --force-with-lease=<branch>:<sha> origin <branch>`, taking <sha> with " +
      "`git rev-parse origin/<branch>` right before the push."
  ),
  "worktree-remove-force": form(
    "BG-GIT-WORKTREE-REMOVE-FORCE",
    "Blocked for security reasons: forced git worktree remove (worktree-remove-force). " +
      "Remove the worktree without the force flag; when git refuses, use /sweep-worktrees."
  ),
  "clean-force": form(
    "BG-GIT-CLEAN-FORCE",
    "Blocked for security reasons: forced git clean (clean-force). " +
      "List the candidates with `git clean -n` first, then delete the listed paths explicitly."
  ),
});

module.exports = { GIT_DEVIANT_FORMS };
