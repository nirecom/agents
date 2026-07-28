# tests/unit-quote-spans/edges.sh
# Tests: hooks/lib/quote-spans/scan.js, hooks/lib/quote-spans/query.js
# Tags: hook, quote-spans, parser, unit, edge-cases, security, scope:common
#
# STATUS: RED until C1 lands — every row fails with
# `ERROR: require quote-spans.js: Cannot find module ...`.
#
# Sourced by tests/unit-quote-spans.sh. String-level edge coverage:
#   - non-string / null / undefined scanner inputs (must not throw; must be
#     fail-closed, because a hook that throws is a hook that stops guarding)
#   - trailing lone backslashes at end-of-string and at end-of-span
#   - very long deeply-nested input (no stack overflow, no quadratic blowup)
#   - Unicode and astral-plane characters in span bodies (offsets are UTF-16
#     code-unit indices, so a surrogate pair must not shift a span boundary)

run_edge_cases() {

    # ── non-string inputs: never throw, always fail-closed ───────────────────
    # `ok=false` + an empty span list + failReason "exception" is the documented
    # degenerate-input shape. "" is the one legal non-throwing empty case.
    assert_eq "EDGE-badinput-null"      'ok=false,spans=0,reason=exception' "$(probe badinput null)"
    assert_eq "EDGE-badinput-undefined" 'ok=false,spans=0,reason=exception' "$(probe badinput undefined)"
    assert_eq "EDGE-badinput-number"    'ok=false,spans=0,reason=exception' "$(probe badinput number)"
    assert_eq "EDGE-badinput-object"    'ok=false,spans=0,reason=exception' "$(probe badinput object)"
    assert_eq "EDGE-badinput-array"     'ok=false,spans=0,reason=exception' "$(probe badinput array)"
    assert_eq "EDGE-badinput-bool"      'ok=false,spans=0,reason=exception' "$(probe badinput bool)"
    # Anti-vacuity: the empty STRING is valid input and must scan cleanly.
    assert_eq "EDGE-badinput-empty-ok"  'ok=true,spans=0,reason=undefined'  "$(probe badinput empty)"

    # The predicate API on the same degenerate inputs answers on the danger
    # side (single error contract), rather than propagating a TypeError.
    assert_eq "EDGE-badpred-null"      'test=true,find=0,unclosed=true' "$(probe badpredicate null)"
    assert_eq "EDGE-badpred-undefined" 'test=true,find=0,unclosed=true' "$(probe badpredicate undefined)"
    assert_eq "EDGE-badpred-number"    'test=true,find=0,unclosed=true' "$(probe badpredicate number)"
    assert_eq "EDGE-badpred-object"    'test=true,find=0,unclosed=true' "$(probe badpredicate object)"
    # ...and the empty string is a clean miss, not danger.
    assert_eq "EDGE-badpred-empty"     'test=false,find=-1,unclosed=false' "$(probe badpredicate empty)"

    # ── trailing lone backslash ──────────────────────────────────────────────
    # A `\` as the final character has nothing to escape. It must not consume
    # the end-of-string sentinel and silently swallow an unterminated quote —
    # that would turn a fail-closed input into a fail-open one.
    run_table <<'TABLE'
EDGE-bs-trailing-unquoted-ok  |a b\        |ok       | |true
EDGE-bs-trailing-in-dq-open   |"a b\       |ok       | |false
EDGE-bs-trailing-in-dq-kinds  |"a b\       |failkinds| |dq
EDGE-bs-trailing-in-sq-open   |'a b\       |ok       | |false
EDGE-bs-trailing-in-sq-kinds  |'a b\       |failkinds| |sq
EDGE-bs-escaped-quote-open    |a \" b      |ok       | |true
EDGE-bs-double-then-quote     |a \\" b     |ok       | |false
EDGE-bs-sq-no-escapes         |'a\'        |ok       | |true
EDGE-bs-sq-no-escapes-count   |'a\'        |count    |sq|1
EDGE-bs-dq-escaped-dq-count   |"a\"b"      |count    |dq|1
EDGE-bs-dq-escaped-dq-end     |"a\"b"      |spanfield|dq 0 end|6
EDGE-bs-trailing-after-span   |"ab" \      |ok       | |true
EDGE-bs-only                  |\           |ok       | |true
EDGE-bs-only-two              |\\          |ok       | |true
TABLE

    # The searched-for token after a trailing backslash is still findable —
    # i.e. the backslash handling must not truncate the scan.
    run_table <<'TABLE'
EDGE-bs-find-after     |a\ b rm     |find|rm|5
EDGE-bs-find-escaped   |a\ rm       |find|rm|3
TABLE

    # ── very long, deeply nested input ───────────────────────────────────────
    # Built inside Node (bash argv cannot carry it safely). Each level is
    # `$(echo "` … `")`, so depth D yields 2*D spans and must stay ok:true.
    assert_eq "EDGE-longnest-64"   'ok=true,spans=128'  "$(probe longnest 64)"
    assert_eq "EDGE-longnest-256"  'ok=true,spans=512'  "$(probe longnest 256)"
    assert_eq "EDGE-longnest-1000" 'ok=true,spans=2000' "$(probe longnest 1000)"

    # ── Unicode / astral plane ───────────────────────────────────────────────
    # Offsets are UTF-16 code-unit indices. A 2-unit surrogate pair inside a dq
    # body must move the closing quote by 2, not by 1 — a naive
    # code-point-based index would silently misplace every later span.
    assert_probe "EDGE-uni-bmp-end"     '"日本語" x'    spanfield 'dq 0 end' 5
    assert_probe "EDGE-uni-bmp-inner"   '"日本語" x'    innertext 'dq 0'     '日本語'
    assert_probe "EDGE-uni-astral-end"  '"a𝕏b" x'      spanfield 'dq 0 end' 6
    assert_probe "EDGE-uni-astral-text" '"a𝕏b" x'      innertext 'dq 0'     'a𝕏b'
    assert_probe "EDGE-uni-emoji-count" '"a👍b" c "d"' count     'dq'        2
    assert_probe "EDGE-uni-find-after"  '"日本" rm'     find      'rm'        5
    # Combining marks and zero-width joiners are ordinary body characters.
    assert_probe "EDGE-uni-zwj-ok"      '"👨‍👩‍👦" x'   ok        ''          true
}
