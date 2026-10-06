# Tests: bin/lib/case-record-reader.sh
# Tags: TL2, case-markers, scope:common
# Fixture test files for the crr_read / bash caseEmbedRules cases. Every marker lives in a
# heredoc body, so this file itself carries none. Line numbers are asserted by the cases:
# keep each body's lines exactly where its comment says. Sourced by the dispatcher.

# none — no markers at all.
cat >"$FXD/none.sh" <<'FX'
#!/usr/bin/env bash
# Tests: bin/a.sh
echo plain
FX

# conforming — two cases; alpha uses two top-level helpers, beta none.
# begin/end lines: alpha 7..10, beta 11..13.
cat >"$FXD/conforming.sh" <<'FX'
#!/usr/bin/env bash
# Tests: bin/a.sh, bin/b.sh
helper_a() { echo a; }
helper_b() {
  echo b
}
case_begin "alpha" "bin/a.sh"
helper_a
helper_b
case_end
case_begin "beta" "bin/b.sh"
echo none
case_end
FX

# malformed — an indented marker is a grammar violation at line 3.
cat >"$FXD/malformed.sh" <<'FX'
#!/usr/bin/env bash
# Tests: bin/a.sh, bin/b.sh
  case_begin "a" "bin/a.sh"
echo a
case_end
FX

# uncertain — a quote left open on line 2 skews depth; the marker on line 5 is a depth
# violation seen after a quote risk.
cat >"$FXD/uncertain.sh" <<'FX'
#!/usr/bin/env bash
echo "multi
line"
if true; then
case_begin "a" "bin/a.sh"
echo a
case_end
fi
FX

# unsupported — a recognized-only language (js) and a supported one with no reader.
printf '%s\n' '// Tests: bin/a.sh' 'test("x", () => {});' >"$FXD/x.test.js"
printf '%s\n' '# Tests: bin/a.sh' 'Describe "x" { }' >"$FXD/x.Tests.ps1"

# heredoc-pseudo — markers and a helper call only inside a heredoc body.
cat >"$FXD/heredoc-pseudo.sh" <<'FX'
#!/usr/bin/env bash
hd_fn() { :; }
cat <<'EOF'
case_begin "fake" "bin/a.sh"
hd_fn
case_end
EOF
FX

# deps-heredoc — doc_fn appears in case 0 only inside a heredoc; it is used for real on
# line 10 (outside every case), so it is neither a dep nor a leftover.
cat >"$FXD/deps-heredoc.sh" <<'FX'
#!/usr/bin/env bash
real_fn() { :; }
doc_fn() { :; }
case_begin "a" "bin/a.sh"
real_fn
cat <<'EOF'
doc_fn
EOF
case_end
doc_fn
FX

# deps-boundary — mk is a prefix of mk_more (word boundary); fn_kw uses the `function`
# keyword form; VAR_ONLY is a variable, never a dep.
cat >"$FXD/deps-boundary.sh" <<'FX'
#!/usr/bin/env bash
mk() { :; }
mk_more() { :; }
function fn_kw {
  :
}
VAR_ONLY=1
case_begin "word-boundary" "bin/a.sh"
mk_more x
echo "$VAR_ONLY"
case_end
case_begin "function-keyword" "bin/a.sh"
fn_kw
case_end
FX

# leftover — orphan_fn (line 4) is referenced nowhere but its own definition.
cat >"$FXD/leftover.sh" <<'FX'
#!/usr/bin/env bash
used_in_case() { :; }
used_outside() { :; }
orphan_fn() { :; }
case_begin "a" "bin/a.sh"
used_in_case
case_end
used_outside
FX

# self-impl — unguarded PASS=0 (3) and FAIL=0 (4), and a harness function redefined (5).
# The guarded SKIP init, the Results echo and `exit "$FAIL"` are not self-implementation.
cat >"$FXD/self-impl.sh" <<'FX'
#!/usr/bin/env bash
. "$AGENTS_DIR/tests/lib/harness.sh"
PASS=0
FAIL=0
pass() { echo ok; }
: "${SKIP:=0}"
my_helper() { :; }
my_helper
echo "Results: $PASS passed, $FAIL failed"
exit "$FAIL"
FX

# self-impl-clean — the shared harness only, closed by the conventional trailer.
cat >"$FXD/self-impl-clean.sh" <<'FX'
#!/usr/bin/env bash
. "$AGENTS_DIR/tests/lib/harness.sh"
assert_eq "1" "1"
echo "Results: $PASS passed, $FAIL failed"
exit "$FAIL"
FX

# skip-reason fixtures: one source line each (name|line), plus a heredoc-only mention.
while IFS='|' read -r sname sline; do
  [ -n "$sname" ] || continue
  printf '%s\n' '#!/usr/bin/env bash' "$sline" 'echo x' >"$FXD/skip-$sname.sh"
done <<'ROWS'
narrow-dot-agents|. "$AGENTS_DIR/tests/lib/request-off-clearance-harness.sh"
narrow-source-repo-root|source "$REPO_ROOT/tests/lib/clearance-hook-harness.sh"
narrow-unquoted|. $AGENTS_DIR/tests/lib/clearance-hook-harness.sh
shared-harness|. "$AGENTS_DIR/tests/lib/harness.sh"
section-runner|. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/section-runner.sh"
ROWS
cat >"$FXD/skip-narrow-in-heredoc.sh" <<'FX'
#!/usr/bin/env bash
. "$AGENTS_DIR/tests/lib/harness.sh"
cat <<'EOF'
. "$AGENTS_DIR/tests/lib/clearance-hook-harness.sh"
EOF
FX

# tab-in-name — the parser's name grammar admits a tab inside the quotes; @TAB@ becomes one.
cat >"$FXD/tab-in-name.tmpl" <<'FX'
#!/usr/bin/env bash
case_begin "a@TAB@b" "bin/a.sh"
echo a
case_end
FX
sed "s/@TAB@/$T/" "$FXD/tab-in-name.tmpl" >"$FXD/tab-in-name.sh"
