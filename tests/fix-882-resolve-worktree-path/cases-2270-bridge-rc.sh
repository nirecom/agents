#!/usr/bin/env bash
# Tests: skills/review-tests/scripts/select-staged-files.sh, skills/review-tests/scripts/run-codex-review-loop.sh, bin/resolve-session-id
# Tags: scope:issue-specific, pwsh-not-required, session-id, ssot, dup-group-keep:size-hard-limit
# Part of tests/fix-882-resolve-worktree-path.sh (rules/coding/file-split.md).
# Cases BR-A..BR-C (#2270 S5-4): the two review-tests scripts receive the bridge's
# rc, and only rc 2 means "no session". rc 3 (resolver threw) and rc 127 (node
# absent) are faults: they must surface as exit 4 (HALT), never as exit 3, which
# tells the caller "no session id — carry on by hand" and would let a broken
# resolver silently review the wrong file set.
# rc contract: docs/architecture/claude-code/session-id-resolution.md

REVIEW_LOOP_SH="$AGENTS_WORKTREE/skills/review-tests/scripts/run-codex-review-loop.sh"
BRC_SID="fix-882-bridge-rc-sid"
BRC_WSID="fix-882-bridge-rc-wsid"

# A shadow AGENTS_CONFIG_DIR whose bin/resolve-session-id exits with a chosen rc.
# The whole bin/ is copied (the scripts reach for sibling bins), the four hooks
# modules the copied bridges require are forwarded to the real tree, and
# bin/run-codex-review-loop is stubbed out so no case can ever spawn codex.
#   $1: rc for the stub bridge, or "real" to keep the genuine bridge
# Echoes the shadow dir in node form.
brc_shadow_root() {
  local rc="$1" root="$TMPDIR_BASE/shadow-bridge-$1" m
  if [[ ! -d "$root" ]]; then
    mkdir -p "$root/hooks/workflow-state/state-io" "$root/hooks/workflow-gate"
    cp -r "$AGENTS_WORKTREE/bin" "$root/bin"
    for m in workflow-state workflow-state/session-id workflow-state/state-io \
             workflow-state/state-io/core workflow-state/resolve-worktree-path \
             workflow-gate/review-tests-evidence; do
      printf 'module.exports = require("%s/hooks/%s");\n' "$AGENTS_NODE" "$m" > "$root/hooks/$m.js"
    done
    if [[ "$rc" != "real" ]]; then
      printf '#!/usr/bin/env bash\nprintf "resolve-session-id: resolver failed: boom\\n" >&2\nexit %s\n' \
        "$rc" > "$root/bin/resolve-session-id"
      chmod +x "$root/bin/resolve-session-id"
    fi
    printf '#!/usr/bin/env bash\nexit 0\n' > "$root/bin/run-codex-review-loop"
    chmod +x "$root/bin/run-codex-review-loop"
  fi
  _tonode "$root"
}

# A shadow AGENTS_CONFIG_DIR whose bin/resolve-session-id unconditionally
# echoes a fixed sid (rc 0), ignoring every env var. Used to prove a receiver
# script follows the BRIDGE's sid rather than deriving its own from env
# (test-reviewer Blocker #2: cross-module wiring — skills/_shared/test-design.md
# "Mandatory integration coverage #4"). A shadow that echoed the SAME sid as
# env would pass even if the receiver ignored the bridge entirely, so this
# helper's sid must differ from whatever CLAUDE_CODE_SESSION_ID carries.
#   $1: sid to echo unconditionally
# Echoes the shadow dir in node form.
brc_shadow_root_sid() {
  local sid="$1" root="$TMPDIR_BASE/shadow-bridge-sid-$1" m
  if [[ ! -d "$root" ]]; then
    mkdir -p "$root/hooks/workflow-state/state-io" "$root/hooks/workflow-gate"
    cp -r "$AGENTS_WORKTREE/bin" "$root/bin"
    for m in workflow-state workflow-state/session-id workflow-state/state-io \
             workflow-state/state-io/core workflow-state/resolve-worktree-path \
             workflow-gate/review-tests-evidence; do
      printf 'module.exports = require("%s/hooks/%s");\n' "$AGENTS_NODE" "$m" > "$root/hooks/$m.js"
    done
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" "%s"\nexit 0\n' "$sid" > "$root/bin/resolve-session-id"
    chmod +x "$root/bin/resolve-session-id"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$root/bin/run-codex-review-loop"
    chmod +x "$root/bin/run-codex-review-loop"
  fi
  _tonode "$root"
}

# Run run-codex-review-loop.sh with the three script-required vars pinned
# (:6-8) and the session vars under test. Sets RCRL_RC / RCRL_ERR.
#   $1: AGENTS_CONFIG_DIR (node form)   $2: CLAUDE_CODE_SESSION_ID ("" to unset)
RCRL_RC=0
RCRL_ERR=""
run_review_loop() {
  local errfile="$TMPDIR_BASE/brc-review-loop.err"
  (
    cd "$TMPDIR_BASE" || exit 1
    SESSION_ID="$BRC_WSID" \
    CLAUDE_SESSION_ID="" \
    CLAUDE_CODE_SESSION_ID="$2" \
    PLANS_DIR="$PLANS_DIR_NODE" \
    EXTENSIONS_USED="0" \
    CLAUDE_ENV_FILE="" \
    CLAUDE_TRANSCRIPT_BASE_DIR="$TRANSCRIPTS_NODE" \
    CLAUDE_WORKFLOW_DIR="$WF_DIR_NODE" \
    WORKFLOW_PLANS_DIR="$PLANS_DIR_NODE" \
    AGENTS_CONFIG_DIR="$1" \
      bash "$RUN_TIMEOUT" 60 bash "$REVIEW_LOOP_SH"
  ) >/dev/null 2>"$errfile"
  RCRL_RC=$?
  RCRL_ERR="$(cat "$errfile" 2>/dev/null || true)"
}

run_cases_2270_bridge_rc() {

BRC_TERMINAL="$PLANS_DIR/$BRC_WSID-test-review-terminal.txt"

# ---------------------------------------------------------------------------
# Case BR-A [RED, #2270 S5-4 (a)]: select-staged-files.sh with a bridge that
# exits 127 (node absent) while CLAUDE_CODE_SESSION_ID names a resolvable
# session. The fault must halt the selection with exit 4 and an explicit
# diagnostic; exit 3 would be read as "no session, pick files by hand".
# ---------------------------------------------------------------------------
rm -f "$WF_DIR"/*.json
BRC_ROOT127="$(brc_shadow_root 127)"
run_select "$TMPDIR_BASE" "" "state" "wta" "$SESSION_ID" "$BRC_ROOT127"
if [[ "$SELECT_RC" -eq 4 && -z "$SELECT_OUT" && "$SELECT_ERR" == *"failed (rc 127)"* ]]; then
  pass "Case BR-A (select-staged-files, bridge rc 127 -> exit 4): rc=$SELECT_RC, empty stdout"
else
  fail "Case BR-A (select-staged-files, bridge rc 127 -> exit 4): rc=$SELECT_RC out='$SELECT_OUT' err='$SELECT_ERR'"
fi

# ---------------------------------------------------------------------------
# Case BR-B [RED, #2270 S5-4 (a')]: the CPR-ORTH twin of BR-A. rc 3 means the
# resolver itself threw — equally a fault, so the same exit 4 and the same
# wording with the rc it actually saw.
# ---------------------------------------------------------------------------
rm -f "$WF_DIR"/*.json
BRC_ROOT3="$(brc_shadow_root 3)"
run_select "$TMPDIR_BASE" "" "state" "wta" "$SESSION_ID" "$BRC_ROOT3"
if [[ "$SELECT_RC" -eq 4 && -z "$SELECT_OUT" && "$SELECT_ERR" == *"failed (rc 3)"* ]]; then
  pass "Case BR-B (select-staged-files, bridge rc 3 -> exit 4): rc=$SELECT_RC, empty stdout"
else
  fail "Case BR-B (select-staged-files, bridge rc 3 -> exit 4): rc=$SELECT_RC out='$SELECT_OUT' err='$SELECT_ERR'"
fi

# ---------------------------------------------------------------------------
# Case BR-C [RED, #2270 S5-4 (b)]: run-codex-review-loop.sh under the same rc
# 127 fault. exit 4 is its existing HALT code, so the terminal marker must stay
# unwritten — arming the re-invoke guard on a resolver fault would block the
# next legitimate review too (#1361).
# ---------------------------------------------------------------------------
rm -f "$WF_DIR"/*.json "$BRC_TERMINAL"
write_state_for "$BRC_SID" "$WTA_NODE"
run_review_loop "$BRC_ROOT127" "$BRC_SID"
if [[ "$RCRL_RC" -eq 4 && "$RCRL_ERR" == *"failed (rc 127)"* && ! -f "$BRC_TERMINAL" ]]; then
  pass "Case BR-C (review loop, bridge rc 127 -> exit 4, no terminal marker): rc=$RCRL_RC"
else
  fail "Case BR-C (review loop, bridge rc 127 -> exit 4, no terminal marker): rc=$RCRL_RC err='$RCRL_ERR' marker=$([[ -f "$BRC_TERMINAL" ]] && echo present || echo absent)"
fi

# ---------------------------------------------------------------------------
# Case BR-D [contract guard, #2270 S5-4 (c)]: the rc 2 half of the pair. No CC
# session id anywhere and a workflow SESSION_ID with no state file, so the
# bridge legitimately reports "unresolvable" and the script keeps its historic
# exit 3. The genuine bridge runs here; only codex itself is stubbed.
# ---------------------------------------------------------------------------
rm -f "$WF_DIR"/*.json "$BRC_TERMINAL"
BRC_ROOTREAL="$(brc_shadow_root real)"
run_review_loop "$BRC_ROOTREAL" ""
if [[ "$RCRL_RC" -eq 3 ]]; then
  pass "Case BR-D (review loop, bridge rc 2 -> historic exit 3): rc=$RCRL_RC"
else
  fail "Case BR-D (review loop, bridge rc 2 -> historic exit 3): rc=$RCRL_RC err='$RCRL_ERR', expected 3"
fi

# ---------------------------------------------------------------------------
# Case BR-E [RED, #2270 S5-1 wiring, test-reviewer Blocker #2]: select-staged-
# files.sh must follow the BRIDGE's resolved sid, not derive its own from
# CLAUDE_CODE_SESSION_ID. Two distinct sids point at two distinct worktrees
# (WTA / WTB) with two distinct distinguishable staged files; the shadow
# bridge echoes the WTB sid while env carries the WTA sid. A script that
# still reads env directly (ignoring the bridge) selects fixture-wta.sh —
# this case proves it must select fixture-wtb.sh instead.
# ---------------------------------------------------------------------------
BRC_SIDA="fix-882-brc-sida"
BRC_SIDB="fix-882-brc-sidb"
rm -f "$WF_DIR"/*.json
write_state_for "$BRC_SIDA" "$WTA_NODE"
write_state_for "$BRC_SIDB" "$WTB_NODE"
BRC_ROOTSIDB="$(brc_shadow_root_sid "$BRC_SIDB")"
run_select "$TMPDIR_BASE" "" "nostate" "wta" "$BRC_SIDA" "$BRC_ROOTSIDB"
if [[ "$SELECT_RC" -eq 0 && "$SELECT_OUT" == *"fixture-wtb.sh"* && "$SELECT_OUT" != *"fixture-wta.sh"* ]]; then
  pass "Case BR-E (select-staged-files follows bridge sid, not env sid): out='$SELECT_OUT'"
else
  fail "Case BR-E (select-staged-files follows bridge sid, not env sid): rc=$SELECT_RC out='$SELECT_OUT' err='$SELECT_ERR'"
fi

# ---------------------------------------------------------------------------
# Case BR-F [RED, #2270 S5-1 wiring, CPR-ORTH pair of BR-E]: run-codex-review-
# loop.sh's COMMIT_TARGET resolution must likewise follow the bridge's sid,
# not env's. Same dual-sid/dual-worktree setup; the review loop is invoked
# with CLAUDE_CODE_SESSION_ID=$BRC_SIDA while the shadow bridge echoes
# $BRC_SIDB, and only a real state file for $BRC_SIDB names a worktree with a
# staged file — so a run that stayed on env's sid would find no state (rc 3),
# while one that follows the bridge resolves WTB and proceeds past rc 3.
# ---------------------------------------------------------------------------
rm -f "$WF_DIR"/*.json "$BRC_TERMINAL"
write_state_for "$BRC_SIDB" "$WTB_NODE"
run_review_loop "$BRC_ROOTSIDB" "$BRC_SIDA"
if [[ "$RCRL_RC" -ne 3 ]]; then
  pass "Case BR-F (review loop COMMIT_TARGET follows bridge sid, not env sid): rc=$RCRL_RC (resolved via bridge sid, not env's stateless sid)"
else
  fail "Case BR-F (review loop COMMIT_TARGET follows bridge sid, not env sid): rc=$RCRL_RC err='$RCRL_ERR' (still reading env sid directly, found no state)"
fi

}
