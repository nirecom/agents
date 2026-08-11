# shellcheck shell=bash
# Tests: hooks/instructions-loaded-audit.js, hooks/lib/rules-injection-policy.js
# Tags: rules-injection, instructions-loaded, frontmatter, parser, error-handling, table-driven, TL2, scope:common
#
# Frontmatter parser error surface. One malformed form is not coverage: a parser
# that only guards against the single "unclosed flow sequence" shape passes that
# case and still mis-classifies every other degenerate `paths:` spelling.
#
# CONTRACT NOTE (asserted here, to be honoured by hooks/instructions-loaded-audit.js):
#   A frontmatter block is "present" only when the file OPENS with `---` and a
#   closing `---` line follows. Within a present block:
#     - `paths:` absent                      -> not on-demand; ok if listed, else S-MISSING
#     - `paths:` present but not a non-empty
#       list of glob strings (null / scalar /
#       empty list / duplicated key)         -> S-MALFORMED
#     - `paths:` a non-empty glob list       -> ok
#   An unterminated block is NOT a block: the file is treated as having no
#   frontmatter at all (S-MISSING when unlisted), never as a parse error.
#   CRLF line endings and a leading UTF-8 BOM must not defeat the block anchor.
#   An unreadable / nonexistent file must fail open: exit 0, empty stdout, and a
#   receipt whose verdict is never a crash artifact.

echo ""
echo "=== frontmatter parser error surface ==="

fm_write() { printf '%b' "$2" > "$REPO/rules/$1"; }

fm_write fm-null.md          '---\npaths:\n---\n\n# paths: with no value\n'
fm_write fm-scalar.md        '---\npaths: "tests/**"\n---\n\n# scalar instead of a list\n'
fm_write fm-empty-list.md    '---\npaths: []\n---\n\n# explicitly empty list\n'
fm_write fm-empty-block.md   '---\n---\n\n# frontmatter block with no keys at all\n'
fm_write fm-dup-key.md       '---\npaths:\n  - "tests/**"\npaths:\n  - "docs/**"\n---\n\n# duplicated key\n'
fm_write fm-unterminated.md  '---\npaths:\n  - "tests/**"\n\n# the closing --- never comes\n'
fm_write fm-crlf.md          '---\r\npaths:\r\n  - "tests/**"\r\n---\r\n\r\n# CRLF throughout\r\n'
fm_write fm-bom.md           '\xef\xbb\xbf---\npaths:\n  - "tests/**"\n---\n\n# leading UTF-8 BOM\n'
: > "$REPO/rules/fm-empty-file.md"

# Element-level degeneracy. The rows above only exercise the `paths:` VALUE; a parser
# that checks "is a non-empty array" and stops there accepts a list whose members are
# not globs at all. Each of these is a rule that silently matches nothing (or, for the
# empty string, potentially everything, depending on the matcher) while looking
# well-formed to a shape-only check — so the element type is part of the contract.
fm_write fm-el-empty.md   '---\npaths:\n  - ""\n---\n\n# an empty-string element\n'
fm_write fm-el-null.md    '---\npaths:\n  - \n  - "tests/**"\n---\n\n# a null element\n'
fm_write fm-el-number.md  '---\npaths:\n  - 42\n---\n\n# a numeric element\n'
fm_write fm-el-bool.md    '---\npaths:\n  - true\n---\n\n# a boolean element\n'
fm_write fm-el-mixed.md   '---\npaths:\n  - "tests/**"\n  - 42\n  - true\n---\n\n# a mixed-type array: one valid glob is not enough\n'

# --- table: name | rules-relative file | want verdict ---
FM_N=0
while IFS='|' read -r name relname want; do
    [ -z "${name// /}" ] && continue
    case "$name" in \#*) continue ;; esac
    name="${name//[[:space:]]/}"; relname="${relname//[[:space:]]/}"; want="${want//[[:space:]]/}"
    FM_N=$((FM_N + 1))
    sid="fmsid$FM_N"
    fp="$(node_path "$REPO/rules/$relname")"
    res="$(fire "$sid" "$fp" OMIT)"
    rc="${res%%|*}"; sout="${res#*|}"
    got="$(read_field "$sid" "$fp" verdict)"
    if [ "$rc" != "0" ]; then
        fail "$name: hook exited $rc (must always be 0)"
    elif [ -n "$sout" ]; then
        fail "$name: stdout must be empty, got '$sout'"
    elif [ "$got" != "$want" ]; then
        fail "$name: want verdict $want, got $got"
    else
        pass "$name (verdict=$got)"
    fi
done <<'TABLE'
fm-paths-null          | fm-null.md         | S-MALFORMED
fm-paths-scalar        | fm-scalar.md       | S-MALFORMED
fm-paths-empty-list    | fm-empty-list.md   | S-MALFORMED
fm-paths-duplicate-key | fm-dup-key.md      | S-MALFORMED
fm-empty-block         | fm-empty-block.md  | S-MISSING
fm-unterminated-block  | fm-unterminated.md | S-MISSING
fm-empty-file          | fm-empty-file.md   | S-MISSING
fm-crlf-valid-paths    | fm-crlf.md         | ok
fm-bom-valid-paths     | fm-bom.md          | ok
fm-element-empty       | fm-el-empty.md     | S-MALFORMED
fm-element-null        | fm-el-null.md      | S-MALFORMED
fm-element-number      | fm-el-number.md    | S-MALFORMED
fm-element-bool        | fm-el-bool.md      | S-MALFORMED
fm-element-mixed       | fm-el-mixed.md     | S-MALFORMED
TABLE

# --- F-ENOENT: a rules/ path that does not exist on disk must fail open.
# The loader can report a file the audit process cannot stat (race, symlink,
# permissions); crashing here would take the hook down for the whole session.
F_SID="fmenoent"
F_FP="$(node_path "$REPO/rules/does-not-exist.md")"
f_res="$(fire "$F_SID" "$F_FP" OMIT)"
f_rc="${f_res%%|*}"; f_out="${f_res#*|}"
f_verdict="$(read_field "$F_SID" "$F_FP" verdict)"
if [ "$f_rc" != "0" ] || [ -n "$f_out" ]; then
    fail "F-ENOENT: want exit 0 + empty stdout, got rc=$f_rc stdout='$f_out'"
elif [ "$f_verdict" = "MISSING_RECEIPT" ] || [ "$f_verdict" = "UNREADABLE" ]; then
    fail "F-ENOENT: a nonexistent rule still needs a readable receipt, got $f_verdict"
else
    pass "F-ENOENT: a nonexistent rules/ path fails open with a readable receipt (verdict=$f_verdict)"
fi

# --- F-ENOTDIR: the unreadable-rule branch, provoked WITHOUT permission bits.
# `rules/regular.md/child.md` treats a regular file as a directory, so readFileSync
# raises ENOTDIR on every platform. This is the deterministic stand-in for the
# EACCES / read-only case that chmod cannot express on this Windows host (see the
# Skipped-Because note in the dispatcher). ---
printf '# a regular file, not a directory\n' > "$REPO/rules/regular.md"
FN_SID="fmenotdir"
FN_FP="$(node_path "$REPO/rules/regular.md")/child.md"
fn_res="$(fire "$FN_SID" "$FN_FP" OMIT)"
fn_rc="${fn_res%%|*}"; fn_out="${fn_res#*|}"
fn_verdict="$(read_field "$FN_SID" "$FN_FP" verdict)"
if [ "$fn_rc" != "0" ] || [ -n "$fn_out" ]; then
    fail "F-ENOTDIR: want exit 0 + empty stdout, got rc=$fn_rc stdout='$fn_out'"
elif [ "$fn_verdict" = "MISSING_RECEIPT" ] || [ "$fn_verdict" = "UNREADABLE" ]; then
    fail "F-ENOTDIR: an unreadable rule still needs a readable receipt, got $fn_verdict"
else
    pass "F-ENOTDIR: an unreadable rule path (ENOTDIR) fails open with a readable receipt (verdict=$fn_verdict)"
fi

# --- F-NOCRASH: no frontmatter shape above may write anything to stderr that looks
# like an unhandled throw. A silent catch-all is the contract; a stack trace means
# the hook is one node version away from breaking the session. ---
F2_PAYLOAD="$(node -e 'console.log(JSON.stringify({session_id:"fmthrow",file_path:process.argv[1],hook_event_name:"InstructionsLoaded"}))' "$(node_path "$REPO/rules/fm-dup-key.md")")"
f2_res="$(fire_raw "$F2_PAYLOAD")"
f2_err="${f2_res##*|}"
if printf '%s' "$f2_err" | grep -qE 'at [A-Za-z_$][^ ]*\ \(|Error:.*\n\s+at '; then
    fail "F-NOCRASH: stderr contains an unhandled stack trace — $(printf '%s' "$f2_err" | head -2 | tr '\n' ' ')"
else
    pass "F-NOCRASH: a degenerate frontmatter form produces no unhandled stack trace"
fi
