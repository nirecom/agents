#!/usr/bin/env bash
# tests/bin-sweep-supervisor-state.sh
# Tests: bin/sweep-supervisor-state.sh, bin/sweep-supervisor-state/signatures.js, bin/sweep-supervisor-state/scrub.js
# Tags: sweep, supervisor-state, contamination, cleanup, scope:common, pwsh-not-required, TL2
#
# #1799 remediation tool: removes the escape_hatch_event records that leaking test suites
# already wrote into real supervisor state files, from FINISHED sessions only.
#
# Three invariants this suite exists to pin, all of which bias toward keeping data:
#   1. dry-run is the DEFAULT (deliberate deviation from the apply-by-default sweep family —
#      the blast radius here is a governance audit trail, not a regenerable derivative).
#   2. The live-session scope guard is UNCONDITIONAL. No --include-live override exists, and
#      --session narrows the target set without ever relaxing the guard.
#   3. Only layer1.findings is filtered. alert.findings / audit.findings carry position-
#      dependent `idx` references and derived scalars the tool does not own.
#
# TL2 gap (what this test does NOT catch): fixtures are synthesized, not drawn from a real
# contaminated ~/.workflow-plans. A signature that fails to match real-world record shapes
# would look green here. Mitigation: the implementer re-runs --dry-run against the live plans
# dir and confirms the measured distribution (matches = short high-frequency reasons;
# non-matches = one-off long prose).

set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
SWEEP="$AGENTS_DIR/bin/sweep-supervisor-state.sh"
SCHEMA_NODE="$(node_path "$AGENTS_DIR")/hooks/lib/supervisor-state-schema.js"
RWT="$AGENTS_DIR/bin/run-with-timeout.sh"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

TMPDIR_BASE="$(mktemp -d 2>/dev/null || mktemp -d -t 'sweepss')"
trap 'chmod -R u+rwX "$TMPDIR_BASE" 2>/dev/null; rm -rf "$TMPDIR_BASE"' EXIT

BACKUP_ROOT_NAME=".sweep-supervisor-state-backup"

# ── Helpers ─────────────────────────────────────────────────────────────────

# mkstate.js — build a schema-valid supervisor state file from a small JSON spec.
MKSTATE="$TMPDIR_BASE/mkstate.js"
cat > "$MKSTATE" <<'MKSTATE_JS'
const fs = require("fs");
const path = require("path");
const [outdir, sid, specStr] = process.argv.slice(2);
const spec = JSON.parse(specStr);
const stamp = spec.last_updated || "2024-01-02T03:04:05.000Z";
const state = {
  version: 1,
  session_id: sid,
  created_at: "2024-01-01T00:00:00.000Z",
  last_updated: stamp,
  layer1: { findings: spec.findings || [] },
  alert: Object.assign({
    alert_armed_at: null, last_run_at: null, cumulative_severity: null, findings: [],
    alert_phase: null, alert_cause: null, alert_retry_count: 0,
    findings_surfaced_at: null, alert_eligible_phase: null,
  }, spec.alert || {}),
  audit: Object.assign({
    audit_phase: null, audit_verdict: null, audit_last_run_at: null, audit_armed_at: null,
    audit_cause: null, audit_retry_count: 0, findings: [],
  }, spec.audit || {}),
};
fs.writeFileSync(path.join(outdir, sid + "-supervisor-state.json"), JSON.stringify(state, null, 2));
MKSTATE_JS

# finfo.js — "<md5> <mtimeMs>" for byte-identity + mtime assertions.
FINFO="$TMPDIR_BASE/finfo.js"
cat > "$FINFO" <<'FINFO_JS'
const fs = require("fs");
const crypto = require("crypto");
const f = process.argv[2];
const buf = fs.readFileSync(f);
process.stdout.write(crypto.createHash("md5").update(buf).digest("hex") + " " + fs.statSync(f).mtimeMs);
FINFO_JS

finfo() { node "$FINFO" "$(node_path "$1")" 2>/dev/null; }
now_iso() { node -e 'process.stdout.write(new Date().toISOString())'; }

# Finding constructors. Contaminated records must satisfy ALL of: layer1.findings,
# severity=warning, categories exactly ["workflow"], reporter in the emitter set,
# record_type escape_hatch_event (or absent), and a full-match detail whose captured
# reason is strictly in the allowlist.
contaminated() {  # <reason-literal> [kind=WORKFLOW_OFF]
    printf '{"categories":["workflow"],"severity":"warning","detail":"escape-hatch sentinel: %s (%s)","reporter":"enforce-override-handlers","record_type":"escape_hatch_event","timestamp":"2024-01-02T03:04:05.000Z"}' \
        "${2:-WORKFLOW_OFF}" "$1"
}
# Pre-record_type era: reporter was "workflow-mark" and the field did not exist yet.
old_format() {  # <reason-literal>
    printf '{"categories":["workflow"],"severity":"warning","detail":"escape-hatch sentinel: WORKTREE_OFF (%s)","reporter":"workflow-mark","timestamp":"2024-01-02T03:04:05.000Z"}' "$1"
}
# Same shape, reason NOT in the allowlist — a real human escape hatch. Must survive.
legit_sentinel() {  # <reason-prose>
    printf '{"categories":["workflow"],"severity":"warning","detail":"escape-hatch sentinel: WORKFLOW_OFF (%s)","reporter":"enforce-override-handlers","record_type":"escape_hatch_event","timestamp":"2024-01-02T03:04:05.000Z"}' "$1"
}
# A wholly different finding class — never in scope regardless of reason.
legit_block() {  # <command>
    printf '{"categories":["workflow"],"severity":"notice","detail":"hook blocked: enforce-worktree on %s","reporter":"enforce-worktree","timestamp":"2024-01-02T03:04:05.000Z"}' "$1"
}

# mk_state <plansdir> <sid> <spec-json>
mk_state() { node "$MKSTATE" "$(node_path "$1")" "$2" "$3"; }

new_plans_dir() { local d="$TMPDIR_BASE/$1"; mkdir -p "$d"; printf '%s' "$d"; }

# run_sweep <plansdir> [flags...] → stdout+stderr; sets RC.
RC=0
run_sweep() {
    local dir="$1"; shift
    local out
    out="$(env -u AGENTS_CONFIG_DIR -u CLAUDE_SESSION_ID "WORKFLOW_PLANS_DIR=$(node_path "$dir")" \
        "$RWT" 90 bash "$SWEEP" "$@" 2>&1)"
    RC=$?
    printf '%s' "$out"
}

# run_sweep_as_session <plansdir> <sid> [flags...] — same, but with a live CLAUDE_SESSION_ID.
run_sweep_as_session() {
    local dir="$1" sid="$2"; shift 2
    local out
    out="$(env -u AGENTS_CONFIG_DIR "WORKFLOW_PLANS_DIR=$(node_path "$dir")" "CLAUDE_SESSION_ID=$sid" \
        "$RWT" 90 bash "$SWEEP" "$@" 2>&1)"
    RC=$?
    printf '%s' "$out"
}

ci_field() {  # <output> <key>
    printf '%s' "$1" | node -e "
        let b='';
        process.stdin.on('data', c => b += c);
        process.stdin.on('end', () => {
            const key = process.argv[1];
            for (const line of b.split(/\r?\n/)) {
                const t = line.trim();
                if (!t.startsWith('{')) continue;
                try { const d = JSON.parse(t); if (key in d) { console.log(typeof d[key] === 'object' ? JSON.stringify(d[key]) : d[key]); return; } }
                catch (e) { /* skip */ }
            }
        });
    " -- "$2" 2>/dev/null
}

# reasons_of <state-file> → one captured escape-hatch reason per line, in file order.
reasons_of() {
    node -e "
const fs=require('fs');
const s=JSON.parse(fs.readFileSync(process.argv[1],'utf8'));
for (const f of (s.layer1&&s.layer1.findings)||[]) {
  const m = typeof f.detail==='string' && f.detail.match(/^escape-hatch sentinel: (?:WORKTREE_OFF|WORKFLOW_OFF) \((.*)\)$/);
  console.log(m ? m[1] : '<other:' + (f.detail||'') + '>');
}
" "$(node_path "$1")" 2>/dev/null
}

backup_dirs() {  # <plansdir> → newline-separated backup dir paths
    find "$1/$BACKUP_ROOT_NAME" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort
}

require_tool() {
    if [ ! -f "$SWEEP" ]; then
        fail "$1 (blocked: $SWEEP does not exist)"
        return 1
    fi
    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# S1 — a file holding only legitimate records is byte-identical after --apply.
# ─────────────────────────────────────────────────────────────────────────────
S1_legitimate_only_untouched() {
    require_tool "S1 legitimate-only file untouched by --apply" || return
    local dir f before after
    dir="$(new_plans_dir s1)"
    mk_state "$dir" "s1sess" "{\"findings\":[
        $(legit_sentinel 'worktree-end cleanup cascade — sanctioned worktree remove/prune/branch-D blocked from main worktree'),
        $(legit_sentinel 'installer smoke run needs .env access for a single verification step'),
        $(legit_block 'git commit -m wip')
    ]}"
    f="$dir/s1sess-supervisor-state.json"
    before="$(finfo "$f")"
    run_sweep "$dir" --apply --ci-mode >/dev/null
    after="$(finfo "$f")"

    if [ "$before" = "$after" ]; then
        pass "S1 legitimate-only file byte-identical and untouched after --apply"
    else
        fail "S1 legitimate-only file was modified: before='$before' after='$after'"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# S2 — mixed file loses exactly the allowlist matches; survivors keep their order.
# ─────────────────────────────────────────────────────────────────────────────
S2_mixed_file_partial_removal() {
    require_tool "S2 mixed file loses only allowlist matches" || return
    local dir f out got want
    dir="$(new_plans_dir s2)"
    mk_state "$dir" "s2sess" "{\"findings\":[
        $(legit_sentinel 'keep me first — a genuine one-off human reason'),
        $(contaminated 'A1 marker test'),
        $(legit_sentinel 'keep me second — another genuine one-off human reason'),
        $(contaminated 'SEC1 traversal' 'WORKTREE_OFF'),
        $(legit_sentinel 'keep me third — yet another genuine one-off human reason')
    ]}"
    f="$dir/s2sess-supervisor-state.json"
    out="$(run_sweep "$dir" --apply --ci-mode)"
    got="$(reasons_of "$f")"
    want="keep me first — a genuine one-off human reason
keep me second — another genuine one-off human reason
keep me third — yet another genuine one-off human reason"

    if [ "$got" = "$want" ]; then
        pass "S2a mixed file: only allowlist matches removed, survivors in original order"
    else
        fail "S2a mixed file wrong survivors:"$'\n'"got:"$'\n'"$got"$'\n'"want:"$'\n'"$want"
    fi
    local removed; removed="$(ci_field "$out" records_removed)"
    if [ "${removed:-0}" = "2" ]; then
        pass "S2b records_removed=2"
    else
        fail "S2b records_removed=${removed:-<absent>}, want 2 (out=$out)"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# S3 — deliberately excluded reasons survive. These are words a human writes.
# ─────────────────────────────────────────────────────────────────────────────
S3_excluded_reasons_survive() {
    require_tool "S3 excluded reasons survive --apply" || return
    local dir f before after
    dir="$(new_plans_dir s3)"
    mk_state "$dir" "s3sess" "{\"findings\":[
        $(contaminated 'recovery'),
        $(contaminated 'test'),
        $(contaminated 'x'),
        $(contaminated '[workflow-bug] next-step bug'),
        $(contaminated 'test reason'),
        $(contaminated 'smoke')
    ]}"
    f="$dir/s3sess-supervisor-state.json"
    before="$(finfo "$f")"
    run_sweep "$dir" --apply --ci-mode >/dev/null
    after="$(finfo "$f")"

    if [ "$before" = "$after" ]; then
        pass "S3 excluded reasons (recovery/test/x/[workflow-bug]/test reason/smoke) all survive"
    else
        fail "S3 an excluded reason was removed — allowlist is too broad. survivors:"$'\n'"$(reasons_of "$f")"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# S4 — pre-record_type records (reporter "workflow-mark", no record_type) still match.
# ─────────────────────────────────────────────────────────────────────────────
S4_old_format_removed() {
    require_tool "S4 old-format records removed" || return
    local dir f left
    dir="$(new_plans_dir s4)"
    mk_state "$dir" "s4sess" "{\"findings\":[
        $(old_format 'A5 no session id'),
        $(old_format 'C1 round trip'),
        $(legit_sentinel 'a genuine long human reason that must survive the sweep')
    ]}"
    f="$dir/s4sess-supervisor-state.json"
    run_sweep "$dir" --apply --ci-mode >/dev/null
    left="$(reasons_of "$f")"

    if [ "$left" = "a genuine long human reason that must survive the sweep" ]; then
        pass "S4 old-format records (workflow-mark reporter, no record_type) removed"
    else
        fail "S4 old-format handling wrong, survivors:"$'\n'"$left"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# S5 — THE EXCEPTION CASE. No flags = dry-run: nothing written, no backup dir created,
#      yet candidates are reported. Deviation from the apply-by-default sweep family.
# ─────────────────────────────────────────────────────────────────────────────
S5_default_is_dry_run() {
    require_tool "S5 flagless run writes nothing (dry-run default)" || return
    local dir f before after out
    dir="$(new_plans_dir s5)"
    mk_state "$dir" "s5sess" "{\"findings\":[
        $(contaminated 'A1 marker test'),
        $(contaminated 'A6 chain test'),
        $(legit_sentinel 'a genuine long human reason that must survive the sweep')
    ]}"
    f="$dir/s5sess-supervisor-state.json"
    before="$(finfo "$f")"
    out="$(run_sweep "$dir" --ci-mode)"
    after="$(finfo "$f")"

    if [ "$before" = "$after" ]; then
        pass "S5a flagless run: content and mtime unchanged"
    else
        fail "S5a flagless run MODIFIED the file — dry-run default violated: before='$before' after='$after'"
    fi
    if [ ! -d "$dir/$BACKUP_ROOT_NAME" ]; then
        pass "S5b flagless run created no backup directory"
    else
        fail "S5b flagless run created $BACKUP_ROOT_NAME — it wrote something"
    fi
    local cand modified removed
    cand="$(ci_field "$out" files_contaminated)"
    modified="$(ci_field "$out" files_modified)"
    removed="$(ci_field "$out" records_removed)"
    if [ "${cand:-0}" -ge 1 ] 2>/dev/null && [ "${modified:-x}" = "0" ] && [ "${removed:-x}" = "0" ]; then
        pass "S5c flagless run reports candidates (files_contaminated=$cand) with zero writes"
    else
        fail "S5c flagless counters wrong: files_contaminated=${cand:-<absent>} files_modified=${modified:-<absent>} records_removed=${removed:-<absent>} (out=$out)"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# S6 — --apply makes a timestamped backup dir + manifest.json holding the full JSON of
#      every removed record. A second --apply gets its OWN dir and cannot clobber the first.
# ─────────────────────────────────────────────────────────────────────────────
S6_backup_and_manifest() {
    require_tool "S6 --apply backup dir + manifest.json" || return
    local dir f pre_hash out b1 b2 n
    dir="$(new_plans_dir s6)"
    mk_state "$dir" "s6sess" "{\"findings\":[
        $(contaminated 'A1 marker test'),
        $(contaminated 'A7 idempotent write'),
        $(legit_sentinel 'a genuine long human reason that must survive the sweep')
    ]}"
    f="$dir/s6sess-supervisor-state.json"
    pre_hash="$(node -e "
const fs=require('fs'),c=require('crypto');
process.stdout.write(c.createHash('md5').update(fs.readFileSync(process.argv[1])).digest('hex'));
" "$(node_path "$f")")"

    out="$(run_sweep "$dir" --apply --ci-mode)"
    n="$(backup_dirs "$dir" | wc -l | tr -d ' ')"
    b1="$(backup_dirs "$dir" | head -1)"

    if [ "$n" = "1" ] && [ -n "$b1" ]; then
        pass "S6a --apply created exactly one timestamped backup directory"
    else
        fail "S6a backup directory count=$n (want 1) under $dir/$BACKUP_ROOT_NAME"
        return
    fi
    # UTC ISO8601 basic form, e.g. 20260802T041233Z
    if basename "$b1" | grep -Eq '^[0-9]{8}T[0-9]{6}Z$'; then
        pass "S6b backup dir name is a UTC ISO8601 basic timestamp ($(basename "$b1"))"
    else
        fail "S6b backup dir name not a UTC basic timestamp: $(basename "$b1")"
    fi
    local copy_hash
    copy_hash="$(node -e "
const fs=require('fs'),c=require('crypto');
try { process.stdout.write(c.createHash('md5').update(fs.readFileSync(process.argv[1])).digest('hex')); } catch(e) { process.stdout.write('MISSING'); }
" "$(node_path "$b1/s6sess-supervisor-state.json")")"
    if [ "$copy_hash" = "$pre_hash" ]; then
        pass "S6c backup copy is the exact pre-modification file"
    else
        fail "S6c backup copy mismatch: backup=$copy_hash pre=$pre_hash"
    fi

    local man_ok
    man_ok="$(node -e "
const fs=require('fs');
let m;
try { m = JSON.parse(fs.readFileSync(process.argv[1],'utf8')); } catch(e) { process.stdout.write('UNPARSABLE'); process.exit(0); }
const files = m.files || [];
const entry = files.find(x => String(x.file||'').includes('s6sess'));
if (!entry) { process.stdout.write('NOENTRY'); process.exit(0); }
if (entry.records_removed !== 2) { process.stdout.write('COUNT:'+entry.records_removed); process.exit(0); }
const det = entry.removed_record_details || [];
if (det.length !== 2) { process.stdout.write('DETAILS:'+det.length); process.exit(0); }
const full = det.every(r => r && r.detail && r.severity === 'warning' && Array.isArray(r.categories) && r.reporter);
process.stdout.write(full ? 'OK' : 'PARTIAL');
" "$(node_path "$b1/manifest.json")" 2>/dev/null)"
    if [ "$man_ok" = "OK" ]; then
        pass "S6d manifest.json holds the full JSON of both removed records"
    else
        fail "S6d manifest.json wrong: $man_ok (path=$b1/manifest.json)"
    fi

    # Second --apply: new dir, first backup preserved intact.
    mk_state "$dir" "s6sess" "{\"findings\":[$(contaminated 'C3 step1')]}"
    run_sweep "$dir" --apply --ci-mode >/dev/null
    n="$(backup_dirs "$dir" | wc -l | tr -d ' ')"
    local recheck
    recheck="$(node -e "
const fs=require('fs'),c=require('crypto');
try { process.stdout.write(c.createHash('md5').update(fs.readFileSync(process.argv[1])).digest('hex')); } catch(e) { process.stdout.write('MISSING'); }
" "$(node_path "$b1/s6sess-supervisor-state.json")")"
    if [ "$n" -ge 2 ] 2>/dev/null && [ "$recheck" = "$pre_hash" ]; then
        pass "S6e second --apply used a separate backup dir; first backup untouched"
    else
        fail "S6e second --apply clobbered history: dirs=$n first_backup_hash=$recheck (want $pre_hash)"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# S7 — the scrubbed file still validates against the schema.
# ─────────────────────────────────────────────────────────────────────────────
S7_scrubbed_file_validates() {
    require_tool "S7 scrubbed file passes schema validate()" || return
    local dir f out
    dir="$(new_plans_dir s7)"
    mk_state "$dir" "s7sess" "{\"findings\":[
        $(contaminated 'A3 non-zero exit'),
        $(contaminated 'A4 env-file fallback'),
        $(legit_sentinel 'a genuine long human reason that must survive the sweep')
    ]}"
    f="$dir/s7sess-supervisor-state.json"
    run_sweep "$dir" --apply --ci-mode >/dev/null
    out="$("$RWT" 20 node -e "
const fs=require('fs');
const s=require('$SCHEMA_NODE');
const st=JSON.parse(fs.readFileSync(process.argv[1],'utf8'));
const r=s.validate(st);
process.stdout.write(r.ok ? 'OK' : 'ERR:'+JSON.stringify(r.errors));
" "$(node_path "$f")" 2>&1)"
    if [ "$out" = "OK" ]; then
        pass "S7 scrubbed file passes supervisor-state-schema validate()"
    else
        fail "S7 scrubbed file fails schema validation: $out"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# S8 — alert/audit are NOT the tool's property. Their findings arrays carry position-
#      dependent idx references and their scalars are completed-lifecycle records.
# ─────────────────────────────────────────────────────────────────────────────
S8_alert_audit_untouched() {
    require_tool "S8 alert/audit arrays and scalars unchanged" || return
    local dir f out
    dir="$(new_plans_dir s8)"
    # alert.findings deliberately carries a record that WOULD match the allowlist if the
    # tool wrongly filtered it, plus an idx to prove position dependence.
    mk_state "$dir" "s8sess" "{
        \"findings\":[$(contaminated 'A1 marker test'), $(legit_sentinel 'a genuine long human reason that must survive')],
        \"alert\":{
            \"alert_phase\":\"done\",
            \"alert_armed_at\":\"2024-01-02T00:00:00.000Z\",
            \"cumulative_severity\":\"warning\",
            \"findings\":[{\"idx\":0,\"categories\":[\"workflow\"],\"severity\":\"warning\",\"detail\":\"escape-hatch sentinel: WORKFLOW_OFF (A1 marker test)\",\"reporter\":\"enforce-override-handlers\"},{\"idx\":1,\"categories\":[\"code\"],\"severity\":\"notice\",\"detail\":\"alert note\",\"reporter\":\"supervisor\"}]
        },
        \"audit\":{
            \"audit_phase\":\"done\",
            \"audit_verdict\":\"CONTINUE\",
            \"findings\":[{\"categories\":[\"workflow\"],\"severity\":\"warning\",\"detail\":\"escape-hatch sentinel: WORKTREE_OFF (A6 chain test)\",\"reporter\":\"enforce-override-handlers\"}]
        }
    }"
    f="$dir/s8sess-supervisor-state.json"
    local before_side
    before_side="$("$RWT" 20 node -e "
const fs=require('fs');
const s=JSON.parse(fs.readFileSync(process.argv[1],'utf8'));
process.stdout.write(JSON.stringify({alert:s.alert,audit:s.audit}));
" "$(node_path "$f")")"

    run_sweep "$dir" --apply --ci-mode >/dev/null

    local after_side layer1_count
    after_side="$("$RWT" 20 node -e "
const fs=require('fs');
const s=JSON.parse(fs.readFileSync(process.argv[1],'utf8'));
process.stdout.write(JSON.stringify({alert:s.alert,audit:s.audit}));
" "$(node_path "$f")")"
    layer1_count="$("$RWT" 20 node -e "
const fs=require('fs');
const s=JSON.parse(fs.readFileSync(process.argv[1],'utf8'));
process.stdout.write(String(s.layer1.findings.length));
" "$(node_path "$f")")"

    if [ "$before_side" = "$after_side" ]; then
        pass "S8a alert/audit findings arrays and all scalars byte-identical after --apply"
    else
        fail "S8a alert/audit block was modified:"$'\n'"before=$before_side"$'\n'"after=$after_side"
    fi
    if [ "$layer1_count" = "1" ]; then
        pass "S8b layer1.findings was still scrubbed (1 survivor) — scope is layer1 only"
    else
        fail "S8b layer1.findings count=$layer1_count, want 1"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# S9 — the scope guard. Every live/recent/current-session shape is skipped even under
#      --apply, and each is accounted for in skipped_live / skipped_recent.
# ─────────────────────────────────────────────────────────────────────────────
S9_scope_guard_skips_live() {
    require_tool "S9 scope guard skips live/recent/current-session files" || return
    local dir out now recent_stamp
    dir="$(new_plans_dir s9)"
    now="$(now_iso)"
    recent_stamp="$now"
    local contam; contam="$(contaminated 'A1 marker test')"

    mk_state "$dir" "s9alertpending" "{\"findings\":[$contam],\"alert\":{\"alert_phase\":\"pending\"}}"
    mk_state "$dir" "s9auditpending" "{\"findings\":[$contam],\"audit\":{\"audit_phase\":\"pending\"}}"
    mk_state "$dir" "s9auditinprog"  "{\"findings\":[$contam],\"audit\":{\"audit_phase\":\"in_progress\"}}"
    mk_state "$dir" "s9recent"       "{\"findings\":[$contam],\"last_updated\":\"$recent_stamp\"}"
    mk_state "$dir" "s9cursession"   "{\"findings\":[$contam]}"
    mk_state "$dir" "s9finished"     "{\"findings\":[$contam]}"

    local -a guarded=(s9alertpending s9auditpending s9auditinprog s9recent s9cursession)
    local -a before=()
    local sid
    for sid in "${guarded[@]}"; do before+=("$(finfo "$dir/$sid-supervisor-state.json")"); done

    out="$(run_sweep_as_session "$dir" "s9cursession" --apply --ci-mode)"

    local i=0 all_same=1 offenders=""
    for sid in "${guarded[@]}"; do
        if [ "$(finfo "$dir/$sid-supervisor-state.json")" != "${before[$i]}" ]; then
            all_same=0; offenders="$offenders $sid"
        fi
        i=$((i + 1))
    done

    if [ "$all_same" = "1" ]; then
        pass "S9a alert_phase=pending / audit_phase pending+in_progress / <24h / current-SID all skipped under --apply"
    else
        fail "S9a scope guard breached for:$offenders"
    fi

    # The run must still have done its job on the one genuinely finished file — otherwise
    # S9a would pass vacuously on a tool that does nothing at all.
    if [ "$(reasons_of "$dir/s9finished-supervisor-state.json")" = "" ]; then
        pass "S9b the one finished session WAS scrubbed (guard is selective, not global)"
    else
        fail "S9b finished session not scrubbed: $(reasons_of "$dir/s9finished-supervisor-state.json")"
    fi

    local live recent
    live="$(ci_field "$out" skipped_live)"
    recent="$(ci_field "$out" skipped_recent)"
    if [ "${live:-0}" -ge 4 ] 2>/dev/null && [ "${recent:-0}" -ge 1 ] 2>/dev/null; then
        pass "S9c counters: skipped_live=$live (>=4), skipped_recent=$recent (>=1)"
    else
        fail "S9c counters wrong: skipped_live=${live:-<absent>} (want >=4) skipped_recent=${recent:-<absent>} (want >=1), out=$out"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# S10 — the guard has NO override. --session narrows only; --include-live must never exist.
# ─────────────────────────────────────────────────────────────────────────────
S10_no_live_override() {
    require_tool "S10 live guard has no override" || return
    local dir f before after out rc
    dir="$(new_plans_dir s10)"
    mk_state "$dir" "s10live" "{\"findings\":[$(contaminated 'A1 marker test')],\"alert\":{\"alert_phase\":\"pending\"}}"
    f="$dir/s10live-supervisor-state.json"
    before="$(finfo "$f")"

    out="$(run_sweep "$dir" --apply --ci-mode --session s10live)"; rc=$RC
    after="$(finfo "$f")"

    if [ "$before" = "$after" ] && [ "$rc" -eq 0 ]; then
        pass "S10a --session on a live file: unchanged, exit 0 (narrows targets, never relaxes the guard)"
    else
        fail "S10a --session breached the guard or errored: rc=$rc before='$before' after='$after'"
    fi
    local live; live="$(ci_field "$out" skipped_live)"
    if [ "${live:-0}" -ge 1 ] 2>/dev/null; then
        pass "S10b the skip is reported (skipped_live=$live), not silent"
    else
        fail "S10b skip not reported: skipped_live=${live:-<absent>}, out=$out"
    fi

    # S10c: capture exit code directly (run_sweep sets RC inside a command substitution
    # subshell — the update does not propagate to the caller's shell).
    local incl_out incl_rc
    incl_out="$(env -u AGENTS_CONFIG_DIR -u CLAUDE_SESSION_ID "WORKFLOW_PLANS_DIR=$(node_path "$dir")" \
        "$RWT" 90 bash "$SWEEP" --apply --include-live 2>&1)"
    incl_rc=$?
    if [ "$incl_rc" -ne 0 ]; then
        pass "S10c --include-live is an unrecognized flag (exit $incl_rc) — override cannot be reintroduced quietly"
    else
        fail "S10c --include-live was accepted (exit 0) — a live-session override exists: $incl_out"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# S11 — co-occurrence rule. "maintenance recovery" and "standalone reason" are the only two
#       allowlist entries a human could plausibly write, so they are contamination ONLY when
#       a case-label sibling sits in the same file.
# ─────────────────────────────────────────────────────────────────────────────
S11_cooccurrence_rule() {
    require_tool "S11 co-occurrence rule for human-plausible reasons" || return
    local dir_alone dir_sib before after left
    dir_alone="$(new_plans_dir s11alone)"
    mk_state "$dir_alone" "s11alone" "{\"findings\":[
        $(contaminated 'maintenance recovery'),
        $(legit_sentinel 'a genuine long human reason that must survive the sweep')
    ]}"
    before="$(finfo "$dir_alone/s11alone-supervisor-state.json")"
    run_sweep "$dir_alone" --apply --ci-mode >/dev/null
    after="$(finfo "$dir_alone/s11alone-supervisor-state.json")"
    if [ "$before" = "$after" ]; then
        pass "S11a 'maintenance recovery' alone (no sibling case label) survives"
    else
        fail "S11a 'maintenance recovery' removed without a sibling case label — over-broad"
    fi

    dir_sib="$(new_plans_dir s11sib)"
    mk_state "$dir_sib" "s11sib" "{\"findings\":[
        $(contaminated 'maintenance recovery'),
        $(contaminated 'A1 marker test'),
        $(contaminated 'standalone reason'),
        $(legit_sentinel 'a genuine long human reason that must survive the sweep')
    ]}"
    run_sweep "$dir_sib" --apply --ci-mode >/dev/null
    left="$(reasons_of "$dir_sib/s11sib-supervisor-state.json")"
    if [ "$left" = "a genuine long human reason that must survive the sweep" ]; then
        pass "S11b same reasons removed when a case-label sibling shares the file"
    else
        fail "S11b co-occurrence removal wrong, survivors:"$'\n'"$left"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# S12 — a file emptied of findings stays on disk; deletion is never the tool's decision.
# ─────────────────────────────────────────────────────────────────────────────
S12_emptied_file_kept() {
    require_tool "S12 emptied file stays on disk" || return
    local dir f out n
    dir="$(new_plans_dir s12)"
    mk_state "$dir" "s12sess" "{\"findings\":[$(contaminated 'A1 marker test'), $(contaminated 'A6 chain test')]}"
    f="$dir/s12sess-supervisor-state.json"
    out="$(run_sweep "$dir" --apply --ci-mode)"

    if [ -f "$f" ]; then
        pass "S12a file emptied of findings still exists on disk"
    else
        fail "S12a tool deleted the emptied state file"
        return
    fi
    n="$(ci_field "$out" files_emptied)"
    if [ "${n:-0}" -ge 1 ] 2>/dev/null; then
        pass "S12b files_emptied=$n"
    else
        fail "S12b files_emptied=${n:-<absent>}, want >=1 (out=$out)"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# S13 — unparsable JSON is skipped and counted, never deleted or rewritten.
# ─────────────────────────────────────────────────────────────────────────────
S13_unparsable_skipped() {
    require_tool "S13 unparsable JSON skipped and counted" || return
    local dir bad before after out n
    dir="$(new_plans_dir s13)"
    bad="$dir/s13broken-supervisor-state.json"
    printf '{ "layer1": { "findings": [ this is not json' > "$bad"
    mk_state "$dir" "s13ok" "{\"findings\":[$(contaminated 'A1 marker test')]}"
    before="$(finfo "$bad")"
    out="$(run_sweep "$dir" --apply --ci-mode)"
    after="$(finfo "$bad")"

    if [ -f "$bad" ] && [ "$before" = "$after" ]; then
        pass "S13a unparsable file left byte-identical on disk"
    else
        fail "S13a unparsable file was deleted or rewritten: exists=$([ -f "$bad" ] && echo yes || echo no) before='$before' after='$after'"
    fi
    n="$(ci_field "$out" files_skipped_unparsable)"
    if [ "${n:-0}" -ge 1 ] 2>/dev/null; then
        pass "S13b files_skipped_unparsable=$n"
    else
        fail "S13b files_skipped_unparsable=${n:-<absent>}, want >=1 (out=$out)"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# S14 — machine-readable surfaces: --ci-mode counters and --list-signatures.
# ─────────────────────────────────────────────────────────────────────────────
S14_ci_mode_and_list_signatures() {
    require_tool "S14 --ci-mode counters and --list-signatures" || return
    local dir out missing k v
    dir="$(new_plans_dir s14)"
    mk_state "$dir" "s14sess" "{\"findings\":[$(contaminated 'A1 marker test'), $(legit_sentinel 'a genuine long human reason')]}"
    out="$(run_sweep "$dir" --apply --ci-mode)"

    missing=""
    for k in scanned skipped_live skipped_recent files_contaminated files_modified \
             records_removed files_emptied files_skipped_unparsable backup_dir errors; do
        v="$(ci_field "$out" "$k")"
        [ -z "$v" ] && missing="$missing $k"
    done
    if [ -z "$missing" ]; then
        pass "S14a --ci-mode JSON carries every declared counter"
    else
        fail "S14a --ci-mode JSON missing key(s):$missing (out=$out)"
    fi

    local sig rc n
    sig="$(env -u AGENTS_CONFIG_DIR "WORKFLOW_PLANS_DIR=$(node_path "$dir")" "$RWT" 30 bash "$SWEEP" --list-signatures 2>&1)"
    rc=$?
    if [ "$rc" -eq 0 ]; then
        pass "S14b --list-signatures exits 0"
    else
        fail "S14b --list-signatures exited $rc: $sig"
    fi
    n="$(printf '%s\n' "$sig" | grep -v '^[[:space:]]*$' | grep -vc '^[[:space:]]*#')"
    if [ "$n" = "14" ]; then
        pass "S14c --list-signatures prints exactly 14 allowlist entries"
    else
        fail "S14c --list-signatures printed $n entries, want 14:"$'\n'"$sig"
    fi

    # Spot-check both ends of the allowlist boundary.
    local want_present="A1 marker test|SEC2 metachars|maintenance recovery|standalone reason"
    local IFS='|'
    local w miss_p=""
    for w in $want_present; do
        printf '%s\n' "$sig" | grep -qxF "$w" || miss_p="$miss_p '$w'"
    done
    unset IFS
    if [ -z "$miss_p" ]; then
        pass "S14d allowlist contains the expected literals"
    else
        fail "S14d allowlist missing:$miss_p"
    fi
    if ! printf '%s\n' "$sig" | grep -qxF 'test' && ! printf '%s\n' "$sig" | grep -qxF 'x' \
       && ! printf '%s\n' "$sig" | grep -qxF 'recovery'; then
        pass "S14e allowlist excludes the human-plausible generics (test / x / recovery)"
    else
        fail "S14e allowlist wrongly includes an excluded generic:"$'\n'"$sig"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────

S1_legitimate_only_untouched
S2_mixed_file_partial_removal
S3_excluded_reasons_survive
S4_old_format_removed
S5_default_is_dry_run
S6_backup_and_manifest
S7_scrubbed_file_validates
S8_alert_audit_untouched
S9_scope_guard_skips_live
S10_no_live_override
S11_cooccurrence_rule
S12_emptied_file_kept
S13_unparsable_skipped
S14_ci_mode_and_list_signatures

echo ""
echo "─────────────────────────────────────────"
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
