"use strict";
// tests/bin/feature-2561-worker-child-roots/selfcheck.js
// Both verdicts of the two classifiers the suite leans on: the preload's "run it or hold it"
// and the record analyser's "right root or wrong root". Run under the preload.
// Usage: selfcheck.js <empty work dir> <retired names csv>
// Prints ok<TAB>name / ng<TAB>name<TAB>detail lines; always exits 0.

const fs = require("fs");
const path = require("path");
const childProcess = require("child_process");

const [work, retiredCsv] = process.argv.slice(2);
const out = [];
const check = (name, cond, detail) =>
  out.push(cond ? `ok\tself/${name}` : `ng\tself/${name}\t${String(detail === undefined ? "" : detail).replace(/\s+/g, " ").slice(0, 300)}`);

// --- preload ------------------------------------------------------------------------------
const touch = (file) => ["-e", "require('fs').writeFileSync(process.argv[1], 'x')", file];
const childEnv = Object.assign({}, process.env, { GH_TOKEN: "selfcheck-secret-value" });
const opts = { cwd: work, env: childEnv, encoding: "utf8" };
const spawn = (cmd, args) => childProcess.spawnSync(cmd, args, opts);

process.env.SPAWN_RECORD_MODE = "record-only";
const a = spawn(process.execPath, touch(path.join(work, "a.txt")));
check("preload:record-only-answers-success", a.status === 0 && a.stdout === "" && a.stderr === "", JSON.stringify(a));
check("preload:record-only-runs-nothing", !fs.existsSync(path.join(work, "a.txt")));

process.env.SPAWN_RECORD_MODE = "run-real";
spawn(process.execPath, touch(path.join(work, "b.txt")));
check("preload:run-real-runs-the-child", fs.existsSync(path.join(work, "b.txt")));
const push = spawn("git", ["-C", work, "push", "-u", "origin", "no-such-branch"]);
check("preload:a-git-push-is-held-even-in-run-real", push.status === 0 && push.stderr === "", JSON.stringify(push));
const version = spawn("git", ["--version"]);
check("preload:a-local-git-call-is-run", version.status === 0 && /git version/.test(version.stdout), JSON.stringify(version));
process.env.SPAWN_RECORD_HOLD = "c.txt";
spawn(process.execPath, touch(path.join(work, "c.txt")));
check("preload:a-requested-hold-runs-nothing", !fs.existsSync(path.join(work, "c.txt")));
process.env.SPAWN_RECORD_HOLD = "";

const raw = fs.readFileSync(process.env.SPAWN_RECORD_OUT, "utf8");
const recs = raw.split("\n").filter((l) => l !== "").map((l) => JSON.parse(l));
check("preload:one-record-per-call-with-the-right-verdict",
  JSON.stringify(recs.map((r) => r.held)) === JSON.stringify([true, false, true, false, true]), JSON.stringify(recs.map((r) => r.held)));
check("preload:a-credential-value-never-reaches-the-record", !raw.includes("selfcheck-secret-value") && recs[0].env.GH_TOKEN === "<redacted>");
check("preload:cwd-and-argv-are-recorded", recs[3].command === "git" && recs[3].args[0] === "--version" && recs[3].cwd === work, JSON.stringify(recs[3]));

// Classifier table, run-real mode: [name, command, args, held?]. A row that is not held really
// runs, so those rows are read-only git calls in a directory that is no repository.
const CLASSIFIER_ROWS = [
  ["gh", "gh", ["api", "user"], true],
  ["glab", "glab", ["mr", "list"], true],
  ["docker", "docker", ["ps"], true],
  ["uv", "uv", ["run", "x.py"], true],
  ["exe-suffix-upper-case", "GH.EXE", ["api", "user"], true],
  ["windows-path-basename", "C:\\Tools\\bin\\gh.exe", ["api", "user"], true],
  ["posix-path-basename", "/usr/local/bin/docker", ["ps"], true],
  ["git-exe-push", "git.exe", ["push"], true],
  ["git-fetch", "git", ["fetch", "--all"], true],
  ["git-pull", "git", ["pull"], true],
  ["git-clone", "git", ["clone", "https://example.invalid/x.git"], true],
  ["git-ls-remote", "git", ["ls-remote", "origin"], true],
  ["git-dash-C-fetch", "git", ["-C", work, "fetch"], true],
  ["git-dash-c-pull", "git", ["-c", "user.name=x", "pull"], true],
  ["git-git-dir-work-tree-fetch", "git", ["--git-dir", "x", "--work-tree", "y", "fetch"], true],
  ["git-valueless-option-fetch", "git", ["--no-pager", "fetch"], true],
  ["git-remote-update", "git", ["-C", work, "remote", "update"], true],
  ["git-submodule-update", "git", ["-C", work, "submodule", "--quiet", "update"], true],
  ["git-version", "git", ["--version"], false],
  ["git-status", "git", ["-C", work, "status"], false],
  ["git-remote-list", "git", ["-C", work, "remote", "-v"], false],
  ["git-submodule-status", "git", ["-C", work, "submodule", "status"], false],
  ["git-dash-C-value-named-push", "git", ["-C", path.join(work, "push"), "status"], false],
  ["git-log-argument-named-fetch", "git", ["-C", work, "log", "fetch"], false],
];
for (const [, command, args] of CLASSIFIER_ROWS) spawn(command, args);
const tableRecs = fs.readFileSync(process.env.SPAWN_RECORD_OUT, "utf8").split("\n").filter((l) => l !== "").map((l) => JSON.parse(l)).slice(recs.length);
check("preload:classifier-table-one-record-per-row", tableRecs.length === CLASSIFIER_ROWS.length, `${tableRecs.length} of ${CLASSIFIER_ROWS.length}`);
CLASSIFIER_ROWS.forEach(([name, , , held], i) => {
  check(`preload:classifier/${name}-is-${held ? "held" : "run"}`, tableRecs[i] !== undefined && tableRecs[i].held === held, JSON.stringify(tableRecs[i]));
});
process.env.SPAWN_RECORD_ALLOW = "git";
const narrowed = spawn(process.execPath, touch(path.join(work, "d.txt")));
const allowedGit = spawn("git", ["--version"]);
delete process.env.SPAWN_RECORD_ALLOW;
check("preload:an-allow-list-holds-every-other-command", narrowed.status === 0 && !fs.existsSync(path.join(work, "d.txt")), JSON.stringify(narrowed));
check("preload:an-allow-list-still-runs-a-listed-command", /git version/.test(String(allowedGit.stdout)), JSON.stringify(allowedGit));
// An allow-list only adds holds: [name, allow list, command, args]. Were a row run after all,
// its arguments keep it local (a version print, a push in a directory that is no repository).
const ALLOWED_NETWORK_ROWS = [
  ["gh", "gh", "gh", ["--version"]],
  ["git-push", "git", "git", ["-C", work, "push"]],
];
for (const [name, allow, command, args] of ALLOWED_NETWORK_ROWS) {
  process.env.SPAWN_RECORD_ALLOW = allow;
  const res = spawn(command, args);
  delete process.env.SPAWN_RECORD_ALLOW;
  const last = fs.readFileSync(process.env.SPAWN_RECORD_OUT, "utf8").split("\n").filter((l) => l !== "").map((l) => JSON.parse(l)).pop();
  check(`preload:an-allow-list-naming-${name}-still-holds-it`,
    last.command === command && last.held === true && res.status === 0 && res.stdout === "" && res.stderr === "", JSON.stringify([last, res]));
}

// --- record analyser ------------------------------------------------------------------------
const dirs = {};
for (const name of ["agents-main", "checkout", "target-main", "target-linked", "launcher", "elsewhere"]) {
  dirs[name] = path.join(work, name);
  fs.mkdirSync(dirs[name], { recursive: true });
}
const retired = retiredCsv.split(",").filter((s) => s !== "");
const record = (env, cwd, extra) =>
  JSON.stringify(Object.assign({ mode: "run-real", held: false, tag: null, command: "node", args: [], cwd, envExplicit: true, env }, extra || {}));
// The dispatcher's own anchor probe: git asked about the script checkout, no explicit environment.
const probe = record(null, dirs.checkout, {
  command: "git", args: ["-C", dirs.checkout, "rev-parse", "--path-format=absolute", "--git-common-dir"], envExplicit: false,
});
const judge = (label, line, more) => {
  const file = path.join(work, `${label}.jsonl`);
  fs.writeFileSync(file, `${line}\n`);
  const text = childProcess.execFileSync(process.execPath, [
    path.join(__dirname, "check-records.js"), "--label", label, "--records", file,
    "--agents-main", dirs["agents-main"], "--checkout", dirs.checkout, "--target-main", dirs["target-main"],
    "--target-linked", dirs["target-linked"], "--launcher", dirs.launcher, "--retired", retiredCsv,
  ].concat(more || []), { encoding: "utf8" });
  return text.split("\n").filter((l) => l !== "").map((l) => l.split("\t"));
};

const good = judge("good", record({ AGENTS_MAIN_ROOT: dirs["agents-main"], PATH: "x" }, dirs["target-linked"]));
check("analyser:a-correct-record-gets-no-refusal", good.length >= 9 && good.every((l) => l[0] === "ok"), JSON.stringify(good.filter((l) => l[0] !== "ok")));

const goodEnv = { AGENTS_MAIN_ROOT: dirs["agents-main"], PATH: "x" };
const withProbe = judge("probe", `${probe}\n${record(goodEnv, dirs["target-linked"])}`);
check("analyser:the-dispatcher-probe-of-its-own-checkout-is-not-refused",
  withProbe.length >= 9 && withProbe.every((l) => l[0] === "ok"), JSON.stringify(withProbe.filter((l) => l[0] !== "ok")));
const probeOnly = judge("probeonly", probe);
check("analyser:a-probe-alone-does-not-count-as-a-started-child",
  probeOnly.some((l) => l[0] === "ng" && l[1] === "probeonly/setup:the-dispatcher-started-at-least-one-child"), JSON.stringify(probeOnly));

// The names no child environment may carry; a wrong record is data for the analyser, never an
// environment handed to a process, so the names are keyed in from this list.
const OTHER_ROOT_NAMES = ["SCRIPT_CHECKOUT_ROOT", "TARGET_MAIN_ROOT", "TARGET_CHECKOUT_ROOT"];
const badEnv = { AGENTS_MAIN_ROOT: path.join(dirs.launcher, "main") };
badEnv[OTHER_ROOT_NAMES[1]] = dirs["target-main"];
if (retired.length > 0) badEnv[retired[0]] = dirs.checkout;
const bad = judge("bad", record(badEnv, dirs.elsewhere));
// One fault each, in an otherwise correct record, so each path check is shown to refuse alone.
const onlyRefusal = (label, extra, name) => {
  const ng = judge(label, record(goodEnv, dirs["target-linked"], extra)).filter((l) => l[0] === "ng").map((l) => l[1]);
  check(`analyser:a-wrong-record-is-refused-by-${name}`, ng.length === 1 && ng[0] === `${label}/${name}`, ng.join(","));
};
onlyRefusal("dashc", { command: "git", args: ["-C", dirs.elsewhere, "status"] }, "path:every-git-dash-C-names-the-target-repository");
onlyRefusal("stray", { args: [path.join(dirs["agents-main"], "bin", "x.js")] }, "path:no-command-or-argument-points-into-an-agents-main-tree");
// The launcher root spelled through a `..` detour: no substring of the value is the root itself.
const detour = [dirs.elsewhere, "..", "launcher", "main"].join(path.sep);
onlyRefusal("detour", { env: Object.assign({ SOME_DIR: detour }, goodEnv) }, "env:nothing-from-the-launcher-environment-roots");
// Each of the three names alone, in an otherwise correct record, is refused by the one check.
OTHER_ROOT_NAMES.forEach((name, i) => {
  const env = Object.assign({}, goodEnv);
  env[name] = dirs["target-main"];
  onlyRefusal(`other${i}`, { env }, "env:no-other-root-name-is-handed-down");
});
const refused = bad.filter((l) => l[0] === "ng").map((l) => l[1]);
for (const name of [
  "env:AGENTS_MAIN_ROOT-is-the-agents-main-worktree",
  "env:AGENTS_MAIN_ROOT-is-not-another-root",
  "env:no-other-root-name-is-handed-down",
  "env:no-retired-name-is-handed-down",
  "env:nothing-from-the-launcher-environment-roots",
  "path:every-child-works-inside-the-target-repository",
]) {
  check(`analyser:a-wrong-record-is-refused-by-${name}`, refused.includes(`bad/${name}`), refused.join(","));
}
const absent = judge("absent", record({ PATH: "x" }, dirs["target-main"]));
check("analyser:a-missing-AGENTS_MAIN_ROOT-is-refused",
  absent.some((l) => l[0] === "ng" && l[1] === "absent/env:AGENTS_MAIN_ROOT-is-the-agents-main-worktree"), JSON.stringify(absent));
const keyless = ["--agents-main-key", "absent"];
const wantAbsent = judge("keyless", record({ PATH: "x" }, dirs["target-main"]), keyless);
check("analyser:asked-for-no-key-a-missing-AGENTS_MAIN_ROOT-gets-no-refusal",
  wantAbsent.length >= 9 && wantAbsent.every((l) => l[0] === "ok"), JSON.stringify(wantAbsent.filter((l) => l[0] !== "ok")));
const gotKey = judge("keyed", record(goodEnv, dirs["target-main"]), keyless);
check("analyser:asked-for-no-key-a-present-AGENTS_MAIN_ROOT-is-refused",
  gotKey.some((l) => l[0] === "ng" && l[1] === "keyed/env:AGENTS_MAIN_ROOT-is-absent"), JSON.stringify(gotKey));

process.stdout.write(`${out.join("\n")}\n`);
process.exit(0);
