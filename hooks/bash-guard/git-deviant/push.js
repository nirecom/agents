"use strict";
// hooks/bash-guard/git-deviant/push.js — `git push` argv -> git-deviant form id, or null.
//
// With `--repo` the remote comes from the option and every positional is a refspec; without
// it the first positional is the remote. Only the explicit lease `<ref>:<40 lowercase hex>`
// passes, and a valid lease never masks another deviant argument in the same push.

const { scanOptions, hasLong } = require("./options");

const PUSH_SPEC = Object.freeze({
  shortWithValue: new Set(["o"]),
  longWithValue: new Set(["push-option", "repo", "receive-pack", "exec"]),
  longNames: [
    "all", "branches", "mirror", "delete", "tags", "dry-run", "porcelain",
    "force", "no-force", "force-with-lease", "no-force-with-lease",
    "force-if-includes", "no-force-if-includes", "repo", "set-upstream",
    "thin", "no-thin", "quiet", "verbose", "progress", "no-progress",
    "recurse-submodules", "no-recurse-submodules", "verify", "no-verify",
    "follow-tags", "no-follow-tags", "signed", "no-signed", "atomic", "no-atomic",
    "push-option", "receive-pack", "exec", "prune", "no-prune", "ipv4", "ipv6",
  ],
});

const EXPLICIT_LEASE_RE = /^[^:]+:[0-9a-f]{40}$/;

function refspecForm(refspec) {
  if (refspec.startsWith("+")) return "push-plus-refspec";
  if (refspec === ":") return "push-matching-refspec";
  if (refspec.startsWith(":")) return "push-delete";
  return null;
}

/** @param {string[]} args the argv after `push` @returns {string|null} a forms.js id */
function judgePush(args) {
  const scan = scanOptions(args, PUSH_SPEC);
  if (scan.shortFlags.has("f") || hasLong(scan, "force")) return "push-force";
  if (hasLong(scan, "mirror")) return "push-mirror";
  if (scan.shortFlags.has("d") || hasLong(scan, "delete") || hasLong(scan, "prune")) return "push-delete";

  const refspecs = hasLong(scan, "repo") ? scan.positionals : scan.positionals.slice(1);
  for (const refspec of refspecs) {
    const formId = refspecForm(refspec);
    if (formId) return formId;
  }

  const implicitLease = scan.longFlags.some(
    (f) => f.name === "force-with-lease" && !EXPLICIT_LEASE_RE.test(f.value === undefined ? "" : f.value)
  );
  return implicitLease ? "push-lease-implicit" : null;
}

module.exports = { judgePush };
