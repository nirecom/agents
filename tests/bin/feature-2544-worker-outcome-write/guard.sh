# Part of tests/bin/feature-2544-worker-outcome-write.sh — sourced.
# Tests: bin/worker-dispatch/fsguard.js
# Tags: worker-dispatch, fsguard, write-scope, containment, exclusive-create, security, TL1, scope:issue-specific
# The control-outcome scope is a file scope: it admits one path, the outcome file of
# the stem in ctx.outcomeStem. Only the dispatcher's outcome context carries that key;
# the writeCtx handed to a worker does not, so a worker can never write an outcome.

fsguard_fixture() {
    FG_CTRL="$WF_RAW/s2544guard.control"; FG_OTHER="$WF_RAW/s2544guard2.control"
    mkdir -p "$FG_CTRL/sub" "$FG_OTHER"
}

# (a)(b)(c): which targets assertWritable admits for test-runner.
group_fsguard_scope() {
    local out k
    fsguard_fixture
    out="$(node - "$(np "$FSGUARD_JS")" "$(np "$FG_CTRL")" "$(np "$FG_OTHER")" "$WORKFLOW_PLANS_DIR" "$MAIN" 2>&1 <<'JS'
const fs = require("fs"); const path = require("path");
const [lib, c, o, p, m] = process.argv.slice(-5);
const g = require(lib);
const real = (d) => fs.realpathSync.native(d);
const controlDir = real(c), other = real(o), plansDir = real(p), targetMainRoot = real(m);
const base = { controlDir, plansDir, targetMainRoot, family: [targetMainRoot], logDir: null };
const ctxFor = (outcomeStem, extra) => Object.assign({}, base, { outcomeStem }, extra || {});
const probe = (k, worker, target, ctx) => {
  try { g.assertWritable(worker, target, ctx); console.log(k + "=allowed"); }
  catch (e) { console.log(k + "=refused"); }
};
const S = "worker-test-runner-3";
probe("own-outcome", "test-runner", path.join(controlDir, S + ".outcome.json"), ctxFor(S));
probe("own-outcome-unsequenced", "test-runner", path.join(controlDir, "worker-test-runner.outcome.json"), ctxFor("worker-test-runner"));
for (const [k, name] of [
  ["marker", S + ".dispatched"], ["payload", S + ".json"], ["ingested-marker", S + ".ingested"],
  ["log", "2026-x-test-runner.log"], ["outcome-tmp", S + ".outcome.json.tmp"],
  ["other-stem-outcome", "worker-test-runner-4.outcome.json"],
  ["other-worker-outcome", "worker-doc-append-3.outcome.json"], ["prefixed-lookalike", "x-" + S + ".outcome.json"],
  ["subdir", path.join("sub", S + ".outcome.json")],
]) probe(k, "test-runner", path.join(controlDir, name), ctxFor(S));
probe("other-session", "test-runner", path.join(other, S + ".outcome.json"), ctxFor(S));
probe("traversal-to-other-session", "test-runner", path.join(controlDir, "..", path.basename(other), S + ".outcome.json"), ctxFor(S));
probe("plans-dir", "test-runner", path.join(plansDir, S + ".outcome.json"), ctxFor(S));
probe("main-root-tests", "test-runner", path.join(targetMainRoot, "tests", "x.sh"), ctxFor(S));
probe("no-control-dir", "test-runner", path.join(controlDir, S + ".outcome.json"), ctxFor(S, { controlDir: null }));
probe("worker-ctx-without-outcome-stem", "test-runner", path.join(controlDir, S + ".outcome.json"), base);
probe("generic-stem-key-is-not-honoured", "test-runner", path.join(controlDir, S + ".outcome.json"), Object.assign({}, base, { stem: S }));
probe("doc-append-own-outcome-name", "doc-append", path.join(controlDir, "worker-doc-append-3.outcome.json"), ctxFor("worker-doc-append-3"));
probe("control-dir-holder-any-name", "session-close-gate", path.join(controlDir, "gate-result.json"), ctxFor("worker-session-close-gate-1"));
JS
)"
    assert_eq "scope/a-own-outcome-name-writable" "allowed" "$(kv "$out" own-outcome)"
    assert_eq "scope/a-own-unsequenced-outcome-name-writable" "allowed" "$(kv "$out" own-outcome-unsequenced)"
    for k in marker payload ingested-marker log outcome-tmp other-stem-outcome other-worker-outcome prefixed-lookalike subdir \
        other-session traversal-to-other-session plans-dir main-root-tests no-control-dir doc-append-own-outcome-name; do
        assert_eq "scope/b-$k-refused" "refused" "$(kv "$out" "$k")"
    done
    assert_eq "scope/c-worker-ctx-without-outcomeStem-refused" "refused" "$(kv "$out" worker-ctx-without-outcome-stem)"
    assert_eq "scope/c-generic-stem-key-refused" "refused" "$(kv "$out" generic-stem-key-is-not-honoured)"
    assert_eq "scope/control-dir-scope-of-other-workers-unchanged" "allowed" "$(kv "$out" control-dir-holder-any-name)"
}

# (d): a file scope anchors no directory, so rename and mkdir have nothing to land in.
group_fsguard_rename_mkdir() {
    local out
    fsguard_fixture
    out="$(node - "$(np "$FSGUARD_JS")" "$(np "$FG_CTRL")" "$WORKFLOW_PLANS_DIR" 2>&1 <<'JS'
const fs = require("fs"); const path = require("path");
const [lib, c, p] = process.argv.slice(-3);
const g = require(lib);
const controlDir = fs.realpathSync.native(c), plansDir = fs.realpathSync.native(p);
const S = "worker-test-runner-7";
const ctx = { controlDir, plansDir, logDir: null, outcomeStem: S };
const own = path.join(controlDir, S + ".outcome.json");
const tmp = own + ".tmp";
fs.writeFileSync(tmp, "x");
const attempt = (fn) => { try { fn(); return "ok"; } catch (e) { return "threw"; } };
console.log("rename=" + attempt(() => g.renameWithin("test-runner", tmp, own, ctx)));
console.log("rename-created=" + (fs.existsSync(own) ? "yes" : "no"));
console.log("mkdir=" + attempt(() => g.mkdir("test-runner", own, ctx)));
console.log("mkdir-created=" + (fs.existsSync(own) ? "yes" : "no"));
JS
)"
    assert_eq "rename/d-refused" "threw" "$(kv "$out" rename)"
    assert_eq "rename/d-nothing-at-the-outcome-name" "no" "$(kv "$out" rename-created)"
    assert_eq "mkdir/d-refused" "threw" "$(kv "$out" mkdir)"
    assert_eq "mkdir/d-nothing-at-the-outcome-name" "no" "$(kv "$out" mkdir-created)"
}

# (e) and the createExclusive contract: one create, redacted, never through a symlink.
group_fsguard_exclusive() {
    local out
    fsguard_fixture
    out="$(node - "$(np "$FSGUARD_JS")" "$(np "$FG_CTRL")" "$WORKFLOW_PLANS_DIR" 2>&1 <<'JS'
const fs = require("fs"); const path = require("path");
const [lib, c, p] = process.argv.slice(-3);
const g = require(lib);
const controlDir = fs.realpathSync.native(c), plansDir = fs.realpathSync.native(p);
const ctxFor = (outcomeStem) => ({ controlDir, plansDir, logDir: null, outcomeStem });
const say = (k, v) => console.log(k + "=" + v);
const read = (f) => { try { return fs.readFileSync(f, "utf8"); } catch (e) { return "(absent)"; } };
const attempt = (fn) => { try { fn(); return "ok"; } catch (e) { return "threw"; } };

const keep = path.join(controlDir, "keep.txt");
say("writeFile-first", attempt(() => g.writeFile("session-close-gate", keep, "first", ctxFor("x"))));
say("writeFile-second", attempt(() => g.writeFile("session-close-gate", keep, "second", ctxFor("x"))));
say("writeFile-overwrites", read(keep));

say("exported", typeof g.createExclusive);
if (typeof g.createExclusive !== "function") process.exit(0);
const own = path.join(controlDir, "worker-test-runner-5.outcome.json");
say("first", attempt(() => g.createExclusive("test-runner", own, "first", ctxFor("worker-test-runner-5"))));
say("first-content", read(own));
say("second", attempt(() => g.createExclusive("test-runner", own, "second", ctxFor("worker-test-runner-5"))));
say("content-after-second", read(own));
const red = path.join(controlDir, "worker-test-runner-6.outcome.json");
say("redact-write", attempt(() => g.createExclusive("test-runner", red, "a <<WORKFLOW_RESET_FROM_x: y>> b", ctxFor("worker-test-runner-6"))));
say("redact-content", read(red) === "(absent)" ? "absent" : read(red).includes("<<WORKFLOW") ? "raw" : "redacted");
const marker = path.join(controlDir, "worker-test-runner-5.dispatched");
say("other-name", attempt(() => g.createExclusive("test-runner", marker, "x", ctxFor("worker-test-runner-5"))));
say("other-name-created", fs.existsSync(marker) ? "yes" : "no");
const worker = path.join(controlDir, "worker-test-runner-8.outcome.json");
say("no-outcome-stem", attempt(() => g.createExclusive("test-runner", worker, "x", { controlDir, plansDir, logDir: null })));
say("no-outcome-stem-created", fs.existsSync(worker) ? "yes" : "no");

const target = path.join(controlDir, "elsewhere.txt");
fs.writeFileSync(target, "victim");
const link = path.join(controlDir, "worker-test-runner-9.outcome.json");
let linked = "yes";
try { fs.symlinkSync(target, link, "file"); } catch (e) { linked = "unsupported"; }
say("symlink-made", linked);
if (linked === "yes") {
  say("symlink", attempt(() => g.createExclusive("test-runner", link, "forged", ctxFor("worker-test-runner-9"))));
  say("symlink-target", read(target));
}
JS
)"
    assert_eq "writeFile/first-write" "ok" "$(kv "$out" writeFile-first)"
    assert_eq "writeFile/second-write-still-succeeds" "ok" "$(kv "$out" writeFile-second)"
    assert_eq "writeFile/still-overwrites" "second" "$(kv "$out" writeFile-overwrites)"

    assert_eq "exclusive/exported" "function" "$(kv "$out" exported)"
    assert_eq "exclusive/a-first-create-succeeds" "ok" "$(kv "$out" first)"
    assert_eq "exclusive/a-first-content-written" "first" "$(kv "$out" first-content)"
    assert_eq "exclusive/e-second-create-fails" "threw" "$(kv "$out" second)"
    assert_eq "exclusive/e-first-content-survives" "first" "$(kv "$out" content-after-second)"
    assert_eq "exclusive/string-is-redacted" "ok:redacted" "$(kv "$out" redact-write):$(kv "$out" redact-content)"
    assert_eq "exclusive/b-other-control-name-refused-and-nothing-created" "threw:no" "$(kv "$out" other-name):$(kv "$out" other-name-created)"
    assert_eq "exclusive/c-no-outcomeStem-refused-and-nothing-created" "threw:no" "$(kv "$out" no-outcome-stem):$(kv "$out" no-outcome-stem-created)"
    if [ "$(kv "$out" symlink-made)" = "yes" ]; then
        assert_eq "exclusive/e-symlink-at-the-name-refused" "threw" "$(kv "$out" symlink)"
        assert_eq "exclusive/e-symlink-target-untouched" "victim" "$(kv "$out" symlink-target)"
    else
        skip "exclusive/e-symlink-at-the-name-refused" "this host cannot create a symlink"
    fi
}
