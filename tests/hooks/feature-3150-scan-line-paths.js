"use strict";
// Tests: hooks/lib/outbound-scan/scan-line.js
// Tags: TL1, hooks, scan-outbound, outbound-scan, security, regex, table-driven, scope:issue-specific
// #3150 T-A1: the built-in user-profile path check matches every separator form (/, \, JSON \\,
// U+00A5), any case of "users" / "home", with or without a drive letter. A drive-less users path
// counts only after line start, a blank, a quote, "=" or "(" (URL and API paths stay clean).
// The recorded expectations (golden/cli.json, stdin-builtin-patterns) stay as they are: those
// exact matched strings are pinned here too. Every path is assembled from BS / SL / YEN and the
// name constants, so this source never trips the commit-time scan.
const { caseBegin, caseEnd, isolate } = require("../lib/harness");

const assert = require("node:assert");
const path = require("node:path");
const { after, test } = require("node:test");

const restore = isolate();
after(() => restore());

const LIB = path.join(__dirname, "..", "..", "hooks", "lib", "outbound-scan");
const BS = "\\";
const SL = "/";
const YEN = "¥";
const NAME = "someone";
const OTHER = "other";
const PATH_KINDS = new Set(["path", "msys-path", "wsl-path"]);

// scan(line, allow, file) -> the path-class findings of one line (empty lists, real hard secrets).
function scan(line, allow = [], file = "f.txt") {
  const { prepareScan } = require(path.join(LIB, "scan-text"));
  const s = prepareScan({ allow, blockHard: [], blockWarn: [] });
  assert.ok(!s.incomplete, `scanner compiled (${s.incomplete && s.incomplete.reason})`);
  return s.scanLine(file, 1, line).filter((f) => PATH_KINDS.has(f.kind));
}
const pathOnly = (fs) => fs.filter((f) => f.kind === "path");

caseBegin("module-loads-built-in-eres", "hooks/lib/outbound-scan/scan-line.js");
test("scan-line.js loads: every built-in ERE translates", () => {
  assert.doesNotThrow(() => require(path.join(LIB, "scan-line")));
});
caseEnd();

// The recorded expectations, verbatim (golden/cli.json stdin-builtin-patterns lines 6, 7, 9, 10).
const RECORDED = [
  { name: "recorded-mac-users", line: `p ${SL}Users${SL}fixtureuser${SL}x`, want: `${SL}Users${SL}fixtureuser` },
  { name: "recorded-home", line: `p ${SL}home${SL}fixtureuser`, want: `${SL}home${SL}fixtureuser` },
  { name: "recorded-drive-backslash", line: `p C:${BS}Users${BS}fixtureuser`, want: `C:${BS}Users${BS}fixtureuser` },
  { name: "recorded-drive-slash", line: `p C:${SL}Users${SL}fixtureuser`, want: `${SL}Users${SL}fixtureuser` },
];

caseBegin("recorded-expectation-matched-unchanged", "hooks/lib/outbound-scan/scan-line.js");
for (const { name, line, want } of RECORDED) {
  test(`${name}: matched stays the recorded string`, () => {
    const got = pathOnly(scan(line));
    assert.deepStrictEqual(got.map((f) => f.matched), [want], `${name}: line=${JSON.stringify(line)}`);
  });
}
caseEnd();

// Every separator x every "users" case x drive (none / upper / lower). JSON doubles the backslash.
const SEPS = [["slash", SL], ["backslash", BS], ["json-backslash", BS + BS], ["yen", YEN]];
const USERS = ["Users", "users", "USERS", "UsErS"];
const DRIVES = [["no-drive", ""], ["upper-drive", "C:"], ["lower-drive", "c:"]];
const USERS_HITS = [];
for (const [sepName, sep] of SEPS) {
  for (const users of USERS) {
    for (const [driveName, drive] of DRIVES) {
      const bare = `${sep}${users}${sep}${NAME}`;
      USERS_HITS.push({
        name: `${sepName}-${users}-${driveName}`,
        line: `open ${drive}${bare}${sep}proj now`,
        // A drive form may report the drive or start at the separator; nothing else.
        want: drive === "" ? [bare] : [drive + bare, bare],
      });
    }
  }
}

caseBegin("users-path-every-separator-case-drive", "hooks/lib/outbound-scan/scan-line.js");
for (const { name, line, want } of USERS_HITS) {
  test(`${name}: one hard path finding`, () => {
    const got = pathOnly(scan(line));
    assert.strictEqual(got.length, 1, `${name}: one path finding for ${JSON.stringify(line)} (got ${JSON.stringify(got)})`);
    assert.strictEqual(got[0].severity, "hard", `${name}: severity`);
    assert.ok(want.includes(got[0].matched), `${name}: matched ${JSON.stringify(got[0].matched)} is one of ${JSON.stringify(want)}`);
  });
}
caseEnd();

const HOME_HITS = ["home", "Home", "HOME", "hOmE"].map((h) => ({
  name: `home-${h}`, line: `cd ${SL}${h}${SL}${NAME}${SL}src`, want: `${SL}${h}${SL}${NAME}`,
}));

caseBegin("home-path-any-case", "hooks/lib/outbound-scan/scan-line.js");
for (const { name, line, want } of HOME_HITS) {
  test(`${name}: reported with the exact matched text`, () => {
    assert.deepStrictEqual(pathOnly(scan(line)).map((f) => f.matched), [want], `${name}: line=${JSON.stringify(line)}`);
  });
}
caseEnd();

// A drive-less users path counts right after line start, a blank, a quote, "=" or "(".
const LEADS = [["line-start", ""], ["blank", "x "], ["tab", "x\t"],["double-quote", 'x "'], ["single-quote", "x '"], ["equals", "x="], ["paren", "x("]];
const BOUNDARY_HITS = [];
for (const [leadName, lead] of LEADS) {
  for (const [sepName, sep] of [["slash", SL], ["backslash", BS]]) {
    const bare = `${sep}users${sep}${NAME}`;
    BOUNDARY_HITS.push({ name: `${leadName}-${sepName}`, line: `${lead}${bare}${sep}x`, want: bare });
  }
}

caseBegin("drive-less-users-boundary-hits", "hooks/lib/outbound-scan/scan-line.js");
for (const { name, line, want } of BOUNDARY_HITS) {
  test(`${name}: a drive-less users path after an allowed boundary is reported`, () => {
    assert.deepStrictEqual(pathOnly(scan(line)).map((f) => f.matched), [want], `${name}: line=${JSON.stringify(line)}`);
  });
}
caseEnd();

// A capitalized "Users" is reported anywhere (as the pre-#3150 scan did); the widened-case spellings
// still need a boundary, and the boundary set also holds a backtick, "[", "<", ",", "*" and "|".
const MARKUP_LEADS = [["backtick", "`"], ["open-bracket", "["], ["angle", "<"], ["comma", ","], ["star", "*"], ["pipe", "|"]];
const MARKUP_HITS = [];
for (const [leadName, lead] of MARKUP_LEADS) {
  MARKUP_HITS.push({ name: `capital-users-after-${leadName}`, line: `x${lead}${SL}Users${SL}${NAME}${SL}x`, want: `${SL}Users${SL}${NAME}` });
}
MARKUP_HITS.push({ name: "lower-users-after-backtick", line: `x\`${SL}users${SL}${NAME}${SL}x`, want: `${SL}users${SL}${NAME}` });
MARKUP_HITS.push({ name: "capital-users-in-url-path", line: `GET https:${SL}${SL}api.github.com${SL}Users${SL}${NAME}`, want: `${SL}Users${SL}${NAME}` });

caseBegin("markup-boundary-and-capital-users-hits", "hooks/lib/outbound-scan/scan-line.js");
for (const { name, line, want } of MARKUP_HITS) {
  test(`${name}: reported`, () => {
    assert.deepStrictEqual(pathOnly(scan(line)).map((f) => f.matched), [want], `${name}: line=${JSON.stringify(line)}`);
  });
}
test("lower-users-in-url-path: api.github.com users path stays clean", () => {
  const line = `GET https:${SL}${SL}api.github.com${SL}users${SL}${NAME}`;
  assert.deepStrictEqual(pathOnly(scan(line)), [], `line=${JSON.stringify(line)}`);
});
caseEnd();

const MISSES = [
  { name: "non-path-users-groups", line: `Manage Users${SL}Groups in the admin panel` },
  { name: "linuxbrew-exception", line: `export PATH=${SL}home${SL}linuxbrew${SL}.linuxbrew${SL}bin` },
  { name: "placeholder-slash", line: `see ${SL}Users${SL}<name>${SL}proj` },
  { name: "placeholder-drive-backslash", line: `see C:${BS}Users${BS}<name>${BS}proj` },
  { name: "placeholder-home", line: `see ${SL}home${SL}<name>` },
  { name: "url-host-users", line: `GET https:${SL}${SL}api.github.com${SL}users${SL}${NAME}` },
  { name: "gh-api-users", line: `gh api users${SL}${NAME}` },
  { name: "api-path-users", line: `curl -s api${SL}users${SL}${NAME}` },
  { name: "backslash-joined-users", line: `foo${BS}users${BS}${NAME}` },
];

caseBegin("non-path-look-alikes-miss", "hooks/lib/outbound-scan/scan-line.js");
for (const { name, line } of MISSES) {
  test(`${name}: no path finding`, () => {
    assert.deepStrictEqual(pathOnly(scan(line)), [], `${name}: line=${JSON.stringify(line)}`);
  });
}
caseEnd();

// A non-boundary users match must not end the search: a real path later on the same line is still reported.
const LATER_PATH = [
  { name: "url-then-drive-path", line: `GET https:${SL}${SL}api.github.com${SL}users${SL}${NAME} from C:${BS}Users${BS}${OTHER}${BS}proj`, want: [`C:${BS}Users${BS}${OTHER}`, `${BS}Users${BS}${OTHER}`] },
  { name: "api-then-blank-path", line: `api${SL}users${SL}x and ${SL}users${SL}${NAME}`, want: [`${SL}users${SL}${NAME}`] },
];

caseBegin("non-boundary-match-then-real-path-same-line", "hooks/lib/outbound-scan/scan-line.js");
for (const { name, line, want } of LATER_PATH) {
  test(`${name}: the later real path is reported`, () => {
    const got = pathOnly(scan(line));
    assert.strictEqual(got.length, 1, `${name}: ${JSON.stringify(got)}`);
    assert.ok(want.includes(got[0].matched), `${name}: matched ${JSON.stringify(got[0].matched)} in ${JSON.stringify(want)}`);
  });
}
caseEnd();

// By design (atBoundary): a one-letter segment before users is the msys drive marker "/c", so it counts.
caseBegin("msys-one-letter-segment-before-users", "hooks/lib/outbound-scan/scan-line.js");
test("host/u/users/<name> is reported like an msys drive path (documented trade-off)", () => {
  const got = pathOnly(scan(`https:${SL}${SL}example.com${SL}u${SL}users${SL}${NAME}`));
  assert.deepStrictEqual(got.map((f) => f.matched), [`${SL}users${SL}${NAME}`]);
});
caseEnd();

caseBegin("msys-wsl-regression","hooks/lib/outbound-scan/scan-line.js");
test("msys users path: exactly path + msys-path (two findings)", () => {
  const got = scan(`cd ${SL}c${SL}Users${SL}${NAME}${SL}proj`);
  assert.deepStrictEqual(got.map((f) => f.kind).sort(), ["msys-path", "path"], JSON.stringify(got));
});
test("wsl users path: the wsl-path finding is still reported", () => {
  const got = scan(`cd ${SL}mnt${SL}c${SL}Users${SL}${NAME}${SL}proj`);
  assert.ok(got.some((f) => f.kind === "wsl-path"), JSON.stringify(got));
});
caseEnd();

// Allowlist rows written for the old matched forms keep working (drive-slash rows included).
const ere = (s) => s.replace(/[.\\]/g, (c) => BS + c);
const ALLOW = [
  { name: "anchored-old-form-mac-line", allow: [`^${SL}Users${SL}${NAME}$`], line: ` ${SL}Users${SL}${NAME}${SL}x`, want: 0 },
  { name: "anchored-old-form-drive-slash-line", allow: [`^${SL}Users${SL}${NAME}$`], line: `p C:${SL}Users${SL}${NAME}${SL}x`, want: 0 },
  // A row's first ":" ends its file glob, so a drive-letter row carries a "*:" glob.
  { name: "drive-backslash-row", allow: [`*:${ere(`C:${BS}Users${BS}${NAME}`)}`], line: `p C:${BS}Users${BS}${NAME}${BS}x`, want: 0 },
  { name: "name-row-covers-new-form", allow: [NAME], line: `p c:${BS}users${BS}${NAME}${BS}x`, want: 0 },
  { name: "other-name-not-covered", allow: [`${SL}Users${SL}${NAME}`], line: ` ${SL}Users${SL}${OTHER}${SL}x`, want: 1 },
  { name: "glob-row-matching-file", allow: [`docs/*:${SL}Users${SL}${NAME}`], line: ` ${SL}Users${SL}${NAME}`, file: "docs/a.md", want: 0 },
  { name: "glob-row-other-file", allow: [`docs/*:${SL}Users${SL}${NAME}`], line: ` ${SL}Users${SL}${NAME}`, file: "src/a.js", want: 1 },
];

caseBegin("allowlist-interaction", "hooks/lib/outbound-scan/scan-line.js");
for (const { name, allow, line, file, want } of ALLOW) {
  test(`${name}: ${want} path finding(s) left`, () => {
    assert.strictEqual(pathOnly(scan(line, allow, file)).length, want, `${name}: line=${JSON.stringify(line)} allow=${JSON.stringify(allow)}`);
  });
}
caseEnd();

// One report per line; the users pattern is tried before the home pattern (current order).
const TWO_PATHS = [
  { name: "home-then-users", line: ` ${SL}home${SL}aaa and ${SL}Users${SL}bbb`, want: `${SL}Users${SL}bbb` },
  { name: "users-then-home", line: ` ${SL}Users${SL}bbb and ${SL}home${SL}aaa`, want: `${SL}Users${SL}bbb` },
];

caseBegin("two-paths-one-line-selection-order", "hooks/lib/outbound-scan/scan-line.js");
for (const { name, line, want } of TWO_PATHS) {
  test(`${name}: one path finding, users pattern first`, () => {
    assert.deepStrictEqual(pathOnly(scan(line)).map((f) => f.matched), [want], `${name}: line=${JSON.stringify(line)}`);
  });
}
caseEnd();

// C1: a lowercase users path directly after each markup boundary char is reported.
caseBegin("lower-users-after-every-markup-boundary", "hooks/lib/outbound-scan/scan-line.js");
for (const [leadName, lead] of MARKUP_LEADS) {
  test(`lower-users-after-${leadName}: reported`, () => {
    const line = `x${lead}${SL}users${SL}${NAME}${SL}x`;
    assert.deepStrictEqual(pathOnly(scan(line)).map((f) => f.matched), [`${SL}users${SL}${NAME}`], `line=${JSON.stringify(line)}`);
  });
}
caseEnd();

// C2: only the exact spelling "Users" is exempt from the boundary; other cases after a URL host stay clean.
caseBegin("url-embedded-non-capital-users-stays-clean", "hooks/lib/outbound-scan/scan-line.js");
for (const users of ["USERS", "UsErS"]) {
  test(`url-${users}: no path finding`, () => {
    const line = `GET https:${SL}${SL}host.example${SL}${users}${SL}${NAME}`;
    assert.deepStrictEqual(pathOnly(scan(line)), [], `line=${JSON.stringify(line)}`);
  });
}
caseEnd();

// C3: a drive marker preceded by a letter still counts (the letter before "C:" is the boundary).
caseBegin("drive-marker-preceded-by-letter", "hooks/lib/outbound-scan/scan-line.js");
test("xC-drive-lower-users: matched is the drive path", () => {
  const line = `xC:${BS}users${BS}${NAME}${BS}p`;
  assert.deepStrictEqual(pathOnly(scan(line)).map((f) => f.matched), [`C:${BS}users${BS}${NAME}`], `line=${JSON.stringify(line)}`);
});
caseEnd();

// C4: a digit before ":" is not a drive letter, so the lowercase users path has no boundary.
caseBegin("non-letter-drive-marker-misses", "hooks/lib/outbound-scan/scan-line.js");
for (const lead of ["1:", "x9:"]) {
  test(`${lead}-lower-users: no path finding`, () => {
    const line = `${lead}${SL}users${SL}${NAME}`;
    assert.deepStrictEqual(pathOnly(scan(line)), [], `line=${JSON.stringify(line)}`);
  });
}
caseEnd();

// C5: the home pattern is slash-only; backslash and yen separators are not reported.
caseBegin("home-path-is-slash-only", "hooks/lib/outbound-scan/scan-line.js");
for (const [sepName, sep] of [["backslash", BS], ["yen", String.fromCharCode(0xa5)]]) {
  test(`home-${sepName}: no path finding`, () => {
    const line = `cd ${sep}home${sep}${NAME}${sep}src`;
    assert.deepStrictEqual(pathOnly(scan(line)), [], `line=${JSON.stringify(line)}`);
  });
}
caseEnd();
