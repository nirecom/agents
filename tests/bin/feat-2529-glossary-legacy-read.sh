#!/usr/bin/env bash
# tests/bin/feat-2529-glossary-legacy-read.sh
# Tests: bin/lib/glossary-format/files.js, bin/lib/codex-glossary.sh, bin/check-glossary-drift, bin/glossary-promote, bin/review-doc-glossary, bin/lib/glossary-provenance.js, bin/lib/glossary-format/cli.js, bin/check-glossary-provenance
# Tags: scope:issue-specific, TL2, glossary, migration, codex, drift, pwsh-not-required
# Issue #2529 T1-4 — the migration period: until this PR merges the main worktree still holds
# docs/glossary-<category>.md. The combined-glossary readers (codex prompt data and the drift
# CLI) fall back to those old paths per category, only for a category with no docs/glossary/ file; the
# writers never fall back and the staged gates refuse an added / modified old-layout file
# (the move away passes); one marked migration block per file, listed in files.js.
# Remove this file together with both migration blocks once their deletion-condition holds.
# TL3 gap: a real codex review run is not driven; codex_glossary_block is sourced and called.

set -uo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

TMP_ROOT="$(make_tmp)"
readonly TMP_ROOT
trap 'rm -rf "$TMP_ROOT"' EXIT
harness_isolate "$TMP_ROOT"
unset CLAUDE_CODE_SESSION_ID CLAUDE_PROJECT_DIR CODEX_GLOSSARY_MAX_LINES CODEX_GLOSSARY_MAX_BYTES 2>/dev/null || true
export CLAUDE_TRANSCRIPT_BASE_DIR="$TMP_ROOT/transcripts"
mkdir -p "$CLAUDE_TRANSCRIPT_BASE_DIR"

START_DELIM="[COMBINED GLOSSARY START]"
FILES_JS="$SCRIPT_CHECKOUT_ROOT/bin/lib/glossary-format/files.js"
PROV_JS="$SCRIPT_CHECKOUT_ROOT/bin/lib/glossary-provenance.js"

# --- helpers ---------------------------------------------------------------

has() { if [ -f "$2" ] && grep -qF -- "$3" "$2"; then pass "$1"; else fail "$1" "'$3' absent from $(basename "$2")"; fi; }
lacks() {
    if [ ! -s "$2" ]; then fail "$1" "$(basename "$2") missing or empty; absence not provable"
    elif grep -qF -- "$3" "$2"; then fail "$1" "'$3' unexpectedly present in $(basename "$2")"
    else pass "$1"; fi
}

# entry_file <file> <title> <term> <definition>
entry_file() {
    mkdir -p "$(dirname "$1")"
    printf '# %s\n\n### %s\n\n- **Definition**: %s\n- **Related**: [README.md](../README.md)\n' "$2" "$3" "$4" > "$1"
}

commit_all() {
    git -C "$1" add -A >/dev/null 2>&1
    git -C "$1" -c user.email=t@example.com -c user.name=T -c commit.gpgsign=false commit -q -m "$2" >/dev/null 2>&1
}

CFG="$TMP_ROOT/cfg"
mkdir -p "$CFG/rules" "$CFG/bin"
cp -R "$SCRIPT_CHECKOUT_ROOT/bin/lib" "$CFG/bin/lib"
cp "$SCRIPT_CHECKOUT_ROOT/rules/core-principles.md" "$CFG/rules/core-principles.md"
printf 'CODE_LANG=english\n' > "$CFG/.env"

# The probe programs are heredocs, not multi-line quoted strings, so the case-marker reader
# tracks nesting depth below unambiguously.
# GLOSS_BLOCK_SH: args <checkout-root> <project-root> — rc 3: not sourceable, 4: function absent.
read -r -d '' GLOSS_BLOCK_SH <<'SH' || true
source "$1/bin/lib/codex-core.sh" >/dev/null 2>&1 || exit 3
source "$1/bin/lib/codex-glossary.sh" >/dev/null 2>&1 || exit 3
declare -F codex_glossary_block >/dev/null || exit 4
codex_glossary_block "$2"
SH

# SEED_SESSION_JS: args <checkout-root> <sid> <cwd> — a raw v2 state whose current step is
# clarify_intent (every earlier non-terminal step complete).
read -r -d '' SEED_SESSION_JS <<'JS' || true
const path = require("path"); const fs = require("fs");
const [root, sid, cwd] = process.argv.slice(1);
const { VALID_STEPS, TERMINAL_STEPS } = require(path.join(root, "hooks/workflow-state"));
const at = new Date().toISOString(); const events = [];
for (const s of VALID_STEPS) {
  if (s === "clarify_intent") break;
  if (TERMINAL_STEPS.includes(s)) continue;
  events.push({ kind: "step_status", step: s, status: "complete", provenance: "observed", origin: "test-fixture" });
}
events.forEach((e, i) => { e.at = at; e.seq = i + 1; });
fs.writeFileSync(path.join(process.env.WORKFLOW_STATE_DIR, sid + ".json"), JSON.stringify({ version: 2, session_id: sid,
  created_at: at, session_start_context: { cwd, git_branch: "feature/legacy-read" }, workflow_type: "wf-code",
  deliverable_type: "wf-code", events }, null, 2));
JS

# gloss_block <project-root> <out> — rc 3: not sourceable, 4: function absent.
gloss_block() {
    run_with_timeout 30 env AGENTS_MAIN_ROOT="$CFG" bash -c "$GLOSS_BLOCK_SH" _ "$SCRIPT_CHECKOUT_ROOT" "$1" > "$2" 2>/dev/null
}

# seed_session <sid> <cwd> <intent-body-file> — intent.md plus the SEED_SESSION_JS state.
seed_session() {
    cp "$3" "$WORKFLOW_PLANS_DIR/$1-intent.md"
    node -e "$SEED_SESSION_JS" "$SCRIPT_CHECKOUT_ROOT" "$1" "$2"
}

# drift <sid> <cwd> <out> — check-glossary-drift for the intent stage; echoes the exit code.
drift() {
    (cd "$2" && run_with_timeout 60 env AGENTS_MAIN_ROOT="$SCRIPT_CHECKOUT_ROOT" \
        node "$SCRIPT_CHECKOUT_ROOT/bin/check-glossary-drift" --session "$1" --stage intent > "$3" 2>&1)
    echo $?
}

# intent_body <out> <goal-line> <glossary-table-rows...>
intent_body() {
    local out="$1" goal="$2"; shift 2
    {
        printf '# Intent\n\n## Issues\n\n- #1 fixture\n\n## Glossary\n\n'
        printf '| Term | Category | Operation | Definition |\n|---|---|---|---|\n'
        for row in "$@"; do printf '%s\n' "$row"; done
        printf '\n## Goal\n\n%s\n' "$goal"
    } > "$out"
}

# --- fixture: main worktree on old paths, linked worktree on new paths -------

WT_MAIN="$TMP_ROOT/wt/main"; WT_LINKED="$TMP_ROOT/wt/linked"
mkdir -p "$TMP_ROOT/wt"
harness_git_init "$WT_MAIN" >/dev/null 2>&1
entry_file "$WT_MAIN/docs/glossary-user.md" "Glossary - user" "glossary drift" "LEGACYUSERDEF a spelling that differs."
entry_file "$WT_MAIN/docs/glossary-internal.md" "Glossary - internal" "kilo term" "LEGACYINTERNALDEF an internal term."
printf '# Fixture\n' > "$WT_MAIN/README.md"
commit_all "$WT_MAIN" "init (old paths)"
git -C "$WT_MAIN" worktree add -q -b side "$WT_LINKED" >/dev/null 2>&1
if [ -f "$WT_LINKED/.git" ]; then
    pass "fixture/linked-worktree-created"
    mkdir -p "$WT_LINKED/docs/glossary"
    git -C "$WT_LINKED" mv docs/glossary-user.md docs/glossary/user.md >/dev/null 2>&1
    git -C "$WT_LINKED" mv docs/glossary-internal.md docs/glossary/internal.md >/dev/null 2>&1
    entry_file "$WT_LINKED/docs/glossary/user.md" "Glossary - user" "linked term" "NEWLINKEDDEF only in the linked copy."
else
    fail "fixture/linked-worktree-created" "git worktree add did not produce $WT_LINKED"
fi

# ============================================================================
case_begin "codex-block-falls-back-to-old-paths" "bin/lib/codex-glossary.sh"
# ============================================================================
B_LEG="$TMP_ROOT/block-legacy.txt"
gloss_block "$WT_LINKED" "$B_LEG"; rc=$?
if [ "$rc" -eq 0 ]; then pass "L1/probe-ran"; else fail "L1/probe-ran" "rc=$rc"; fi
has "L1/old-path-user-entry-read" "$B_LEG" "LEGACYUSERDEF"
has "L1/old-path-internal-entry-read" "$B_LEG" "LEGACYINTERNALDEF"
has "L1/label-is-the-old-path" "$B_LEG" "docs/glossary-user.md"
lacks "L1/linked-copy-not-read" "$B_LEG" "NEWLINKEDDEF"
case_end

# ============================================================================
case_begin "drift-falls-back-to-old-paths" "bin/check-glossary-drift"
# ============================================================================
SID_LEG="p2529-legacy-drift-$$"; INTENT_LEG="$TMP_ROOT/intent-legacy.md"
intent_body "$INTENT_LEG" "Mid-line the glossary-drift shows up here." "| unrelated thing | session | add | Not a glossary term. |"
seed_session "$SID_LEG" "$WT_MAIN" "$INTENT_LEG"  # drift reads its own worktree's glossary (#2796)
D_LEG="$TMP_ROOT/drift-legacy.txt"
rc="$(drift "$SID_LEG" "$WT_MAIN" "$D_LEG")"
if [ "$rc" = "1" ]; then pass "L2/drift-exit-1"; else fail "L2/drift-exit-1" "rc=$rc $(head -c 300 "$D_LEG" 2>/dev/null)"; fi
has "L2/old-path-term-variant-is-drift" "$D_LEG" '"glossary-drift" -> "glossary drift"'
case_end

# ============================================================================
case_begin "new-dir-wins-over-old-files" "bin/lib/glossary-format/files.js"
# ============================================================================
BOTH="$TMP_ROOT/both"
harness_git_init "$BOTH" >/dev/null 2>&1
entry_file "$BOTH/docs/glossary/user.md" "Glossary - user" "new term" "NEWDIRDEF from docs/glossary."
entry_file "$BOTH/docs/glossary-user.md" "Glossary - user" "old term" "OLDSHADOWDEF from the old path."
printf '# Fixture\n' > "$BOTH/README.md"
commit_all "$BOTH" "init (both)"
B_BOTH="$TMP_ROOT/block-both.txt"
gloss_block "$BOTH" "$B_BOTH"; rc=$?
if [ "$rc" -eq 0 ]; then pass "L3/probe-ran"; else fail "L3/probe-ran" "rc=$rc"; fi
has "L3/new-dir-entry-read" "$B_BOTH" "NEWDIRDEF"
lacks "L3/old-file-not-read-when-new-dir-exists" "$B_BOTH" "OLDSHADOWDEF"
case_end

# ============================================================================
case_begin "neither-layout-is-not-an-error" "bin/check-glossary-drift"
# ============================================================================
NONE="$TMP_ROOT/none"
harness_git_init "$NONE" >/dev/null 2>&1
mkdir -p "$NONE/docs"; printf '# Other\n' > "$NONE/docs/other.md"
commit_all "$NONE" "init (no glossary)"
B_NONE="$TMP_ROOT/block-none.txt"
gloss_block "$NONE" "$B_NONE"; rc=$?
if [ "$rc" -eq 0 ] && [ -s "$B_NONE" ]; then pass "L4/codex-instruction-part-only"; else fail "L4/codex-instruction-part-only" "rc=$rc"; fi
lacks "L4/codex-no-data-part" "$B_NONE" "$START_DELIM"
SID_NONE="p2529-legacy-none-$$"
INTENT_NONE="$TMP_ROOT/intent-none.md"
intent_body "$INTENT_NONE" "The concern-ledger is spelled with a hyphen here." "| concern ledger | internal | add | The per-round list of review concerns. |"
seed_session "$SID_NONE" "$NONE" "$INTENT_NONE"
D_NONE="$TMP_ROOT/drift-none.txt"
rc="$(drift "$SID_NONE" "$NONE" "$D_NONE")"
if [ "$rc" = "1" ]; then pass "L4/drift-runs-on-intent-rows-only"; else fail "L4/drift-runs-on-intent-rows-only" "rc=$rc $(head -c 300 "$D_NONE" 2>/dev/null)"; fi
has "L4/intent-row-variant-is-drift" "$D_NONE" '"concern-ledger" -> "concern ledger"'
SID_CLEAN="p2529-legacy-clean-$$"
INTENT_CLEAN="$TMP_ROOT/intent-clean.md"
intent_body "$INTENT_CLEAN" "The concern ledger is spelled as agreed." "| concern ledger | internal | add | The per-round list of review concerns. |"
seed_session "$SID_CLEAN" "$NONE" "$INTENT_CLEAN"
rc="$(drift "$SID_CLEAN" "$NONE" "$TMP_ROOT/drift-clean.txt")"
if [ "$rc" = "0" ]; then pass "L4/no-glossary-and-no-variant-exits-0"; else fail "L4/no-glossary-and-no-variant-exits-0" "rc=$rc $(head -c 300 "$TMP_ROOT/drift-clean.txt" 2>/dev/null)"; fi
case_end

# ============================================================================
case_begin "writers-and-format-gate-have-no-fallback" "bin/glossary-promote"
# ============================================================================
OLD="$TMP_ROOT/oldonly"
harness_git_init "$OLD" >/dev/null 2>&1
entry_file "$OLD/docs/glossary-user.md" "Glossary - user" "alpha" "OLDONLYDEF the first term."
entry_file "$OLD/docs/glossary-internal.md" "Glossary - internal" "kilo" "OLDONLYDEF an internal term."
printf '# Fixture\n' > "$OLD/README.md"
commit_all "$OLD" "init (old only)"
cp "$OLD/docs/glossary-user.md" "$TMP_ROOT/old-user-before.md"
RDG_OUT="$TMP_ROOT/rdg-old.txt"
(cd "$OLD" && run_with_timeout 60 bash "$SCRIPT_CHECKOUT_ROOT/bin/review-doc-glossary" --all > "$RDG_OUT" 2>&1)
has "L5/review-doc-glossary-lists-no-old-path-file" "$RDG_OUT" "(no glossary entry files in the working tree)"
lacks "L5/review-doc-glossary-checks-no-old-path-file" "$RDG_OUT" "OK:"
SID_PRO="p2529-legacy-promote-$$"
{
    printf '# Intent\n\n## Issues\n\n- #1 fixture\n\n## Glossary\n\n'
    printf '| Term | Category | Definition |\n|---|---|---|\n| beta | user | A legacy fixture term. |\n\n## Goal\n\nx\n'
} > "$TMP_ROOT/intent-promote.md"
seed_session "$SID_PRO" "$OLD" "$TMP_ROOT/intent-promote.md"
node -e '
  const path = require("path"); const fs = require("fs");
  const [root, sid] = process.argv.slice(1);
  const { computeArtifactSha } = require(path.join(root, "hooks/workflow-state/completion-approval.js"));
  const p = path.join(process.env.WORKFLOW_STATE_DIR, sid + ".json");
  const st = JSON.parse(fs.readFileSync(p, "utf8"));
  st.events.push({ kind: "step_status", step: "clarify_intent", status: "complete", provenance: "observed", origin: "test-fixture",
    at: new Date().toISOString(), seq: st.events.length + 1 });
  st.events.push({ kind: "plan_approval", step: "clarify_intent", source: "confirm-sentinel", reason: "fixture approval",
    artifact_sha256: computeArtifactSha(sid, "clarify_intent"), artifact_session_id: sid, artifact_hash_status: "recorded",
    provenance: "declared", origin: "test-fixture", at: new Date().toISOString(), seq: st.events.length + 1 });
  fs.writeFileSync(p, JSON.stringify(st, null, 2));
' "$SCRIPT_CHECKOUT_ROOT" "$SID_PRO"
PRO_OUT="$TMP_ROOT/promote-old.txt"
(cd "$OLD" && run_with_timeout 60 node "$SCRIPT_CHECKOUT_ROOT/bin/glossary-promote" "$WORKFLOW_PLANS_DIR/$SID_PRO-intent.md" "$OLD" > "$PRO_OUT" 2>&1)
rc=$?
if [ "$rc" -eq 0 ]; then pass "L5/promote-exits-0"; else fail "L5/promote-exits-0" "rc=$rc $(head -c 300 "$PRO_OUT")"; fi
has "L5/promote-summary-counts-nothing" "$PRO_OUT" "ADDED=0 DELETED=0 REDEFINED=0 SKIPPED_EXISTING=0 SKIPPED_SESSION=0"
has "L5/promote-warns-no-user-glossary-file" "$PRO_OUT" "WARN: no user glossary file; 'beta' not promoted"
if cmp -s "$OLD/docs/glossary-user.md" "$TMP_ROOT/old-user-before.md"; then pass "L5/promote-never-writes-an-old-path-file"
else fail "L5/promote-never-writes-an-old-path-file" "docs/glossary-user.md changed: $(head -c 300 "$PRO_OUT")"; fi
if [ ! -e "$OLD/docs/glossary" ]; then pass "L5/promote-creates-no-glossary-dir"; else fail "L5/promote-creates-no-glossary-dir" "docs/glossary appeared"; fi
porcelain="$(git -C "$OLD" status --porcelain --untracked-files=all 2>&1)"
if [ -z "$porcelain" ]; then pass "L5/promote-leaves-working-tree-clean"; else fail "L5/promote-leaves-working-tree-clean" "$porcelain"; fi
case_end

# ============================================================================
case_begin "empty-new-dir-falls-back-to-old-files" "bin/lib/glossary-format/files.js"
# ============================================================================
# list_main <root> — "<count> <legacy> <labels,...>" from listMainGlossaryFiles.
list_main() {
    node -e 'const r = require(process.argv[1]).listMainGlossaryFiles(process.argv[2]); console.log(r.files.length + " " + r.legacy + " " + r.files.map((f) => f.label).join(","));' "$FILES_JS" "$1" 2>&1
}
EMPTY="$TMP_ROOT/emptydir"
harness_git_init "$EMPTY" >/dev/null 2>&1
entry_file "$EMPTY/docs/glossary-user.md" "Glossary - user" "old term" "EMPTYDIRSHADOWDEF from the old path."
printf '# Fixture\n' > "$EMPTY/README.md"
commit_all "$EMPTY" "init (old files)"
mkdir -p "$EMPTY/docs/glossary"
got="$(list_main "$EMPTY")"
if [ "$got" = "1 true docs/glossary-user.md" ]; then pass "L7/empty-dir-with-old-files-lists-them-as-legacy"; else fail "L7/empty-dir-with-old-files-lists-them-as-legacy" "got=$got"; fi
B_EMPTY="$TMP_ROOT/block-empty.txt"
gloss_block "$EMPTY" "$B_EMPTY"; rc=$?
if [ "$rc" -eq 0 ]; then pass "L7/probe-ran"; else fail "L7/probe-ran" "rc=$rc"; fi
has "L7/codex-old-file-read" "$B_EMPTY" "EMPTYDIRSHADOWDEF"
has "L7/codex-data-part-present" "$B_EMPTY" "$START_DELIM"

EMPTY_NONE="$TMP_ROOT/emptydir-nolegacy"
mkdir -p "$EMPTY_NONE/docs/glossary"
printf '# Other\n' > "$EMPTY_NONE/docs/other.md"
got="$(list_main "$EMPTY_NONE")"
if [ "$got" = "0 false " ]; then pass "L7/empty-dir-without-old-files-is-empty-and-not-legacy"; else fail "L7/empty-dir-without-old-files-is-empty-and-not-legacy" "got=$got"; fi

NEW_ONLY="$TMP_ROOT/newdir-and-old"
entry_file "$NEW_ONLY/docs/glossary/user.md" "Glossary - user" "new term" "NEWONLYDEF from docs/glossary."
entry_file "$NEW_ONLY/docs/glossary-user.md" "Glossary - user" "old term" "OLDIGNOREDDEF from the old path."
got="$(list_main "$NEW_ONLY")"
if [ "$got" = "1 false docs/glossary/user.md" ]; then pass "L7/dir-with-a-file-lists-the-new-layout-only"; else fail "L7/dir-with-a-file-lists-the-new-layout-only" "got=$got"; fi
case_end

# ============================================================================
case_begin "legacy-name-re-table" "bin/lib/glossary-format/files.js"
# ============================================================================
while IFS='|' read -r name input want; do
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name//[[:space:]]/}"; input="${input//[[:space:]]/}"; want="${want//[[:space:]]/}"
    got="$(node -e 'const { LEGACY_NAME_RE } = require(process.argv[1]); console.log(LEGACY_NAME_RE.test(process.argv[2]) ? "match" : "no-match");' "$FILES_JS" "$input" 2>&1)"
    if [ "$got" = "$want" ]; then pass "L8/$name"; else fail "L8/$name" "input=$input want=$want got=$got"; fi
done <<'TABLE'
user-unsplit            | docs/glossary-user.md            | match
internal-unsplit        | docs/glossary-internal.md        | match
user-range-split        | docs/glossary-user-a-m.md        | match
internal-range-single   | docs/glossary-internal-q-q.md    | match
reversed-range-regex    | docs/glossary-user-z-a.md        | match
unknown-category        | docs/glossary-session.md         | no-match
range-one-letter        | docs/glossary-user-a.md          | no-match
range-two-letters       | docs/glossary-user-ab-m.md       | no-match
range-uppercase         | docs/glossary-user-A-M.md        | no-match
range-digit             | docs/glossary-user-1-9.md        | no-match
range-underscore-sep    | docs/glossary-user_a-m.md        | no-match
trailing-hyphen         | docs/glossary-user-.md           | no-match
leading-prefix          | x/docs/glossary-user.md          | no-match
new-layout-path         | docs/glossary/user.md            | no-match
nested-dir              | docs/sub/glossary-user.md        | no-match
wrong-extension         | docs/glossary-user.txt           | no-match
suffix-after-md         | docs/glossary-user.md.bak        | no-match
unrelated-doc           | docs/other.md                    | no-match
backslash-separator     | docs\glossary-user.md            | no-match
TABLE
REV="$TMP_ROOT/reversed"
entry_file "$REV/docs/glossary-user-a-m.md" "Glossary - user a-m" "alpha" "A ranged term."
entry_file "$REV/docs/glossary-user-z-a.md" "Glossary - user z-a" "zulu" "A reversed range."
entry_file "$REV/docs/glossary-session.md" "Glossary - session" "sigma" "Not a legacy category."
# A reversed legacy range throws naming the file (its terms must not vanish silently);
# a docs file outside the legacy category names stays out of the message.
got="$(node -e 'try { const r = require(process.argv[1]).listMainGlossaryFiles(process.argv[2]); console.log("listed:" + r.files.map((f) => f.label).join(",")); } catch (e) { console.log("threw:" + e.message); }' "$FILES_JS" "$REV" 2>&1)"
case "$got" in
    "threw:docs/glossary-user-z-a.md: unparseable glossary file name"*) pass "L8/reversed-range-file-throws-naming-it" ;;
    *) fail "L8/reversed-range-file-throws-naming-it" "got=$got" ;;
esac
case "$got" in
    *glossary-session.md*|*glossary-user-a-m.md*) fail "L8/reversed-range-message-names-only-the-bad-file" "got=$got" ;;
    *) pass "L8/reversed-range-message-names-only-the-bad-file" ;;
esac
SOURCES_JS="$SCRIPT_CHECKOUT_ROOT/hooks/workflow-state/glossary-check/scope/sources.js"
git -C "$REV" init -q >/dev/null 2>&1
git -C "$REV" config core.hooksPath /dev/null
got="$(node -e 'const g = require(process.argv[1]).combinedGlossary({ repoDir: process.argv[2] }); console.log(String(g.ok) + "|" + g.error + "|" + g.detail);' "$SOURCES_JS" "$REV" 2>&1)"
case "$got" in
    "false|glossary-unavailable|"*"docs/glossary-user-z-a.md: unparseable glossary file name"*) pass "L8/reversed-range-fingerprint-reader-fails-closed" ;;
    *) fail "L8/reversed-range-fingerprint-reader-fails-closed" "got=$got" ;;
esac
pd_out="$(node "$SCRIPT_CHECKOUT_ROOT/bin/lib/glossary-format.js" prompt-data --root "$REV" 2>"$TMP_ROOT/rev-pd.err")"
pd_rc=$?
if [ "$pd_rc" = 2 ] && [ -z "$pd_out" ] && grep -qF "docs/glossary-user-z-a.md: unparseable glossary file name" "$TMP_ROOT/rev-pd.err"; then
    pass "L8/reversed-range-prompt-data-exits-2-naming-it"
else
    fail "L8/reversed-range-prompt-data-exits-2-naming-it" "rc=$pd_rc out=$pd_out err=$(cat "$TMP_ROOT/rev-pd.err")"
fi
case_end

# ============================================================================
case_begin "migration-block-markers" "bin/lib/glossary-format/files.js"
# ============================================================================
BEGIN_LINE='// --- BEGIN temporary: docs/glossary-<category>.md -> docs/glossary/<category>.md migration added 2026-10-17 ---'
COND_PREFIX='// deletion-condition: remove once origin/main has no docs/glossary-user.md / docs/glossary-internal.md and no worktree in "git worktree list" still has them'
END_LINE='// --- END temporary: docs/glossary-<category>.md -> docs/glossary/<category>.md migration ---'
for f in "$FILES_JS" "$PROV_JS"; do
    name="$(basename "$f")"
    if [ ! -f "$f" ]; then fail "L6/$name/exists" "missing"; continue; fi
    b="$(grep -nF -- "$BEGIN_LINE" "$f" | head -1 | cut -d: -f1)"
    e="$(grep -nF -- "$END_LINE" "$f" | head -1 | cut -d: -f1)"
    nb="$(grep -cF -- "BEGIN temporary: docs/glossary-<category>.md" "$f")"
    if [ -n "$b" ] && [ "$nb" = "1" ]; then pass "L6/$name/one-begin-line"; else fail "L6/$name/one-begin-line" "begin=${b:-none} count=$nb"; fi
    if [ -n "$b" ] && sed -n "$((b + 1))p" "$f" | sed 's/^[ \t]*//' | grep -qF -- "$COND_PREFIX"; then pass "L6/$name/deletion-condition-follows-begin"
    else fail "L6/$name/deletion-condition-follows-begin" "line after BEGIN is not the deletion-condition"; fi
    if [ -n "$b" ] && sed -n "$((b + 1))p" "$f" | grep -qF -- "tests/bin/feat-2529-glossary-legacy-read.sh"; then pass "L6/$name/deletion-condition-names-this-test"
    else fail "L6/$name/deletion-condition-names-this-test" "deletion-condition does not name this test"; fi
    if [ -n "$b" ] && [ -n "$e" ] && [ "$e" -gt "$b" ]; then pass "L6/$name/end-after-begin"; else fail "L6/$name/end-after-begin" "begin=${b:-none} end=${e:-none}"; fi
done
case_end

# ============================================================================
case_begin "staged-legacy-path-rejected" "bin/review-doc-glossary"
# ============================================================================
# The index-side term sets skip old-layout paths, so a staged add / modify of one would carry
# terms no provenance operation shows: both the format gate and the provenance CLI refuse it.
# A deletion (the move away into docs/glossary/) passes.
PROV_CLI="$SCRIPT_CHECKOUT_ROOT/bin/check-glossary-provenance"
RDG="$SCRIPT_CHECKOUT_ROOT/bin/review-doc-glossary"
# staged_gates <repo> <tag> — runs both gates on the index; sets RDG_RC / PROV_RC.
staged_gates() {
    (cd "$1" && run_with_timeout 60 bash "$RDG" --staged > "$TMP_ROOT/rdg-$2.txt" 2>&1); RDG_RC=$?
    (cd "$1" && run_with_timeout 60 node "$PROV_CLI" --staged --repo "$1" > "$TMP_ROOT/prov-$2.txt" 2>&1); PROV_RC=$?
}
ADD="$TMP_ROOT/staged-add"
harness_git_init "$ADD" >/dev/null 2>&1
entry_file "$ADD/docs/glossary/user.md" "Glossary - user" "alpha" "NEWLAYOUTDEF the first term."
entry_file "$ADD/docs/glossary/internal.md" "Glossary - internal" "kilo" "NEWLAYOUTDEF an internal term."
printf '# Fixture\n' > "$ADD/README.md"
commit_all "$ADD" "init (new layout)"
entry_file "$ADD/docs/glossary-user.md" "Glossary - user" "smuggled" "SMUGGLEDDEF a term no operation shows."
git -C "$ADD" add docs/glossary-user.md
staged_gates "$ADD" add
if [ "$RDG_RC" -eq 1 ]; then pass "L9/add/review-doc-glossary-exits-1"; else fail "L9/add/review-doc-glossary-exits-1" "rc=$RDG_RC $(head -c 300 "$TMP_ROOT/rdg-add.txt")"; fi
has "L9/add/review-doc-glossary-performs" "$TMP_ROOT/rdg-add.txt" "PERFORMED (staged mode)"
has "L9/add/review-doc-glossary-names-old-layout" "$TMP_ROOT/rdg-add.txt" "BLOCK: docs/glossary-user.md: old glossary layout"
has "L9/add/review-doc-glossary-points-at-new-file" "$TMP_ROOT/rdg-add.txt" "docs/glossary/user.md"
if [ "$PROV_RC" -eq 1 ]; then pass "L9/add/provenance-exits-1"; else fail "L9/add/provenance-exits-1" "rc=$PROV_RC $(head -c 300 "$TMP_ROOT/prov-add.txt")"; fi
has "L9/add/glossary-provenance-check-not-judged" "$TMP_ROOT/prov-add.txt" "BLOCK: glossary provenance check not judged — docs/glossary-user.md: old glossary layout"
lacks "L9/add/provenance-no-zero-op-pass" "$TMP_ROOT/prov-add.txt" "no glossary operation staged"

MOV="$TMP_ROOT/staged-move"
harness_git_init "$MOV" >/dev/null 2>&1
entry_file "$MOV/docs/glossary-user.md" "Glossary - user" "alpha" "MOVEDEF the first term."
entry_file "$MOV/docs/glossary-internal.md" "Glossary - internal" "kilo" "MOVEDEF an internal term."
printf '# Fixture\n' > "$MOV/README.md"
commit_all "$MOV" "init (old layout)"
printf '\n### beta\n\n- **Definition**: MODIFIEDDEF a new term.\n- **Related**: [README.md](../README.md)\n' >> "$MOV/docs/glossary-user.md"
git -C "$MOV" add docs/glossary-user.md
staged_gates "$MOV" modify
if [ "$RDG_RC" -eq 1 ]; then pass "L9/modify/review-doc-glossary-exits-1"; else fail "L9/modify/review-doc-glossary-exits-1" "rc=$RDG_RC $(head -c 300 "$TMP_ROOT/rdg-modify.txt")"; fi
has "L9/modify/review-doc-glossary-names-old-layout" "$TMP_ROOT/rdg-modify.txt" "BLOCK: docs/glossary-user.md: old glossary layout"
if [ "$PROV_RC" -eq 1 ]; then pass "L9/modify/provenance-exits-1"; else fail "L9/modify/provenance-exits-1" "rc=$PROV_RC $(head -c 300 "$TMP_ROOT/prov-modify.txt")"; fi
has "L9/modify/glossary-provenance-check-not-judged" "$TMP_ROOT/prov-modify.txt" "glossary provenance check not judged — docs/glossary-user.md"
git -C "$MOV" reset -q -- docs/glossary-user.md
git -C "$MOV" checkout -q -- docs/glossary-user.md
mkdir -p "$MOV/docs/glossary"
git -C "$MOV" mv docs/glossary-user.md docs/glossary/user.md
git -C "$MOV" mv docs/glossary-internal.md docs/glossary/internal.md
staged_gates "$MOV" move
has "L9/move/review-doc-glossary-performs" "$TMP_ROOT/rdg-move.txt" "PERFORMED (staged mode)"
lacks "L9/move/review-doc-glossary-no-old-layout-block" "$TMP_ROOT/rdg-move.txt" "old glossary layout"
if [ "$RDG_RC" -eq 0 ]; then pass "L9/move/review-doc-glossary-exits-0"; else fail "L9/move/review-doc-glossary-exits-0" "rc=$RDG_RC $(head -c 300 "$TMP_ROOT/rdg-move.txt")"; fi
if [ "$PROV_RC" -eq 0 ]; then pass "L9/move/provenance-exits-0"; else fail "L9/move/provenance-exits-0" "rc=$PROV_RC $(head -c 300 "$TMP_ROOT/prov-move.txt")"; fi
has "L9/move/provenance-zero-operations" "$TMP_ROOT/prov-move.txt" "glossary provenance check: no glossary operation staged"

# A malformed old-layout name (one-letter range) is no valid entry file name either way: both refuse it.
MALF="$TMP_ROOT/staged-malformed"
harness_git_init "$MALF" >/dev/null 2>&1
entry_file "$MALF/docs/glossary/user.md" "Glossary - user" "alpha" "MALFNEWDEF the first term."
printf '# Fixture\n' > "$MALF/README.md"
commit_all "$MALF" "init (new layout)"
entry_file "$MALF/docs/glossary-user-a.md" "Glossary - user a" "smuggled" "MALFDEF a term no operation shows."
git -C "$MALF" add docs/glossary-user-a.md
staged_gates "$MALF" malformed
if [ "$RDG_RC" -ne 0 ]; then pass "L9/malformed/review-doc-glossary-exits-nonzero"; else fail "L9/malformed/review-doc-glossary-exits-nonzero" "rc=$RDG_RC $(head -c 300 "$TMP_ROOT/rdg-malformed.txt")"; fi
has "L9/malformed/review-doc-glossary-names-old-layout" "$TMP_ROOT/rdg-malformed.txt" "BLOCK: docs/glossary-user-a.md: old glossary layout"
if [ "$PROV_RC" -ne 0 ]; then pass "L9/malformed/provenance-exits-nonzero"; else fail "L9/malformed/provenance-exits-nonzero" "rc=$PROV_RC $(head -c 300 "$TMP_ROOT/prov-malformed.txt")"; fi
has "L9/malformed/glossary-provenance-check-not-judged" "$TMP_ROOT/prov-malformed.txt" "glossary provenance check not judged — docs/glossary-user-a.md"
lacks "L9/malformed/provenance-no-zero-op-pass" "$TMP_ROOT/prov-malformed.txt" "no glossary operation staged"

got="$(node -e 'console.log(JSON.stringify(require(process.argv[1]).legacyLayoutBlocks(process.argv.slice(2)).map((b) => b.split(":")[0])));' "$FILES_JS" 'docs\glossary-internal-a-m.md' docs/glossary-user-z-a.md docs/glossary-session.md docs/glossary/user.md docs/other.md 2>&1)"
if [ "$got" = '["docs/glossary-internal-a-m.md","docs/glossary-user-z-a.md"]' ]; then pass "L9/legacy-layout-blocks-table"; else fail "L9/legacy-layout-blocks-table" "got=$got"; fi
case_end

# ============================================================================
case_begin "legacy-fallback-is-per-category" "bin/lib/glossary-format/files.js"
# ============================================================================
# A category with a docs/glossary/ file never reads its legacy files; a category without one
# still does, whatever the other category holds. Each fixture file's definition carries a
# marker derived from its path, so the codex reader can be checked for exactly the listed set.
# mark_of <label> — DEFMARK_<label with / -> S, - -> H, . -> D>, so the new-layout and legacy
# names of one category stay distinct.
mark_of() { local m="${1//\//S}"; m="${m//-/H}"; m="${m//./D}"; printf 'DEFMARK_%s' "$m"; }
while IFS='|' read -r name files want_list; do
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name//[[:space:]]/}"; files="${files//[[:space:]]/}"
    want_list="$(printf '%s' "$want_list" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    FX="$TMP_ROOT/percat-$name"
    harness_git_init "$FX" >/dev/null 2>&1
    IFS=',' read -r -a fx_files <<< "$files"
    n=0
    for f in "${fx_files[@]}"; do
        n=$((n + 1))
        cat_name="$(basename "$f" .md)"; cat_name="${cat_name#glossary-}"
        entry_file "$FX/$f" "Glossary - $cat_name" "fixture term $n" "$(mark_of "$f") fixture term."
    done
    printf '# Fixture\n' > "$FX/README.md"
    commit_all "$FX" "init ($name)"
    got="$(list_main "$FX")"
    if [ "$got" = "$want_list" ]; then pass "L10/$name/listed-set"; else fail "L10/$name/listed-set" "want=$want_list got=$got"; fi
    B_FX="$TMP_ROOT/block-percat-$name.txt"
    gloss_block "$FX" "$B_FX"; rc=$?
    if [ "$rc" -eq 0 ]; then pass "L10/$name/probe-ran"; else fail "L10/$name/probe-ran" "rc=$rc"; fi
    listed="${want_list#* * }"
    for f in "${fx_files[@]}"; do
        case ",$listed," in
            *",$f,"*) has "L10/$name/codex-reads-$f" "$B_FX" "$(mark_of "$f")" ;;
            *) lacks "L10/$name/codex-skips-$f" "$B_FX" "$(mark_of "$f")" ;;
        esac
    done
done <<'TABLE'
# name               | fixture files (comma-separated)                                            | want "<count> <legacy> <labels>"
mixed-layout         | docs/glossary/user.md,docs/glossary-internal.md                            | 2 true docs/glossary/user.md,docs/glossary-internal.md
both-moved-stale     | docs/glossary/user.md,docs/glossary/internal.md,docs/glossary-user.md      | 2 false docs/glossary/internal.md,docs/glossary/user.md
user-moved-both-old  | docs/glossary/user.md,docs/glossary-user.md,docs/glossary-internal.md      | 2 true docs/glossary/user.md,docs/glossary-internal.md
TABLE
# The mixed layout's legacy internal terms also reach the prompt-data reader.
MIX="$TMP_ROOT/percat-mixed-layout"
pd_out="$(node "$SCRIPT_CHECKOUT_ROOT/bin/lib/glossary-format.js" prompt-data --root "$MIX" 2>"$TMP_ROOT/mix-pd.err")"
pd_rc=$?
if [ "$pd_rc" = 0 ]; then pass "L10/mixed-layout/prompt-data-exits-0"; else fail "L10/mixed-layout/prompt-data-exits-0" "rc=$pd_rc err=$(cat "$TMP_ROOT/mix-pd.err")"; fi
printf '%s\n' "$pd_out" > "$TMP_ROOT/mix-pd.out"
has "L10/mixed-layout/prompt-data-reads-legacy-internal" "$TMP_ROOT/mix-pd.out" "$(mark_of docs/glossary-internal.md)"
has "L10/mixed-layout/prompt-data-reads-new-user" "$TMP_ROOT/mix-pd.out" "$(mark_of docs/glossary/user.md)"
# A malformed legacy name now throws even when docs/glossary/ holds a file: the legacy scan
# runs for the category that has not moved yet.
MAL="$TMP_ROOT/percat-malformed"
entry_file "$MAL/docs/glossary/user.md" "Glossary - user" "alpha" "A moved term."
entry_file "$MAL/docs/glossary-user-z-a.md" "Glossary - user z-a" "zulu" "A reversed range."
got="$(node -e 'try { const r = require(process.argv[1]).listMainGlossaryFiles(process.argv[2]); console.log("listed:" + r.files.map((f) => f.label).join(",")); } catch (e) { console.log("threw:" + e.message); }' "$FILES_JS" "$MAL" 2>&1)"
case "$got" in
    "threw:docs/glossary-user-z-a.md: unparseable glossary file name"*) pass "L10/malformed-legacy-throws-with-new-dir-present" ;;
    *) fail "L10/malformed-legacy-throws-with-new-dir-present" "got=$got" ;;
esac
case_end

# ============================================================================
case_begin "staged-legacy-deletion-triggers-provenance" "bin/review-doc-glossary"
# ============================================================================
# A staged deletion of an old-layout file alone (nothing under docs/glossary/ staged) still
# triggers, so the provenance check sees the terms it removes from HEAD; the glob trigger is a
# superset, and a deletion outside 'docs/glossary-*' still skips.
# del_fixture <dir> <path-to-delete> — HEAD holds docs/glossary-user.md and the given path;
# only its deletion is staged.
del_fixture() {
    harness_git_init "$1" >/dev/null 2>&1
    entry_file "$1/docs/glossary-user.md" "Glossary - user" "alpha" "DELDEF the first term."
    mkdir -p "$1/docs"; [ -e "$1/$2" ] || printf 'notes\n' > "$1/$2"
    printf '# Fixture\n' > "$1/README.md"
    commit_all "$1" "init (old layout)"
    git -C "$1" rm -q -- "$2" >/dev/null 2>&1
}
DEL="$TMP_ROOT/staged-delete"
del_fixture "$DEL" docs/glossary-user.md
SID_DEL="p2529-legacy-delete-$$"
INTENT_DEL="$TMP_ROOT/intent-delete.md"
intent_body "$INTENT_DEL" "x" "| unrelated thing | session | add | Not a glossary term. |"
seed_session "$SID_DEL" "$DEL" "$INTENT_DEL"
(cd "$DEL" && run_with_timeout 60 bash "$RDG" --staged --session "$SID_DEL" > "$TMP_ROOT/rdg-delete.txt" 2>&1); rc=$?
has "L11/delete/review-doc-glossary-performs" "$TMP_ROOT/rdg-delete.txt" "PERFORMED (staged mode)"
lacks "L11/delete/review-doc-glossary-not-skipped" "$TMP_ROOT/rdg-delete.txt" "SKIPPED"
lacks "L11/delete/no-old-layout-block" "$TMP_ROOT/rdg-delete.txt" "old glossary layout"
has "L11/delete/provenance-reports-delete-operation" "$TMP_ROOT/rdg-delete.txt" "BLOCK: alpha delete user:"
if [ "$rc" -eq 1 ]; then pass "L11/delete/review-doc-glossary-exits-1"; else fail "L11/delete/review-doc-glossary-exits-1" "rc=$rc $(head -c 300 "$TMP_ROOT/rdg-delete.txt")"; fi

NOTES="$TMP_ROOT/staged-delete-notes"
# docs/glossary-user.md stays untouched in HEAD and the index: both sides read it, zero operations.
del_fixture "$NOTES" docs/glossary-notes.txt
(cd "$NOTES" && run_with_timeout 60 bash "$RDG" --staged > "$TMP_ROOT/rdg-notes.txt" 2>&1); rc=$?
has "L11/superset/non-glossary-match-performs" "$TMP_ROOT/rdg-notes.txt" "PERFORMED (staged mode)"
has "L11/superset/provenance-zero-operations" "$TMP_ROOT/rdg-notes.txt" "glossary provenance check: no glossary operation staged"
if [ "$rc" -eq 0 ]; then pass "L11/superset/exits-0"; else fail "L11/superset/exits-0" "rc=$rc $(head -c 300 "$TMP_ROOT/rdg-notes.txt")"; fi

OTHER="$TMP_ROOT/staged-delete-other"
del_fixture "$OTHER" docs/other.md
(cd "$OTHER" && run_with_timeout 60 bash "$RDG" --staged > "$TMP_ROOT/rdg-other.txt" 2>&1); rc=$?
has "L11/control/unrelated-deletion-skips" "$TMP_ROOT/rdg-other.txt" "SKIPPED — no glossary entry file staged"
if [ "$rc" -eq 0 ]; then pass "L11/control/exits-0"; else fail "L11/control/exits-0" "rc=$rc"; fi
case_end

# ============================================================================
case_begin "legacy-read-on-both-sides-per-category" "bin/check-glossary-provenance"
# ============================================================================
# Both HEAD and the index read an old-layout path, only for a category with no docs/glossary/
# path on that side; an untouched legacy file therefore yields no operation. (HEAD old paths ->
# index new paths is T3-2 in feat-2529-glossary-provenance/split.js.)
SPLIT="$TMP_ROOT/legacy-split-delete"
harness_git_init "$SPLIT" >/dev/null 2>&1
entry_file "$SPLIT/docs/glossary-user-a-m.md" "Glossary - user a-m" "alpha" "SPLITAMDEF a first-half term."
entry_file "$SPLIT/docs/glossary-user-n-z.md" "Glossary - user n-z" "november" "SPLITNZDEF a second-half term."
printf '# Fixture\n' > "$SPLIT/README.md"
commit_all "$SPLIT" "init (ranged old layout)"
git -C "$SPLIT" rm -q -- docs/glossary-user-a-m.md >/dev/null 2>&1
SID_SPLIT="p2529-legacy-split-$$"
seed_session "$SID_SPLIT" "$SPLIT" "$INTENT_DEL"
(cd "$SPLIT" && run_with_timeout 60 node "$PROV_CLI" --staged --session "$SID_SPLIT" --repo "$SPLIT" > "$TMP_ROOT/prov-split.txt" 2>&1); rc=$?
if [ "$rc" -eq 1 ]; then pass "L13/split-delete/exits-1"; else fail "L13/split-delete/exits-1" "rc=$rc $(head -c 300 "$TMP_ROOT/prov-split.txt")"; fi
has "L13/split-delete/a-m-term-reported-as-delete" "$TMP_ROOT/prov-split.txt" "BLOCK: alpha delete user:"
lacks "L13/split-delete/n-z-term-not-reported" "$TMP_ROOT/prov-split.txt" "november"

STALE="$TMP_ROOT/legacy-stale-beside-new"
harness_git_init "$STALE" >/dev/null 2>&1
entry_file "$STALE/docs/glossary/user.md" "Glossary - user" "alpha" "STALENEWDEF the moved term."
entry_file "$STALE/docs/glossary-user.md" "Glossary - user" "zulu" "STALEOLDDEF a stale old-path term."
entry_file "$STALE/docs/glossary-notes.md" "Notes" "note" "Not a glossary file."
printf '# Fixture\n' > "$STALE/README.md"
commit_all "$STALE" "init (new layout plus a stale old file)"
git -C "$STALE" rm -q -- docs/glossary-notes.md >/dev/null 2>&1
(cd "$STALE" && run_with_timeout 60 node "$PROV_CLI" --staged --repo "$STALE" > "$TMP_ROOT/prov-stale.txt" 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then pass "L13/stale-legacy/exits-0"; else fail "L13/stale-legacy/exits-0" "rc=$rc $(head -c 300 "$TMP_ROOT/prov-stale.txt")"; fi
has "L13/stale-legacy/zero-operations" "$TMP_ROOT/prov-stale.txt" "glossary provenance check: no glossary operation staged"
case_end

# ============================================================================
case_begin "legacy-docs-read-failure-throws" "bin/lib/glossary-format/files.js"
# ============================================================================
# A missing docs/ is an empty set; any other read failure of docs/ throws, like listGlossaryFiles.
NODOCS="$TMP_ROOT/no-docs"
mkdir -p "$NODOCS"
got="$(list_main "$NODOCS")"
if [ "$got" = "0 false " ]; then pass "L12/missing-docs-is-empty"; else fail "L12/missing-docs-is-empty" "got=$got"; fi
DOCSFILE="$TMP_ROOT/docs-is-file"
mkdir -p "$DOCSFILE"; printf 'not a dir\n' > "$DOCSFILE/docs"
got="$(node -e 'try { const r = require(process.argv[1]).listMainGlossaryFiles(process.argv[2]); console.log("listed:" + r.files.length); } catch (e) { console.log("threw:" + e.code); }' "$FILES_JS" "$DOCSFILE" 2>&1)"
if [ "$got" = "threw:ENOTDIR" ]; then pass "L12/docs-not-a-directory-throws"; else fail "L12/docs-not-a-directory-throws" "got=$got"; fi
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
