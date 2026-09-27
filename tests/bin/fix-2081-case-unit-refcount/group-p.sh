# Group P: marker parse split, D1/D2 depth handling, conformance query (#2388)
# Tests: bin/lib/test-retire-predicate.sh, bin/lib/test-retire-predicate/case-parser.sh
# Tags: TL2, retire, case-markers, scope:issue-specific
# Sourced by tests/bin/fix-2081-case-unit-refcount.sh
#
# #2388 splits the analysis phase out of trp_enumerate_cases into
# trp_parse_case_markers (no repo root, no survival) and adds a public query
# trp_marker_conformance. Fixture marker text lives only in heredoc bodies so
# this file's own markers stay the only real ones.

P_DIR="$TMPDIR_BASE/p-fixtures"
mkdir -p "$P_DIR"

# p_fx <name> — fixture body from stdin.
p_fx() {
    cat > "$P_DIR/$1"
}

# p_check <label> <fixture> <malformed> <line> <reason> <uncertain> — run the
# parse phase and compare the four diagnostic globals. An unset or 0 line is
# normalised to "" (the reset contract allows either).
p_check() {
    local label="$1" fx="$2" ln
    trp_parse_case_markers "$P_DIR/$fx"
    ln="${_TRP_MARKER_MALFORMED_LINE:-}"
    [[ "$ln" == 0 ]] && ln=""
    assert_eq "$label malformed" "$3" "${_TRP_MARKER_MALFORMED:-}"
    assert_eq "$label line" "$4" "$ln"
    assert_eq "$label reason" "$5" "${_TRP_MARKER_MALFORMED_REASON:-}"
    assert_eq "$label uncertain" "$6" "${_TRP_MARKER_UNCERTAIN:-0}"
}

# p_state <label> <fixture> <state> <line> <reason> — public conformance query.
p_state() {
    local label="$1" fx="$2" rc=0
    trp_marker_conformance "$P_DIR/$fx" || rc=$?
    assert_eq "$label rc" "0" "$rc"
    assert_eq "$label state" "$3" "${TRP_MARKER_STATE:-}"
    assert_eq "$label line" "$4" "${TRP_MARKER_LINE:-}"
    assert_eq "$label reason" "$5" "${TRP_MARKER_REASON:-}"
}

# ── Fixtures ────────────────────────────────────────────────────────────────
p_fx conforming.sh <<'EOF'
#!/usr/bin/env bash
# Tests: bin/a.sh, bin/b.sh
case_begin "alpha" "bin/a.sh"
echo a
case_end
case_begin "beta" "bin/b.sh"
echo b
case_end
EOF

p_fx none.sh <<'EOF'
#!/usr/bin/env bash
# Tests: bin/a.sh, bin/b.sh
echo no markers here
EOF

p_fx grammar.sh <<'EOF'
#!/usr/bin/env bash
# Tests: bin/a.sh, bin/b.sh
  case_begin "a" "bin/a.sh"
  case_end
EOF

p_fx depth.sh <<'EOF'
#!/usr/bin/env bash
# Tests: bin/a.sh, bin/b.sh
if true; then
case_begin "a" "bin/a.sh"
echo a
case_end
fi
EOF

p_fx target.sh <<'EOF'
#!/usr/bin/env bash
# Tests: bin/a.sh, bin/b.sh
case_begin "a" "/abs/bin/a.sh"
case_end
EOF

p_fx balance.sh <<'EOF'
#!/usr/bin/env bash
# Tests: bin/a.sh, bin/b.sh
case_begin "a" "bin/a.sh"
echo a
echo tail
EOF

p_fx d1-openers.sh <<'EOF'
#!/usr/bin/env bash
# Tests: bin/a.sh, bin/b.sh
if [ -n "$X" ]; then echo x; fi
for f in a b; do echo "$f"; done > /dev/null
while false; do :; done 2>&1 | cat
until true; do :; done && echo ok
case "$X" in a) echo a ;; esac || true
case_begin "a" "bin/a.sh"
echo a
case_end
EOF

p_fx d1-else-fi.sh <<'EOF'
#!/usr/bin/env bash
# Tests: bin/a.sh, bin/b.sh
if [ -n "$X" ]; then
  echo x
else echo y; fi
case_begin "a" "bin/a.sh"
echo a
case_end
EOF

p_fx d1-echo-done.sh <<'EOF'
#!/usr/bin/env bash
# Tests: bin/a.sh, bin/b.sh
while true; do
  break
echo all done
done
case_begin "a" "bin/a.sh"
echo a
case_end
EOF

p_fx d1-select.sh <<'EOF'
#!/usr/bin/env bash
# Tests: bin/a.sh, bin/b.sh
select f in a b; do echo "$f"; done
case_begin "a" "bin/a.sh"
echo a
case_end
EOF

p_fx q-odd-double.sh <<'EOF'
#!/usr/bin/env bash
# Tests: bin/a.sh, bin/b.sh
MSG="first line
second line"
if true; then
case_begin "a" "bin/a.sh"
case_end
fi
EOF

p_fx q-odd-single.sh <<'EOF'
#!/usr/bin/env bash
# Tests: bin/a.sh, bin/b.sh
node -e '
for (const a of [1]) console.log(a)
'
case_begin "a" "bin/a.sh"
case_end
EOF

p_fx q-closed.sh <<'EOF'
#!/usr/bin/env bash
# Tests: bin/a.sh, bin/b.sh
echo "double" 'single'
if true; then
case_begin "a" "bin/a.sh"
case_end
fi
EOF

p_fx q-escaped-only.sh <<'EOF'
#!/usr/bin/env bash
# Tests: bin/a.sh, bin/b.sh
echo it\'s \"fine\"
if true; then
case_begin "a" "bin/a.sh"
case_end
fi
EOF

p_fx q-comment-apostrophe.sh <<'EOF'
#!/usr/bin/env bash
# Tests: bin/a.sh, bin/b.sh
# it's only a comment
if true; then
case_begin "a" "bin/a.sh"
case_end
fi
EOF

p_fx q-heredoc-apostrophe.sh <<'EOF'
#!/usr/bin/env bash
# Tests: bin/a.sh, bin/b.sh
cat <<'INNER'
it's inside a heredoc body
INNER
if true; then
case_begin "a" "bin/a.sh"
case_end
fi
EOF

p_fx q-risk-grammar.sh <<'EOF'
#!/usr/bin/env bash
# Tests: bin/a.sh, bin/b.sh
echo "it's"
  case_begin "a" "bin/a.sh"
EOF

p_fx q-risk-clean.sh <<'EOF'
#!/usr/bin/env bash
# Tests: bin/a.sh, bin/b.sh
echo "it's"
case_begin "a" "bin/a.sh"
echo a
case_end
EOF

# ── P1: trp_enumerate_cases external contract (runs pre-implementation) ─────
P1_REPO="$(make_repo)"
add_src "$P1_REPO" "bin/p-live.sh"
add_raw "$P1_REPO" "p-plain.sh" <<'EOF'
#!/usr/bin/env bash
# Tests: bin/p-live.sh, bin/p-dead.sh
case_begin "live" "bin/p-live.sh"
echo live
case_end
case_begin "dead" "bin/p-dead.sh"
echo dead
case_end
EOF
add_raw "$P1_REPO" "p-d1.sh" <<'EOF'
#!/usr/bin/env bash
# Tests: bin/p-live.sh, bin/p-dead.sh
if [ -n "$X" ]; then echo x; fi
case_begin "live" "bin/p-live.sh"
echo live
case_end
case_begin "dead" "bin/p-dead.sh"
echo dead
case_end
EOF
add_raw "$P1_REPO" "p-depth.sh" <<'EOF'
#!/usr/bin/env bash
# Tests: bin/p-live.sh, bin/p-dead.sh
if true; then
case_begin "live" "bin/p-live.sh"
case_end
fi
EOF
commit_repo "$P1_REPO" "group-p enumerate fixtures"

case_begin "enumerate-conforming-unchanged" "bin/lib/test-retire-predicate/case-parser.sh"
run_enum "$P1_REPO" "tests/p-plain.sh"
assert_eq "P1a plain file not malformed" "0" "$_TRP_MARKER_MALFORMED"
assert_eq "P1a plain file case names" "live dead" "$(join_sp "${TRP_CASE_NAMES[@]:-}")"
assert_eq "P1a plain file alive flags" "1 0" "$(join_sp "${TRP_CASE_ALIVE[@]:-}")"
assert_eq "P1a plain file refcount" "1" "$TRP_REFCOUNT"
assert_eq "P1a plain file begin lines" "3 6" "$(join_sp "${TRP_CASE_BEGIN_LINES[@]:-}")"
case_end

case_begin "enumerate-depth-still-malformed" "bin/lib/test-retire-predicate/case-parser.sh"
run_enum "$P1_REPO" "tests/p-depth.sh"
assert_eq "P1b depth violation still malformed via enumerate" "1" "$_TRP_MARKER_MALFORMED"
assert_eq "P1b malformed file yields no cases" "0" "$TRP_CASE_COUNT"
case_end

case_begin "enumerate-d1-now-case-mode" "bin/lib/test-retire-predicate/case-parser.sh"
# D1: the one-line if no longer pushes the file into the malformed fallback.
run_enum "$P1_REPO" "tests/p-d1.sh"
assert_eq "P1c one-line if is depth-neutral (not malformed)" "0" "$_TRP_MARKER_MALFORMED"
assert_eq "P1c one-line if file alive flags" "1 0" "$(join_sp "${TRP_CASE_ALIVE[@]:-}")"
assert_eq "P1c one-line if file refcount" "1" "$TRP_REFCOUNT"
case_end

case_begin "enumerate-non-sh-guard-kept" "bin/lib/test-retire-predicate/case-parser.sh"
cp "$P1_REPO/tests/p-plain.sh" "$P1_REPO/tests/p-plain.txt"
run_enum "$P1_REPO" "tests/p-plain.txt"
assert_eq "P1d non-.sh file keeps file-level fallback" "0" "$TRP_HAS_MARKERS"
case_end

require_fn trp_parse_case_markers "P0 parse split" || return 0
require_fn trp_marker_conformance "P0 conformance query" || return 0

# ── P2: parse-phase diagnostic globals, one row per reason ──────────────────
case_begin "parse-reason-line-table" "bin/lib/test-retire-predicate/case-parser.sh"
# label|fixture|malformed|line|reason|uncertain
P2_ROWS=(
    "P2 conforming|conforming.sh|0|||0"
    "P2 none|none.sh|0|||0"
    "P2 grammar|grammar.sh|1|3|grammar|0"
    "P2 depth|depth.sh|1|4|depth|0"
    "P2 target|target.sh|1|3|target|0"
    "P2 balance (last line)|balance.sh|1|5|balance|0"
)
for _row in "${P2_ROWS[@]}"; do
    IFS='|' read -r _l _f _m _n _r _u <<< "$_row"
    p_check "$_l" "$_f" "$_m" "$_n" "$_r" "$_u"
done
case_end

case_begin "parse-has-markers-and-cases" "bin/lib/test-retire-predicate/case-parser.sh"
trp_parse_case_markers "$P_DIR/conforming.sh"
assert_eq "P3a conforming has markers" "1" "$TRP_HAS_MARKERS"
assert_eq "P3a conforming case names" "alpha beta" "$(join_sp "${TRP_CASE_NAMES[@]:-}")"
assert_eq "P3a conforming case targets" "bin/a.sh bin/b.sh" "$(join_sp "${TRP_CASE_TARGETS[@]:-}")"
trp_parse_case_markers "$P_DIR/none.sh"
assert_eq "P3b none has no markers" "0" "$TRP_HAS_MARKERS"
case_end

# ── P4: D1 one-line compounds ───────────────────────────────────────────────
case_begin "parse-d1-one-line-compounds" "bin/lib/test-retire-predicate/case-parser.sh"
P4_ROWS=(
    "P4 opener one-liners with redirect/pipe/list tails|d1-openers.sh|0|||0"
    "P4 else-fi one-liner closes the block|d1-else-fi.sh|0|||0"
    "P4 echo all done is not a closer|d1-echo-done.sh|0|||0"
    "P4 select one-liner is depth-neutral|d1-select.sh|0|||0"
)
for _row in "${P4_ROWS[@]}"; do
    IFS='|' read -r _l _f _m _n _r _u <<< "$_row"
    p_check "$_l" "$_f" "$_m" "$_n" "$_r" "$_u"
done
case_end

# ── P5: D2 quote-risk → uncertain (MALFORMED stays 1) ───────────────────────
case_begin "parse-d2-quote-risk-table" "bin/lib/test-retire-predicate/case-parser.sh"
P5_ROWS=(
    "P5 odd double quote then depth violation|q-odd-double.sh|1|6|depth|1"
    "P5 odd single quote (node -e) then depth violation|q-odd-single.sh|1|6|depth|1"
    "P5 closed quotes do not raise risk|q-closed.sh|1|5|depth|0"
    "P5 escaped quotes only do not raise risk|q-escaped-only.sh|1|5|depth|0"
    "P5 comment apostrophe does not raise risk|q-comment-apostrophe.sh|1|5|depth|0"
    "P5 heredoc-body apostrophe does not raise risk|q-heredoc-apostrophe.sh|1|7|depth|0"
    "P5 quote risk never softens a grammar violation|q-risk-grammar.sh|1|4|grammar|0"
    "P5 quote risk alone is not a violation|q-risk-clean.sh|0|||0"
)
for _row in "${P5_ROWS[@]}"; do
    IFS='|' read -r _l _f _m _n _r _u <<< "$_row"
    p_check "$_l" "$_f" "$_m" "$_n" "$_r" "$_u"
done
case_end

# ── P6: reset contract across consecutive calls ─────────────────────────────
case_begin "parse-reset-between-calls" "bin/lib/test-retire-predicate/case-parser.sh"
p_check "P6 first call uncertain" "q-odd-double.sh" 1 6 depth 1
p_check "P6 next conforming call resets diagnostics" "conforming.sh" 0 "" "" 0
p_check "P6 grammar call after conforming" "grammar.sh" 1 3 grammar 0
trp_parse_case_markers "$P_DIR/none.sh"
assert_eq "P6 none after grammar clears case names" "" "$(join_sp "${TRP_CASE_NAMES[@]:-}")"
assert_eq "P6 none after grammar clears malformed" "0" "$_TRP_MARKER_MALFORMED"
case_end

# ── P7: trp_marker_conformance four states ──────────────────────────────────
case_begin "conformance-four-states" "bin/lib/test-retire-predicate.sh"
p_state "P7 none" "none.sh" none "" ""
p_state "P7 conforming" "conforming.sh" conforming "" ""
p_state "P7 malformed" "grammar.sh" malformed 3 grammar
p_state "P7 uncertain" "q-odd-double.sh" uncertain 6 depth
p_state "P7 conforming after uncertain resets" "conforming.sh" conforming "" ""
case_end

unset P1_REPO P2_ROWS P4_ROWS P5_ROWS _row _l _f _m _n _r _u
