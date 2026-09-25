#!/usr/bin/env bash
# Tests: hooks/lib/protected-basenames.js, hooks/lib/active-session-ids.js
# Tags: protected-basename, classifier, session-marker, regex, boundary, stem-rule, security, scope:issue-specific, pwsh-not-required
# Part of tests/fix-2108-subagent-artifact-write-path.sh (rules/coding/file-split.md).

# Section C8 — NEAR-CANONICAL session-id stems (review C4). Section C1 proves the
# far-apart shapes; an anchored regex fails at its EDGES, one character either side.
C8_WF=""

# The clean spelling demands SID_CANONICAL_EXACT_RE (`^…$`), the bash spelling only
# SID_CANONICAL_TAIL_RE (`(?:^|[^0-9A-Za-z])…$`), so every row carries BOTH columns:
# a single-column table cannot tell "the anchor is right" from "the anchor is missing".
# The observed-sid rows (stem `wsid`, from the fixture workflow dir) get the same
# treatment, because the set membership test has the same two spellings.

_c8_write_probe() {
    cat > "$PROBE_DIR/sid-boundary-probe.js" <<'PROBE_EOF'
"use strict";
// argv: <protected-basenames.js> <stem>...
// Emits `<spelling> <stem>=<verdict>` for `<stem>.workflow-off` under sid "wsid".
const p = require(process.argv[2]);
const sessionCtx = { sessionId: "wsid" };
const out = [];
for (const stem of process.argv.slice(3)) {
  for (const spelling of ["clean", "bash"]) {
    out.push(`${spelling} ${stem}=${String(p.classifyProtectedPath(stem + ".workflow-off", { sessionCtx, spelling }))}`);
  }
}
process.stdout.write(out.join("\n"));
PROBE_EOF
}

_c8_get() { printf '%s\n' "$1" | grep -F "$2 $3=" | head -1 | sed 's/.*=//'; }

run_C8_sid_boundaries() {
    local out stems label stem want_clean want_bash

    # A workflow dir holding exactly ONE state file, so the observed sid set is known
    # and `complete` is true — without that precondition every `null` row below would
    # be indistinguishable from the fail-closed path (which returns "marker").
    C8_WF="$TMPBASE_SH/c8-workflow"
    rm -rf "$C8_WF" 2>/dev/null || true
    mkdir -p "$C8_WF"
    printf '{"version":1,"session_id":"wsid"}' > "$C8_WF/wsid.json"

    _c8_write_probe

    # Stems, in the same order the table reads them. Canonical anchors:
    #   uuid  0f3d9a21-4b6c-4d7e-8f90-a1b2c3d4e5f6   (8-4-4-4-12)
    #   ts    20260825-143012                        (8-6, clarify-intent fallback)
    stems="0f3d9a21-4b6c-4d7e-8f90-a1b2c3d4e5f6 \
0F3D9A21-4B6C-4D7E-8F90-A1B2C3D4E5F6 \
0f3d9a21-4b6c-4d7e-8f90-a1b2c3d4e5f \
0f3d9a21-4b6c-4d7e-8f90-a1b2c3d4e5f6a \
0f3d9a21_4b6c_4d7e_8f90_a1b2c3d4e5f6 \
0f3d9a2-14b6c-4d7e-8f90-a1b2c3d4e5f6 \
0f3d9a214b6c4d7e8f90a1b2c3d4e5f6 \
report-0f3d9a21-4b6c-4d7e-8f90-a1b2c3d4e5f6 \
report0f3d9a21-4b6c-4d7e-8f90-a1b2c3d4e5f6 \
20260825-143012 \
20260825-14301 \
20260825-1430123 \
20260825_143012 \
2026082-5143012 \
run-20260825-143012 \
wsid WSID wsi wsidx backup-wsid backupwsid issue-2108-survey"

    # shellcheck disable=SC2086
    out="$(run_probe "$PROBE_DIR/sid-boundary-probe.js" "$PB_NODE" $stems)"
    if [ -z "$out" ]; then
        fail "C8 sid-boundary probe produced no output (protected-basenames.js unusable or opts unsupported)"
        return
    fi

    # C8-0 — the fixture's own precondition. If the observation were incomplete the
    # classifier would fail closed and EVERY `null` row would pass for the wrong reason.
    assert_eq "C8-0 observation is complete under the C8 fixture" "true" \
        "$(cd "$NEUTRAL_CWD" && CLAUDE_WORKFLOW_DIR="$(node_path "$C8_WF")" run_probe -e "const m=require(process.argv[1]);process.stdout.write(String(m.observeActiveSessionIds({sessionId:'wsid'}).complete))" "$ACTIVE_SIDS_NODE")"

    # Columns: label | stem | clean verdict | bash verdict.
    while IFS='|' read -r label stem want_clean want_bash; do
        [[ -z "$label" || "$label" =~ ^[[:space:]]*# ]] && continue
        label="${label//[[:space:]]/}"; stem="${stem//[[:space:]]/}"
        want_clean="${want_clean//[[:space:]]/}"; want_bash="${want_bash//[[:space:]]/}"
        assert_eq "C8 $label [clean]" "$want_clean" "$(_c8_get "$out" clean "$stem")"
        assert_eq "C8 $label [bash]"  "$want_bash"  "$(_c8_get "$out" bash "$stem")"
    done <<'BOUNDARY_TABLE'
# label                    | stem                                         | clean  | bash
# --- CANONICAL UUID: the anchor itself, and its case variant (both regexes carry /i)
C8-uuid-exact              | 0f3d9a21-4b6c-4d7e-8f90-a1b2c3d4e5f6         | marker | marker
C8-uuid-uppercase          | 0F3D9A21-4B6C-4D7E-8F90-A1B2C3D4E5F6         | marker | marker
# --- ONE CHARACTER EITHER SIDE of the canonical length: no reader can open these
C8-uuid-one-short          | 0f3d9a21-4b6c-4d7e-8f90-a1b2c3d4e5f          | null   | null
C8-uuid-one-long           | 0f3d9a21-4b6c-4d7e-8f90-a1b2c3d4e5f6a        | null   | null
# --- MALFORMED SEPARATORS: wrong delimiter character, and a delimiter one place off
C8-uuid-underscore-seps    | 0f3d9a21_4b6c_4d7e_8f90_a1b2c3d4e5f6         | null   | null
C8-uuid-shifted-hyphen     | 0f3d9a2-14b6c-4d7e-8f90-a1b2c3d4e5f6         | null   | null
C8-uuid-no-seps            | 0f3d9a214b6c4d7e8f90a1b2c3d4e5f6             | null   | null
# --- PREFIXED: the R2c named exception is a NON-ALNUM boundary only. An alphanumeric
# --- character butted against the uuid is not a tail match on either spelling.
C8-uuid-nonalnum-prefix    | report-0f3d9a21-4b6c-4d7e-8f90-a1b2c3d4e5f6  | null   | marker
C8-uuid-alnum-prefix       | report0f3d9a21-4b6c-4d7e-8f90-a1b2c3d4e5f6   | null   | null
# --- TIMESTAMP FALLBACK: the same five questions asked of the 8-6 shape (CPR-ORTH)
C8-ts-exact                | 20260825-143012                              | marker | marker
C8-ts-one-short            | 20260825-14301                               | null   | null
C8-ts-one-long             | 20260825-1430123                             | null   | null
C8-ts-underscore-sep       | 20260825_143012                              | null   | null
C8-ts-shifted-hyphen       | 2026082-5143012                              | null   | null
C8-ts-nonalnum-prefix      | run-20260825-143012                          | null   | marker
# --- OBSERVED (non-canonical) SID: set membership has the same two spellings
C8-observed-exact          | wsid                                         | marker | marker
C8-observed-case-variant   | WSID                                         | marker | marker
C8-observed-one-short      | wsi                                          | null   | null
C8-observed-trailing-char  | wsidx                                        | null   | null
C8-observed-nonalnum-pfx   | backup-wsid                                  | null   | marker
C8-observed-alnum-pfx      | backupwsid                                   | null   | null
# --- CONTROL: the #2108 artifact name, allowed on both spellings
C8-artifact-control        | issue-2108-survey                            | null   | null
BOUNDARY_TABLE

    # SKIPPED: the same boundary matrix asserted against a REAL session id minted by
    # Claude Code rather than the synthetic "wsid".
    # Because: a live session id is not obtainable at TL2 without a claude -p run.
    # L3 gap: whether Claude Code's actual id alphabet ever produces a stem that this
    # matrix would classify differently from the canonical uuid row.
}
