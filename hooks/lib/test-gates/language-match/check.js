"use strict";
// One test file through the language-match check (#2507 D7; ports the loop body of
// bin/check-test-language-match.sh). check(file, name, head, { root }) ->
// { lines: [{ err, text }], violation, infra }; an err line belongs on stderr. An invalid
// declaration is reported and then counts as none.

const R = require("../registry");
const { langException } = require("./exception");
const { judge } = require("./judge");

const ME = "check-test-language-match.sh";

function check(file, name, head, opts = {}) {
  const res = { lines: [], violation: false, infra: false };
  const say = (text, err = false) => res.lines.push({ err, text });
  const ex = langException(file, name);
  if (!ex.ok) {
    const allowed = (R.reg().testLanguageExceptions || []).join(" ") || "none";
    say(`HIGH: ${name}: invalid test-lang-exception value '${ex.bad}' (allowed: ${allowed}) code=INVALID_TEST_LANG_EXCEPTION`);
    res.violation = true;
  }
  const m = R.match(name);
  if (!m) {
    say(`WARN: ${name}: test language not checked (no test language registry entry matches this name) code=TEST_LANGUAGE_UNSUPPORTED`);
    return res;
  }
  if (m.status !== "supported") {
    say(`WARN: ${name}: test language not checked (${m.id} is ${m.status} in the test language registry) code=TEST_LANGUAGE_UNSUPPORTED`);
    return res;
  }
  if (ex.ok && ex.value) return res;
  const j = judge(file, name, head, opts);
  if (j.rc === 0) return res;
  if (j.rc === 1) {
    j.lines.forEach((l) => say(l));
    res.violation = true;
  } else {
    say(`${ME}: language match not judged (rc=${j.rc}): ${name}`, true);
    res.infra = true;
  }
  return res;
}

module.exports = { check };
