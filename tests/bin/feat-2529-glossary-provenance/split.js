"use strict";
// Tests: bin/check-glossary-provenance, bin/lib/glossary-provenance.js
// Tags: TL2, bin, glossary, provenance, migration, scope:issue-specific
// T3-2: a range split moves terms between files without an operation, and the HEAD-old-path /
// index-new-path directory move (the migration block) is zero operations too. Zero operations
// exit 0 before any session is resolved, so every run here has no --session and no env id.
// This file builds the old-path fixture on purpose (excluded from the T1-1 old-path sweep).

const { caseBegin, caseEnd } = require("../../lib/harness");
const fs = require("fs");
const path = require("path");
const { check, eq, ok, DEFS, glossaryText, git, stage, mkRepo, prov, U0, I0 } = require("./common");

caseBegin("t3-2-range-split-is-zero-operations", "bin/check-glossary-provenance");
function rangeSplit() {
  const repo = mkRepo("split");
  git(repo, ["rm", "-q", "--", "docs/glossary/user.md"]);
  stage(repo, "docs/glossary/user-a-m.md", glossaryText("user", [["alpha", DEFS.alpha]]));
  stage(repo, "docs/glossary/user-n-z.md", glossaryText("user", [["omega", DEFS.omega]]));
  check("T3-2 a range split (user.md -> user-a-m.md + user-n-z.md) is zero operations: exit 0 with no session", () => {
    const r = prov(repo, null);
    eq(r.code, 0, `exit (out: ${r.all})`);
  });
  check("T3-2 control: the same split plus one new term is an operation (no-session block, exit 1)", () => {
    stage(repo, "docs/glossary/user-a-m.md", glossaryText("user", [["alpha", DEFS.alpha], ["beta", "A split-time term."]]));
    const r = prov(repo, null);
    eq(r.code, 1, `exit (out: ${r.all})`);
    ok(/no-session/.test(r.all), `want no-session, got: ${r.all}`);
  });
}
caseEnd();

caseBegin("t3-2-legacy-directory-move-is-zero-operations", "bin/check-glossary-provenance");
function legacyMove() {
  const repo = mkRepo("legacy-move", {
    "docs/glossary-user.md": glossaryText("user", U0()),
    "docs/glossary-internal.md": glossaryText("internal", I0()),
  });
  fs.mkdirSync(path.join(repo, "docs", "glossary"), { recursive: true }); // git mv needs the target dir
  git(repo, ["mv", "docs/glossary-user.md", "docs/glossary/user.md"]);
  git(repo, ["mv", "docs/glossary-internal.md", "docs/glossary/internal.md"]);
  check("T3-2 HEAD old paths -> index new paths is zero operations (migration block): exit 0 with no session", () => {
    const r = prov(repo, null);
    eq(r.code, 0, `exit (out: ${r.all})`);
  });
  check("T3-2 control: the move plus a redefine is an operation (no-session block, exit 1)", () => {
    stage(repo, "docs/glossary/user.md", glossaryText("user", [["alpha", "The moved first term."], ["omega", DEFS.omega]]));
    const r = prov(repo, null);
    eq(r.code, 1, `exit (out: ${r.all})`);
  });
}
caseEnd();

module.exports = { rangeSplit, legacyMove };
