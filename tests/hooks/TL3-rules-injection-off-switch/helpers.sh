# shellcheck shell=bash
# Tests: hooks/instructions-loaded-audit.js, hooks/lib/instructions-loaded-receipt.js, hooks/lib/rules-injection-policy.js
# Tags: rules-injection, on-demand-rules, off-switch, instructions-loaded, fixtures, claude-e2e, TL3, scope:common
#
# Helpers for TL3-rules-injection-off-switch. Sourced by ../TL3-rules-injection-off-switch.sh
# (assumes AGENTS_DIR, pass(), fail() defined) and by tests/cc-tl3-rules-injection-gate.sh,
# which exercises ril_gate_verdict() at TL2 without spawning claude.
# WSL-via-Windows bridge: CLAUDECODE is not propagated and user settings are read from
# the Windows profile, so a green run here does not prove the macOS-native behaviour.

# Portable timeout: bin/run-with-timeout.sh works on macOS (no `timeout` there).
run_with_timeout() {
    local secs="$1"; shift
    "$AGENTS_DIR/bin/run-with-timeout.sh" "$secs" "$@"
}

node_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi; }

make_tmp_base() {
    local d
    d="$(node -e "
const os=require('os'),path=require('path'),fs=require('fs');
console.log(fs.mkdtempSync(path.join(os.tmpdir(),'ril-')).replace(/\\\\/g,'/'));
" 2>/dev/null)"
    [ -z "$d" ] && d="$(mktemp -d)"
    echo "$d"
}

RIL_TOKEN='.on-demand-only/never-match'
RIL_MARKER='<!-- injection: on-demand-only - auto-injection disabled; the owning skill Reads it explicitly. -->'

# ril_write_probe <abs-path> <nonce> <kind:plain|reserved>
ril_write_probe() {
    local p="$1" nonce="$2" kind="$3"
    mkdir -p "$(dirname "$p")"
    if [ "$kind" = "reserved" ]; then
        {
            printf -- '---\n'
            printf 'paths:\n'
            printf -- '  - "%s"\n' "$RIL_TOKEN"
            printf -- '---\n'
            printf '%s\n\n' "$RIL_MARKER"
            printf '# Probe %s\n' "$nonce"
        } > "$p"
    else
        printf '# Probe %s\n\nNonce: %s\n' "$nonce" "$nonce" > "$p"
    fi
}

# ril_build_repo <repo-dir> — fixture project with ONLY the hook under test registered.
# No disableBypassPermissionsMode (rules/test/claude-e2e.md).
ril_build_repo() {
    local repo="$1"
    mkdir -p "$repo/.claude"
    git -C "$repo" init -q 2>/dev/null || { mkdir -p "$repo"; git -C "$repo" init -q; }
    git -C "$repo" config core.hooksPath /dev/null
    git -C "$repo" config user.email "test@example.com"
    git -C "$repo" config user.name "Test"
    local hook_js; hook_js="$(node_path "$AGENTS_DIR/hooks/instructions-loaded-audit.js")"
    cat > "$repo/.claude/settings.json" <<SETTINGS_EOF
{
  "hooks": {
    "InstructionsLoaded": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "node \"$hook_js\"",
            "timeout": 5
          }
        ]
      }
    ]
  }
}
SETTINGS_EOF
}

# ril_seed_rules <rules-dir> <mode:base|judge>
# RUN-BASE: every probe lacks frontmatter. RUN-JUDGE: probe-target.md alone gains the
# reserved glob + marker. Everything else is byte-identical between the two runs.
ril_seed_rules() {
    local rd="$1" mode="$2"
    mkdir -p "$rd"
    ril_write_probe "$rd/probe-control-1.md" "$RIL_NONCE_A1" plain
    ril_write_probe "$rd/probe-control-2.md" "$RIL_NONCE_A2" plain
    ril_write_probe "$rd/probe-control-3.md" "$RIL_NONCE_A3" plain
    if [ "$mode" = "judge" ]; then
        ril_write_probe "$rd/probe-target.md" "$RIL_NONCE_B" reserved
    else
        ril_write_probe "$rd/probe-target.md" "$RIL_NONCE_B" plain
    fi
}

# ril_prepare <strategy:project|configdir|home> <base> <mode> — sets RIL_RULES_DIR,
# RIL_REPO and the strategy-specific env carried into `claude -p`.
RIL_ENV_KIND=""; RIL_ENV_VALUE=""; RIL_RULES_DIR=""; RIL_REPO=""
ril_prepare() {
    local strategy="$1" base="$2" mode="$3"
    RIL_REPO="$base/repo"
    ril_build_repo "$RIL_REPO"
    case "$strategy" in
        project)
            RIL_RULES_DIR="$RIL_REPO/.claude/rules"; RIL_ENV_KIND=""; RIL_ENV_VALUE="" ;;
        configdir)
            RIL_RULES_DIR="$base/cfg/rules"
            mkdir -p "$base/cfg"
            RIL_ENV_KIND="CLAUDE_CONFIG_DIR"; RIL_ENV_VALUE="$(node_path "$base/cfg")" ;;
        home)
            RIL_RULES_DIR="$base/home/.claude/rules"
            mkdir -p "$base/home/.claude"
            cp "$HOME/.claude/settings.json" "$base/home/.claude/settings.json" 2>/dev/null || \
                printf '{}\n' > "$base/home/.claude/settings.json"
            # Preserve authentication so the probe session can actually start.
            cp "$HOME/.claude/.credentials.json" "$base/home/.claude/.credentials.json" 2>/dev/null || true
            RIL_ENV_KIND="HOME"; RIL_ENV_VALUE="$base/home" ;;
        *) return 2 ;;
    esac
    ril_seed_rules "$RIL_RULES_DIR" "$mode"
}

# ril_run_claude <session-id> <workflow-dir> <plans-dir> — one probe session.
# Echoes the exit code; transcript goes to $RIL_LAST_OUTPUT.
RIL_LAST_OUTPUT=""
ril_run_claude() {
    local sid="$1" wf="$2" plans="$3" rc=0
    RIL_LAST_OUTPUT="$(
        cd "$RIL_REPO" || exit 90
        unset CLAUDECODE
        unset CLAUDE_SESSION_ID
        unset CLAUDE_CODE_SESSION_ID
        # Dual-pin the isolation pair (rules/test/fixture-isolation.md).
        export CLAUDE_WORKFLOW_DIR="$(node_path "$wf")"
        export WORKFLOW_PLANS_DIR="$(node_path "$plans")"
        [ -n "$RIL_ENV_KIND" ] && export "$RIL_ENV_KIND=$RIL_ENV_VALUE"
        run_with_timeout 180 claude -p \
            'Output the exact text: RIL_PROBE_DONE' \
            --session-id "$sid" \
            --setting-sources project \
            --dangerously-skip-permissions \
            --output-format json \
            2>&1
    )" || rc=$?
    echo "$rc"
}

ril_receipt_dir() { echo "$1/$2.instructions-loaded"; }

# ril_entry_paths <workflow-dir> <sid> — one file_path per line, settled entries only.
ril_entry_paths() {
    node -e "
const fs=require('fs'),path=require('path');
const dir=path.join(process.argv[1], process.argv[2] + '.instructions-loaded');
if (!fs.existsSync(dir)) process.exit(0);
for (const n of fs.readdirSync(dir)) {
  if (!n.endsWith('.json')) continue;
  try { const j=JSON.parse(fs.readFileSync(path.join(dir,n),'utf8'));
    if (j && j.file_path) console.log(j.file_path); } catch (_) {}
}
" "$(node_path "$1")" "$2" 2>/dev/null
}

# ril_verdict_for <workflow-dir> <sid> <basename> — verdict of the entry whose
# file_path ends with <basename>, or ABSENT.
ril_verdict_for() {
    node -e "
const fs=require('fs'),path=require('path');
const dir=path.join(process.argv[1], process.argv[2] + '.instructions-loaded');
if (!fs.existsSync(dir)) { console.log('ABSENT'); process.exit(0); }
for (const n of fs.readdirSync(dir)) {
  if (!n.endsWith('.json')) continue;
  try { const j=JSON.parse(fs.readFileSync(path.join(dir,n),'utf8'));
    if (j && typeof j.file_path==='string' && j.file_path.endsWith(process.argv[3])) {
      console.log(j.verdict === undefined ? 'NO_VERDICT' : String(j.verdict)); process.exit(0);
    } } catch (_) {}
}
console.log('ABSENT');
" "$(node_path "$1")" "$2" "$3" 2>/dev/null
}

# ril_span_seconds <workflow-dir> <sid> — max(fired_at) - min(fired_at), whole seconds.
ril_span_seconds() {
    node -e "
const fs=require('fs'),path=require('path');
const dir=path.join(process.argv[1], process.argv[2] + '.instructions-loaded');
let ts=[];
if (fs.existsSync(dir)) for (const n of fs.readdirSync(dir)) {
  if (!n.endsWith('.json')) continue;
  try { const j=JSON.parse(fs.readFileSync(path.join(dir,n),'utf8'));
    const t=Date.parse(j.fired_at); if (Number.isFinite(t)) ts.push(t); } catch (_) {}
}
console.log(ts.length ? Math.ceil((Math.max(...ts)-Math.min(...ts))/1000) : 0);
" "$(node_path "$1")" "$2" 2>/dev/null
}

# ril_load_reason_rate <workflow-dir> <sid> — "<with>/<total>"
ril_load_reason_rate() {
    node -e "
const fs=require('fs'),path=require('path');
const dir=path.join(process.argv[1], process.argv[2] + '.instructions-loaded');
let n=0,w=0;
if (fs.existsSync(dir)) for (const f of fs.readdirSync(dir)) {
  if (!f.endsWith('.json')) continue;
  try { const j=JSON.parse(fs.readFileSync(path.join(dir,f),'utf8'));
    n++; if (j.load_reason !== null && j.load_reason !== undefined) w++; } catch (_) {}
}
console.log(w + '/' + n);
" "$(node_path "$1")" "$2" 2>/dev/null
}

# ril_terminal_recheck <workflow-dir> <sid> <needle> <seconds> — Q3.
# The detail plan's terminal re-read is a CUMULATIVE observation, not a single stat:
# the receipt writer is asynchronous, so one read taken the instant the quiescence
# window closes cannot distinguish "absent" from "has not arrived yet". This polls for
# the full requested span (unless the needle shows up, which is decisive immediately)
# and reports how much observation actually happened, so the caller can refuse to grade
# a run that was cut short. Prints "SEEN=<0|1> ELAPSED=<seconds>".
ril_terminal_recheck() {
    local wf="$1" sid="$2" needle="$3" secs="$4"
    local start now elapsed=0 seen=0
    start="$(date +%s)"
    while :; do
        if ril_entry_paths "$wf" "$sid" | grep -q "$needle"; then seen=1; fi
        now="$(date +%s)"; elapsed=$((now - start))
        [ "$seen" -eq 1 ] && break
        [ "$elapsed" -ge "$secs" ] && break
        sleep 1
    done
    echo "SEEN=$seen ELAPSED=$elapsed"
}

# --- gate decision logic (pure; no filesystem, no subprocess) ----------------------
# Lives in decisions.sh (sibling split, rules/coding/file-split.md Pattern A) and is
# sourced here so helpers.sh remains the single entry point for both the TL3 body and
# the TL2 gate test tests/cc-tl3-rules-injection-gate.sh.
# shellcheck source=tests/TL3-rules-injection-off-switch/decisions.sh
. "$(dirname "${BASH_SOURCE[0]}")/decisions.sh"


# ril_quiesce <workflow-dir> <sid> <expected-json-array> <window-sec> — Q1 then Q2 via
# the SSOT waitForQuiescence(); prints "STATUS=<..> COUNT=<n>".
ril_quiesce() {
    node -e "
const path=require('path');
const { waitForQuiescence } = require(process.argv[1]);
const dir = path.join(process.argv[2], process.argv[3] + '.instructions-loaded');
let res;
try {
  res = waitForQuiescence(dir, {
    expected: JSON.parse(process.argv[4]),
    windowSec: Number(process.argv[5]),
    q1DeadlineSec: 60,
    totalDeadlineSec: 90,
    pollMs: 1000,
  });
} catch (e) { console.log('STATUS=THREW COUNT=0 (' + e.message + ')'); process.exit(0); }
const entries = (res && Array.isArray(res.entries)) ? res.entries : [];
console.log('STATUS=' + (res && res.status !== undefined ? res.status : 'NO_STATUS') + ' COUNT=' + entries.length);
" "$(node_path "$AGENTS_DIR/hooks/lib/instructions-loaded-receipt.js")" \
  "$(node_path "$1")" "$2" "$3" "$4" 2>&1
}
