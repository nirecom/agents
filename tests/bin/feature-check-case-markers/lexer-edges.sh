# Lexer edge cases for the case-marker parser (#2388): one-line compounds,
# comments, heredoc delimiters, and openers closed by an inner group.
# Sourced by tests/bin/feature-check-case-markers.sh; shares chk/expect_* and $TMP.

case_begin "one-line-function-before-marker" "bin/check-case-markers.sh"
# A function opened and closed on one line leaves depth at 0.
cat > "$TMP/oneline-fn.sh" <<'SH'
#!/usr/bin/env bash
# Tests: bin/a.sh, bin/b.sh
function helper() { :; }
other() { :; }
{ echo x; } > /dev/null
case_begin "a" "bin/a.sh"
echo hi
case_end
SH
chk "$TMP/oneline-fn.sh"
expect_clean "one-line-function-before-marker"
case_end

case_begin "nospace-function-marker-inside" "bin/check-case-markers.sh"
# `f(){` opens a function body just like `f() {`, so a marker inside is depth.
cat > "$TMP/nospace-fn.sh" <<'SH'
#!/usr/bin/env bash
# Tests: bin/a.sh, bin/b.sh
helper(){
case_begin "a" "bin/a.sh"
echo hi
case_end
}
SH
chk "$TMP/nospace-fn.sh"
expect_high "nospace-function-marker-inside" '^HIGH: .*nospace-fn\.sh line 4: malformed case marker \(depth\) code=MALFORMED_CASE_MARKER$'
case_end

case_begin "literal-heredoc-text-not-opener" "bin/check-case-markers.sh"
# `<<WORD` inside quotes or a comment, and an arithmetic shift, open no heredoc.
cat > "$TMP/literal-hd.sh" <<'SH'
#!/usr/bin/env bash
# Tests: bin/a.sh, bin/b.sh
printf '%s\n' '<<EOF'
echo "<<EOF"
echo x # <<EOF
n=$((1<<2)); echo done
case_begin "a" "bin/a.sh"
echo hi
case_end
SH
chk "$TMP/literal-hd.sh"
expect_clean "literal-heredoc-text-not-opener"
case_end

case_begin "closer-in-comment-not-closer" "bin/check-case-markers.sh"
# `; fi` inside a comment closes nothing: the marker is still inside the if.
cat > "$TMP/comment-closer.sh" <<'SH'
#!/usr/bin/env bash
# Tests: bin/a.sh, bin/b.sh
if true; then # ; fi
case_begin "a" "bin/a.sh"
echo hi
case_end
fi
SH
chk "$TMP/comment-closer.sh"
expect_high "closer-in-comment-not-closer" '^HIGH: .*comment-closer\.sh line 4: malformed case marker \(depth\) code=MALFORMED_CASE_MARKER$'
case_end

case_begin "quoted-nonword-heredoc-delimiter" "bin/check-case-markers.sh"
# A quoted delimiter may hold any text; the heredoc ends at it exactly, so the
# markers after it are seen.
cat > "$TMP/hyphen-hd.sh" <<'SH'
#!/usr/bin/env bash
# Tests: bin/a.sh, bin/b.sh
cat > /dev/null <<'fixture-text'
if true; then
fixture-text
case_begin "a" "bin/a.sh"
echo hi
case_end
SH
chk "$TMP/hyphen-hd.sh"
expect_clean "quoted-nonword-heredoc-delimiter"
case_end

case_begin "comment-after-paren-and-select" "bin/check-case-markers.sh"
# A comment right after a case-arm `)` is still a comment, and `select` opens a
# block like `for`: both markers below sit inside a block.
cat > "$TMP/paren-comment.sh" <<'SH'
#!/usr/bin/env bash
# Tests: bin/a.sh, bin/b.sh
if true; then
case x in
x)# ; fi
;;
esac
case_begin "a" "bin/a.sh"
echo hi
case_end
fi
SH
chk "$TMP/paren-comment.sh"
expect_high "comment-after-paren" '^HIGH: .*paren-comment\.sh line 8: malformed case marker \(depth\) code=MALFORMED_CASE_MARKER$'
cat > "$TMP/select.sh" <<'SH'
#!/usr/bin/env bash
# Tests: bin/a.sh, bin/b.sh
select x in a b; do
case_begin "a" "bin/a.sh"
echo hi
case_end
done
SH
chk "$TMP/select.sh"
expect_high "select-block" '^HIGH: .*select\.sh line 4: malformed case marker \(depth\) code=MALFORMED_CASE_MARKER$'
case_end

case_begin "unquoted-nonword-heredoc-delimiter" "bin/check-case-markers.sh"
# Unquoted delimiters may start with a digit or dot; an arithmetic shift inside
# (( )) opens no heredoc.
cat > "$TMP/digit-hd.sh" <<'SH'
#!/usr/bin/env bash
# Tests: bin/a.sh, bin/b.sh
cat > /dev/null <<123
if true; then
123
cat > /dev/null <<.END
if true; then
.END
(( n = 1 << 2 ))
case_begin "a" "bin/a.sh"
echo hi
case_end
SH
chk "$TMP/digit-hd.sh"
expect_clean "unquoted-nonword-heredoc-delimiter"
case_end

case_begin "inner-closer-does-not-close-opener" "bin/check-case-markers.sh"
# An opener line is one-line only when its LAST closer is its own: `{ :; }`
# closes the inner group and leaves the `if` open.
cat > "$TMP/inner-closer.sh" <<'SH'
#!/usr/bin/env bash
# Tests: bin/a.sh, bin/b.sh
if true; then { :; }
case_begin "a" "bin/a.sh"
echo hi
case_end
fi
SH
chk "$TMP/inner-closer.sh"
expect_high "inner-closer" '^HIGH: .*inner-closer\.sh line 4: malformed case marker \(depth\) code=MALFORMED_CASE_MARKER$'
cat > "$TMP/nested-oneline.sh" <<'SH'
#!/usr/bin/env bash
# Tests: bin/a.sh, bin/b.sh
for i in 1; do { :; }; done
while false; do if true; then :; fi; done
case_begin "a" "bin/a.sh"
echo hi
case_end
SH
chk "$TMP/nested-oneline.sh"
expect_clean "nested-oneline-compounds"
case_end
