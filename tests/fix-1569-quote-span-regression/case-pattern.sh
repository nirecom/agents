# tests/fix-1569-quote-span-regression/case-pattern.sh
# Tests: hooks/lib/quote-spans/scan.js, hooks/lib/strip-quoted-args.js, hooks/enforce-worktree.js
# Tags: worktree, enforce, hook, quote-spans, scanner, security, classifier, scope:issue-specific
#
# STATUS: RED on the CASE-* rows. Sourced by
# tests/fix-1569-quote-span-regression.sh — uses its pass/fail, run_with_timeout
# and _AGENTS_DIR_NODE.
#
# Defect: the scanner closes a `$(` command substitution at the FIRST `)` it
# meets, but `)` is also the pattern terminator inside a `case` statement, and a
# `case` is legal inside a command substitution. So for
#
#     echo "$(case x in x) rm -f README.md;; esac)"
#
# the cmdsubst span is scanned as `$(case x in x)` and everything real bash
# executes after it — including `rm -f README.md` — falls OUTSIDE the
# substitution, back into the enclosing double quote, where it is treated as
# inert literal text. The scan still reports ok:true, so nothing downstream
# knows anything was missed: stripDqPreservingCmdSubst unwraps the truncated
# span and produces `echo ""  case x in x  `, with the write DELETED from the
# text the write-pattern layer sees.

run_case_pattern_cases() {

# The honest twin `echo "$(rm -f README.md)"` is the control that runs through
# EVERY row below: same write, same quoting, no `case`. It is blocked today.
# If a fix blocked the `case` form by blanket-rejecting the word `case`, or by
# giving up on every command substitution, the read-only `case` row and the
# already-green control rows fail.
CASE_WRITE='echo "$(case x in x) rm -f README.md;; esac)"'
CASE_READ='echo "$(case x in x) cat README.md;; esac)"'
PLAIN_WRITE='echo "$(rm -f README.md)"'
PLAIN_READ='echo "$(cat README.md)"'
DQ_LITERAL='echo "rm -f README.md"'
SQ_SUBST="echo '\$(rm -f README.md)'"

# ── Layer 1: the hook verdict ───────────────────────────────────────────────
# `rm -f README.md` targets the main worktree's own README.md, so the write is
# in scope for enforce-worktree and the pairing is not vacuous.
assert_block "CASE-hook case-pattern hides a repo write inside \$( )" "$CASE_WRITE"
assert_block "CASE-hook-pair same write without the case wrapper (control)" "$PLAIN_WRITE"
assert_allow "CASE-hook read-only case body stays allowed" "$CASE_READ"
assert_allow "CASE-hook read-only substitution stays allowed (control)" "$PLAIN_READ"

# ── Layer 2: the scanner / unwrap seam ──────────────────────────────────────
# Pinned as "is the executable text still VISIBLE downstream", because that is
# the property both acceptable fixes deliver:
#   - extend the span to the real closing paren -> the write is inside the
#     unwrapped substitution, hence visible;
#   - fail closed (scan ok:false) -> unwrapCmdSubstInDq returns the input
#     unchanged, so the write is still literally present.
# What must NOT happen is today's third outcome: a clean parse whose unwrap has
# silently dropped the write.
case_probe() {
    run_with_timeout 30 node -e '
      const path = require("path");
      const root = process.argv[1];
      const op = process.argv[2], cmd = process.argv[3], needle = process.argv[4];
      let qs, sq;
      try {
        qs = require(path.join(root, "hooks", "lib", "quote-spans.js"));
        sq = require(path.join(root, "hooks", "lib", "strip-quoted-args.js"));
      } catch (e) { console.log("ERROR: " + e.message); process.exit(0); }
      try {
        if (op === "unwrapexposes") {
          const out = sq.stripDqPreservingCmdSubst(cmd);
          console.log(typeof out === "string" && out.indexOf(needle) !== -1 ? "exposed" : "hidden");
        } else if (op === "spanexposes") {
          const sr = qs.scanSpans(cmd);
          if (sr.ok !== true) { console.log("exposed"); process.exit(0); }
          const hit = sr.spans.some(function (s) {
            if (s.kind !== "cmdsubst" && s.kind !== "backtick") return false;
            return cmd.slice(s.innerStart, s.innerEnd).indexOf(needle) !== -1;
          });
          console.log(hit ? "exposed" : "hidden");
        } else {
          console.log("ERROR: unknown op " + op);
        }
      } catch (e) { console.log("ERROR: threw " + e.message); }
    ' "$_AGENTS_DIR_NODE" "$1" "$2" "$3" 2>&1
}

assert_case_probe() {
    local label="$1" op="$2" cmd="$3" needle="$4" want="$5" got
    got="$(case_probe "$op" "$cmd" "$needle")"
    if [ "$got" = "$want" ]; then pass "$label"
    else fail "$label (want=$want got=$got)"; fi
}

# The unwrap must not lose the write. RED: today it prints `hidden` because the
# `rm` sits outside the truncated span and is blanked as double-quoted literal.
assert_case_probe "CASE-unwrap write survives the case-pattern paren" \
    unwrapexposes "$CASE_WRITE" "rm -f README.md" exposed
assert_case_probe "CASE-unwrap write survives without the wrapper (control)" \
    unwrapexposes "$PLAIN_WRITE" "rm -f README.md" exposed
# Opposite direction, so "stop unwrapping / return the input unchanged" is not a
# passing fix: text that really is inert double-quoted literal must still be
# blanked.
assert_case_probe "CASE-unwrap plain DQ literal stays blanked (pair)" \
    unwrapexposes "$DQ_LITERAL" "rm -f README.md" hidden
# ...and the complementary direction: this transform only rewrites DQ spans, so
# text outside them passes through untouched. A fix that started blanking
# single-quoted text would hide a `$(...)`-looking payload that a later
# unquoted-context reader still has to see.
assert_case_probe "CASE-unwrap text outside DQ passes through untouched (pair)" \
    unwrapexposes "$SQ_SUBST" "rm -f README.md" exposed

# Same property one layer down, on the span geometry itself: the substitution
# body must reach its real end (`esac`), or the scan must fail closed.
assert_case_probe "CASE-span cmdsubst body reaches the real closing paren" \
    spanexposes "$CASE_WRITE" "esac" exposed
assert_case_probe "CASE-span cmdsubst body covers the write (control)" \
    spanexposes "$PLAIN_WRITE" "rm -f README.md" exposed
assert_case_probe "CASE-span no cmdsubst span inside single quotes (pair)" \
    spanexposes "$SQ_SUBST" "rm -f README.md" hidden

}
