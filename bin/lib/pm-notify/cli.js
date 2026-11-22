"use strict";
// bin/pm-notify (#2942): the notification-point layer between workflow sessions and their PM.
//   record --point <p> --issue <ref>             keep a pending notification          (record.js)
//   next                                         hand out the next one to send         (next.js)
//   settle --id <id> --result ack|timeout|offline                                     (settle.js)
//   close                                        last resync at session-close          (close.js)
//   inbox --pm [--budget-ms <n>]                 the PM's mailbox, drift, meta detach  (inbox.js)
//   check-header --tag <t> --pm-issues <l> [--closes <l>]  CP-1b check of a role=pm header (check-header.js)
//   detach --issue <ref> --phase before|after    owner record around a dispatch       (detach.js)
// Output: KEY=VALUE lines (and SEND) on stdout; a refusal adds REASON= (and NEW_TAG=) there, its text on stderr.
// Exit 0 on success, 1 on a refusal, 2 on a malformed request.

const C = require("./common");

const VERBS = {
  record: () => require("./record").record,
  next: () => require("./next").next,
  settle: () => require("./settle").settle,
  close: () => require("./close").close,
  inbox: () => require("./inbox").inbox,
  "check-header": () => require("./check-header").checkHeader,
  detach: () => require("./detach").detach,
};

function main(argv, deps) {
  const d = deps || {};
  const out = d.out || ((s) => process.stdout.write(s));
  const err = d.err || ((s) => process.stderr.write(s));
  const print = (lines) => { if (lines.length > 0) out(`${lines.join("\n")}\n`); };
  try {
    const verb = Object.prototype.hasOwnProperty.call(VERBS, argv[0]) ? VERBS[argv[0]]() : null;
    if (!verb) C.fail(2, `usage: pm-notify ${Object.keys(VERBS).join("|")} …`, ["REASON=usage"]);
    print(verb(argv.slice(1)));
    return 0;
  } catch (e) {
    if (!(e instanceof C.Exit)) { err(`pm-notify: ${e.message}\n`); return 1; }
    print(e.lines);
    err(`pm-notify: ${e.message}\n`);
    return e.code;
  }
}

module.exports = { main };
