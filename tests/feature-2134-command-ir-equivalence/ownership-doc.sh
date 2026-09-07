#!/usr/bin/env bash
# tests/feature-2134-command-ir-equivalence/ownership-doc.sh
# Tests: docs/architecture/claude-code/shell-command-parsing.md, hooks/lib/command-parser.js, hooks/lib/shell-segments.js, hooks/lib/command-ir.js
# Tags: hook, command-ir, equivalence, ownership-map, docs-sync, TL1, scope:issue-specific
#
# Checks whether the ownership map (the consumer list for the three module families) matches
# the repo's actual require() reality -- the sole mechanical guard against the doc silently
# going stale (detail.md S2-10).
# EXPECTED NON-GREEN UNTIL STEP 2: the doc under test is a Step 2 deliverable, absent at Step 1,
# so d01-d03 FAIL with <MISSING:...> until then -- intentional red, not SKIP, so nobody stops
# noticing even if the doc never lands.

set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENTS_DIR="$(cd "$DIR/../.." && pwd)"

command -v node >/dev/null 2>&1 || { echo "SKIP: node not found"; exit 77; }

# Fixture isolation (rules/test/fixture-isolation.md): read-only, but the parent session's id
# must always be dropped -- the child node inheriting it could touch real session state.
unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID

npath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
AGENTS_N="$(npath "$AGENTS_DIR")"
RUNNER="$AGENTS_DIR/bin/run-with-timeout.sh"

DOC_REL="docs/architecture/claude-code/shell-command-parsing.md"
DOC="$AGENTS_DIR/$DOC_REL"

PASS=0; FAIL=0; ROWS=0
assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then echo "PASS: $name"; PASS=$((PASS + 1))
    else echo "FAIL: $name"; echo "    want: $want"; echo "    got:  $got"; FAIL=$((FAIL + 1)); fi
}

# Scans only production code (a require() under tests/ is the test's own concern, not a
# consumer the ownership map should list). Returns a sorted set "a.js,b.js,...".
scan_requirers() { # <module-basename>
    bash "$RUNNER" 60 node -e '
      const fs = require("fs");
      const path = require("path");
      const root = process.argv[1];
      const mod = process.argv[2];
      const ROOTS = ["hooks", "bin", "install", "lib"];
      const found = [];
      const re = new RegExp("require\\([^)]*[\"\x27][^\"\x27]*/" + mod + "[\"\x27]\\)");
      const walk = (abs) => {
        let ents;
        try { ents = fs.readdirSync(abs, { withFileTypes: true }); } catch (e) { return; }
        for (const ent of ents) {
          const p = path.join(abs, ent.name);
          if (ent.isDirectory()) {
            if (ent.name === "node_modules" || ent.name === ".git" || ent.name === "_archive") continue;
            walk(p);
          } else if (ent.isFile() && ent.name.endsWith(".js")) {
            let src;
            try { src = fs.readFileSync(p, "utf8"); } catch (e) { continue; }
            if (re.test(src)) found.push(path.relative(root, p).split(path.sep).join("/"));
          }
        }
      };
      for (const r of ROOTS) walk(path.join(root, r));
      process.stdout.write(found.sort().join(","));
    ' "$AGENTS_N" "$1" 2>/dev/null
}

# Returns the `...js` paths listed in the doc's marker section as a sorted set.
# Returns <MISSING:...> if the doc is absent, <NO-MARKER:...> if the marker is absent -- so a
# missing element always shows up as a distinct string on the got side, never as a green "it
# matched the empty set".
doc_listed() { # <marker-name>
    bash "$RUNNER" 30 node -e '
      const fs = require("fs");
      const docPath = process.argv[1];
      const rel = process.argv[2];
      const name = process.argv[3];
      const out = (() => {
        let src;
        try { src = fs.readFileSync(docPath, "utf8"); } catch (e) { return "<MISSING:" + rel + ">"; }
        const begin = "<!-- BEGIN CONSUMERS: " + name + " -->";
        const end = "<!-- END CONSUMERS: " + name + " -->";
        const i = src.indexOf(begin);
        const j = src.indexOf(end);
        if (i === -1 || j === -1 || j < i) return "<NO-MARKER:" + name + ">";
        const body = src.slice(i + begin.length, j);
        const paths = new Set();
        const re = /`([A-Za-z0-9_./-]+\.js)`/g;
        let m;
        while ((m = re.exec(body)) !== null) paths.add(m[1]);
        return Array.from(paths).sort().join(",");
      })();
      process.stdout.write(out);
    ' "$(npath "$DOC")" "$DOC_REL" "$1" 2>/dev/null
}

CP_ACTUAL="$(scan_requirers "command-parser")"
SS_ACTUAL="$(scan_requirers "shell-segments")"

# Harness self-check: with the scanner finding nothing, the set comparison below would
# unconditionally go green on "empty == empty". Naming a consumer known to actually exist
# closes off that false green.
ROWS=$((ROWS + 1))
case ",$CP_ACTUAL," in
  *",hooks/block-dotenv.js,"*) echo "PASS: h01-scanner: command-parser requirers detected"; PASS=$((PASS + 1)) ;;
  *) echo "FAIL: h01-scanner: hooks/block-dotenv.js not detected as a command-parser requirer -- the scanner is broken, not the doc"; echo "    got: $CP_ACTUAL"; FAIL=$((FAIL + 1)) ;;
esac

ROWS=$((ROWS + 1))
case ",$SS_ACTUAL," in
  *",hooks/enforce-worktree/bash-write-scope.js,"*) echo "PASS: h02-scanner: shell-segments requirers detected"; PASS=$((PASS + 1)) ;;
  *) echo "FAIL: h02-scanner: hooks/enforce-worktree/bash-write-scope.js not detected as a shell-segments requirer -- the scanner is broken, not the doc"; echo "    got: $SS_ACTUAL"; FAIL=$((FAIL + 1)) ;;
esac

# Reconciling the doc. The SSOT is the marker section itself. Backtick-quoted `*.js` entries
# inside the section are treated as the consumer list, and a two-way match against the actual
# require() set is required (one-sided containment can't catch the "staleness" of a removed
# consumer that lingers in the doc).
DOC_PRESENT="absent"
[ -f "$DOC" ] && DOC_PRESENT="present"
ROWS=$((ROWS + 1))
assert_eq "d01-doc exists: $DOC_REL (a Step 2 deliverable -- intentional red at Step 1)" "present" "$DOC_PRESENT"

ROWS=$((ROWS + 1))
assert_eq "d02-command-parser consumers: doc matches require() reality" "$CP_ACTUAL" "$(doc_listed "command-parser")"

ROWS=$((ROWS + 1))
assert_eq "d03-shell-segments consumers: doc matches require() reality" "$SS_ACTUAL" "$(doc_listed "shell-segments")"

# Budget for the number of rows executed. Doesn't read as green even if a row disappears via an early return or a branch.
ROWS_EXPECTED=5
if [ "$ROWS" = "$ROWS_EXPECTED" ]; then
    echo "PASS: row budget: $ROWS_EXPECTED ownership rows executed"; PASS=$((PASS + 1))
else
    echo "FAIL: row budget: executed=$ROWS expected=$ROWS_EXPECTED"; FAIL=$((FAIL + 1))
fi

echo ""
echo "Total: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
