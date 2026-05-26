#!/usr/bin/env node
// Unit tests for hooks/lib/command-head.js
// Pure Node.js — no external framework.
//
// The module under test does NOT exist yet (test-first development).
// Running this file will fail with a module-not-found error until the
// source file is created. That is EXPECTED.

const { hasCommandHead } = require("../../hooks/lib/command-head");

let passed = 0;
let failed = 0;

function pass(label) {
  passed++;
  console.log("PASS: " + label);
}

function fail(label, expected, actual) {
  failed++;
  console.log("FAIL: " + label + " — expected " + JSON.stringify(expected) + ", got " + JSON.stringify(actual));
}

function check(label, actual, expected) {
  if (actual === expected) pass(label);
  else fail(label, expected, actual);
}

// --- Matchers ---
const docAppend = (t) =>
  t[0] === "doc-append" || /(^|\/)doc-append(\.py)?$/.test(t[0] || "");

const ghIssueClose = (t) =>
  t[0] === "gh" && t[1] === "issue" && t[2] === "close";

// ============================================================================
// Basic head matching
// ============================================================================
check(
  "bare match: doc-append docs/history.md",
  hasCommandHead("doc-append docs/history.md", docAppend),
  true
);
check(
  "env-prefix: FOO=bar doc-append ...",
  hasCommandHead("FOO=bar doc-append docs/history.md", docAppend),
  true
);
check(
  "multi env-prefix: FOO=1 BAR=2 doc-append ...",
  hasCommandHead("FOO=1 BAR=2 doc-append docs/history.md", docAppend),
  true
);

// ============================================================================
// uv run peeling — happy path
// ============================================================================
check(
  "uv run doc-append --foo bar",
  hasCommandHead("uv run doc-append --foo bar", docAppend),
  true
);
check(
  "uv run bin/doc-append.py ... (suffix match)",
  hasCommandHead("uv run bin/doc-append.py docs/history.md", docAppend),
  true
);

// ============================================================================
// uv run peeling — flag forms
// ============================================================================
check(
  "uv run --with foo doc-append ...",
  hasCommandHead("uv run --with foo doc-append docs/history.md", docAppend),
  true
);
check(
  "uv run --python 3.12 doc-append ...",
  hasCommandHead("uv run --python 3.12 doc-append docs/history.md", docAppend),
  true
);
check(
  "uv run --with foo --with bar doc-append ...",
  hasCommandHead("uv run --with foo --with bar doc-append docs/history.md", docAppend),
  true
);
check(
  "uv run --no-project doc-append ... (boolean flag)",
  hasCommandHead("uv run --no-project doc-append docs/history.md", docAppend),
  true
);
check(
  "uv run --isolated --frozen doc-append ...",
  hasCommandHead("uv run --isolated --frozen doc-append docs/history.md", docAppend),
  true
);
check(
  "uv run -- doc-append ... (-- separator)",
  hasCommandHead("uv run -- doc-append docs/history.md", docAppend),
  true
);
check(
  "uv run --with foo -- doc-append ...",
  hasCommandHead("uv run --with foo -- doc-append docs/history.md", docAppend),
  true
);

// ============================================================================
// uv run peeling — module/script forms
// ============================================================================
{
  const m = (t) => t[0] === "foo";
  check(
    "uv run --module foo",
    hasCommandHead("uv run --module foo", m),
    true
  );
  check(
    "uv run -m foo",
    hasCommandHead("uv run -m foo", m),
    true
  );
}
{
  const m = (t) => t[0] === "script.py";
  check(
    "uv run --script script.py",
    hasCommandHead("uv run --script script.py", m),
    true
  );
  check(
    "uv run script.py (plain positional)",
    hasCommandHead("uv run script.py", m),
    true
  );
}

// ============================================================================
// uv run peeling — empty/degenerate
// ============================================================================
check(
  "uv run alone (no head)",
  hasCommandHead("uv run", docAppend),
  false
);
check(
  "uv run --with foo (flag consumes last token)",
  hasCommandHead("uv run --with foo", docAppend),
  false
);

// ============================================================================
// bash -c recursion
// ============================================================================
check(
  "bash -c 'doc-append ...'",
  hasCommandHead("bash -c 'doc-append docs/history.md'", docAppend),
  true
);
check(
  "bash -lc 'doc-append ...'",
  hasCommandHead("bash -lc 'doc-append docs/history.md'", docAppend),
  true
);
check(
  'sh -c "doc-append ..."',
  hasCommandHead('sh -c "doc-append docs/history.md"', docAppend),
  true
);
{
  // No -c flag — bash is the head, matcher sees ["bash", ...]
  const m = (t) => t[0] === "bash";
  check(
    "bash 'doc-append ...' (no -c flag) → head=bash",
    hasCommandHead("bash 'doc-append docs/history.md'", m),
    true
  );
  // doc-append matcher should NOT match (head=bash)
  check(
    "bash 'doc-append ...' (no -c flag) → not doc-append",
    hasCommandHead("bash 'doc-append docs/history.md'", docAppend),
    false
  );
}

// ============================================================================
// Quoting / false positives
// ============================================================================
check(
  'gh issue comment --body "blah doc-append blah"',
  hasCommandHead('gh issue comment --body "blah doc-append blah"', docAppend),
  false
);
check(
  "echo 'doc-append'",
  hasCommandHead("echo 'doc-append'", docAppend),
  false
);
check(
  'echo "$(doc-append ...)" (outer head is echo)',
  hasCommandHead('echo "$(doc-append docs/history.md)"', docAppend),
  false
);

// ============================================================================
// Segment splitting
// ============================================================================
check(
  "true && doc-append ...",
  hasCommandHead("true && doc-append docs/history.md", docAppend),
  true
);
check(
  "doc-append ... || true",
  hasCommandHead("doc-append docs/history.md || true", docAppend),
  true
);
check(
  "false ; doc-append ...",
  hasCommandHead("false ; doc-append docs/history.md", docAppend),
  true
);
check(
  "cat foo | doc-append ...",
  hasCommandHead("cat foo | doc-append docs/history.md", docAppend),
  true
);

// ============================================================================
// Consecutive-token matcher (for gh issue close)
// ============================================================================
check(
  "gh issue close 123",
  hasCommandHead("gh issue close 123", ghIssueClose),
  true
);
check(
  'gh issue comment --body "issue close 123"',
  hasCommandHead('gh issue comment --body "issue close 123"', ghIssueClose),
  false
);

// ============================================================================
// Composition
// ============================================================================
check(
  "FOO=1 uv run doc-append ...",
  hasCommandHead("FOO=1 uv run doc-append docs/history.md", docAppend),
  true
);
check(
  "bash -c 'uv run doc-append ...' (recurse then peel)",
  hasCommandHead("bash -c 'uv run doc-append docs/history.md'", docAppend),
  true
);

// ============================================================================
// Edge cases
// ============================================================================
check(
  "empty command",
  hasCommandHead("", docAppend),
  false
);
check(
  "whitespace-only command",
  hasCommandHead("   ", docAppend),
  false
);
{
  // python is NOT in launcher allowlist — matcher receives ["python", ...]
  const m = (t) => t[0] === "python";
  check(
    "python doc-append.py (python not a launcher) → head=python",
    hasCommandHead("python doc-append.py", m),
    true
  );
  check(
    "python doc-append.py (python not a launcher) → not doc-append",
    hasCommandHead("python doc-append.py", docAppend),
    false
  );
}

console.log("");
console.log("=== Summary ===");
console.log("Passed: " + passed);
console.log("Failed: " + failed);
if (failed > 0) process.exit(1);
