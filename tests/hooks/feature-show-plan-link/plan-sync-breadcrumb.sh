# #2513 plan-sync breadcrumb cases (H1-H7): formatBreadcrumb pure function plus the real
# hook on every path where no push succeeds. Sourced last by ../feature-show-plan-link.sh
# (inherits pass/fail, HOOK, AGENTS_DIR); psf_setup re-pins every env var to a fresh root.
# The successful push path lives in feature-2513-plan-sync-e2e.sh (ssh stub).

# shellcheck source=../../lib/plan-sync-fixture.sh
. "$AGENTS_DIR/tests/lib/plan-sync-fixture.sh"
psf_setup || { fail "H setup — psf_setup failed"; return 0; }
trap 'psf_cleanup; rm -rf "$PLANS_DIR" "$WORKFLOW_DIR_TEST" "$CFG_DIR_TEST"' EXIT
SPS_HOOK="$(psf_np "$HOOK")"
SPS_PLANS="$WORKFLOW_PLANS_DIR"
SPS_RUN_HINT='— run node "$AGENTS_CONFIG_DIR/bin/plan-sync-init"'

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
const hint = " — run node \"$AGENTS_CONFIG_DIR/bin/plan-sync-init\"";
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
SPS_MARKERS=("$CLAUDE_WORKFLOW_DIR"/test-sid-h2.confirm-plan-turn-*.json)
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
SPS_H9_SCRIPT="$(psf_np "$AGENTS_DIR/skills/_shared/assemble-mandatory.sh")"
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
