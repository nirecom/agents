#!/usr/bin/env bash
# tests/bin/feature-1643-worker-dispatch-capability/matrix.sh
# Tests: bin/worker-dispatch/capability.js, bin/worker-dispatch/fsguard.js, bin/worker-dispatch/spawn.js, bin/worker-dispatch/anchor.js, hooks/lib/worker-dispatch-registry.js
# Tags: worker-dispatch, capability, fsguard, spawn, security, attack-matrix, TL1, scope:issue-specific
# Sourced by ../feature-1643-worker-dispatch-capability.sh after observe.sh — defines run_matrix
# and run_matrix_controls. Attack-matrix columns: name | worker | reason | payload. `reason` is
# text the dispatcher must print for the rejection, on every row, so a row refused for another
# cause (an undeclared key, say) fails instead of passing by accident. One hostile field per row.
run_matrix() {
    local name worker reason payload pfile before after spawns got_status
    local i=0
    while IFS='|' read -r name worker reason payload; do
        [ -z "$name" ] && continue
        case "$name" in \#*) continue ;; esac
        trim "$name";   name="$TRIMMED"
        trim "$worker"; worker="$TRIMMED"
        trim "$reason"; reason="$TRIMMED"
        i=$((i + 1))

        if [ ! -f "$DISPATCH_JS" ]; then
            fail "cap/$name/status — implementation missing: bin/worker-dispatch.js"
            fail "cap/$name/exit-code — implementation missing: bin/worker-dispatch.js"
            fail "cap/$name/no-spawn — implementation missing: bin/worker-dispatch.js"
            fail "cap/$name/no-write — implementation missing: bin/worker-dispatch.js"
            continue
        fi
        if [ "$name" = "worktree-via-symlink" ] && [ "$SYMLINK_OK" -eq 0 ]; then
            # SKIPPED: symlink-escape containment case
            # Because: this host refuses unprivileged symlink creation (Windows
            #          without Developer Mode); the fixture cannot be built.
            # L3 gap: only a real NTFS/POSIX host with symlink support proves
            #          that realpath-based containment defeats the escape.
            echo "SKIP: cap/$name (symlink creation unsupported on this host)"
            continue
        fi

        pfile="$PLANS_RAW/attack-$i.json"
        printf '%s' "$payload" > "$pfile"

        before="$(snapshot_all)"
        # $PLANS is already the cygpath -m form of $PLANS_RAW, so the payload
        # path is composed rather than converted — one less cygpath per row.
        run_dispatch "$worker" "$MAIN" "$PLANS/attack-$i.json"
        after="$(snapshot_all)"
        count_effectful_spawns; spawns="$EFFECTFUL_SPAWNS"
        status_of; got_status="$STATUS_LINE"

        assert_eq "cap/$name/status"   "$(expected_reject_status "$worker")" "$got_status"
        assert_eq "cap/$name/exit-code" "0"     "$DRC"
        assert_eq "cap/$name/no-spawn" "0"      "$spawns"
        assert_eq "cap/$name/no-write" "$before" "$after"
        # The test-runner YAML renderer doubles each single quote inside its quoted summary.
        case "${DOUT//\'\'/\'}" in
            *"$reason"*) pass "cap/$name/reason" ;;
            *) fail "cap/$name/reason — want text: $reason — got: $(printf '%s' "$DOUT" | tr '\n' ' ')" ;;
        esac
        # A row whose attack IS an undeclared key is the one kind allowed to name one.
        case "$reason" in "unknown field "*) continue ;; esac
        case "$DOUT" in
            *"unknown field '"*) fail "cap/$name/declared-keys-only — the row names a key the worker does not declare" ;;
            *) pass "cap/$name/declared-keys-only" ;;
        esac
    done <<TABLE
script-checkout-root-other-dir | worktree-copy | field 'script_checkout_root' must be exactly | {"target_main_root":"$MAIN","worktree_path":"$LINKED","branch":"feature/cap-probe","session_id":"s1","script_checkout_root":"$OTHER_CHECKOUT","artifact_dir":"$PLANS"}
target-main-root-mismatch | worktree-copy | field 'target_main_root' must be exactly | {"target_main_root":"$ALT","worktree_path":"$LINKED","branch":"feature/cap-probe","session_id":"s1","artifact_dir":"$PLANS"}
worktree-unregistered  | worktree-copy | field 'worktree_path' must be a worktree registered under target-main-root | {"target_main_root":"$MAIN","worktree_path":"$NONGIT","branch":"feature/cap-probe","session_id":"s1","artifact_dir":"$PLANS"}
worktree-dotdot        | worktree-copy | field 'worktree_path' must be a worktree registered under target-main-root | {"target_main_root":"$MAIN","worktree_path":"$LINKED/../../outside","branch":"feature/cap-probe","session_id":"s1","artifact_dir":"$PLANS"}
worktree-via-symlink   | worktree-copy | field 'worktree_path' must be a worktree registered under target-main-root | {"target_main_root":"$MAIN","worktree_path":"$SYMLINK","branch":"feature/cap-probe","session_id":"s1","artifact_dir":"$PLANS"}
worktree-other-repo    | worktree-copy | field 'worktree_path' must be a worktree registered under target-main-root | {"target_main_root":"$MAIN","worktree_path":"$ALT_LINKED","branch":"feature/alt-probe","session_id":"s1","artifact_dir":"$PLANS"}
worktree-relative      | worktree-copy | field 'worktree_path' must be an absolute path | {"target_main_root":"$MAIN","worktree_path":"linked-wt","branch":"feature/cap-probe","session_id":"s1","artifact_dir":"$PLANS"}
backup-dir-arbitrary   | worktree-backup  | field 'backup_dir' must be exactly | {"mode":"execute","worktree_path":"$LINKED","branch":"feature/cap-probe","backup_dir":"$OUTSIDE","docker_check":false,"artifact_dir":"$PLANS"}
backup-dir-sibling     | worktree-backup  | field 'backup_dir' must be exactly | {"mode":"execute","worktree_path":"$LINKED","branch":"feature/cap-probe","backup_dir":"$EVIL","docker_check":false,"artifact_dir":"$PLANS"}
cwd-outside-family     | doc-append       | field 'cwd' must be a worktree registered under target-main-root | {"mode":"history","cwd":"$ALT","category":"FEATURE","subject":"x","commits":"abcdef1","background":"b","changes":"c","artifact_dir":"$PLANS"}
notes-sibling-prefix   | doc-append       | field 'notes_path' must be inside a worktree of the target-main-root family | {"mode":"compose","cwd":"$LINKED","notes_path":"$EVIL/WORKTREE_NOTES.md","branch":"feature/cap-probe","pr_number":"1","merge_commit":"abcdef1","pr_title":"t","closes_issues_count":1,"artifact_dir":"$PLANS"}
history-md-outside-repo | issue-reconcile | field 'history_md_path' must be inside a worktree of the target-main-root family | {"owner_repo":"example-owner/example-repo","history_md_path":"$OUTSIDE/history.md","history_dir_path":"$MAIN/docs/history","limit":10,"artifact_dir":"$PLANS"}
history-dir-outside-repo | issue-reconcile | field 'history_dir_path' must be inside a worktree of the target-main-root family | {"owner_repo":"example-owner/example-repo","history_md_path":"$MAIN/docs/history.md","history_dir_path":"$OUTSIDE","limit":10,"artifact_dir":"$PLANS"}
artifact-outside-plans | issue-reconcile  | field 'artifact_dir' must be inside the workflow plans directory | {"owner_repo":"example-owner/example-repo","history_md_path":"$MAIN/docs/history.md","history_dir_path":"$MAIN/docs/history","limit":10,"artifact_dir":"$OUTSIDE"}
payload-binary-key     | test-runner      | unknown field 'binary' | {"cwd":"$MAIN","test_args":[],"timeout_seconds":15,"binary":"/bin/sh"}
payload-env-keys       | test-runner      | unknown field 'env' | {"cwd":"$MAIN","test_args":[],"timeout_seconds":15,"env":{"PATH":"$EVIL"}}
payload-jobs-string    | test-runner      | field 'jobs' must be an integer | {"cwd":"$MAIN","test_args":[],"timeout_seconds":15,"jobs":"4"}
payload-jobs-zero      | test-runner      | field 'jobs' must be >= 1 | {"cwd":"$MAIN","test_args":[],"timeout_seconds":15,"jobs":0}
payload-jobs-huge      | test-runner      | field 'jobs' must be <= 1024 | {"cwd":"$MAIN","test_args":[],"timeout_seconds":15,"jobs":99999}
cwd-outside-family-tr  | test-runner      | field 'cwd' must be a worktree registered under target-main-root | {"cwd":"$ALT","test_args":[],"timeout_seconds":15}
owner-repo-injection   | issue-reconcile  | field 'owner_repo' is not a well-formed owner/repo identifier | {"owner_repo":"example-owner/example-repo --json body","history_md_path":"$MAIN/docs/history.md","history_dir_path":"$MAIN/docs/history","limit":10,"artifact_dir":"$PLANS"}
plans-dir-sibling      | session-close-gate | field 'plans_dir' must be inside the workflow plans directory | {"session_id":"s1","plans_dir":"$EVIL","artifact_dir":"$PLANS"}
artifact-dir-sibling   | session-close-gate | field 'artifact_dir' must be inside the workflow plans directory | {"session_id":"s1","plans_dir":"$PLANS","artifact_dir":"$EVIL"}
outcome-path-chosen    | session-close-gate | field 'outcome_json_path' must be omitted | {"session_id":"s1","plans_dir":"$PLANS","artifact_dir":"$PLANS","outcome_json_path":"$EVIL/o.json"}
TABLE
}

# Controls: the worktree-copy attack rows with only the attack value put right. Judged by
# capability.validate itself rather than a dispatch, so an accepted payload starts no worker.
# One rejected row runs through the same probe to show it can give both verdicts.
MATRIX_CONTROL_PROBE="$TMPD/matrix-control-probe.js"
cat > "$MATRIX_CONTROL_PROBE" <<'CTLJS'
"use strict";
const fs = require("fs");
const path = require("path");
const [scriptCheckoutRoot, targetMainRoot, rowsFile] = process.argv.slice(2);
const capMod = require(path.join(scriptCheckoutRoot, "bin/worker-dispatch/capability.js"));
const anchorMod = require(path.join(scriptCheckoutRoot, "bin/worker-dispatch/anchor.js"));
const registry = require(path.join(scriptCheckoutRoot, "bin/worker-dispatch/registry.js"));
const anchors = anchorMod.resolveAnchors(targetMainRoot);
const out = [];
for (const raw of fs.readFileSync(rowsFile, "utf8").split(/\r?\n/)) {
  if (raw === "") continue;
  const [name, worker, json] = raw.split("\t");
  let verdict = "probe-error";
  let detail = "";
  try {
    if (anchors.error) throw new Error(anchors.error);
    const res = capMod.validate(JSON.parse(json), registry.get(worker), Object.assign({}, anchors, { payloadSid: null }));
    verdict = res.ok ? "accept" : "reject";
    detail = res.ok ? "" : res.errors.join("; ");
  } catch (e) {
    detail = e.message;
  }
  out.push([name, verdict, detail.replace(/\s+/g, " ")].join("\t"));
}
process.stdout.write(out.join("\n") + "\n");
CTLJS

run_matrix_controls() {
    local name worker want reason payload out rname rverdict rdetail
    local rows="$TMPD/matrix-control-rows.tsv"
    local -a NAMES=() WANTS=() REASONS=()
    : > "$rows"
    while IFS='|' read -r name worker want reason payload; do
        [ -z "$name" ] && continue
        trim "$name"; name="$TRIMMED"
        trim "$worker"; worker="$TRIMMED"
        trim "$want"; want="$TRIMMED"
        trim "$reason"; reason="$TRIMMED"
        trim "$payload"; payload="$TRIMMED"
        printf '%s\t%s\t%s\n' "$name" "$worker" "$payload" >> "$rows"
        NAMES+=("$name"); WANTS+=("$want"); REASONS+=("$reason")
    done <<TABLE
script-checkout-root-this-checkout | worktree-copy | accept | - | {"target_main_root":"$MAIN","worktree_path":"$LINKED","branch":"feature/cap-probe","session_id":"s1","script_checkout_root":"$THIS_CHECKOUT","artifact_dir":"$PLANS"}
target-main-root-and-registered-worktree | worktree-copy | accept | - | {"target_main_root":"$MAIN","worktree_path":"$LINKED","branch":"feature/cap-probe","session_id":"s1","artifact_dir":"$PLANS"}
probe-refuses-another-checkout | worktree-copy | reject | field 'script_checkout_root' must be exactly | {"target_main_root":"$MAIN","worktree_path":"$LINKED","branch":"feature/cap-probe","session_id":"s1","script_checkout_root":"$OTHER_CHECKOUT","artifact_dir":"$PLANS"}
worktree-backup-derived-dir | worktree-backup | accept | - | {"mode":"execute","worktree_path":"$LINKED","branch":"feature/cap-probe","docker_check":false,"artifact_dir":"$PLANS"}
doc-append-history-in-family | doc-append | accept | - | {"mode":"history","cwd":"$LINKED","category":"FEATURE","subject":"x","commits":"abcdef1","background":"b","changes":"c","artifact_dir":"$PLANS"}
doc-append-notes-in-family | doc-append | accept | - | {"mode":"compose","cwd":"$LINKED","notes_path":"$LINKED/WORKTREE_NOTES.md","branch":"feature/cap-probe","pr_number":"1","merge_commit":"abcdef1","pr_title":"t","closes_issues_count":1,"artifact_dir":"$PLANS"}
issue-reconcile-paths-in-family | issue-reconcile | accept | - | {"owner_repo":"example-owner/example-repo","history_md_path":"$MAIN/docs/history.md","history_dir_path":"$MAIN/docs/history","limit":10,"artifact_dir":"$PLANS"}
test-runner-declared-keys | test-runner | accept | - | {"cwd":"$MAIN","test_args":[],"timeout_seconds":15,"jobs":4}
session-close-gate-plans-dir | session-close-gate | accept | - | {"session_id":"s1","plans_dir":"$PLANS","artifact_dir":"$PLANS"}
TABLE

    out="$(cd "$MAIN_RAW" && run_with_timeout 60 \
        node "$(nodepath "$MATRIX_CONTROL_PROBE")" "$THIS_CHECKOUT" "$MAIN" "$(nodepath "$rows")" 2>&1)"
    local -A VERDICT=() DETAIL=()
    while IFS=$'\t' read -r rname rverdict rdetail; do
        [ -z "$rname" ] && continue
        VERDICT["$rname"]="$rverdict"; DETAIL["$rname"]="$rdetail"
    done <<< "$out"

    local i got
    for i in "${!NAMES[@]}"; do
        got="${VERDICT[${NAMES[$i]}]-}"
        if [ "$got" = "${WANTS[$i]}" ]; then
            pass "cap-control/${NAMES[$i]}"
        else
            fail "cap-control/${NAMES[$i]} — want=${WANTS[$i]} got=$got — ${DETAIL[${NAMES[$i]}]-$out}"
        fi
        [ "${REASONS[$i]}" = "-" ] && continue
        case "${DETAIL[${NAMES[$i]}]-}" in
            *"${REASONS[$i]}"*) pass "cap-control/${NAMES[$i]}/reason" ;;
            *) fail "cap-control/${NAMES[$i]}/reason — want text: ${REASONS[$i]} — got: ${DETAIL[${NAMES[$i]}]-}" ;;
        esac
    done
}
