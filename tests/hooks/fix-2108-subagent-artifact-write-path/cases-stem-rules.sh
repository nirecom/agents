#!/usr/bin/env bash
# Tests: hooks/lib/protected-basenames.js, hooks/lib/basename-glob-normalize.js, hooks/lib/active-session-ids.js
# Tags: protected-basename, classifier, session-marker, forge-state, stem-rule, spelling, security, scope:issue-specific, pwsh-not-required
# Part of tests/fix-2108-subagent-artifact-write-path.sh (rules/coding/file-split.md).

# Sections C1 + C1b — the stem rule (Scope 4 of #2108). Today the classifier matches
# the basename SUFFIX only; the stem is never examined, so every artifact whose name
# ends in a protected kind is read as forged clearance state. The narrowing says: a
# basename only carries clearance when its stem IS the effective session-id, because
# every READER (session-markers.js / gh-env-state.js / mechanism-failure.js) opens
# exactly `path.join(dir, sid + ".<kind>")`. Both matrices are derived from the SSOT
# so the 9th kind added after PR #2089 — and the 10th — are covered automatically.

_c1_write_probe() {
    cat > "$PROBE_DIR/stem-probe.js" <<'PROBE_EOF'
"use strict";
// Emits `<tag> <label>=<verdict>` lines; verdict is the classifier's own return
// value stringified, so `null` (allow) and "marker"/"token" (block) are both visible.
const p = require(process.argv[2]);
const sessionCtx = { sessionId: process.env.PROBE_SID || "wsid" };
const UUID = "0f3d9a21-4b6c-4d7e-8f90-a1b2c3d4e5f6";
const TS = "20260825-143012";
const clean = { sessionCtx, spelling: "clean" };
const bash = { sessionCtx, spelling: "bash" };
const cl = (b, o) => String(p.classifyProtectedPath(b, o));
const tok = (b) => String(p.classifyProtectedBashToken(b, { sessionCtx }));
const out = [];
const kinds = p.PROTECTED_STATE_KINDS || [];
for (const k of kinds) {
  // TRUE POSITIVES — the forgeries that must stay blocked.
  out.push(`tp-uuid-clean .${k}=${cl(UUID + "." + k, clean)}`);
  out.push(`tp-uuid-bash .${k}=${cl(UUID + "." + k, bash)}`);
  out.push(`tp-uuid-tmp-clean .${k}=${cl(UUID + "." + k + ".tmp", clean)}`);
  out.push(`tp-ts-clean .${k}=${cl(TS + "." + k, clean)}`);
  out.push(`tp-ts-bash .${k}=${cl(TS + "." + k, bash)}`);
  out.push(`tp-stdin-clean .${k}=${cl(sessionCtx.sessionId + "." + k, clean)}`);
  out.push(`tp-stdin-bash .${k}=${cl(sessionCtx.sessionId + "." + k, bash)}`);
  // Windows bash-word normalization residue: `C:\wf\<uuid>.<kind>` collapses to
  // `C:wf<uuid>.<kind>`, so the Bash spelling keeps a TAIL match (R2a).
  out.push(`tp-residue-bash .${k}=${tok("C:wf" + UUID + "." + k)}`);
  // FALSE POSITIVES — S3-0a families F-a..F-e. None of these can be opened by any
  // reader, so none of them can grant clearance to any session.
  out.push(`fp-kebab-clean .${k}=${cl("issue-2108-survey." + k, clean)}`);
  out.push(`fp-kebab-bash .${k}=${cl("issue-2108-survey." + k, bash)}`);
  out.push(`fp-dated-clean .${k}=${cl("report.2026-08-25." + k, clean)}`);
  out.push(`fp-dated-bash .${k}=${cl("report.2026-08-25." + k, bash)}`);
  out.push(`fp-prefixuuid-clean .${k}=${cl("report-" + UUID + "." + k, clean)}`);
  out.push(`fp-prefixuuid-bash .${k}=${cl("report-" + UUID + "." + k, bash)}`);
  out.push(`fp-empty-clean .${k}=${cl("." + k, clean)}`);
  out.push(`fp-empty-bash .${k}=${cl("." + k, bash)}`);
  // The `.tmp` write-then-rename intermediate is protected for a SID stem
  // (tp-uuid-tmp-clean above), so its non-SID counterpart is the other half of the
  // same pair. Without it the `.tmp` variant is asserted in one direction only.
  out.push(`fp-kebab-tmp-clean .${k}=${cl("issue-2108-survey." + k + ".tmp", clean)}`);
  out.push(`fp-kebab-tmp-bash .${k}=${cl("issue-2108-survey." + k + ".tmp", bash)}`);
  out.push(`fp-notes-tmp-clean .${k}=${cl("notes." + k + ".tmp", clean)}`);
  out.push(`ctrl-compound .${k}=${cl("notes." + k + ".md", clean)}`);
}
for (const s of p.OFF_CLEARANCE_TOKEN_SUFFIXES || []) {
  out.push(`tp-uuid-clean ${s}=${cl(UUID + s, clean)}`);
  out.push(`tp-stdin-clean ${s}=${cl(sessionCtx.sessionId + s, clean)}`);
  out.push(`tp-stdin-bash ${s}=${cl(sessionCtx.sessionId + s, bash)}`);
  out.push(`fp-kebab-clean ${s}=${cl("issue-2108-survey" + s, clean)}`);
  out.push(`fp-kebab-bash ${s}=${cl("issue-2108-survey" + s, bash)}`);
  out.push(`fp-prefixuuid-clean ${s}=${cl("report-" + UUID + s, clean)}`);
  out.push(`fp-empty-clean ${s}=${cl(s, clean)}`);
}
// C1b: the DEFAULT (opts omitted) must equal the BASH result, never the clean one —
// a wiring gap must fall to the broad side, never open a hole (plan R12).
out.push(`default-vs-bash prefixuuid=${cl("report-" + UUID + ".workflow-off") === cl("report-" + UUID + ".workflow-off", bash)}`);
out.push(`default-vs-bash kebab=${cl("issue-2108-survey.workflow-off") === cl("issue-2108-survey.workflow-off", bash)}`);
out.push(`default-vs-bash uuid=${cl(UUID + ".workflow-off") === cl(UUID + ".workflow-off", bash)}`);
out.push(`exported isClearanceBearingStem=${typeof p.isClearanceBearingStem}`);
out.push(`exported SID_CANONICAL_EXACT_RE=${p.SID_CANONICAL_EXACT_RE instanceof RegExp}`);
out.push(`exported SID_CANONICAL_TAIL_RE=${p.SID_CANONICAL_TAIL_RE instanceof RegExp}`);
process.stdout.write(out.join("\n"));
PROBE_EOF
}

# _c1_get <output> <tag> <label> -> the verdict for one probe line
_c1_get() { printf '%s\n' "$1" | grep -F "$2 $3=" | head -1 | sed 's/.*=//'; }

run_C1_stem_rules() {
    local out kinds sfxs k s

    _c1_write_probe
    kinds="$(run_probe -e "process.stdout.write((require(process.argv[1]).PROTECTED_STATE_KINDS||[]).join(' '))" "$PB_NODE")"
    sfxs="$(run_probe -e "process.stdout.write((require(process.argv[1]).OFF_CLEARANCE_TOKEN_SUFFIXES||[]).join(' '))" "$PB_NODE")"
    if [ -z "$kinds" ] || [ -z "$sfxs" ]; then
        fail "C1 SSOT not introspectable (PROTECTED_STATE_KINDS / OFF_CLEARANCE_TOKEN_SUFFIXES)"
        return
    fi
    pass "C1 SSOT introspected: kinds=[$kinds]"

    out="$(PROBE_SID=wsid run_probe "$PROBE_DIR/stem-probe.js" "$PB_NODE")"
    if [ -z "$out" ]; then
        fail "C1 stem probe produced no output (protected-basenames.js unusable or opts unsupported)"
        return
    fi
    C1_PROBE_OUT="$out"

    # Table-driven named cases (skills/_shared/test-design/parser-regex-tests.md, and the
    # same `while IFS='|' read -r` form as cases-allowlist.sh / cases-wiring.sh). One row
    # per BASENAME SHAPE; the kind axis is the inner loop, so a 10th protected kind is
    # covered by the SSOT introspection above without touching the table.
    # Columns: case-label | probe tag | expected classifier verdict.
    while IFS='|' read -r label tag want; do
        [[ -z "$label" || "$label" =~ ^[[:space:]]*# ]] && continue
        label="${label//[[:space:]]/}"; tag="${tag//[[:space:]]/}"; want="${want//[[:space:]]/}"
        for k in $kinds; do
            assert_eq "C1 marker-kind $label [$k]" "$want" "$(_c1_get "$out" "$tag" ".$k")"
        done
    done <<'MARKER_TABLE'
# --- TRUE POSITIVES: the narrowing must not weaken any of these ---------------
TP-uuid-stem-clean               | tp-uuid-clean        | marker
TP-uuid-stem-bash                | tp-uuid-bash         | marker
TP-uuid-stem-dot-tmp             | tp-uuid-tmp-clean    | marker
TP-date-fallback-sid-clean       | tp-ts-clean          | marker
TP-date-fallback-sid-bash        | tp-ts-bash           | marker
TP-stdin-sid-clean               | tp-stdin-clean       | marker
TP-stdin-sid-bash                | tp-stdin-bash        | marker
TP-windows-bash-residue-R2a      | tp-residue-bash      | marker
# --- FALSE POSITIVES: the artifact names #2108 was blocked on -----------------
FP-Fa-kebab-stem-clean           | fp-kebab-clean       | null
FP-Fa-kebab-stem-bash            | fp-kebab-bash        | null
FP-Fa-kebab-stem-dot-tmp-clean   | fp-kebab-tmp-clean   | null
FP-Fa-kebab-stem-dot-tmp-bash    | fp-kebab-tmp-bash    | null
FP-Fa-plain-stem-dot-tmp-clean   | fp-notes-tmp-clean   | null
FP-Fb-dated-stem-clean           | fp-dated-clean       | null
FP-Fb-dated-stem-bash            | fp-dated-bash        | null
FP-Fc-prefix-uuid-clean          | fp-prefixuuid-clean  | null
FP-Fd-empty-stem-clean-R4        | fp-empty-clean       | null
FP-Fd-empty-stem-bash-R4         | fp-empty-bash        | null
FP-Fe-control-notes-kind-dot-md  | ctrl-compound        | null
# --- R2c named exception: the Bash spelling KEEPS the tail match, on purpose --
R2c-prefix-uuid-blocked-on-bash  | fp-prefixuuid-bash   | marker
MARKER_TABLE

    # Same form for the token suffixes. The suffix list already carries its own `.tmp`
    # / `.claimed` / `.mint` members, so the kind axis here is the suffix itself.
    while IFS='|' read -r label tag want; do
        [[ -z "$label" || "$label" =~ ^[[:space:]]*# ]] && continue
        label="${label//[[:space:]]/}"; tag="${tag//[[:space:]]/}"; want="${want//[[:space:]]/}"
        for s in $sfxs; do
            assert_eq "C1 token-suffix $label [$s]" "$want" "$(_c1_get "$out" "$tag" "$s")"
        done
    done <<'TOKEN_TABLE'
TP-token-uuid-stem-clean     | tp-uuid-clean       | token
TP-token-stdin-sid-clean     | tp-stdin-clean      | token
TP-token-stdin-sid-bash      | tp-stdin-bash       | token
FP-token-kebab-stem-clean    | fp-kebab-clean      | null
FP-token-kebab-stem-bash     | fp-kebab-bash       | null
FP-token-prefix-uuid-clean   | fp-prefixuuid-clean | null
FP-token-empty-stem-R4       | fp-empty-clean      | null
TOKEN_TABLE
}

run_C1b_spelling_split() {
    local out
    out="${C1_PROBE_OUT:-}"
    if [ -z "$out" ]; then
        _c1_write_probe
        out="$(PROBE_SID=wsid run_probe "$PROBE_DIR/stem-probe.js" "$PB_NODE")"
    fi
    if [ -z "$out" ]; then
        fail "C1b stem probe produced no output"
        return
    fi

    # C1b-1 — the split itself: the SAME basename resolves differently by spelling.
    # Edit/Write carries the stem exactly as written, so exact match is provable;
    # a Bash word may have been mangled by unquoteBashWord, so tail match is kept.
    assert_eq "C1b report-<uuid>.gh-env allows on the clean path" "null" \
        "$(_c1_get "$out" fp-prefixuuid-clean ".gh-env")"
    assert_eq "C1b report-<uuid>.gh-env still blocks on the bash path (R2c)" "marker" \
        "$(_c1_get "$out" fp-prefixuuid-bash ".gh-env")"
    assert_eq "C1b <uuid>.gh-env blocks on BOTH spellings" "marker" \
        "$(_c1_get "$out" tp-uuid-clean ".gh-env")"
    assert_eq "C1b <uuid>.gh-env blocks on BOTH spellings (bash)" "marker" \
        "$(_c1_get "$out" tp-uuid-bash ".gh-env")"

    # C1b-2 — backup-wsid.workflow-off: a stem that CONTAINS the effective sid but is
    # not equal to it. No reader can open it, so the clean path allows; the bash path
    # keeps its tail match. This is the pair the plan calls out explicitly (S3-3).
    local bw_clean bw_bash
    bw_clean="$(run_probe -e "const p=require(process.argv[1]);process.stdout.write(String(p.classifyProtectedPath('backup-wsid.workflow-off',{sessionCtx:{sessionId:'wsid'},spelling:'clean'})))" "$PB_NODE")"
    bw_bash="$(run_probe -e "const p=require(process.argv[1]);process.stdout.write(String(p.classifyProtectedPath('backup-wsid.workflow-off',{sessionCtx:{sessionId:'wsid'},spelling:'bash'})))" "$PB_NODE")"
    assert_eq "C1b backup-wsid.workflow-off allows on the clean path" "null" "$bw_clean"
    assert_eq "C1b backup-wsid.workflow-off blocks on the bash path" "marker" "$bw_bash"

    # C1b-3 — DEFAULT ARGUMENT DIRECTION (plan R12). Omitting opts must behave like
    # the BASH spelling, so any missed wiring in S3b falls to the protective side.
    assert_eq "C1b default opts == bash for prefix+uuid" "true" "$(_c1_get "$out" default-vs-bash prefixuuid)"
    assert_eq "C1b default opts == bash for kebab stem"  "true" "$(_c1_get "$out" default-vs-bash kebab)"
    assert_eq "C1b default opts == bash for uuid stem"   "true" "$(_c1_get "$out" default-vs-bash uuid)"

    # C1b-4 — the introspection surface the rest of this suite (and the mutation probe)
    # depends on. Without these exports the narrowing cannot be tested at unit level.
    assert_eq "C1b isClearanceBearingStem is exported" "function" "$(_c1_get "$out" exported isClearanceBearingStem)"
    assert_eq "C1b SID_CANONICAL_EXACT_RE is exported" "true" "$(_c1_get "$out" exported SID_CANONICAL_EXACT_RE)"
    assert_eq "C1b SID_CANONICAL_TAIL_RE is exported"  "true" "$(_c1_get "$out" exported SID_CANONICAL_TAIL_RE)"

    # C1b-5 — the detection breadth that must NOT be narrowed (S3 completion condition):
    # glob spellings, over-cap enumeration and the consuming-claim wrapper still block
    # regardless of stem, because none of them can prove the post-expansion stem.
    local g c
    g="$(run_probe -e "const p=require(process.argv[1]);process.stdout.write(String(p.classifyProtectedBashToken('issue-2108-survey.workflow-of*')))" "$PB_NODE")"
    c="$(run_probe -e "const p=require(process.argv[1]);process.stdout.write(String(p.classifyProtectedPath('0f3d9a21-4b6c-4d7e-8f90-a1b2c3d4e5f6.off-clearance.consuming-ab12cd34ab12cd34.tmp',{sessionCtx:{sessionId:'wsid'}})))" "$PB_NODE")"
    assert_eq "C1b glob spelling keeps blocking (stem unprovable)" "marker" "$g"
    assert_eq "C1b consuming-claim wrapper keeps blocking" "token" "$c"
}
