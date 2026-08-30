#!/bin/bash
# tests/feature-workflow-init-driver/driver-issue-comments/_lib.sh — shared helper library, NOT a test file.
# Tests: bin/workflow/workflow-init-driver, bin/workflow/lib/workflow-init/phases/fetch-issues.js, bin/workflow/lib/workflow-init/phases/write-context.js, bin/workflow/lib/workflow-init/issue-comments.js, bin/workflow/lib/workflow-init/checkpoint.js
# Tags: workflow-init, driver, issue-comments, fetch-issues, write-context, sentinel-strip, prompt-injection, scope:issue-specific
# Source from sibling group files: . "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
# Injection seams the driver MUST honor (SSOT): ../HARNESS-CONTRACT.md

set -u

# The driver-suite harness (setup_case/run_driver/assert_ckpt/...) comes first;
# everything below narrows it to the #2063 comments observables.
. "$(dirname "${BASH_SOURCE[0]}")/../_lib.sh"

# --- local helpers ------------------------------------------------------------
ctx_file() { printf '%s' "$PLANS/$SID-context.md"; }

# The issue's own body is the third surface the shared stripSentinels serves (#2063
# S2), and `mock_issue` hardcodes it, so the corruption seam for it lives here beside
# the comments one. The text travels in the environment: a body may legitimately begin
# with `-`, which node would read as its own option.
mock_issue_body() {  # <N> <body-text> — replaces the fixture's body verbatim
    WID_BODY_IN="$2" node -e '
const fs = require("fs");
const p = process.argv[1];
const o = JSON.parse(fs.readFileSync(p, "utf8"));
o.body = process.env.WID_BODY_IN || "";
fs.writeFileSync(p, JSON.stringify(o) + "\n");
' "$RESP/issue-view-$1.json"
}

# `mock_issue` builds `labels` from a COMMA-separated list, so it can express neither a
# label carrying a comma nor one carrying a line terminator — the two shapes the
# `labels:` line of context.md is rendered from. This seam replaces the `labels` VALUE
# with raw JSON, the same way `mock_issue_comments` replaces `comments`, so a label can
# be given verbatim. GitHub label names admit `<`, `>` and `:`, so a sentinel-shaped
# label is a real payload, not a hypothetical one (#2063 C3).
mock_issue_labels() {  # <N> <labels-json>
    node -e '
const fs = require("fs");
const p = process.argv[1];
const o = JSON.parse(fs.readFileSync(p, "utf8"));
o.labels = JSON.parse(process.argv[2]);
fs.writeFileSync(p, JSON.stringify(o) + "\n");
' "$RESP/issue-view-$1.json" "$2"
}

count_issue_view() {  # <N> — `gh issue view <N> ...` invocations for THAT issue only
    count_gh_calls "^issue view $1( |\$)"
}

assert_ctx_has() {  # <label> <fixed-string>
    local f
    f="$(ctx_file)"
    if [ -f "$f" ] && grep -qF -- "$2" "$f"; then
        pass "$1"
    else
        fail "$1: '$2' absent from $f"
    fi
}

assert_ctx_lacks() {  # <label> <fixed-string>
    local f
    f="$(ctx_file)"
    if [ ! -f "$f" ]; then
        fail "$1: context.md missing at $f"
    elif grep -qF -- "$2" "$f"; then
        fail "$1: '$2' leaked into $f"
    else
        pass "$1"
    fi
}

assert_ctx_count() {  # <label> <ERE> <want-count>
    local f got
    f="$(ctx_file)"
    if [ ! -f "$f" ]; then
        fail "$1: context.md missing at $f"
        return
    fi
    got="$(grep -Ec -- "$2" "$f" || true)"
    if [ "$got" = "$3" ]; then pass "$1"; else fail "$1: want $3 match(es) for /$2/, got $got"; fi
}

# A "this must NOT appear" assertion is satisfied by a context.md that rendered no
# comments at all, so the injection cases route their negatives through these two:
# without a rendered comments section the assertion is reported unmet, never met.
comments_rendered() {
    local f
    f="$(ctx_file)"
    [ -f "$f" ] || return 1
    grep -qE '^### Comment [0-9]+ — ' "$f"
}
assert_ctx_count_live() {  # <label> <ERE> <want-count> — gated on a rendered section
    if ! comments_rendered; then
        fail "$1: no comments section was rendered — the assertion is unfalsifiable"
        return
    fi
    assert_ctx_count "$1" "$2" "$3"
}
assert_ctx_lacks_live() {  # <label> <fixed-string> — gated on a rendered section
    if ! comments_rendered; then
        fail "$1: no comments section was rendered — the assertion is unfalsifiable"
        return
    fi
    assert_ctx_lacks "$1" "$2"
}

assert_count() {  # <label> <want> <got>
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1: want $2, got $3"; fi
}

# grep ends a line at LF and nothing else, so a payload that breaks its line with
# U+0085 / U+2028 / U+2029 never reaches "line start" for `assert_ctx_count_live`: the
# count comes back 0 and the negative passes with the renderer having neutralized
# nothing. Markdown renderers, editors and JS string APIs do treat those as line ends,
# so these two re-split on every Unicode line terminator — the boundary a downstream
# reader actually sees — and are the only correct form for such a payload.
uni_lines() {  # context.md re-split on every Unicode line terminator, one per LF line
    node -e '
const fs = require("fs");
const p = process.argv[1];
if (!fs.existsSync(p)) process.exit(0);
const t = fs.readFileSync(p, "utf8");
process.stdout.write(t.split(/\r\n|[\n\r\u0085\u2028\u2029]/).join("\n"));
' "$(ctx_file)"
}
assert_ctx_count_uni_live() {  # <label> <ERE> <want-count> — gated on a rendered section
    local got
    if ! comments_rendered; then
        fail "$1: no comments section was rendered — the assertion is unfalsifiable"
        return
    fi
    got="$(uni_lines | grep -Ec -- "$2" || true)"
    if [ "$got" = "$3" ]; then
        pass "$1"
    else
        fail "$1: want $3 match(es) for /$2/ across Unicode line breaks, got $got"
    fi
}

# `(none)` is NOT unique to the comments section — context.md writes it for an empty
# user prompt and an empty keyword list too. A file-wide "must not contain (none)"
# therefore fails on a correctly rendered file and can only ever pass by accident, so
# every such assertion is scoped to the section that owns the claim.
ctx_section() {  # <exact '## ' heading> — that heading through the line before the next '## '
    local f
    f="$(ctx_file)"
    if [ ! -f "$f" ]; then printf '<<NO-CONTEXT-MD>>'; return 0; fi
    node -e '
const fs = require("fs");
const lines = fs.readFileSync(process.argv[1], "utf8").split("\n");
const i = lines.indexOf(process.argv[2]);
if (i < 0) { process.stdout.write("<<SECTION-NOT-FOUND>>"); process.exit(0); }
let j = i + 1;
while (j < lines.length && !/^## /.test(lines[j])) j++;
const sec = lines.slice(i, j);
while (sec.length && sec[sec.length - 1] === "") sec.pop();
process.stdout.write(sec.join("\n"));
' "$f" "$1"
}
comments_section() { ctx_section '## Issue comments'; }
assert_section_eq() {  # <label> <want-whole-section>
    local got
    got="$(comments_section)"
    if [ "$got" = "$2" ]; then pass "$1"; else fail "$1: section is [$got] not [$2]"; fi
}
# The heading counts above name the forgeries they expect; this one needs no list. The
# comments section may hold exactly three shapes — its own `## `/`### ` structure, a
# blank line, and blockquoted comment text — so ANY other line, at any Unicode line
# boundary, is untrusted text that escaped the blockquote. Section extraction stays
# LF-based on purpose: only a real heading ends the section, never a forged one.
assert_comments_uni_quoted() {  # <label>
    local sec bad
    if ! comments_rendered; then
        fail "$1: no comments section was rendered — the assertion is unfalsifiable"
        return
    fi
    sec="$(comments_section)"
    bad="$(WID_SEC_IN="$sec" node -e '
const lines = (process.env.WID_SEC_IN || "").split(/\r\n|[\n\r\u0085\u2028\u2029]/);
const ok = (l) => l === "" || l.indexOf("> ") === 0 ||
  /^## Issue comments$/.test(l) || /^### Comment [0-9]+ — /.test(l);
const off = lines.filter((l) => !ok(l));
process.stdout.write(off.length ? off[0].slice(0, 160) : "");
')"
    if [ -z "$bad" ]; then
        pass "$1"
    else
        fail "$1: a comments-section line is neither structure nor blockquote: [$bad]"
    fi
}

assert_section_lacks() {  # <label> <fixed-string>
    local sec
    sec="$(comments_section)"
    case "$sec" in
        '<<NO-CONTEXT-MD>>'|'<<SECTION-NOT-FOUND>>')
            fail "$1: no '## Issue comments' section was rendered — the assertion is unfalsifiable" ;;
        *"$2"*)
            fail "$1: '$2' present in the comments section: [$(printf '%s' "$sec" | head -c 200)]" ;;
        *)
            pass "$1" ;;
    esac
}
