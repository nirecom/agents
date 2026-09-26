# tests/hooks/feature-2169-workflow-not-started-notify-gate/p-wiring.sh
# Tests: hooks/user-prompt-submit-mechanism-check.js, hooks/lib/stop-exemption-policy.js, hooks/workflow-state/lifecycle.js
# Tags: stall-detection, user-prompt-submit, prompt-notify, pre-workflow-init, wi-10-lookahead, regression-2169, scope:issue-specific, pwsh-not-required, TL1, TL2
# P4-P5/P11-P12 (round-2 review C1/C3; round-5 review C2/C3) — cross-module wiring, fail-open proofs, same-step origin-ordering, and stop-exemption-policy fault-injection, against the real hook subprocess. See dispatcher frontmatter; depends on helpers.sh.

# P4: cross-module wiring proof — mutates EXEMPTION_MATRIX at require-time (preload, same technique N3 uses) so pre-workflow-init.promptNotify is forced false, and asserts the real hook subprocess's verdict flips to notify. Proves the gate reads the matrix at runtime, not a hard-coded copy.
run_P4() {
    local tmp tn preload problems=""
    tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
    dispatch_lookahead "$tn" p4
    backdate_research "$tmp" p4 $((TTL_MS + 60000))

    preload="$tmp/mutate-matrix-preload.js"
    cat > "$preload" <<'EOF'
"use strict";
const Module = require("module");
const origRequire = Module.prototype.require;
Module.prototype.require = function (request) {
  if (request === "./lib/stop-exemption-policy") {
    const real = origRequire.call(this, request);
    const mutated = {};
    for (const k of Object.keys(real.EXEMPTION_MATRIX)) {
      mutated[k] = Object.assign({}, real.EXEMPTION_MATRIX[k]);
    }
    if (mutated["pre-workflow-init"]) mutated["pre-workflow-init"].promptNotify = false;
    return Object.assign({}, real, { EXEMPTION_MATRIX: Object.freeze(mutated) });
  }
  return origRequire.apply(this, arguments);
};
EOF

    UPS_OUT=$(SID="p4" "$RWT" 15 node -e "
process.stdout.write(JSON.stringify({ session_id: process.env.SID, transcript_path: '',
  prompt: 'where are we?', hook_event_name: 'UserPromptSubmit' }));" \
        | CLAUDE_WORKFLOW_DIR="$tn" WORKFLOW_PLANS_DIR="$tn" AGENTS_CONFIG_DIR="$_AGENTS_DIR_NODE" \
          "$RWT" 25 node -r "$(node_path "$preload")" "$(node_path "$UPS_HOOK")" 2>/dev/null)
    UPS_RC=$?
    [ "$UPS_RC" -eq 0 ] || problems="$problems [hook exited $UPS_RC]"
    compact="$(printf '%s' "$UPS_OUT" | tr -d ' \n\r')"
    case "$compact" in
        *'"blocks":true'*) : ;;
        *) problems="$problems [forcing pre-workflow-init.promptNotify=false did not flip the verdict to notify — got '${UPS_OUT:-<empty>}'; if P1 is passing, the gate reads a hard-coded duplicate instead of EXEMPTION_MATRIX]" ;;
    esac
    rm -rf "$tmp" 2>/dev/null || true
    if [ -z "$problems" ]; then
        pass "P4: forcing EXEMPTION_MATRIX['pre-workflow-init'].promptNotify=false at load time flips the real hook subprocess's verdict to notify — proves the gate reads the matrix at runtime rather than a hard-coded duplicate (meaningful once P1 also passes)"
    else
        fail "P4: mutating EXEMPTION_MATRIX did not change the real hook's verdict;$problems"
    fi
}

# P5 (best-effort): fail-open in the full subprocess, not just N3's isolated
# isSessionExemptFromPromptNotify() call. Uses P2's genuinely-started +
# TTL-expired fixture, fault-injects require('./workflow-state') to throw
# inside the REAL hook subprocess, and asserts the hook still notifies
# (blocks:true, exit 0) instead of silently swallowing the failure.
run_P5() {
    local tmp tn preload problems=""
    tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
    dispatch_lookahead "$tn" p5
    complete_workflow_init "$tn" p5
    backdate_research "$tmp" p5 $((TTL_MS + 60000))

    preload="$tmp/fault-inject-workflow-state-preload.js"
    cat > "$preload" <<'EOF'
"use strict";
const Module = require("module");
const origRequire = Module.prototype.require;
Module.prototype.require = function (request) {
  if (request === "./workflow-state") {
    throw new Error("simulated require failure (#2169 P5/C3)");
  }
  return origRequire.apply(this, arguments);
};
EOF

    UPS_OUT=$(SID="p5" "$RWT" 15 node -e "
process.stdout.write(JSON.stringify({ session_id: process.env.SID, transcript_path: '',
  prompt: 'where are we?', hook_event_name: 'UserPromptSubmit' }));" \
        | CLAUDE_WORKFLOW_DIR="$tn" WORKFLOW_PLANS_DIR="$tn" AGENTS_CONFIG_DIR="$_AGENTS_DIR_NODE" \
          "$RWT" 25 node -r "$(node_path "$preload")" "$(node_path "$UPS_HOOK")" 2>/dev/null)
    UPS_RC=$?
    [ "$UPS_RC" -eq 0 ] || problems="$problems [hook exited $UPS_RC instead of failing open]"
    compact="$(printf '%s' "$UPS_OUT" | tr -d ' \n\r')"
    case "$compact" in
        *'"blocks":true'*) : ;;
        *) problems="$problems [expected blocks:true (fail-open toward notifying) when ./workflow-state require fails, got '${UPS_OUT:-<empty>}']" ;;
    esac
    rm -rf "$tmp" 2>/dev/null || true
    if [ -z "$problems" ]; then
        pass "P5: a require('./workflow-state') failure inside the REAL hook subprocess (genuinely-started, TTL-expired) still notifies — fail-open holds end-to-end, not just in N3's isolated function check"
    else
        fail "P5: the real hook subprocess did not fail open toward notifying when ./workflow-state require failed;$problems"
    fi
}

# P11 (round-5 review C2): isLookaheadOnlyInFlight's "last step_status event for the step wins" rule, exercised on the SAME step
# with its origin changing over time (existing coverage only covered different-step, same-instant cases). Two orderings:
# lookahead-then-genuine must resolve false (the step was later genuinely claimed); genuine-then-lookahead must resolve true
# (a lookahead re-mark is the step's last word).
run_P11() {
    local tmp tn tmp2 tn2 problems="" out
    tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
    mark_step_with_origin "$tn" p11a research postuse-in-flight
    mark_step_with_origin "$tn" p11a research mark-step
    out=$(CLAUDE_WORKFLOW_DIR="$tn" WORKFLOW_PLANS_DIR="$tn" "$RWT" 20 node -e "
process.stdout.write(String(require('$LIFECYCLE_NODE').isLookaheadOnlyInFlight('p11a', 'research')));" 2>/dev/null)
    [ "$out" = "false" ] ||
        problems="$problems [lookahead-then-genuine: isLookaheadOnlyInFlight=${out:-<err>}, expected false — the LATER genuine mark-step event should win over the earlier lookahead mark]"

    tmp2="$(make_tmp)"; tn2="$(node_path "$tmp2")"
    mark_step_with_origin "$tn2" p11b research mark-step
    mark_step_with_origin "$tn2" p11b research postuse-in-flight
    out=$(CLAUDE_WORKFLOW_DIR="$tn2" WORKFLOW_PLANS_DIR="$tn2" "$RWT" 20 node -e "
process.stdout.write(String(require('$LIFECYCLE_NODE').isLookaheadOnlyInFlight('p11b', 'research')));" 2>/dev/null)
    [ "$out" = "true" ] ||
        problems="$problems [genuine-then-lookahead: isLookaheadOnlyInFlight=${out:-<err>}, expected true — the LATER lookahead mark should win over the earlier genuine mark]"

    rm -rf "$tmp" "$tmp2" 2>/dev/null || true
    if [ -z "$problems" ]; then
        pass "P11: for the SAME step, isLookaheadOnlyInFlight follows the LAST step_status event's origin regardless of which origin came first — lookahead-then-genuine resolves false, genuine-then-lookahead resolves true"
    else
        fail "P11: isLookaheadOnlyInFlight does not correctly apply 'last event wins' when the SAME step's origin changes over time;$problems"
    fi
}

# P12 (round-5 review C3): fault-injection for getExemptionMatrix()'s own require('./lib/stop-exemption-policy') failure,
# mirroring P5's fault injection of require('./workflow-state') on the SAME kind of fixture (a genuinely pre-workflow-init,
# WI-10-lookahead-only session that P1 proves is normally suppressed). getExemptionMatrix() catches the failure and caches {},
# so PROMPT_NOTIFY_EXEMPTIONS finds no matching row and the session must now notify instead of silently staying suppressed.
run_P12() {
    local tmp tn preload problems=""
    tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
    dispatch_lookahead "$tn" p12
    backdate_research "$tmp" p12 $((TTL_MS + 60000))

    preload="$tmp/fault-inject-stop-exemption-policy-preload.js"
    cat > "$preload" <<'EOF'
"use strict";
const Module = require("module");
const origRequire = Module.prototype.require;
Module.prototype.require = function (request) {
  if (request === "./lib/stop-exemption-policy") {
    throw new Error("simulated require failure (#2169 P12/C3)");
  }
  return origRequire.apply(this, arguments);
};
EOF

    UPS_OUT=$(SID="p12" "$RWT" 15 node -e "
process.stdout.write(JSON.stringify({ session_id: process.env.SID, transcript_path: '',
  prompt: 'where are we?', hook_event_name: 'UserPromptSubmit' }));" \
        | CLAUDE_WORKFLOW_DIR="$tn" WORKFLOW_PLANS_DIR="$tn" AGENTS_CONFIG_DIR="$_AGENTS_DIR_NODE" \
          "$RWT" 25 node -r "$(node_path "$preload")" "$(node_path "$UPS_HOOK")" 2>/dev/null)
    UPS_RC=$?
    [ "$UPS_RC" -eq 0 ] || problems="$problems [hook exited $UPS_RC instead of failing safe]"
    compact="$(printf '%s' "$UPS_OUT" | tr -d ' \n\r')"
    case "$compact" in
        *'"blocks":true'*) : ;;
        *) problems="$problems [expected blocks:true (fail-safe toward notifying) when ./lib/stop-exemption-policy require fails inside getExemptionMatrix(), got '${UPS_OUT:-<empty>}']" ;;
    esac
    rm -rf "$tmp" 2>/dev/null || true
    if [ -z "$problems" ]; then
        pass "P12: a require('./lib/stop-exemption-policy') failure inside getExemptionMatrix() makes an otherwise-exempt pre-workflow-init/WI-10-lookahead session notify instead of staying silently suppressed — fail-safe, distinct from P5's fault injection of require('./workflow-state')"
    else
        fail "P12: getExemptionMatrix()'s own require failure did not fail safe toward notifying;$problems"
    fi
}

# P15 (#2279): the drift detector. "Is this in_progress mark only the WI-10
# lookahead's?" is one question with one owner — lifecycle.js's LOOKAHEAD_ORIGIN
# and isLookaheadOnlyInFlight. The prompt-notify gate P1-P12 exercise already
# asks it correctly; the readers that decide ADOPTION do not, and that split is
# #2279. Read as data, so it costs nothing and holds for every future reader.
run_P15() {
    local f label problems="" owner="hooks/workflow-state/lifecycle.js"
    # (a) the constant has exactly one definition site.
    for f in $(grep -rl 'postuse-in-flight' "$AGENTS_DIR/hooks" "$AGENTS_DIR/bin" 2>/dev/null); do
        case "$f" in
            *"$owner") : ;;
            *) problems="$problems [$(basename "$f") hard-codes the origin string instead of importing LOOKAHEAD_ORIGIN]" ;;
        esac
    done
    # (b) every module that gates on "has this session recorded progress" reaches
    #     the shared predicate. The list is the reader set, not an inventory of
    #     today's call sites: adding a reader without the predicate is the drift.
    for label in hooks/user-prompt-submit-mechanism-check.js \
                 hooks/workflow-state/inheritance/adopt.js \
                 bin/resume-session-detect; do
        f="$AGENTS_DIR/$label"
        if [ ! -f "$f" ]; then
            problems="$problems [$label: not found]"
        elif ! grep -qE 'isLookaheadOnlyInFlight|LOOKAHEAD_ORIGIN' "$f"; then
            problems="$problems [$label: decides on in_progress without ever asking whether the mark is lookahead-only]"
        fi
    done
    if [ -z "$problems" ]; then
        pass "P15: the lookahead origin has a single owner and every progress-gating reader consults the shared predicate (CPR-SSOT)"
    else
        fail "P15: the WI-10 lookahead rule has drifted across its readers;$problems"
    fi
}

# _p16_verdicts <tn> <sid> <step> <kind> — the two per-finding exemption
# verdicts for ONE (session, finding) pair, as "c4=<v>,pn=<v>". A missing export
# or a throwing predicate is reported as its own token rather than collapsing
# into `false`, so the case can name what is actually absent.
_p16_verdicts() {
    CLAUDE_WORKFLOW_DIR="$1" WORKFLOW_PLANS_DIR="$1" AGENTS_CONFIG_DIR="$_AGENTS_DIR_NODE" \
    SID="$2" STEP="$3" KIND="$4" "$RWT" 20 node -e "
const finding = { step: process.env.STEP, kind: process.env.KIND };
const sid = process.env.SID;
const c4mod = require('$(node_path "$C4_HOOK")');
const pnmod = require('$(node_path "$UPS_HOOK")');
let c4;
if (typeof c4mod.isFindingExemptFromC4 !== 'function') c4 = '<no-export:isFindingExemptFromC4>';
else if (typeof c4mod.buildExemptionDeps !== 'function') c4 = '<no-export:buildExemptionDeps>';
else {
  try { c4 = String(c4mod.isFindingExemptFromC4(sid, finding, c4mod.buildExemptionDeps())); }
  catch (e) { c4 = '<threw>'; }
}
let pn;
try { pn = String(pnmod.isFindingExemptFromPromptNotify(sid, finding)); }
catch (e) { pn = '<threw>'; }
process.stdout.write('c4=' + c4 + ',pn=' + pn);" 2>/dev/null
}

# P16 (#2213, detail.md (h)): C4's C4_MECHANISM_EXEMPTIONS and the prompt-notify
# hook's PROMPT_NOTIFY_EXEMPTIONS encode the SAME per-finding pre-workflow-init
# rule in two places on purpose (#2169's implementation stays untouched as the
# reference). A deliberate duplicate needs a machine-checked equality, or the two
# drift and the same session gets contradictory answers from Stop and from the
# next prompt. Fixtures are the C-b / C-c / C-d population of
# tests/hooks/feature-2013-step-in-flight-automark/e-lookahead-guard.sh plus the
# corrupt-state shape C-f adds. Expected to FAIL until the S-5 fix exports
# isFindingExemptFromC4.
run_P16() {
    local tmp tn sid label step kind want out c4 pn problems="" C4_HOOK
    C4_HOOK="$AGENTS_DIR/hooks/stop-premature-stop-guard.js"
    while IFS='|' read -r label step kind want; do
        label="$(printf '%s' "$label" | tr -d ' ')"
        step="$(printf '%s' "$step" | tr -d ' ')"
        kind="$(printf '%s' "$kind" | tr -d ' ')"
        want="$(printf '%s' "$want" | tr -d ' ')"
        [ -z "$label" ] && continue
        case "$label" in \#*) continue ;; esac
        tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
        sid="p16-${label}"
        case "$label" in
            allpending)   seed_all_pending "$tmp" "$sid" ;;
            lookahead)    dispatch_lookahead "$tn" "$sid"
                          backdate_research "$tmp" "$sid" $((TTL_MS + 60000)) ;;
            metaopskill)  dispatch_meta_skill "$tn" "$sid" ;;
            statecorrupt) seed_state_corrupt "$tmp" "$sid" ;;
        esac

        out="$(_p16_verdicts "$tn" "$sid" "$step" "$kind")"
        c4="${out%%,*}"; c4="${c4#c4=}"
        pn="${out#*,pn=}"
        [ "$c4" = "$pn" ] ||
            problems="$problems [$label ($step/$kind): C4 says '$c4' but prompt-notify says '$pn' — the two copies of the pre-workflow-init per-finding rule disagree]"
        [ "$c4" = "$want" ] ||
            problems="$problems [$label ($step/$kind): C4 exemption verdict is '$c4', expected '$want']"
        [ "$pn" = "$want" ] ||
            problems="$problems [$label ($step/$kind): prompt-notify exemption verdict is '$pn', expected '$want']"
        rm -rf "$tmp" 2>/dev/null || true
    done <<'TABLE'
# label      | finding step | finding kind      | both must answer
allpending   | research     | in-flight-expired | false
lookahead    | research     | in-flight-expired | true
metaopskill  | research     | in-flight-expired | false
statecorrupt | (state)      | state-corrupt     | false
TABLE

    if [ -z "$problems" ]; then
        pass "P16: C4's C4_MECHANISM_EXEMPTIONS and the prompt-notify hook's PROMPT_NOTIFY_EXEMPTIONS return the SAME per-finding verdict across the C-b/C-c/C-d/corrupt-state population — the intentional duplicate has not drifted (#2213)"
    else
        fail "P16: the two per-finding pre-workflow-init exemption implementations disagree;$problems"
    fi
}
