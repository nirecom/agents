#!/usr/bin/env bash
# tests/feature-1640-measure-norm-docs.sh
# Tests: bin/measure-norm-docs
# Tags: measurement, norm-docs, frontmatter-parser, cli-args, scope:issue-specific, pwsh-not-required, TL2
#
# (a) of #1640. `bin/measure-norm-docs` statically measures the ALWAYS-LOADED normative
# documents of a repository: `rules/**/*.md` whose YAML frontmatter carries no `paths:`
# key, plus the repo-root `CLAUDE.md`. `_archived` paths are excluded.
#
# ISOLATION CONTRACT: every invocation passes `--repo <fixture>`. The real repository is
# never scanned, so the expected byte/line totals below are fixed constants and the suite
# cannot start failing because someone edited rules/.
#
# TL3 gap (what this test does NOT catch):
# - the real rules/ tree of this repo: the actual always-loaded byte budget, the real
#   distribution of `paths:` frontmatter, and a CRLF checkout on the Windows host
#   (every fixture here is written LF-only).
# - `git show <ref>` against real multi-year history, where the frontmatter convention
#   itself changed over time; only a two-commit fixture repository is exercised.
# - the shipped execute bit (git mode 100755): this suite always invokes the CLI through
#   `node <path>`, never as a bare executable resolved from PATH.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: installer.

set -uo pipefail

command -v node >/dev/null 2>&1 || { echo "SKIP: node not available"; exit 77; }

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$AGENTS_DIR/bin/measure-norm-docs"

TMPROOT="$(mktemp -d)"
trap 'chmod -R u+rwx "$TMPROOT" >/dev/null 2>&1 || true; rm -rf "$TMPROOT"' EXIT

PASS=0
FAIL=0
SKIP=0

assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then echo "PASS: $name"; PASS=$((PASS + 1))
    else echo "FAIL: $name — want=$(printf '%q' "$want") got=$(printf '%q' "$got")"; FAIL=$((FAIL + 1)); fi
}

skip_case() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

run_with_timeout() { "$AGENTS_DIR/bin/run-with-timeout.sh" "$@"; }

# Native path spelling: on Windows `pwd -W` yields C:/... which is the only form Node's
# fs and path.isAbsolute() agree on. Never a hardcoded path.
native_path() { (cd "$1" 2>/dev/null && (pwd -W 2>/dev/null || pwd)) || printf '%s' "$1"; }

# Runs the CLI; sets CLI_RC and CLI_OUT (stdout+stderr merged).
run_cli() {
    CLI_RC=0
    CLI_OUT="$(run_with_timeout 60 node "$SCRIPT" "$@" 2>&1)" || CLI_RC=$?
}

# Extract `<key>=<n>` from the first output line mentioning <needle>.
metric() { # <needle> <key>
    local line
    line="$(grep -F -- "$1" <<< "$CLI_OUT" | head -1)"
    [ -n "$line" ] || { printf 'NO-LINE'; return 0; }
    local v
    v="$(grep -oE "$2=[0-9]+" <<< "$line" | head -1 | cut -d= -f2)"
    printf '%s' "${v:-NO-KEY}"
}

# Extract `<key>=<value>` from the summary line.
summary() { # <key>
    local line
    line="$(grep -F -- 'norm-docs-summary:' <<< "$CLI_OUT" | head -1)"
    [ -n "$line" ] || { printf 'NO-SUMMARY'; return 0; }
    local v
    v="$(grep -oE "$1=[A-Za-z0-9_~^-]+" <<< "$line" | head -1 | cut -d= -f2)"
    printf '%s' "${v:-NO-KEY}"
}

# POSIX read denial with proof it took effect. chmod is advisory on MSYS/Windows and
# ignored for root, so a naive `chmod 000` would produce a false PASS. Mirrors deny_read
# in tests/feature-1640-count-subagents.sh (CPR-ORTH).
deny_read() { # <path>
    chmod 000 "$1" 2>/dev/null || return 1
    head -c 1 "$1" >/dev/null 2>&1 && { chmod 644 "$1" 2>/dev/null || true; return 1; }
    return 0
}

# yes|no, but `no` is only reported when the tool actually produced a report — an
# absent file must never be indistinguishable from an absent run (no vacuous pass).
present() { # <needle> -> yes|no|NO-REPORT
    if grep -qF -- "$1" <<< "$CLI_OUT"; then printf 'yes'
    elif grep -qF -- 'norm-docs-summary:' <<< "$CLI_OUT"; then printf 'no'
    else printf 'NO-REPORT'; fi
}

# ---- fixture: the core repository -------------------------------------------
#
# Byte/line constants below are derived from these exact literals. `lines` counts
# newline-terminated content lines: a trailing newline does not add a line.
#
#   CLAUDE.md         "# Root\n"                        ->  7 bytes, 1 line   COUNTED
#   rules/a.md        "# A\nline two\n"                 -> 13 bytes, 2 lines  COUNTED
#   rules/b.md        frontmatter with `paths:`         -> excluded (conditional)
#   rules/_archived/c.md                                -> excluded (_archived)
#   rules/nofm-close.md  frontmatter with no closing --- -> 22 bytes, 3 lines COUNTED + warn
#   rules/other-key.md   frontmatter, other keys only    -> 21 bytes, 4 lines COUNTED
#   rules/notrail.md     "abc" (no trailing newline)     ->  3 bytes, 1 line  COUNTED
#
#   total: files=5 bytes=66 lines=11
CORE="$TMPROOT/core"
mkdir -p "$CORE/rules/_archived"
printf '# Root\n'                        > "$CORE/CLAUDE.md"
printf '# A\nline two\n'                 > "$CORE/rules/a.md"
printf -- '---\npaths:\n  - x\n---\n# B\n' > "$CORE/rules/b.md"
printf '# C\n'                           > "$CORE/rules/_archived/c.md"
printf -- '---\ntitle: x\n# broken\n'     > "$CORE/rules/nofm-close.md"
printf -- '---\ntitle: x\n---\n# D\n'     > "$CORE/rules/other-key.md"
printf 'abc'                             > "$CORE/rules/notrail.md"
CORE_NATIVE="$(native_path "$CORE")"

echo "== L1: always-loaded vs conditional split =="
run_cli --repo "$CORE_NATIVE"
assert_eq "L1/exit-0" "0" "$CLI_RC"

# Table-driven: same predicate (isAlwaysLoaded ∘ collectTargets) over 7 inputs.
while IFS='|' read -r name needle want; do
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name//[[:space:]]/}"
    needle="${needle//[[:space:]]/}"
    want="${want//[[:space:]]/}"
    assert_eq "L1/$name" "$want" "$(present "$needle")"
done <<'TABLE'
root-claude-md-counted   | CLAUDE.md     | yes
no-frontmatter-counted   | a.md          | yes
paths-key-not-counted    | b.md          | no
archived-not-counted     | c.md          | no
unclosed-fm-counted      | nofm-close.md | yes
other-key-fm-counted     | other-key.md  | yes
no-trailing-newline-kept | notrail.md    | yes
TABLE

echo "== L2: frontmatter edges =="
# An unclosed frontmatter block is treated as always-loaded AND must warn (it is a
# malformed document, not a silent inclusion).
WARN_STATE="no-warning-in-output"
if grep -qiE 'warn' <<< "$CLI_OUT" && grep -qF -- 'nofm-close.md' <<< "$CLI_OUT"; then
    WARN_STATE="warned"
fi
assert_eq "L2/unclosed-fm-warns" "warned" "$WARN_STATE"

echo "== L3: numeric accuracy (exact bytes/lines) =="
while IFS='|' read -r name needle key want; do
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name//[[:space:]]/}"; needle="${needle//[[:space:]]/}"
    key="${key//[[:space:]]/}"; want="${want//[[:space:]]/}"
    assert_eq "L3/$name" "$want" "$(metric "$needle" "$key")"
done <<'TABLE'
claude-md-bytes    | CLAUDE.md     | bytes |  7
claude-md-lines    | CLAUDE.md     | lines |  1
a-md-bytes         | a.md          | bytes | 13
a-md-lines         | a.md          | lines |  2
unclosed-fm-bytes  | nofm-close.md | bytes | 22
unclosed-fm-lines  | nofm-close.md | lines |  3
other-key-bytes    | other-key.md  | bytes | 21
other-key-lines    | other-key.md  | lines |  4
notrail-bytes      | notrail.md    | bytes |  3
notrail-lines      | notrail.md    | lines |  1
TABLE

echo "== L4: summary totals =="
assert_eq "L4/files" "5"        "$(summary files)"
assert_eq "L4/bytes" "66"       "$(summary bytes)"
assert_eq "L4/lines" "11"       "$(summary lines)"
assert_eq "L4/ref"   "worktree" "$(summary ref)"

echo "== L5: --json schema and total consistency =="
run_cli --repo "$CORE_NATIVE" --json
assert_eq "L5/exit-0" "0" "$CLI_RC"
JSON_PROBE="$(J="$CLI_OUT" run_with_timeout 30 node -e '
let d; try { d = JSON.parse(process.env.J); } catch (e) { console.log("PARSE-FAIL"); process.exit(0); }
const keys = ["generated_at", "repo", "ref", "files", "total"];
const missing = keys.filter((k) => !(k in d));
if (missing.length) { console.log("MISSING:" + missing.join(",")); process.exit(0); }
if (!Array.isArray(d.files)) { console.log("FILES-NOT-ARRAY"); process.exit(0); }
const rowKeys = d.files.every((f) => f && "path" in f && "bytes" in f && "lines" in f);
if (!rowKeys) { console.log("ROW-KEYS-MISSING"); process.exit(0); }
const sb = d.files.reduce((a, f) => a + f.bytes, 0);
const sl = d.files.reduce((a, f) => a + f.lines, 0);
const t = d.total || {};
console.log([
  t.files === d.files.length ? "files-ok" : "files-mismatch",
  t.bytes === sb ? "bytes-ok" : "bytes-mismatch",
  t.lines === sl ? "lines-ok" : "lines-mismatch",
].join(" "));
' 2>&1)" || true
assert_eq "L5/total-consistent" "files-ok bytes-ok lines-ok" "$JSON_PROBE"

# ---- L5b: --json carries the WARN / ERROR information too ---------------------
#
# Text mode prints a WARN row for a malformed document and an ERROR row for one that
# could not be read. A JSON report that dropped both would be indistinguishable from a
# complete measurement once stored, and asymmetric with `count-subagents --json`, which
# does carry `excluded` / `errors` (CPR-ORTH). CLI_OUT is still the clean --repo $CORE run
# from L5: 5 rows, one of them malformed, no failures.
echo "== L5b: per-file warning + top-level errors in --json =="
JSON_WARN_PROBE="$(J="$CLI_OUT" run_with_timeout 30 node -e '
let d; try { d = JSON.parse(process.env.J); } catch (e) { console.log("PARSE-FAIL"); process.exit(0); }
const by = {};
for (const f of d.files || []) by[f.path] = f;
const clean = by["CLAUDE.md"];
const bad = by["rules/nofm-close.md"];
if (!clean || !bad) { console.log("ROW-MISSING"); process.exit(0); }
console.log([
  !("warning" in clean) ? "clean-key-missing"
    : clean.warning === null ? "clean-null" : "clean-" + JSON.stringify(clean.warning),
  !("warning" in bad) ? "bad-key-missing"
    : (typeof bad.warning === "string" && bad.warning.length > 0) ? "bad-string"
    : "bad-" + JSON.stringify(bad.warning),
  // Present-and-empty, not absent-or-empty: a regression that drops the key entirely
  // must fail here rather than read as "no failures".
  !("errors" in d) ? "errors-key-missing"
    : !Array.isArray(d.errors) ? "errors-not-array"
    : d.errors.length === 0 ? "errors-empty" : "errors-" + d.errors.length,
].join(" "));
' 2>&1)" || true
assert_eq "L5b/warning-and-errors" "clean-null bad-string errors-empty" "$JSON_WARN_PROBE"

# The populated half: an unreadable document must land in `errors` AND keep the exit-code
# contract at 1. chmod is advisory on MSYS/Windows and ignored for root, so the denial is
# proven first — otherwise the row would assert a readable file and pass vacuously.
UNREAD="$TMPROOT/unreadable"
mkdir -p "$UNREAD/rules"
printf '# Root\n' > "$UNREAD/CLAUDE.md"
printf '# X\n'    > "$UNREAD/rules/locked.md"
if deny_read "$UNREAD/rules/locked.md"; then
    run_cli --repo "$(native_path "$UNREAD")" --json
    ERR_PROBE="$(J="$CLI_OUT" run_with_timeout 30 node -e '
let d; try { d = JSON.parse(process.env.J); } catch (e) { console.log("PARSE-FAIL"); process.exit(0); }
const e = (d.errors || [])[0];
console.log([
  (d.errors || []).length,
  e ? e.path : "NO-ENTRY",
  e && typeof e.code === "string" && e.code.length > 0 ? "has-code" : "no-code",
  (d.files || []).some((f) => f.path === "rules/locked.md") ? "row-leaked" : "no-row",
].join(" "));
' 2>&1)" || true
    assert_eq "L5b/unreadable-errors-entry" "1 1 rules/locked.md has-code no-row" \
        "$CLI_RC $ERR_PROBE"
    chmod -R u+rwx "$UNREAD" >/dev/null 2>&1 || true
else
    skip_case "L5b unreadable document: chmod is advisory on this host (or running as root), so no unreadable-file fixture can be produced — the populated errors[] + exit 1 half is unverifiable here"
fi

echo "== L6: --ref retroactive baseline =="
if ! command -v git >/dev/null 2>&1; then
    skip_case "L6 --ref cases: git not available on this host"
else
    REFREPO="$TMPROOT/refrepo"
    mkdir -p "$REFREPO"
    (
      cd "$REFREPO" || exit 1
      git init -q . >/dev/null 2>&1
      # A fresh `git init` inherits the globally configured core.hooksPath, which points
      # at this repo's hooks/. enforce-worktree / pre-commit would then refuse every
      # fixture commit ("commits from main worktree are blocked"), leaving a repo with
      # zero commits and an unresolvable HEAD~1. Repo-wide convention — see
      # tests/feature-1094-evidence-resolver.sh and tests/feature-1180-commit-lang-check/lib.sh.
      git config core.hooksPath /dev/null
      git config commit.gpgsign false
      git config user.email "test@example.com"
      git config user.name "Test"
      printf '# v1\n' > CLAUDE.md          #  5 bytes, 1 line
      git add -A >/dev/null 2>&1
      git commit -qm c1 >/dev/null 2>&1
      printf '# v1\n# v2 extra\n' > CLAUDE.md  # 16 bytes, 2 lines
      git add -A >/dev/null 2>&1
      git commit -qm c2 >/dev/null 2>&1
    )
    REFREPO_NATIVE="$(native_path "$REFREPO")"
    # `.git` existing proves only that `git init` ran. The --ref assertions need TWO
    # commits, so require HEAD~1 to resolve — a fixture that silently produced none must
    # FAIL loudly here rather than degrade every downstream row into NO-SUMMARY.
    FIXTURE_COMMITS="none"
    git -C "$REFREPO" rev-parse --verify -q 'HEAD~1' >/dev/null 2>&1 && FIXTURE_COMMITS="two-commits"
    assert_eq "L6/fixture-has-two-commits" "two-commits" "$FIXTURE_COMMITS"
    if [ "$FIXTURE_COMMITS" != "two-commits" ]; then
        skip_case "L6 --ref cases: fixture repo has no HEAD~1 (git init/commit failed)"
    else
        run_cli --repo "$REFREPO_NATIVE"
        assert_eq "L6/worktree-exit"  "0"  "$CLI_RC"
        assert_eq "L6/worktree-bytes" "16" "$(summary bytes)"
        assert_eq "L6/worktree-lines" "2"  "$(summary lines)"

        run_cli --repo "$REFREPO_NATIVE" --ref 'HEAD~1'
        assert_eq "L6/prev-exit"  "0" "$CLI_RC"
        assert_eq "L6/prev-bytes" "5" "$(summary bytes)"
        assert_eq "L6/prev-lines" "1" "$(summary lines)"

        # An unresolvable ref is an argument-class error, not "zero files".
        run_cli --repo "$REFREPO_NATIVE" --ref 'no-such-ref-1640'
        assert_eq "L6/bad-ref-exit-2" "2" "$CLI_RC"
    fi
fi

# ---- L6b: an empty but valid repo is a clean zero ----------------------------
#
# The positive counterpart of the L7 rejection rows: a directory that is a legitimate
# repo but happens to carry no normative docs must be a success with zeroes, not an
# error. Without this, a guard that treats "0 files" as a misconfiguration would pass
# every failure-side row while breaking every fresh repo.
echo "== L6b: an empty but valid repo reports zero and exits 0 =="
while IFS='|' read -r name mkrules; do
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name//[[:space:]]/}"; mkrules="${mkrules//[[:space:]]/}"
    empty="$TMPROOT/empty-$name"
    mkdir -p "$empty"
    [ "$mkrules" = "yes" ] && mkdir -p "$empty/rules"
    run_cli --repo "$(native_path "$empty")"
    assert_eq "L6b/$name" "0 files=0 bytes=0 lines=0" \
        "$CLI_RC files=$(summary files) bytes=$(summary bytes) lines=$(summary lines)"
done <<'EOF'
no-rules-dir      | no
empty-rules-dir   | yes
EOF

echo "== L7: argument handling =="
run_cli --help
assert_eq "L7/help-exit-0" "0" "$CLI_RC"

run_cli --repo "$CORE_NATIVE" --nope
assert_eq "L7/unknown-flag-exit-2" "2" "$CLI_RC"

run_cli --repo "rules"
assert_eq "L7/relative-repo-exit-2" "2" "$CLI_RC"

run_cli --repo "$CORE_NATIVE/../$(basename "$CORE")"
assert_eq "L7/dotdot-repo-exit-2" "2" "$CLI_RC"

run_cli "$CORE_NATIVE"
assert_eq "L7/positional-rejected-exit-2" "2" "$CLI_RC"

# `git show <ref>:<file>` has no `--` separator, so a `--ref` value starting with `-`
# would be read by git as an option. Two DIFFERENT code paths end at exit 2 and are kept
# as separate rows so the difference stays visible rather than collapsing into one
# "rejects a dash ref" claim.
#
# Equals form: parseArgs accepts `-foo` as the value, so rejectBadRef() is the thing that
# rejects it — the message is asserted because it is the only evidence that this row
# exercised the explicit check and not the `^{commit}` rev-parse gate behind it.
run_cli --repo "$CORE_NATIVE" --ref=-foo
REF_MSG="no-message"
grep -qF -- '--ref must not start with "-": -foo' <<< "$CLI_OUT" && REF_MSG="named-by-reject-bad-ref"
assert_eq "L7/ref-dash-equals-form-exit-2" "2 named-by-reject-bad-ref" "$CLI_RC $REF_MSG"

# Space form: Node's parseArgs intercepts it first ("Option '--ref' argument is
# ambiguous") and rejectBadRef() is never reached, so the message differs by design and
# only the exit code is asserted here. Pinning the rejectBadRef text on this row would
# assert the wrong path and break on a Node upgrade.
run_cli --repo "$CORE_NATIVE" --ref -foo
assert_eq "L7/ref-dash-space-form-exit-2" "2" "$CLI_RC"

# ---- L8: symlinks are not followed (Step 1-4) --------------------------------
#
# Its own repo fixture, so the L3/L4 constants stay a clean baseline:
#   CLAUDE.md      "# Root\n" -> 7 bytes, 1 line   COUNTED
#   rules/real.md  "# R\n"    -> 5 bytes, 1 line   COUNTED
#   total: files=2 bytes=12 lines=2
# plus a symlinked file and a symlinked directory, both of which must be skipped —
# following either would inflate every metric with content outside the repo.
echo "== L8: symlinked file / directory are not followed =="
SYMREPO="$TMPROOT/symrepo"
OUTSIDE="$TMPROOT/outside"
mkdir -p "$SYMREPO/rules" "$OUTSIDE/dir"
printf '# Root\n'                     > "$SYMREPO/CLAUDE.md"
printf '# R\n'                        > "$SYMREPO/rules/real.md"
printf '# LINKED\nmore\nand more\n'   > "$OUTSIDE/linked.md"
printf '# INDIR\nmore\n'              > "$OUTSIDE/dir/d.md"

# `ln -s` silently degrades to a copy on MSYS/Windows without developer mode or
# MSYS=winsymlinks:nativestrict, which would make a "not followed" assertion vacuous.
# Require a real symlink (`-L`) as proof before asserting.
SYM_FILE_OK=0
SYM_DIR_OK=0
ln -s "$OUTSIDE/linked.md" "$SYMREPO/rules/link.md" 2>/dev/null && [ -L "$SYMREPO/rules/link.md" ] && SYM_FILE_OK=1
ln -s "$OUTSIDE/dir"       "$SYMREPO/rules/linkdir" 2>/dev/null && [ -L "$SYMREPO/rules/linkdir" ] && SYM_DIR_OK=1

if [ "$SYM_FILE_OK" = 1 ] || [ "$SYM_DIR_OK" = 1 ]; then
    run_cli --repo "$(native_path "$SYMREPO")"
    assert_eq "L8/exit-0" "0" "$CLI_RC"
    assert_eq "L8/real-file-counted" "yes" "$(present 'rules/real.md')"
    assert_eq "L8/totals" "files=2 bytes=12 lines=2" \
        "files=$(summary files) bytes=$(summary bytes) lines=$(summary lines)"
    if [ "$SYM_FILE_OK" = 1 ]; then
        assert_eq "L8/symlinked-file-skipped" "no" "$(present 'rules/link.md')"
    else
        skip_case "L8 symlinked file: ln -s degraded to a copy on this host"
    fi
    if [ "$SYM_DIR_OK" = 1 ]; then
        assert_eq "L8/symlinked-dir-skipped" "no" "$(present 'linkdir')"
    else
        skip_case "L8 symlinked directory: ln -s degraded to a copy on this host"
    fi
else
    skip_case "L8 symlinks: ln -s degraded to a copy on this host (no native symlink support)"
fi

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
exit "$FAIL"
