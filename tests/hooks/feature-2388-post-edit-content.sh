#!/usr/bin/env bash
# tests/hooks/feature-2388-post-edit-content.sh
# Tests: hooks/lib/post-edit-content.js, hooks/lib/pretool-lang-gate.js, hooks/block-comment-block-size.js
# Tags: TL1, hooks, post-edit-content, case-markers, scope:issue-specific
# Unit contract of the shared post-edit reconstruction module (#2388 Step 4):
# the content a Write/Edit/MultiEdit leaves on disk, rebuilt in memory, plus
# per-edit-path grouping for MultiEdit. The two former owners (pretool-lang-gate,
# block-comment-block-size) must consume it instead of keeping private copies.
set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
source "$AGENTS_DIR/tests/lib/harness.sh"

if ! command -v node >/dev/null 2>&1; then
  echo "SKIP: node not available"
  exit 77
fi

MOD="$AGENTS_DIR/hooks/lib/post-edit-content.js"
TMPBASE="$(make_tmp)"
trap 'rm -rf "$TMPBASE"' EXIT
FIX="$TMPBASE/fix"
mkdir -p "$FIX"
DRV="$TMPBASE/driver.js"

cat > "$DRV" <<'JS'
// driver.js <scenario> — prints one JSON value per scenario.
const fs = require("fs");
const path = require("path");
let m;
try {
  m = require(process.env.MOD);
} catch (e) {
  console.log("MODULE_MISSING");
  process.exit(3);
}
const FIX = process.env.FIX;
const f = (n) => path.join(FIX, n);
function put(n, s) {
  fs.mkdirSync(path.dirname(f(n)), { recursive: true });
  fs.writeFileSync(f(n), s);
  return f(n);
}
const out = (v) => console.log(JSON.stringify(v));
const call = (name, ...a) => (typeof m[name] === "function" ? m[name](...a) : `NO_EXPORT:${name}`);
const shape = (groups) =>
  Array.isArray(groups)
    ? groups
        .map((g) => ({
          file: path.basename(String(g.rawPath)),
          news: Array.isArray(g.edits) ? g.edits.map((e) => e.new_string) : null,
          content: typeof g.content === "string" ? g.content : null,
        }))
        .sort((a, b) => a.file.localeCompare(b.file))
    : groups;

const S = {
  "max-bytes-const": () => out(m.MAX_BYTES),
  "write": () => out(call("buildPostContent", "Write", { file_path: f("w.sh"), content: "abc\n" }, f("w.sh"))),
  "edit-unique": () => {
    const p = put("e1.sh", "one two three\n");
    out(call("buildPostContent", "Edit", { file_path: p, old_string: "two", new_string: "2" }, p));
  },
  "edit-first-only": () => {
    const p = put("e2.sh", "a-a-a");
    out(call("buildPostContent", "Edit", { file_path: p, old_string: "a", new_string: "b" }, p));
  },
  "edit-replace-all": () => {
    const p = put("e3.sh", "a-a-a");
    out(call("buildPostContent", "Edit", { file_path: p, old_string: "a", new_string: "b", replace_all: true }, p));
  },
  "multiedit-sequence": () => {
    const p = put("m1.sh", "x\n");
    const edits = [
      { old_string: "x", new_string: "y" },
      { old_string: "y", new_string: "z" },
    ];
    out(call("buildPostContent", "MultiEdit", { file_path: p, edits }, p));
  },
  "old-string-absent": () => {
    const p = put("e4.sh", "hello\n");
    out(call("buildPostContent", "Edit", { file_path: p, old_string: "absent", new_string: "x" }, p));
  },
  "empty-old-string": () => out(call("applyEdits", "abc", [{ old_string: "", new_string: "x" }])),
  "dollar-amp-literal": () => {
    const p = put("e5.sh", "foo\n");
    out(call("buildPostContent", "Edit", { file_path: p, old_string: "foo", new_string: "$&-$1-$$" }, p));
  },
  "edit-nonexistent-file": () => {
    const p = f("nope/missing.sh");
    out({
      pre: call("readPre", p, { maxBytes: m.MAX_BYTES }),
      post: call("buildPostContent", "Edit", { file_path: p, old_string: "x", new_string: "y" }, p),
    });
  },
  "write-nonexistent-file": () => {
    const p = f("nope2/new.sh");
    out(call("buildPostContent", "Write", { file_path: p, content: "new\n" }, p));
  },
  "max-bytes-exceeded": () => {
    const p = put("big.sh", "0123456789abcdefghij\n");
    out({
      pre: call("readPre", p, { maxBytes: 10 }),
      post: call("buildPostContent", "Edit", { file_path: p, old_string: "0", new_string: "1" }, p, { maxBytes: 10 }),
    });
  },
  "unknown-tool": () => {
    const p = put("u.sh", "abc\n");
    out(call("buildPostContent", "NotebookEdit", { file_path: p, old_string: "a", new_string: "b" }, p));
  },
  "group-write": () => out(shape(call("groupEditTargets", "Write", { file_path: f("gw.sh"), content: "c" }))),
  "group-edit": () =>
    out(shape(call("groupEditTargets", "Edit", { file_path: f("ge.sh"), old_string: "a", new_string: "b" }))),
  "group-multiedit-two-paths": () => {
    const edits = [
      { file_path: f("b.sh"), old_string: "o", new_string: "b1" },
      { file_path: f("a.sh"), old_string: "o", new_string: "a1" },
      { old_string: "o", new_string: "a2" },
    ];
    out(shape(call("groupEditTargets", "MultiEdit", { file_path: f("a.sh"), edits })));
  },
  "group-alias-relative-absolute": () => {
    process.chdir(FIX);
    const edits = [
      { file_path: "sub/c.sh", old_string: "o", new_string: "1" },
      { file_path: path.join(FIX, "sub", "c.sh"), old_string: "o", new_string: "2" },
      { file_path: "./sub/c.sh", old_string: "o", new_string: "3" },
    ];
    out(shape(call("groupEditTargets", "MultiEdit", { file_path: "sub/c.sh", edits })));
  },
  "group-alias-drive": () => {
    if (process.platform !== "win32") {
      out("SKIP");
      return;
    }
    const edits = [
      { file_path: "/c/zz2388/d.sh", old_string: "o", new_string: "1" },
      { file_path: "C:\\zz2388\\d.sh", old_string: "o", new_string: "2" },
      { file_path: "C:/zz2388/d.sh", old_string: "o", new_string: "3" },
    ];
    out(shape(call("groupEditTargets", "MultiEdit", { file_path: "C:\\zz2388\\d.sh", edits })));
  },
  "resolve-target": () => {
    delete process.env.CLAUDE_PROJECT_DIR;
    const r = call("resolveTargetPath", { cwd: FIX }, "sub/r.sh");
    out([r === path.resolve(FIX, "sub/r.sh"), call("resolveTargetPath", { cwd: FIX }, "")]);
  },
  "path-helpers": () =>
    out([
      call("pathOf", { file_path: "a" }),
      call("pathOf", { path: "b" }),
      call("pathOf", {}),
      call("normalizePath", "x") === path.resolve("x"),
    ]),
  "sibling-reexport": () => {
    const lg = require(process.env.LANG_GATE);
    out([lg.applyEdits === m.applyEdits, lg.pathOf === m.pathOf, lg.normalizePath === m.normalizePath]);
  },
};
if (!S[process.argv[2]]) {
  console.log("UNKNOWN_SCENARIO");
  process.exit(4);
}
S[process.argv[2]]();
JS

# drv <scenario> — run one driver scenario; sets DOUT.
export MOD FIX LANG_GATE
MOD="$(np "$MOD")"
FIX="$(np "$FIX")"
LANG_GATE="$(np "$AGENTS_DIR/hooks/lib/pretool-lang-gate.js")"
DRV_N="$(np "$DRV")"
drv() {
  DOUT="$(run_with_timeout 30 node "$DRV_N" "$1" 2>&1)"
}

# expect <scenario> <json> — driver output must equal the JSON literal.
expect() {
  drv "$1"
  if [ "$DOUT" = "$2" ]; then
    pass "$1: $2"
  else
    fail "$1" "want $2 got $DOUT"
  fi
}

case_begin "max-bytes-constant" "hooks/lib/post-edit-content.js"
expect max-bytes-const '1000000'
case_end

case_begin "write-returns-content" "hooks/lib/post-edit-content.js"
expect write '"abc\n"'
expect write-nonexistent-file '"new\n"'
case_end

case_begin "edit-unique-replacement" "hooks/lib/post-edit-content.js"
expect edit-unique '"one 2 three\n"'
expect edit-first-only '"b-a-a"'
case_end

case_begin "edit-replace-all" "hooks/lib/post-edit-content.js"
expect edit-replace-all '"b-b-b"'
case_end

case_begin "multiedit-applies-in-sequence" "hooks/lib/post-edit-content.js"
expect multiedit-sequence '"z\n"'
case_end

case_begin "old-string-absent-is-null" "hooks/lib/post-edit-content.js"
expect old-string-absent 'null'
expect empty-old-string 'null'
case_end

case_begin "dollar-amp-not-expanded" "hooks/lib/post-edit-content.js"
expect dollar-amp-literal '"$&-$1-$$\n"'
case_end

case_begin "edit-on-nonexistent-file" "hooks/lib/post-edit-content.js"
# readPre of a missing file is "" (a new file), so an Edit cannot match → null.
expect edit-nonexistent-file '{"pre":"","post":null}'
case_end

case_begin "max-bytes-exceeded-is-null" "hooks/lib/post-edit-content.js"
expect max-bytes-exceeded '{"pre":null,"post":null}'
case_end

case_begin "unknown-tool-is-null" "hooks/lib/post-edit-content.js"
expect unknown-tool 'null'
case_end

case_begin "group-single-target-tools" "hooks/lib/post-edit-content.js"
expect group-write '[{"file":"gw.sh","news":null,"content":"c"}]'
expect group-edit '[{"file":"ge.sh","news":["b"],"content":null}]'
case_end

case_begin "group-multiedit-per-edit-paths" "hooks/lib/post-edit-content.js"
# Two groups; the path-less element inherits the top-level path; order kept.
expect group-multiedit-two-paths '[{"file":"a.sh","news":["a1","a2"],"content":null},{"file":"b.sh","news":["b1"],"content":null}]'
case_end

case_begin "group-alias-spellings-collapse" "hooks/lib/post-edit-content.js"
expect group-alias-relative-absolute '[{"file":"c.sh","news":["1","2","3"],"content":null}]'
drv group-alias-drive
if [ "$DOUT" = '"SKIP"' ]; then
  skip "group-alias-drive: /c/ vs C:\\ spellings are Windows-only"
else
  assert_eq "$DOUT" '[{"file":"d.sh","news":["1","2","3"],"content":null}]'
fi
case_end

case_begin "resolve-target-path" "hooks/lib/post-edit-content.js"
expect resolve-target '[true,null]'
case_end

case_begin "path-helpers" "hooks/lib/post-edit-content.js"
expect path-helpers '["a","b",null,true]'
case_end

case_begin "lang-gate-reexports-shared" "hooks/lib/pretool-lang-gate.js"
# CPR-SSOT: the lang gate re-exports the shared functions, not private copies.
expect sibling-reexport '[true,true,true]'
case_end

case_begin "comment-block-consumes-shared" "hooks/block-comment-block-size.js"
if grep -qF "./lib/post-edit-content" "$AGENTS_DIR/hooks/block-comment-block-size.js"; then
  pass "comment-block-consumes-shared: requires ./lib/post-edit-content"
else
  fail "comment-block-consumes-shared" "hooks/block-comment-block-size.js does not require ./lib/post-edit-content"
fi
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
