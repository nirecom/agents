# shellcheck shell=bash
# Tests: bin/check-on-demand-rules.sh
# Tags: rules-injection, on-demand-rules, input-injection, untrusted-input, hardening, table-driven, TL2, scope:common

# `--staged <files>` is fed by hooks/pre-commit from `git diff --cached --name-only`,
# i.e. from whatever filenames the working tree happens to contain. Those names are
# attacker-influenced in any repo that accepts contributions, and the checker is a
# bash script that will be handling them with globbing, word splitting and (if written
# carelessly) `eval` / unquoted expansion in play. A checker that can be made to execute
# a filename runs inside the pre-commit hook, with the developer's credentials.

# CONTRACT NOTE (asserted here):
#   - Every hostile name is DATA — reported, skipped, or rejected, never executed, expanded, or followed outside the repo root.
#   - Exit code stays inside {0,1,2}; a 126/127/139 or a bash diagnostic on stdout means the name reached the
#     shell as code.
#   - One argument is one path — a newline or space in a name must not silently split it into two, the way a
#     real file smuggles itself past a per-path check.
#   - A path outside the checked root is SURFACED (exit 1/2), never silently accepted with exit 0. Absence from
#     the output is not assertable here — a checker that correctly REJECTS `../x.md` still echoes it — the
#     observable contract is the verdict, not the wording.

echo ""
echo "=== --staged input injection (untrusted filenames) ==="

INJ_DIR="$BASE/inj-root"
fx_base "$INJ_DIR"
CANARY_DIR="$BASE/canary"
mkdir -p "$CANARY_DIR"

# A malformed rule OUTSIDE the checked root. If a traversal argument is followed, the
# checker grades this file and its name shows up in the diagnostics.
wr "$BASE/outside-rule.md" <<EOF
---
paths:
  - "$TOKEN"
---

# outside the root, deliberately missing its marker
EOF

# inj_case <label> <arg>
# The argument is passed as ONE argv element, exactly as a filename would arrive.
inj_case() {
    local label="$1"
    local arg="$2"
    local before after rc out
    before="$(find "$CANARY_DIR" -type f 2>/dev/null | wc -l | tr -d ' ')"
    rc="$(run_checker_files "$INJ_DIR" "$arg")"
    out="$(cat "$(outfile_for "$INJ_DIR")" 2>/dev/null)"
    after="$(find "$CANARY_DIR" -type f 2>/dev/null | wc -l | tr -d ' ')"

    if [ "$after" != "$before" ]; then
        fail "$label: the argument EXECUTED — $((after - before)) canary file(s) appeared in $CANARY_DIR"
        return
    fi
    case "$rc" in
        0|1|2) ;;
        *) fail "$label: exit $rc is outside the documented set {0,1,2} — the name reached the shell as code; output: $(printf '%s' "$out" | head -3 | tr '\n' ' ')"
           return ;;
    esac
    if printf '%s' "$out" | grep -qiE 'command not found|syntax error|unbound variable|unexpected token|permission denied'; then
        fail "$label: the checker emitted a shell diagnostic instead of handling the name as data — $(printf '%s' "$out" | grep -iE 'command not found|syntax error|unbound variable|unexpected token|permission denied' | head -1)"
        return
    fi
    pass "$label (exit $rc, treated as data)"
}

# inj_escape <label> <arg> — the same invariants PLUS: a path that does not resolve
# inside the checked root must be surfaced, not silently accepted.
inj_escape() {
    local label="$1"
    local arg="$2"
    local before after rc out
    before="$(find "$CANARY_DIR" -type f 2>/dev/null | wc -l | tr -d ' ')"
    rc="$(run_checker_files "$INJ_DIR" "$arg")"
    out="$(cat "$(outfile_for "$INJ_DIR")" 2>/dev/null)"
    after="$(find "$CANARY_DIR" -type f 2>/dev/null | wc -l | tr -d ' ')"
    if [ "$after" != "$before" ]; then
        fail "$label: the argument EXECUTED — $((after - before)) canary file(s) appeared"
    elif [ "$rc" != "1" ] && [ "$rc" != "2" ]; then
        fail "$label: want exit 1 or 2 (out-of-root path surfaced), got $rc — a staged path silently skipped is a gate that has gone dark; output: $(printf '%s' "$out" | head -3 | tr '\n' ' ')"
    else
        pass "$label (exit $rc)"
    fi
}

# Each row is one hostile argv element. `$CANARY_DIR` is interpolated deliberately:
# the shell of THIS test expands it, so what the checker receives is a literal path
# that only a shell-executing checker could act on.
inj_case "X1: a leading dash is a filename, not an option"            "-rf"
inj_case "X2: a long-option lookalike is a filename"                  "--all"
inj_case "X3: a lone double-dash is not a path"                       "--"
inj_case "X4: a name with spaces stays one path"                      "rules/two words.md"
inj_case "X5: a glob is not expanded"                                 "rules/*.md"
inj_case "X6: a brace expansion is not expanded"                      "rules/{od,plain}.md"
inj_case "X7: a semicolon does not start a second command"            "rules/od.md; touch $CANARY_DIR/pwned-semi"
inj_case "X8: command substitution is not evaluated"                  'rules/$(touch '"$CANARY_DIR"'/pwned-subst).md'
inj_case "X9: backtick substitution is not evaluated"                 'rules/`touch '"$CANARY_DIR"'/pwned-tick`.md'
inj_case "X10: a pipe does not start a pipeline"                      "rules/od.md | touch $CANARY_DIR/pwned-pipe"
inj_case "X11: && does not chain a command"                           "rules/od.md && touch $CANARY_DIR/pwned-and"
inj_case "X12: a newline inside one argument is not two paths"        "rules/od.md
../outside-rule.md"
inj_case "X16: a variable reference is not expanded"                  'rules/$HOME.md'
inj_case "X18: a redirection character does not open a file"          "rules/od.md > $CANARY_DIR/pwned-redir"
inj_case "X19: an embedded NUL-ish escape stays literal"              'rules/od.md\x00../outside-rule.md'
inj_case "X20: an empty argument is tolerated"                        ""

# Out-of-root arguments: same data-not-code invariants, plus the verdict contract.
inj_escape "X13: parent traversal is surfaced, not silently accepted"      "../outside-rule.md"
inj_escape "X14: a deep traversal is surfaced"                            "rules/../../outside-rule.md"
inj_escape "X15: an absolute path outside the root is surfaced"           "$BASE/outside-rule.md"
inj_escape "X17: a tilde path is surfaced literally, not expanded"        "~/outside-rule.md"

# --- X21: the whole hostile set at once. Argument-by-argument hardening can still be
# defeated in aggregate (e.g. a loop that re-splits "$*"), so the same names are handed
# over in a single invocation and the same invariants must hold. ---
inj_before="$(find "$CANARY_DIR" -type f 2>/dev/null | wc -l | tr -d ' ')"
inj_rc="$(run_checker_files "$INJ_DIR" \
    "-rf" "rules/two words.md" "rules/*.md" \
    "rules/od.md; touch $CANARY_DIR/pwned-all" \
    "../outside-rule.md" "" "rules/od.md")"
inj_out="$(cat "$(outfile_for "$INJ_DIR")" 2>/dev/null)"
inj_after="$(find "$CANARY_DIR" -type f 2>/dev/null | wc -l | tr -d ' ')"
if [ "$inj_after" != "$inj_before" ]; then
    fail "X21: the combined hostile argument list executed — canary count $inj_before -> $inj_after"
elif [ "$inj_rc" != "1" ] && [ "$inj_rc" != "2" ]; then
    fail "X21: the combined list contains an out-of-root path and a nonexistent path, so the run must surface something — want exit 1 or 2, got $inj_rc; output: $(printf '%s' "$inj_out" | head -3 | tr '\n' ' ')"
else
    pass "X21: the whole hostile argument list is handled as data (exit $inj_rc)"
fi

# --- X22: hardening must not have been bought by ignoring everything. A checker that
# exits 0 on every input would pass every case above, so the same driver is fed ONE
# genuinely broken in-root path and must still fail it. This is the false-green guard
# for this whole section. ---
wr "$INJ_DIR/rules/broken.md" <<EOF
---
paths:
  - "$TOKEN"
---

# registered nowhere and missing its marker
EOF
x22_rc="$(run_checker_files "$INJ_DIR" "rules/broken.md")"
x22_out="$(cat "$(outfile_for "$INJ_DIR")" 2>/dev/null)"
if [ "$x22_rc" = "1" ] && printf '%s' "$x22_out" | grep -q 'rules/broken.md'; then
    pass "X22: a genuinely broken in-root path is still rejected and named"
else
    fail "X22: the hostile-input handling swallowed a real defect — want exit 1 naming rules/broken.md, got $x22_rc; output: $(printf '%s' "$x22_out" | head -3 | tr '\n' ' ')"
fi

# --- X23..X25: REAL violating files whose NAMES are hostile ------------------------
# Everything above hands hostile strings to the checker as arguments for paths that do not exist, proving
# only that argument handling is inert — it does not prove the checker still works on such a path, which is
# the direction that actually bites: a name split on whitespace turns into two nonexistent paths, the checker
# finds no violation in either, exits 0, and the broken rule is committed silently, indistinguishable from
# success. Asserted here with a file that really is broken and really is named this way. The identification
# must reproduce the name WHOLE — "rules/bad" plus "rule.md" is not an identification of `rules/bad rule
# with spaces.md`; it is two wrong answers, and a contributor cannot act on it.

# x_real <label> <filename> — writes a genuinely broken rule under that name and
# requires exit 1 with the exact name in the output.
x_real() {
    local label="$1" name="$2" rc out
    mkdir -p "$INJ_DIR/$(dirname "$name")"
    {
        printf -- '---\npaths:\n  - "%s"\n---\n\n' "$TOKEN"
        printf '# registered nowhere and missing its marker\n'
    } > "$INJ_DIR/$name" 2>/dev/null

    # Two host preconditions, probed rather than assumed. Without them a red result
    # here would mean "this filesystem/argv layer cannot carry the name", not "the
    # checker mishandled it" — and a permanently red case that nobody can act on is
    # indistinguishable from a broken test.
    #   1. the file exists under exactly this name (NTFS rejects " < > : | ? *)
    #   2. the name survives the argv transport into the child process unchanged
    #      (MSYS rewrites arguments that look like POSIX paths)
    if [ ! -f "$INJ_DIR/$name" ]; then
        echo "SKIP: $label: Skipped-Because: this filesystem refuses to create a file named [$name], so the case cannot be staged here"
        return
    fi
    if ! node -e 'process.exit(require("fs").existsSync(process.argv[1]) ? 0 : 1)' "$INJ_DIR/$name" 2>/dev/null; then
        echo "SKIP: $label: Skipped-Because: the name [$name] does not survive this host's argv transport into a child process, so the checker never receives it intact — the checker's own handling is UNVERIFIED for this shape"
        rm -f "$INJ_DIR/$name" 2>/dev/null || true
        return
    fi

    rc="$(run_checker_files "$INJ_DIR" "$name")"
    out="$(cat "$(outfile_for "$INJ_DIR")" 2>/dev/null)"
    if [ "$rc" != "1" ]; then
        fail "$label: a genuinely broken rule at [$name] was not rejected — want exit 1, got $rc; output: $(printf '%s' "$out" | head -3 | tr '\n' ' ')"
    elif ! printf '%s' "$out" | grep -qF "$name"; then
        fail "$label: rejected, but the exact filename [$name] never appears whole in the output: $(printf '%s' "$out" | head -3 | tr '\n' ' ')"
    else
        pass "$label"
    fi
    rm -f "$INJ_DIR/$name" 2>/dev/null || true
}

x_real "X23: a violating rule whose name contains spaces is rejected and named whole" \
       'rules/bad rule with spaces.md'
x_real "X24: a violating rule whose name contains a quote and a space is named whole" \
       "rules/bad \"quoted\" rule.md"

# X25: a newline in the filename. NTFS forbids it outright, so the case is detected
# and recorded rather than substituted with something weaker — the line-splitting half
# of this defect stays uncovered on this host, and says so.
X25_NAME="$(printf 'rules/bad\nname.md')"
if ! (mkdir -p "$INJ_DIR/rules" && : > "$INJ_DIR/$X25_NAME") 2>/dev/null; then
    echo "SKIP: X25: Skipped-Because: this filesystem cannot create a filename containing a newline (NTFS forbids it) — X23/X24 cover word splitting; line splitting is unverified here"
else
    x_real "X25: a violating rule whose name contains a newline is rejected and named whole" "$X25_NAME"
fi
