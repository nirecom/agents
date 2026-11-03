#!/usr/bin/env bash
# tests/bin/unit-render-final-report-notes.sh
# Tests: bin/render-final-report/notes.js, hooks/stop-final-report-guard.js
# Tags: final-report, worktree-notes, compression, severity, table-driven, TL1, scope:common
# notes.js decides how much of WORKTREE_NOTES.md reaches the Final Report (#1886): under-compression
# dumps everything (CPR-UO); over-compression drops a severity:high entry's evidence. Entry lines are
# pinned exactly, with the `[issue-TBD] ` / `#N ` head (#2904); the backup pointer is pinned by count only.
# sanitizeTokens keeps `<TOKEN>` bodies from tripping stop-final-report-guard.js; drift asserted below.
# TL1: the module is pure (no fs / no child_process), required in-process by node.

set -u

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
nodepath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi; }
MOD_JS="$SCRIPT_CHECKOUT_ROOT/bin/render-final-report/notes.js"
GUARD_JS="$SCRIPT_CHECKOUT_ROOT/hooks/stop-final-report-guard.js"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; [ -n "${2:-}" ] && echo "    detail: $2"; FAIL=$((FAIL + 1)); }

TMPD="$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/rfr-notes-$$")"
mkdir -p "$TMPD"
trap 'rm -rf "$TMPD"' EXIT

cat > "$TMPD/run-cases.js" <<'JS'
"use strict";
const mod = require(process.argv[2]);
const {
  compressNotesSections,
  sanitizeTokens,
  titleLine,
  TITLE_MAX_CHARS,
  COMPRESSED_LIST_MAX,
} = mod;

const P = "/bk/notes.md";
const CRLF = (s) => s.replace(/\n/g, "\r\n");
const doc = (body) => `# Worktree Notes\n\n## BugsFound\n${body}\n`;
const bugs = (body, opts) =>
  compressNotesSections(doc(body), opts === undefined ? { backupPath: P } : opts).BugsFound;
const repeat = (s, n) => new Array(n + 1).join(s);
const first = (out) => { const l0 = out.split("\n")[0]; return `${Array.from(l0).length}:${l0.endsWith("…")}`; };
// view(out): entry lines, then `#ptr=<backup pointer line count>`; `#compressed` flags a legacy summary (#2904).
const isPtr = (l) => l.includes("full text: ");
const view = (out) => `${out.split("\n").filter((l) => !isPtr(l)).join("\n")}#ptr=${out.split("\n").filter(isPtr).length}${out.includes("compressed:") ? "#compressed" : ""}`;

const CASES = {
  // --- severity:high is preserved verbatim -------------------------------
  "high-only": () => bugs("- boom <!-- severity: high -->"),

  "no-truncate-high": () => first(bugs(`- ${repeat("x", 200)} <!-- severity: high -->`)),

  // --- untagged entries compress to a title line + one summary line ------
  "untagged-three": () => view(bugs("- a\n- b\n- c")),

  "mixed-order": () => view(bugs("- u1\n- h1 <!-- severity: high -->\n- u2")),

  // The point of the whole change: output line length is bounded by a constant,
  // not by input length.
  "truncate-untagged": () => first(bugs(`- ${repeat("x", 200)}`)),

  "cap-ten-of-fifteen": () => {
    const body = [];
    for (let i = 1; i <= 15; i += 1) body.push(`- entry ${i}`);
    const lines = bugs(body.join("\n")).split("\n");
    return `${lines.length}:${isPtr(lines[lines.length - 1])}:${view(lines.join("\n")).endsWith("#ptr=1")}`;
  },

  // Truncation is code-point safe: never split a surrogate pair in half.
  // (Grapheme-cluster safety is explicitly out of scope — N6.)
  "surrogate-safe": () => {
    const l0 = bugs(`- ${repeat("😀", 200)}`).split("\n")[0];
    const stripped = l0.replace(/[\uD800-\uDBFF][\uDC00-\uDFFF]/g, "");
    return `${Array.from(l0).length}:${/[\uD800-\uDFFF]/.test(stripped)}`;
  },

  // --- fail-safe: anything not in canonical form compresses --------------
  "reversed-marker-compressed": () => {
    const out = bugs("- boom <!-- promoted: #12 --> <!-- severity: high -->");
    return `${out.includes("<!--")}:${out.split("\n")[0]}`;
  },

  "malformed-all-compressed": () => {
    const lines = bugs([
      "- a <!--severity: high-->",
      "- b <!-- Severity: High -->",
      "- c <!-- severity:high -->",
      "- d <!-- severity: HIGH -->",
      "- e <!-- severity: medium -->",
    ].join("\n")).split("\n");
    return `${lines.length}:${lines.some(isPtr)}:${lines.some((l) => l.includes("<!--"))}`;
  },

  // --- empty / missing --------------------------------------------------
  "section-missing": () => compressNotesSections("# Worktree Notes\n", { backupPath: P }).BugsFound,
  "section-placeholder-only": () => bugs("- (none)"),
  "section-empty": () =>
    compressNotesSections("## BugsFound\n\n## RelatedTasks\n- x\n", { backupPath: P }).BugsFound,

  // A trailing space on the heading must not silently blank the section.
  "heading-trailing-space": () =>
    compressNotesSections("# Worktree Notes\n\n## BugsFound \n- a\n- b\n- c\n", { backupPath: P })
      .BugsFound.split("\n").length,

  // --- summary-line parts ------------------------------------------------
  "stray-lines": () => view(bugs("- e1\nprose one\nprose two")),

  // `### ` truncates the section: the entries after it are LOST, not merely
  // compressed, so the summary line must fire even with zero compressed entries.
  "sub-heading-truncation": () => view(bugs("### Repro\n- after <!-- severity: high -->")),
  "sub-heading-after-entry": () =>
    view(bugs("- e1 <!-- severity: high -->\n### Repro\n- lost <!-- severity: high -->")),

  "backup-path-missing": () => { const o = bugs("- a\nprose", {}); return `${view(o)}:${o.split("\n").filter(isPtr).every((l) => l.includes("full text: (none)"))}`; },

  // --- token sanitization (Stop-hook survival) ---------------------------
  "sanitize-high": () => bugs("- boom <BUGS_FOUND> here <!-- severity: high -->"),
  "sanitize-compressed": () => {
    const out = bugs("- x <PR_NUMBER> y");
    return `${/<[A-Z][A-Z0-9_]+>/.test(out)}:${out.split("\n")[0]}`;
  },
  "sanitize-sub-heading": () => { const o = bugs("### Repro <BUGS_FOUND>"); return `${/<[A-Z][A-Z0-9_]+>/.test(o)}:${view(o)}`; },
  // Both ends escaped, and no over-escaping of non-token angle brackets.
  "sanitize-tokens-direct": () => sanitizeTokens("<Foo> <AB> <A> <A_B1>"),

  // --- shape / cross-section --------------------------------------------
  "section-keys": () =>
    Object.keys(compressNotesSections(doc("- a"), { backupPath: P })).sort().join(","),
  "other-sections-compressed": () => {
    const r = compressNotesSections(
      "## RelatedTasks\n- r1\n- r2\n\n## NextTasks\n- n1\n", { backupPath: P });
    return `${r.RelatedTasks.split("\n").length}:${r.NextTasks.split("\n").length}`;
  },
  "crlf-equals-lf": () => {
    const body = "- a\n- b <!-- severity: high -->\nprose\n";
    const lf = compressNotesSections(doc(body), { backupPath: P }).BugsFound;
    const crlf = compressNotesSections(CRLF(doc(body)), { backupPath: P }).BugsFound;
    return String(lf === crlf);
  },

  // --- titleLine / constants --------------------------------------------
  "titleline-collapse": () => titleLine("  a   b  "),
  "titleline-boundary": () => {
    const at = titleLine(repeat("x", TITLE_MAX_CHARS));
    const over = titleLine(repeat("x", TITLE_MAX_CHARS + 1));
    return [
      Array.from(at).length, at.endsWith("…"),
      Array.from(over).length, over.endsWith("…"),
    ].join(":");
  },
  "constants": () => `${TITLE_MAX_CHARS}:${COMPRESSED_LIST_MAX}`,
};

for (const [name, fn] of Object.entries(CASES)) {
  let out;
  try { out = String(fn()); } catch (e) { out = "THREW:" + e.message; }
  process.stdout.write(name + "|" + out.replace(/\n/g, "~") + "\n");
}
JS

if [ ! -f "$MOD_JS" ]; then
    fail "precondition: bin/render-final-report/notes.js is missing" "expected at $MOD_JS"
    REAL_OUT=""
else
    REAL_OUT="$(node "$(nodepath "$TMPD/run-cases.js")" "$(nodepath "$MOD_JS")" 2>&1)"
fi

result_of() { printf '%s\n' "$REAL_OUT" | grep "^$1|" | head -1 | cut -d'|' -f2-; }

check_table() {
    local name want got
    while IFS='|' read -r name want; do
        [ -z "$name" ] && continue
        case "$name" in \#*) continue ;; esac
        got="$(result_of "$name")"
        if [ "$got" = "$want" ]; then
            pass "$name → $want"
        else
            fail "$name" "got=[$got] want=[$want]"
        fi
    done <<'TABLE'
high-only|- [issue-TBD] boom
no-truncate-high|214:false
untagged-three|- [issue-TBD] a~- [issue-TBD] b~- [issue-TBD] c#ptr=0
mixed-order|- [issue-TBD] h1~- [issue-TBD] u1~- [issue-TBD] u2#ptr=0
truncate-untagged|135:true
cap-ten-of-fifteen|11:true:true
surrogate-safe|135:false
reversed-marker-compressed|false:- [issue-TBD] boom
malformed-all-compressed|5:false:false
section-missing|(none)
section-placeholder-only|(none)
section-empty|(none)
heading-trailing-space|3
stray-lines|- [issue-TBD] e1#ptr=1
sub-heading-truncation|#ptr=1
sub-heading-after-entry|- [issue-TBD] e1#ptr=1
backup-path-missing|- [issue-TBD] a#ptr=1:true
sanitize-high|- [issue-TBD] boom &lt;BUGS_FOUND&gt; here
sanitize-compressed|false:- [issue-TBD] x &lt;PR_NUMBER&gt; y
sanitize-sub-heading|false:#ptr=1
sanitize-tokens-direct|<Foo> &lt;AB&gt; <A> &lt;A_B1&gt;
section-keys|BugsFound,NextTasks,RelatedTasks
other-sections-compressed|2:1
crlf-equals-lf|true
titleline-collapse|a b
titleline-boundary|120:false:121:true
constants|120:10
TABLE
}

# ---------------------------------------------------------------------------
# Source-level invariants. These are grep assertions on purpose: they pin
# properties of the module that no runtime case can observe.
# ---------------------------------------------------------------------------

# The module must declare ZERO named regex constants (C12). bin/mutation-probe.sh
# only mutates single-line `const NAME = /…/;` declarations, so a named constant
# here would silently be an untested regex. Adding one means adding probe
# coverage in the same change — this assertion is the reminder.
test_no_named_regex_constants() {
    if [ ! -f "$MOD_JS" ]; then
        fail "no-named-regex-constants: module missing" "$MOD_JS"
        return
    fi
    local hits
    hits="$(grep -nE '^[[:space:]]*const [A-Za-z_][A-Za-z0-9_]* = /' "$MOD_JS" || true)"
    if [ -z "$hits" ]; then
        pass "no-named-regex-constants: module declares 0 named regex constants"
    else
        fail "no-named-regex-constants: named regex constant(s) added without mutation-probe coverage" "$hits"
    fi
}

# Critical-path purity (intent Constraints): this module runs inside the Stop
# hook's path. No subprocesses, no network, no LLM delegation — ever.
test_critical_path_purity() {
    if [ ! -f "$MOD_JS" ]; then
        fail "critical-path-purity: module missing" "$MOD_JS"
        return
    fi
    local hits
    hits="$(grep -nE 'child_process|spawnSync|execSync|codex|fetch|https' "$MOD_JS" || true)"
    if [ -z "$hits" ]; then
        pass "critical-path-purity: no child_process/spawnSync/execSync/codex/fetch/https"
    else
        fail "critical-path-purity: forbidden reference in a Stop-hook-path module" "$hits"
    fi
}

# SSOT drift detector (N4). hooks/stop-final-report-guard.js owns the token
# pattern; the module's inline literal is a subordinate copy. If the guard's
# pattern widens and this copy does not, a Final Report containing the newly
# matched token blocks the session; if it narrows, we over-escape. Neither is
# visible at runtime, so compare the two source literals directly. The only
# permitted difference is the module's capture parentheses.
test_guard_pattern_no_drift() {
    if [ ! -f "$MOD_JS" ] || [ ! -f "$GUARD_JS" ]; then
        fail "guard-pattern-no-drift: source missing" "mod=$MOD_JS guard=$GUARD_JS"
        return
    fi
    local guard_lines guard_count guard_pat mod_lines mod_count mod_pat guard_norm mod_norm
    guard_lines="$(grep -E 'const tokenRegex = /' "$GUARD_JS" || true)"
    guard_count="$(printf '%s' "$guard_lines" | grep -c . || true)"
    if [ "$guard_count" != "1" ]; then
        fail "guard-pattern-no-drift: expected exactly 1 tokenRegex definition in guard" "count=$guard_count lines=$guard_lines"
        return
    fi
    guard_pat="$(printf '%s' "$guard_lines" | sed -E 's#^.*const tokenRegex = /(.*)/g;.*$#\1#')"

    mod_lines="$(grep -oE '/<[^/]*>/g' "$MOD_JS" || true)"
    mod_count="$(printf '%s' "$mod_lines" | grep -c . || true)"
    if [ "$mod_count" != "1" ]; then
        fail "guard-pattern-no-drift: expected exactly 1 token pattern literal in the module" "count=$mod_count lines=$mod_lines"
        return
    fi
    mod_pat="$(printf '%s' "$mod_lines" | sed -E 's#^/(.*)/g$#\1#')"

    guard_norm="$(printf '%s' "$guard_pat" | tr -d '()')"
    mod_norm="$(printf '%s' "$mod_pat" | tr -d '()')"

    if [ "$guard_norm" = "$mod_norm" ] && [ "$guard_norm" = '<[A-Z][A-Z0-9_]+>' ]; then
        pass "guard-pattern-no-drift: module literal matches guard tokenRegex ($guard_norm)"
    else
        fail "guard-pattern-no-drift: token pattern drifted between guard and module" "guard=[$guard_pat] module=[$mod_pat]"
    fi
}

check_table
test_no_named_regex_constants
test_critical_path_purity
test_guard_pattern_no_drift

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $((FAIL > 0 ? 1 : 0))
