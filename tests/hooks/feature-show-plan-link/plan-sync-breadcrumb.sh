# #2513 plan-sync breadcrumb cases (H1-H9, A1-A6, A8): formatBreadcrumb pure function plus the real
# hook on every path where no push succeeds. Sourced last by ../feature-show-plan-link.sh
# (inherits pass/fail, HOOK, SCRIPT_CHECKOUT_ROOT); psf_setup re-pins every env var to a fresh root.
# The successful push path lives in feature-2513-plan-sync-e2e.sh (ssh stub).

# shellcheck source=../../lib/plan-sync-fixture.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/plan-sync-fixture.sh"
psf_setup || { fail "H setup — psf_setup failed"; return 0; }
trap 'psf_cleanup; rm -rf "$PLANS_DIR" "$WORKFLOW_DIR_TEST" "$CFG_DIR_TEST"' EXIT
SPS_HOOK="$(psf_np "$HOOK")"
SPS_PLANS="$WORKFLOW_PLANS_DIR"
SPS_RUN_HINT='— run node "$AGENTS_MAIN_ROOT/bin/plan-sync-init"'

# sps_run_hook <json> — sets HOOK_RC, HOOK_OUT, HOOK_MSG, HOOK_SECS.
sps_run_hook() {
  local t0
  t0="$(date +%s)"
  HOOK_OUT="$(printf '%s' "$1" | psf_timeout 60 node "$SPS_HOOK" 2>/dev/null)"
  HOOK_RC=$?
  HOOK_SECS=$(( $(date +%s) - t0 ))
  HOOK_MSG="$(psf_sysmsg "$HOOK_OUT")"
}

# sps_expect_msg_has <name> <needle...> — every needle is a fixed substring of HOOK_MSG.
sps_expect_msg_has() {
  local name="$1" n
  shift
  for n in "$@"; do
    case "$HOOK_MSG" in
      *"$n"*) ;;
      *) fail "$name — missing $(printf '%q' "$n") in msg=$(printf '%q' "$HOOK_MSG")"; return ;;
    esac
  done
  pass "$name"
}

echo "=== H1: formatBreadcrumb renders each sync result ==="
OUT="$(PSF_HOOK="$SPS_HOOK" psf_timeout 30 node -e '
const m = require(process.env.PSF_HOOK);
if (typeof m.formatBreadcrumb !== "function") { process.stdout.write("NOT_IMPLEMENTED"); process.exit(0); }
const abs = "/plans/s2513-intent.md"; const url = "https://github.com/test-owner/test-repo/blob/main/s2513-intent.md";
const hint = " — run node \"$AGENTS_MAIN_ROOT/bin/plan-sync-init\"";
const cases = [
  [{ status: "pushed", url }, ["Plan file: " + url]],
  [{ status: "pushed", reason: "non-github" }, ["Plan file: " + abs, "[plan-sync] pushed (non-GitHub remote; no URL)"]],
  [{ status: "off" }, ["Plan file: " + abs, "[plan-sync] not configured (PLAN_SYNC_REMOTE_URL empty)"]],
  [{ status: "not-provisioned", reason: "no-repo" }, ["Plan file: " + abs, "[plan-sync] no-repo" + hint]],
  [{ status: "failed", reason: "offline" }, ["Plan file: " + abs, "[plan-sync] offline" + hint]],
];
const bad = cases.filter(([r, want]) => JSON.stringify(m.formatBreadcrumb(r, abs).split(/\r?\n/)) !== JSON.stringify(want));
process.stdout.write((bad.map(([r]) => r.status + "/" + (r.reason || r.url ? "x" : "")).join(",") || "all-match")
  + "|" + ("workspaceFolderUriFrom" in m ? "uri-exported" : "uri-removed"));' 2>&1)"
if [ "$OUT" = "all-match|uri-removed" ]; then pass "H1 formatBreadcrumb 5 results + workspaceFolderUriFrom removed"
else fail "H1 formatBreadcrumb 5 results + workspaceFolderUriFrom removed — got=$OUT"; fi

echo "=== H1b: formatBreadcrumb renders skipped/not-regular-file ==="
OUT="$(PSF_HOOK="$SPS_HOOK" psf_timeout 30 node -e '
const m = require(process.env.PSF_HOOK);
process.stdout.write(m.formatBreadcrumb({ status: "skipped", reason: "not-regular-file" }, "/plans/s2513-intent.md"));' 2>&1)"
SPS_NRF_LINE="[plan-sync] skipped: not a regular file"
case "$OUT" in
  "Plan file: /plans/s2513-intent.md"$'\n'"$SPS_NRF_LINE"*) pass "H1b local path + not-a-regular-file line" ;;
  *) fail "H1b local path + not-a-regular-file line — got=$(printf '%q' "$OUT")" ;;
esac

echo "=== H2: unprovisioned PLANS_DIR -> local path + no-repo hint, marker written ==="
printf 'plan\n' > "$SPS_PLANS/s2513-intent.md"
PLAN_SYNC_REMOTE_URL="$PSF_ORIGIN_GH" sps_run_hook "$(psf_write_json "$SPS_PLANS/s2513-intent.md" test-sid-h2)"
sps_expect_msg_has "H2 Plan file + [plan-sync] no-repo + run hint" "Plan file: " "s2513-intent.md" "[plan-sync] no-repo $SPS_RUN_HINT"
if [ "$HOOK_RC" = 0 ]; then pass "H2 exit 0"; else fail "H2 exit 0 — rc=$HOOK_RC"; fi
SPS_MARKERS=("$WORKFLOW_STATE_DIR"/test-sid-h2.confirm-plan-turn-*.json)
if [ -f "${SPS_MARKERS[0]}" ]; then pass "H2 turn marker written before the message"
else fail "H2 turn marker written before the message — no test-sid-h2.confirm-plan-turn-*.json"; fi

echo "=== H3: empty PLAN_SYNC_REMOTE_URL -> not configured ==="
PLAN_SYNC_REMOTE_URL="" sps_run_hook "$(psf_write_json "$SPS_PLANS/s2513-intent.md" test-sid-h3)"
sps_expect_msg_has "H3 Plan file + not configured" "Plan file: " "[plan-sync] not configured (PLAN_SYNC_REMOTE_URL empty)"

echo "=== H4: provisioned repo + local insteadOf -> url-rewritten, no URL ==="
SPS_PI="$PSF_ROOT/pi-plans"
if psf_make_provisioned "$SPS_PI" "$PSF_ORIGIN_GH" >/dev/null 2>&1; then
  git -C "$SPS_PI" config "url.ssh://git@127.0.0.1:1/.insteadOf" "git@github.com:"
  printf 'plan\n' > "$SPS_PI/s2513-outline.md"
  WORKFLOW_PLANS_DIR="$SPS_PI" PLAN_SYNC_REMOTE_URL="$PSF_ORIGIN_GH" sps_run_hook "$(psf_write_json "$SPS_PI/s2513-outline.md" test-sid-h4)"
  sps_expect_msg_has "H4 Plan file + [plan-sync] url-rewritten" "Plan file: " "s2513-outline.md" "[plan-sync] url-rewritten"
  case "$HOOK_MSG" in
    *https://github.com*) fail "H4 no blob URL on url-rewritten — msg=$HOOK_MSG" ;;
    "") fail "H4 no blob URL on url-rewritten — empty message" ;;
    *) pass "H4 no blob URL on url-rewritten" ;;
  esac
else
  fail "H4 provisioned + insteadOf — fixture needs renderGitignore/INIT_VERSION"
fi

echo "=== H5: push failure (dead origin) -> local path + reason, within budget ==="
SPS_PD="$PSF_ROOT/pd-plans"
if psf_make_provisioned "$SPS_PD" "$PSF_ORIGIN_DEAD" >/dev/null 2>&1; then
  printf 'plan\n' > "$SPS_PD/s2513-detail.md"
  WORKFLOW_PLANS_DIR="$SPS_PD" PLAN_SYNC_REMOTE_URL="$PSF_ORIGIN_DEAD" GIT_SSH_COMMAND=false \
    sps_run_hook "$(psf_write_json "$SPS_PD/s2513-detail.md" test-sid-h5)"
  sps_expect_msg_has "H5 Plan file + [plan-sync] reason" "Plan file: " "s2513-detail.md" "[plan-sync] " "$SPS_RUN_HINT"
  if [ "$HOOK_RC" = 0 ] && [ "$HOOK_SECS" -lt 25 ]; then pass "H5 exit 0 within budget (${HOOK_SECS}s)"
  else fail "H5 exit 0 within budget — rc=$HOOK_RC secs=$HOOK_SECS"; fi
else
  fail "H5 push failure — fixture needs renderGitignore/INIT_VERSION"
fi

echo "=== H6: Bash assemble destination enters the sync path ==="
SPS_H6_JSON="$(psf_timeout 30 node -e '
process.stdout.write(JSON.stringify({ tool_name: "Bash", tool_response: { exit_code: 0 }, session_id: "test-sid-h6",
  tool_input: { command: "assemble-mandatory.sh --source-kind intent /a/i.md " + process.argv[1] + " " + process.argv[1] } }));' \
  "$SPS_PLANS/s2513-outline.md")"
printf 'outline\n' > "$SPS_PLANS/s2513-outline.md"
PLAN_SYNC_REMOTE_URL="$PSF_ORIGIN_GH" sps_run_hook "$SPS_H6_JSON"
sps_expect_msg_has "H6 assemble destination -> no-repo breadcrumb" "Plan file: " "s2513-outline.md" "[plan-sync] no-repo"

echo "=== H7: drafts/ plan -> no breadcrumb, no sync ==="
mkdir -p "$SPS_PLANS/drafts"; printf 'd\n' > "$SPS_PLANS/drafts/s2513-intent.md"
PLAN_SYNC_REMOTE_URL="$PSF_ORIGIN_GH" sps_run_hook "$(psf_write_json "$SPS_PLANS/drafts/s2513-intent.md" test-sid-h7)"
if [ "$HOOK_RC" = 0 ] && [ -z "$HOOK_OUT" ] && [ ! -e "$SPS_PLANS/.git" ]; then pass "H7 drafts/ -> empty output, no .git"
else fail "H7 drafts/ -> empty output, no .git — rc=$HOOK_RC out=$HOOK_OUT"; fi

echo "=== H8: symlinked plan artifact -> local path + not-a-regular-file line ==="
mkdir -p "$PSF_ROOT/h8-outside"; printf 'H8-SECRET\n' > "$PSF_ROOT/h8-outside/secret.txt"
if psf_timeout 30 node -e '
const fs = require("fs");
try { fs.symlinkSync(process.argv[1], process.argv[2], "file"); } catch (e) { process.exit(1); }
process.exit(fs.lstatSync(process.argv[2]).isSymbolicLink() ? 0 : 1);' \
  "$PSF_ROOT/h8-outside/secret.txt" "$SPS_PLANS/s2513h8-detail.md" 2>/dev/null; then
  PLAN_SYNC_REMOTE_URL="$PSF_ORIGIN_GH" sps_run_hook "$(psf_write_json "$SPS_PLANS/s2513h8-detail.md" test-sid-h8)"
  sps_expect_msg_has "H8 Plan file + [plan-sync] skipped: not a regular file" "Plan file: " "s2513h8-detail.md" "$SPS_NRF_LINE"
  case "$HOOK_MSG" in
    *https://github.com*|*H8-SECRET*) fail "H8 no blob URL / target content — msg=$HOOK_MSG" ;;
    *) pass "H8 no blob URL / target content" ;;
  esac
  if [ "$HOOK_RC" = 0 ]; then pass "H8 exit 0"; else fail "H8 exit 0 — rc=$HOOK_RC"; fi
else
  echo "SKIP: H8 host cannot create symlinks (Windows without Developer Mode?)"
fi

echo "=== H9: Bash command that only mentions assemble-mandatory.sh -> no push, no breadcrumb ==="
# #2513 review_security F3: provisioned repo whose origin is served by the ssh stub, so a
# wrongly extracted dest would really push. Negative (cat) first, then the bash positive control.
SPS_H9_BARE="$PSF_ROOT/h9-bare.git"; psf_make_bare "$SPS_H9_BARE"
SPS_H9="$PSF_ROOT/h9-plans"
SPS_H9_SCRIPT="$(psf_np "$SCRIPT_CHECKOUT_ROOT/skills/_shared/assemble-mandatory.sh")"
SPS_H9_URL="https://github.com/test-owner/test-repo/blob/main/s2513h9-outline.md"
# sps_h9_json <verb...> — PostToolUse Bash payload "<verb...> <script> --source-kind intent <src> <draft> <dest>".
sps_h9_json() {
  psf_timeout 30 node -e '
const [verb, script, plans] = process.argv.slice(1);
const cmd = [verb, script, "--source-kind intent", plans + "/s2513h9-intent.md", plans + "/s2513h9-outline.md", plans + "/s2513h9-outline.md"].join(" ");
process.stdout.write(JSON.stringify({ tool_name: "Bash", tool_input: { command: cmd }, tool_response: { exit_code: 0 }, session_id: "test-sid-h9" }));' \
    "$1" "$SPS_H9_SCRIPT" "$SPS_H9"
}
if psf_make_provisioned "$SPS_H9" "$PSF_ORIGIN_E2E" >/dev/null 2>&1; then
  printf 'h9 outline\n' > "$SPS_H9/s2513h9-outline.md"
  setup_ssh_stub "$SPS_H9_BARE"
  WORKFLOW_PLANS_DIR="$SPS_H9" PLAN_SYNC_REMOTE_URL="$PSF_ORIGIN_E2E" sps_run_hook "$(sps_h9_json cat)"
  if [ "$HOOK_RC" = 0 ] && [ -z "$HOOK_OUT" ]; then pass "H9 cat <script> ... <dest> -> exit 0, empty output (no breadcrumb)"
  else fail "H9 cat <script> ... <dest> -> exit 0, empty output (no breadcrumb) — rc=$HOOK_RC out=$HOOK_OUT"; fi
  SPS_H9_MAIN="$(git -C "$SPS_H9_BARE" rev-parse --verify -q refs/heads/main || echo missing)"
  if [ "$SPS_H9_MAIN" = missing ]; then pass "H9 cat form -> bare remote unchanged (no push)"
  else fail "H9 cat form -> bare remote unchanged (no push) — bare main=$SPS_H9_MAIN"; fi
  if [ ! -s "$GIT_SSH_STUB_LOG" ]; then pass "H9 cat form -> remote never contacted"
  else fail "H9 cat form -> remote never contacted — ssh stub log: $(tr '\n' ' ' < "$GIT_SSH_STUB_LOG")"; fi
  WORKFLOW_PLANS_DIR="$SPS_H9" PLAN_SYNC_REMOTE_URL="$PSF_ORIGIN_E2E" sps_run_hook "$(sps_h9_json bash)"
  sps_expect_msg_has "H9 positive control: bash <script> ... <dest> -> blob URL breadcrumb" "Plan file: $SPS_H9_URL"
  SPS_H9_GOT="$(git -C "$SPS_H9_BARE" show refs/heads/main:s2513h9-outline.md 2>&1)"
  if [ "$SPS_H9_GOT" = "h9 outline" ]; then pass "H9 positive control: bare main holds the dest content"
  else fail "H9 positive control: bare main holds the dest content — got=$SPS_H9_GOT"; fi
  unset GIT_SSH_COMMAND GIT_SSH_VARIANT GIT_SSH_STUB_BARE GIT_SSH_STUB_LOG
else
  fail "H9 provisioned fixture — psf_make_provisioned failed"
fi

echo "=== H8b: hard-linked plan artifact (nlink 2) in a provisioned repo -> not-a-regular-file, no push ==="
# Origin served by the ssh stub, so a hard link wrongly treated as regular would really push
# the secret; the positive control removes the extra link and expects the blob URL.
SPS_H8B_BARE="$PSF_ROOT/h8b-bare.git"; psf_make_bare "$SPS_H8B_BARE"
SPS_H8B="$PSF_ROOT/h8b-plans"
SPS_H8B_MARK="H8B-HARDLINK-SECRET-2f9d"
SPS_H8B_SECRET="$PSF_ROOT/h8b-outside/secret.txt"
mkdir -p "$PSF_ROOT/h8b-outside"; printf '%s\n' "$SPS_H8B_MARK" > "$SPS_H8B_SECRET"
if ! psf_make_provisioned "$SPS_H8B" "$PSF_ORIGIN_E2E" >/dev/null 2>&1; then
  fail "H8b provisioned fixture — psf_make_provisioned failed"
elif ! psf_timeout 30 node -e '
const fs = require("fs");
try { fs.linkSync(process.argv[1], process.argv[2]); } catch (e) { process.exit(1); }
process.exit(fs.lstatSync(process.argv[2]).nlink >= 2 ? 0 : 1);' \
  "$SPS_H8B_SECRET" "$SPS_H8B/s2513h8b-detail.md" 2>/dev/null; then
  echo "SKIP: H8b host cannot create hard links (or does not report nlink)"
else
  setup_ssh_stub "$SPS_H8B_BARE"
  WORKFLOW_PLANS_DIR="$SPS_H8B" PLAN_SYNC_REMOTE_URL="$PSF_ORIGIN_E2E" \
    sps_run_hook "$(psf_write_json "$SPS_H8B/s2513h8b-detail.md" test-sid-h8b)"
  sps_expect_msg_has "H8b Plan file + [plan-sync] skipped: not a regular file" "Plan file: " "s2513h8b-detail.md" "$SPS_NRF_LINE"
  case "$HOOK_MSG" in
    *https://github.com*|*"$SPS_H8B_MARK"*) fail "H8b no blob URL / secret content — msg=$HOOK_MSG" ;;
    *) pass "H8b no blob URL / secret content" ;;
  esac
  if [ "$HOOK_RC" = 0 ]; then pass "H8b exit 0"; else fail "H8b exit 0 — rc=$HOOK_RC"; fi
  SPS_H8B_MAIN="$(git -C "$SPS_H8B_BARE" rev-parse --verify -q refs/heads/main || echo missing)"
  if [ "$SPS_H8B_MAIN" = missing ]; then pass "H8b bare remote unchanged (no push)"
  else fail "H8b bare remote unchanged (no push) — bare main=$SPS_H8B_MAIN"; fi
  if [ ! -s "$GIT_SSH_STUB_LOG" ]; then pass "H8b remote never contacted"
  else fail "H8b remote never contacted — ssh stub log: $(tr '\n' ' ' < "$GIT_SSH_STUB_LOG")"; fi
  git -C "$SPS_H8B_BARE" cat-file --batch-all-objects --batch > "$PSF_ROOT/h8b-dump.bin" 2>/dev/null
  if ! grep -qaF -- "$SPS_H8B_MARK" "$PSF_ROOT/h8b-dump.bin"; then pass "H8b no bare object holds the secret"
  else fail "H8b no bare object holds the secret"; fi
  rm -f "$SPS_H8B_SECRET"
  WORKFLOW_PLANS_DIR="$SPS_H8B" PLAN_SYNC_REMOTE_URL="$PSF_ORIGIN_E2E" \
    sps_run_hook "$(psf_write_json "$SPS_H8B/s2513h8b-detail.md" test-sid-h8b)"
  sps_expect_msg_has "H8b positive control: extra link removed (nlink 1) -> blob URL breadcrumb" \
    "Plan file: https://github.com/test-owner/test-repo/blob/main/s2513h8b-detail.md"
  unset GIT_SSH_COMMAND GIT_SSH_VARIANT GIT_SSH_STUB_BARE GIT_SSH_STUB_LOG
fi

# ── A1-A6, A8: edit-write tool class (Edit, MultiEdit, editFiles, NotebookEdit) ──
# Provisioned repo whose origin is the ssh stub, so a sync is observed as the bare
# remote's main:<rel>, not only as a breadcrumb line.
SPS_EW_BLOB="https://github.com/test-owner/test-repo/blob/main"

# sps_ew_json <tool_name> <tool_input JSON> [tool_response JSON] — PostToolUse payload.
sps_ew_json() {
  psf_timeout 30 node -e '
const [tool, input, resp] = process.argv.slice(1);
process.stdout.write(JSON.stringify({ tool_name: tool, tool_input: JSON.parse(input),
  tool_response: JSON.parse(resp || "{\"success\":true}"), session_id: "test-sid-ew" }));' \
    "$1" "$2" "${3:-}"
}

# sps_ew_expect_synced <name> <bare> <rel> <want-content> — bare main:<rel> == want + blob URL breadcrumb.
sps_ew_expect_synced() {
  local name="$1" bare="$2" rel="$3" want="$4" got
  got="$(git -C "$bare" show "refs/heads/main:$rel" 2>&1)"
  if [[ "$got" == "$want" ]]; then pass "$name — bare main:$rel holds the post-edit content"
  else fail "$name — bare main:$rel holds the post-edit content — got=$(printf '%q' "$got") msg=$(printf '%q' "$HOOK_MSG")"; fi
  sps_expect_msg_has "$name — breadcrumb shows the blob URL" "Plan file: $SPS_EW_BLOB/$rel"
}

SPS_EW_BARE="$PSF_ROOT/ew-bare.git"; psf_make_bare "$SPS_EW_BARE"
SPS_EW="$PSF_ROOT/ew-plans"
if psf_make_provisioned "$SPS_EW" "$PSF_ORIGIN_E2E" >/dev/null 2>&1; then
  setup_ssh_stub "$SPS_EW_BARE"

  echo "=== A8: regression — Write and Bash assemble still sync ==="
  printf 'a8 write v1\n' > "$SPS_EW/s2513ew-intent.md"
  WORKFLOW_PLANS_DIR="$SPS_EW" PLAN_SYNC_REMOTE_URL="$PSF_ORIGIN_E2E" \
    sps_run_hook "$(psf_write_json "$SPS_EW/s2513ew-intent.md" test-sid-ew)"
  sps_ew_expect_synced "A8a Write of a plan file" "$SPS_EW_BARE" "s2513ew-intent.md" "a8 write v1"
  printf 'a8 bash outline\n' > "$SPS_EW/s2513a8-outline.md"
  SPS_A8_CMD="bash $SPS_H9_SCRIPT --source-kind intent $SPS_EW/s2513ew-intent.md $SPS_EW/s2513a8-outline.md $SPS_EW/s2513a8-outline.md"
  WORKFLOW_PLANS_DIR="$SPS_EW" PLAN_SYNC_REMOTE_URL="$PSF_ORIGIN_E2E" \
    sps_run_hook "$(sps_ew_json Bash "$(printf '{"command":"%s"}' "$SPS_A8_CMD")" '{"exit_code":0}')"
  sps_ew_expect_synced "A8b Bash assemble-mandatory.sh" "$SPS_EW_BARE" "s2513a8-outline.md" "a8 bash outline"

  echo "=== A1: Edit of intent / outline / detail plan files syncs ==="
  printf 'a1 intent revised by Edit\n' > "$SPS_EW/s2513ew-intent.md"
  WORKFLOW_PLANS_DIR="$SPS_EW" PLAN_SYNC_REMOTE_URL="$PSF_ORIGIN_E2E" \
    sps_run_hook "$(sps_ew_json Edit "$(printf '{"file_path":"%s","old_string":"v1","new_string":"v2"}' "$SPS_EW/s2513ew-intent.md")")"
  sps_ew_expect_synced "A1 Edit of -intent.md (revision after Write)" "$SPS_EW_BARE" "s2513ew-intent.md" "a1 intent revised by Edit"
  for SPS_A1_KIND in outline detail; do
    printf 'a1 %s via Edit\n' "$SPS_A1_KIND" > "$SPS_EW/s2513ew-$SPS_A1_KIND.md"
    WORKFLOW_PLANS_DIR="$SPS_EW" PLAN_SYNC_REMOTE_URL="$PSF_ORIGIN_E2E" \
      sps_run_hook "$(sps_ew_json Edit "$(printf '{"file_path":"%s","old_string":"a","new_string":"b"}' "$SPS_EW/s2513ew-$SPS_A1_KIND.md")")"
    sps_ew_expect_synced "A1 Edit of -$SPS_A1_KIND.md" "$SPS_EW_BARE" "s2513ew-$SPS_A1_KIND.md" "a1 $SPS_A1_KIND via Edit"
  done

  echo "=== A2: MultiEdit of a plan file syncs ==="
  printf 'a2 multiedit\n' > "$SPS_EW/s2513a2-outline.md"
  WORKFLOW_PLANS_DIR="$SPS_EW" PLAN_SYNC_REMOTE_URL="$PSF_ORIGIN_E2E" \
    sps_run_hook "$(sps_ew_json MultiEdit "$(printf '{"file_path":"%s","edits":[{"old_string":"a","new_string":"b"}]}' "$SPS_EW/s2513a2-outline.md")")"
  sps_ew_expect_synced "A2 MultiEdit file_path" "$SPS_EW_BARE" "s2513a2-outline.md" "a2 multiedit"

  echo "=== A3: editFiles naming the plan via path / edits[] syncs ==="
  printf 'a3 editfiles top-level path\n' > "$SPS_EW/s2513a3-detail.md"
  WORKFLOW_PLANS_DIR="$SPS_EW" PLAN_SYNC_REMOTE_URL="$PSF_ORIGIN_E2E" \
    sps_run_hook "$(sps_ew_json editFiles "$(printf '{"path":"%s"}' "$SPS_EW/s2513a3-detail.md")")"
  sps_ew_expect_synced "A3a editFiles top-level path" "$SPS_EW_BARE" "s2513a3-detail.md" "a3 editfiles top-level path"
  printf 'a3 edits intent\n' > "$SPS_EW/s2513a3e-intent.md"
  printf 'a3 edits outline\n' > "$SPS_EW/s2513a3e-outline.md"
  WORKFLOW_PLANS_DIR="$SPS_EW" PLAN_SYNC_REMOTE_URL="$PSF_ORIGIN_E2E" \
    sps_run_hook "$(sps_ew_json editFiles "$(printf '{"edits":[{"path":"%s"},{"path":"%s"}]}' "$SPS_EW/s2513a3e-intent.md" "$SPS_EW/s2513a3e-outline.md")")"
  sps_ew_expect_synced "A3b editFiles edits[0].path" "$SPS_EW_BARE" "s2513a3e-intent.md" "a3 edits intent"
  sps_ew_expect_synced "A3c editFiles edits[1].path" "$SPS_EW_BARE" "s2513a3e-outline.md" "a3 edits outline"
  unset GIT_SSH_COMMAND GIT_SSH_VARIANT GIT_SSH_STUB_BARE GIT_SSH_STUB_LOG
else
  fail "A1-A3/A8 provisioned fixture — psf_make_provisioned failed"
fi

# Negative cases: a fresh bare per run, so any wrongly accepted path really pushes.
SPS_EN_BARE="$PSF_ROOT/en-bare.git"; psf_make_bare "$SPS_EN_BARE"
SPS_EN="$PSF_ROOT/en-plans"
# sps_en_expect_noop <name> <payload> — exit 0, empty output, bare untouched, ssh never contacted.
sps_en_expect_noop() {
  local name="$1" main
  WORKFLOW_PLANS_DIR="$SPS_EN" PLAN_SYNC_REMOTE_URL="$PSF_ORIGIN_E2E" sps_run_hook "$2"
  if [[ "$HOOK_RC" == 0 && -z "$HOOK_OUT" ]]; then pass "$name — exit 0, empty output"
  else fail "$name — exit 0, empty output — rc=$HOOK_RC out=$HOOK_OUT"; fi
  main="$(git -C "$SPS_EN_BARE" rev-parse --verify -q refs/heads/main || echo missing)"
  if [[ "$main" == missing && ! -s "$GIT_SSH_STUB_LOG" ]]; then pass "$name — no push, remote never contacted"
  else fail "$name — no push, remote never contacted — bare main=$main"; fi
}
if psf_make_provisioned "$SPS_EN" "$PSF_ORIGIN_E2E" >/dev/null 2>&1; then
  setup_ssh_stub "$SPS_EN_BARE"
  mkdir -p "$SPS_EN/drafts" "$SPS_EN/nested"
  printf 'n\n' > "$SPS_EN/notes.md"
  printf '{}\n' > "$SPS_EN/s2513en-intent.ipynb"
  printf 'd\n' > "$SPS_EN/drafts/s2513en-intent.md"
  printf 'n\n' > "$SPS_EN/nested/s2513en-outline.md"
  printf 'p\n' > "$SPS_EN/s2513en-detail.md"

  echo "=== A4: Edit of a non-plan file / NotebookEdit of .ipynb -> no-op ==="
  sps_en_expect_noop "A4a Edit of a non-plan file" \
    "$(sps_ew_json Edit "$(printf '{"file_path":"%s","old_string":"a","new_string":"b"}' "$SPS_EN/notes.md")")"
  sps_en_expect_noop "A4b NotebookEdit of a .ipynb" \
    "$(sps_ew_json NotebookEdit "$(printf '{"notebook_path":"%s","new_source":"x"}' "$SPS_EN/s2513en-intent.ipynb")")"

  echo "=== A5: Edit of a plan-named file under drafts/ or nested -> no-op ==="
  sps_en_expect_noop "A5a Edit of drafts/<sid>-intent.md" \
    "$(sps_ew_json Edit "$(printf '{"file_path":"%s","old_string":"a","new_string":"b"}' "$SPS_EN/drafts/s2513en-intent.md")")"
  sps_en_expect_noop "A5b Edit of nested/<sid>-outline.md" \
    "$(sps_ew_json Edit "$(printf '{"file_path":"%s","old_string":"a","new_string":"b"}' "$SPS_EN/nested/s2513en-outline.md")")"

  echo "=== A6: failed Edit of a plan file -> no-op ==="
  SPS_A6_INPUT="$(printf '{"file_path":"%s","old_string":"a","new_string":"b"}' "$SPS_EN/s2513en-detail.md")"
  sps_en_expect_noop "A6a Edit with tool_response success:false" "$(sps_ew_json Edit "$SPS_A6_INPUT" '{"success":false}')"
  sps_en_expect_noop "A6b Edit with tool_response exit_code 1" "$(sps_ew_json Edit "$SPS_A6_INPUT" '{"exit_code":1}')"
  unset GIT_SSH_COMMAND GIT_SSH_VARIANT GIT_SSH_STUB_BARE GIT_SSH_STUB_LOG
else
  fail "A4-A6 provisioned fixture — psf_make_provisioned failed"
fi

# ── C1-C2: one edit-write call naming several paths -> one sync per distinct final plan ──
# The driver builds the payload in node (a backslash variant cannot ride printf JSON) and
# either prints it (real hook) or runs finalPlanPaths + breadcrumbsForArtifacts with a
# recording sync stub, printing "calls=<n>|sync=<basenames>|crumbs=<Plan file: lines>".
SPS_MX_DRIVER="$PSF_ROOT/mx-driver.js"
printf '%s\n' '"use strict";' \
  'const path = require("path");' \
  'const [action, mode, hook, plans] = process.argv.slice(2);' \
  'const det = plans + "/s2513mx-detail.md", non = plans + "/notes-mx.md", dr = plans + "/drafts/s2513mx-intent.md";' \
  'const bs = (p) => p.replace(/\//g, "\\");' \
  'const inputs = {' \
  '  "c1-editfiles": { tool_name: "editFiles", tool_input: { edits: [{ path: non }, { path: det }, { path: dr }] } },' \
  '  "c1-multiedit": { tool_name: "MultiEdit", tool_input: { file_path: det, edits: [{ file_path: non }, { file_path: dr }] } },' \
  '  "c2-editfiles": { tool_name: "editFiles", tool_input: { path: det, edits: [{ path: det }] } },' \
  '  "c2-multiedit": { tool_name: "MultiEdit", tool_input: { file_path: det, edits: [{ file_path: det, old_string: "a", new_string: "b" }] } },' \
  '  "c2-slash": { tool_name: "editFiles", tool_input: { path: det, edits: [{ path: bs(det) }] } },' \
  '  "c2-slash-alone": { tool_name: "editFiles", tool_input: { path: bs(det) } },' \
  '};' \
  'const input = Object.assign({ tool_response: { success: true }, session_id: "test-sid-mx" }, inputs[mode]);' \
  'if (action === "payload") { process.stdout.write(JSON.stringify(input)); process.exit(0); }' \
  'const m = require(hook); const calls = [];' \
  'const msg = m.breadcrumbsForArtifacts(m.finalPlanPaths(input), input,' \
  '  { sync: (abs) => { calls.push(path.basename(abs)); return { status: "off" }; } });' \
  'const crumbs = msg ? msg.split(/\r?\n/).filter((l) => l.startsWith("Plan file: ")).length : 0;' \
  'process.stdout.write("calls=" + calls.length + "|sync=" + calls.join(",") + "|crumbs=" + crumbs);' \
  > "$SPS_MX_DRIVER"
SPS_MX_ONE="calls=1|sync=s2513mx-detail.md|crumbs=1"
mkdir -p "$SPS_PLANS/drafts"
printf 'mx detail\n' > "$SPS_PLANS/s2513mx-detail.md"
printf 'n\n' > "$SPS_PLANS/notes-mx.md"
printf 'd\n' > "$SPS_PLANS/drafts/s2513mx-intent.md"

# sps_mx_stub <mode> — recording-stub result line for the mode's payload.
sps_mx_stub() { psf_timeout 30 node "$SPS_MX_DRIVER" stub "$1" "$SPS_HOOK" "$SPS_PLANS" 2>&1; }
# sps_mx_hook <name> <mode> — real hook, sync off: exactly one Plan file line, for the detail plan only.
sps_mx_hook() {
  local name="$1" n
  PLAN_SYNC_REMOTE_URL="" sps_run_hook "$(psf_timeout 30 node "$SPS_MX_DRIVER" payload "$2" "$SPS_HOOK" "$SPS_PLANS")"
  n="$(printf '%s\n' "$HOOK_MSG" | grep -c '^Plan file: ')"
  case "$HOOK_MSG" in
    *notes-mx.md*|*drafts*) fail "$name — non-plan / drafts path reached the breadcrumb — msg=$(printf '%q' "$HOOK_MSG")" ;;
    *s2513mx-detail.md*)
      if [ "$HOOK_RC" = 0 ] && [ "$n" = 1 ]; then pass "$name"
      else fail "$name — rc=$HOOK_RC breadcrumb lines=$n msg=$(printf '%q' "$HOOK_MSG")"; fi ;;
    *) fail "$name — no breadcrumb for the detail plan — msg=$(printf '%q' "$HOOK_MSG")" ;;
  esac
}

echo "=== C1: mixed batch (final plan + non-plan + drafts/ plan) -> one sync, one breadcrumb ==="
for SPS_MX_MODE in c1-editfiles c1-multiedit; do
  OUT="$(sps_mx_stub "$SPS_MX_MODE")"
  if [ "$OUT" = "$SPS_MX_ONE" ]; then pass "C1 $SPS_MX_MODE -> one sync call for the final plan only"
  else fail "C1 $SPS_MX_MODE -> one sync call for the final plan only — got=$OUT"; fi
  sps_mx_hook "C1 $SPS_MX_MODE real hook -> one breadcrumb, non-plan and drafts silent" "$SPS_MX_MODE"
done

echo "=== C2: the same plan named twice in one call -> one sync, one breadcrumb ==="
for SPS_MX_MODE in c2-editfiles c2-multiedit; do
  OUT="$(sps_mx_stub "$SPS_MX_MODE")"
  if [ "$OUT" = "$SPS_MX_ONE" ]; then pass "C2 $SPS_MX_MODE top-level + edits[] duplicate -> one sync call"
  else fail "C2 $SPS_MX_MODE top-level + edits[] duplicate -> one sync call — got=$OUT"; fi
  sps_mx_hook "C2 $SPS_MX_MODE real hook -> one breadcrumb" "$SPS_MX_MODE"
done
# Windows-only special case: toAbsPath folds "/" to "\", so a slash variant is the same plan.
# The precondition proves the backslash spelling alone is a plan, so the dedupe is not vacuous.
if [ "$(node -p 'process.platform')" = win32 ]; then
  OUT="$(sps_mx_stub c2-slash-alone)"
  if [ "$OUT" = "$SPS_MX_ONE" ]; then pass "C2 precondition: backslash spelling alone is a final plan"
  else fail "C2 precondition: backslash spelling alone is a final plan — got=$OUT"; fi
  OUT="$(sps_mx_stub c2-slash)"
  if [ "$OUT" = "$SPS_MX_ONE" ]; then pass "C2 c2-slash forward + backslash spelling -> one sync call"
  else fail "C2 c2-slash forward + backslash spelling -> one sync call — got=$OUT"; fi
  sps_mx_hook "C2 c2-slash real hook -> one breadcrumb" c2-slash
else
  echo "SKIP: C2 slash variant — a backslash is a literal filename character off Windows"
fi
