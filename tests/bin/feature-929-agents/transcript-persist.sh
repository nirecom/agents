# transcript-persist.sh — fragment of tests/bin/feature-929-agents.sh (no frontmatter).
# Source: hooks/workflow-state/state-io/core.js, hooks/session-start.js (R3-C3).
# NOTE: RED until write-code adds transcript_path to session_start_context (#929):
#   core.js createInitialState + session-start.js ctx.transcript_path.

_tp_run() {
    echo ""
    echo "--- transcript-persist (R3-C3) ---"

    # (a) createInitialState preserves/normalizes transcript_path.
    local probe_a="$TMPDIR_BASE/tp-a.js"
    cat > "$probe_a" <<'JS'
const core = require(process.argv[2]);
const ctx = { cwd: "/w", git_branch: "br" };
const withTp = core.createInitialState("sid-a", Object.assign({}, ctx, { transcript_path: "/t/x.jsonl" }));
const omitted = core.createInitialState("sid-a", ctx);
const nonstr = core.createInitialState("sid-a", Object.assign({}, ctx, { transcript_path: 123 }));
console.log("with=" + ((withTp.session_start_context.transcript_path) ?? "NULL"));
console.log("omitted=" + ((omitted.session_start_context.transcript_path) ?? "NULL"));
console.log("nonstring=" + ((nonstr.session_start_context.transcript_path) ?? "NULL"));
console.log("version=" + withTp.version);
JS
    local out_a
    out_a="$(run_with_timeout 30 node "$probe_a" "$CORE_JS" 2>&1)"
    # NOTE: RED — createInitialState does not yet copy transcript_path.
    assert_contains "tp(a): createInitialState keeps string transcript_path" "$out_a" "with=/t/x.jsonl"
    assert_contains "tp(a): omitted transcript_path -> null" "$out_a" "omitted=NULL"
    assert_contains "tp(a): non-string transcript_path -> null" "$out_a" "nonstring=NULL"
    assert_contains "tp(a): version stays 4 (no bump)" "$out_a" "version=4"

    # (b) session-start.js persists input.transcript_path into state.
    local sid_b="sess-tp-b-$RANDOM$RANDOM"
    local tp_b="/tmp/transcripts/$sid_b.jsonl"
    printf '{"session_id":"%s","transcript_path":"%s","source":"startup"}' "$sid_b" "$tp_b" \
        | run_with_timeout 30 node "$SESSION_START_JS" >/dev/null 2>&1
    local probe_read="$TMPDIR_BASE/tp-read.js"
    cat > "$probe_read" <<'JS'
const core = require(process.argv[2]);
const s = core.readState(process.argv[3]);
const v = (s && s.session_start_context && s.session_start_context.transcript_path) || "NULL";
console.log("tp=" + v);
JS
    local out_b
    out_b="$(run_with_timeout 30 node "$probe_read" "$CORE_JS" "$sid_b" 2>&1)"
    # NOTE: RED — session-start.js does not yet pass transcript_path into ctx.
    assert_contains "tp(b): session-start persists input.transcript_path" "$out_b" "tp=$tp_b"

    # (c) reader resolves transcript_path for a written state (round-trip via writer).
    local sid_c="sess-tp-c-$RANDOM$RANDOM"
    local tp_c="/tmp/tc/$sid_c.jsonl"
    local probe_c="$TMPDIR_BASE/tp-c.js"
    cat > "$probe_c" <<'JS'
const core = require(process.argv[2]);
const sid = process.argv[3];
const tp = process.argv[4];
const st = core.createInitialState(sid, { cwd: "/w", git_branch: "br", transcript_path: tp });
core.writeState(sid, st);
const r = core.readState(sid);
const v = (r && r.session_start_context && r.session_start_context.transcript_path) || "NULL";
console.log("rt=" + v);
console.log("ver=" + (r && r.version));
JS
    local out_c
    out_c="$(run_with_timeout 30 node "$probe_c" "$CORE_JS" "$sid_c" "$tp_c" 2>&1)"
    # NOTE: RED — createInitialState drops transcript_path, so reader sees NULL.
    assert_contains "tp(c): reader resolves transcript_path after write" "$out_c" "rt=$tp_c"
    # (d) round-trip keeps version 4 (guard: no version bump for the additive field).
    assert_contains "tp(d): round-trip keeps state version 4" "$out_c" "ver=4"
}

_tp_run
