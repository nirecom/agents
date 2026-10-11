# shellcheck shell=bash
# Plans-dir scenes and the hook runner for the turn-end plan-link check.
# Sourced by ../feature-plan-url-stop-guard.sh (needs PLANS, TDIR, STOP_HOOK, UPG_BLOB,
# UPG_PROSE, UPG_HOME_DIR, PL_PREFIX, UPG_JS_HELPERS, and the psf_* fixture helpers).

SID_PUB="0d2c5d7e-1111-4222-8333-444455550001"
SID_LOCAL="0d2c5d7e-1111-4222-8333-444455550002"
SID_NOREC_PUB="0d2c5d7e-1111-4222-8333-444455550003"
SID_MISMATCH="0d2c5d7e-1111-4222-8333-444455550004"
SID_NOHOST="0d2c5d7e-1111-4222-8333-444455550005"
SID_MISMATCH_PUB="0d2c5d7e-1111-4222-8333-444455550006"
SID_STALE="0d2c5d7e-1111-4222-8333-444455550007"
SID_ABSENT="0d2c5d7e-1111-4222-8333-444455550008"
SID_OFF="0d2c5d7e-1111-4222-8333-444455550009"
SID_GL="0d2c5d7e-1111-4222-8333-444455550010"
SID_SG="0d2c5d7e-1111-4222-8333-444455550011"
PLANS_HOME="$UPG_HOME_DIR/.workflow-plans"
PLANS_GL="$PSF_ROOT/plans-gitlab"
PLANS_SG="$PSF_ROOT/plans-ssh-github"
UPG_ORIGIN_SSH_GH="ssh://git@ssh.github.com:443/test-owner/test-repo.git"
UPG_FIX="ok"

# upg_plan <plansDir> <sid> <stage> <record-host|none|-> <publish|local>
# "publish" puts the file on origin/main with identical content; "-" leaves no record.
upg_plan() {
  local dir="$1" rel="$2-$3.md"
  printf '%s\n' "$UPG_PROSE" > "$dir/$rel"
  if [ "$5" = publish ]; then
    psf_commit_file "$dir" "$rel" refs/remotes/origin/main >/dev/null 2>&1 || UPG_FIX="commit-$rel"
  fi
  if [ "$4" != "-" ]; then psf_record "$dir" "$rel" "$4" >/dev/null 2>&1; fi
}

psf_make_provisioned "$PLANS" "$PSF_ORIGIN_E2E" >/dev/null 2>&1 || UPG_FIX="provision-github"
for stage in intent outline detail; do
  upg_plan "$PLANS" "$SID_PUB" "$stage" github.com publish
done
upg_plan "$PLANS" "$SID_LOCAL" intent - local
upg_plan "$PLANS" "$SID_NOREC_PUB" intent - publish
upg_plan "$PLANS" "$SID_MISMATCH" intent gitlab.com local
upg_plan "$PLANS" "$SID_NOHOST" intent none local
upg_plan "$PLANS" "$SID_MISMATCH_PUB" intent gitlab.com publish
upg_plan "$PLANS" "$SID_STALE" intent github.com publish
printf 'This artifact body was edited after the earlier text went upstream.\n' > "$PLANS/$SID_STALE-intent.md"

mkdir -p "$PLANS_HOME"
printf '%s\n' "$UPG_PROSE" > "$PLANS_HOME/$SID_OFF-intent.md"

psf_make_provisioned "$PLANS_GL" "$PSF_ORIGIN_GL" >/dev/null 2>&1 || UPG_FIX="provision-gitlab"
upg_plan "$PLANS_GL" "$SID_GL" intent gitlab.com publish
psf_make_provisioned "$PLANS_SG" "$UPG_ORIGIN_SSH_GH" >/dev/null 2>&1 || UPG_FIX="provision-ssh-github"
upg_plan "$PLANS_SG" "$SID_SG" intent github.com publish

URL_INTENT="$UPG_BLOB/$SID_PUB-intent.md"
URL_OUTLINE="$UPG_BLOB/$SID_PUB-outline.md"
URL_DETAIL="$UPG_BLOB/$SID_PUB-detail.md"
if [ "$UPG_FIX" = ok ]; then pass "hook fixture built"; else fail "hook fixture built" "step=$UPG_FIX"; fi

# Writes the transcript (argv 1) from the entries expression (argv 2), drops the per-turn
# marker for the stage in argv 3 ("-" = none) and prints the plans dir in native form.
IFS= read -r -d '' UPG_BUILD_JS <<'JS' || true
const fs = require('fs');
const { URL_INTENT, URL_OUTLINE, URL_DETAIL, UPG_CASE_PLANS, UPG_CASE_SID, UPG_CASE_BLOB, UPG_CASE_MARKERS } = process.env;
const PLANS = path.normalize(UPG_CASE_PLANS);
const file = (stage) => UPG_CASE_SID + '-' + stage + '.md';
const nat = (stage) => path.join(PLANS, file(stage));
const fwd = (stage) => fwdOf(nat(stage));
const tilde = (stage) => '~/.workflow-plans/' + file(stage);
const uri = (stage) => uriOf(nat(stage));
const url = (stage) => UPG_CASE_BLOB + '/' + file(stage);
const [tpath, entriesJs, markerStage] = process.argv.slice(1);
const entries = eval(entriesJs);
fs.writeFileSync(tpath, entries.map((e) => JSON.stringify(e)).join('\n') + '\n');
if (markerStage !== '-') {
  const name = UPG_CASE_SID + '.confirm-plan-turn-' + require('crypto').randomBytes(4).toString('hex') + '.json';
  fs.writeFileSync(path.join(UPG_CASE_MARKERS, name),
    JSON.stringify({ session_id: UPG_CASE_SID, absPath: nat(markerStage), suffix: markerStage, ts: 1234567890 }) + '\n');
}
process.stdout.write(PLANS);
JS

# upg_case <label> <sid> <stage-marker|-> <transcript-js> <want: allow|block> <reason-prefix|-> [stdin-extra-json]
# transcript-js: a JS array of entries; U/R/RT/A/T/B/S/C, url/nat/fwd/tilde/uri(stage) of the
# case's own plan, and URL_INTENT/URL_OUTLINE/URL_DETAIL/PLANS of the GitHub scene are in scope.
# Scene vars: UPG_PLANS (plans dir), UPG_REMOTE (PLAN_SYNC_REMOTE_URL, "" = off), UPG_BLOB_BASE,
# UPG_HOME (home dir), UPG_HOOK_PLANS (WORKFLOW_PLANS_DIR as the hook sees it). Sets
# UPG_MARKERS_LEFT to the number of turn markers the hook left behind.
upg_case() {
  local label="$1" sid="$2" mstage="$3" js="$4" want="$5" prefix="$6" extra="${7:-}"
  local plans="${UPG_PLANS:-$PLANS}" tpath="$TDIR/$sid-$RANDOM$RANDOM.jsonl" native out rc reason ok=1
  local -a henv left
  UPG_MARKERS_LEFT=0
  rm -f "$WORKFLOW_STATE_DIR/$sid".confirm-plan-turn-*.json
  native="$(URL_INTENT="$URL_INTENT" URL_OUTLINE="$URL_OUTLINE" URL_DETAIL="$URL_DETAIL" \
    UPG_CASE_PLANS="$plans" UPG_CASE_SID="$sid" UPG_CASE_BLOB="${UPG_BLOB_BASE:-$UPG_BLOB}" \
    UPG_CASE_MARKERS="$WORKFLOW_STATE_DIR" \
    psf_timeout 30 node -e "$UPG_JS_HELPERS$UPG_BUILD_JS" "$tpath" "$js" "$mstage" 2>/dev/null)"
  if [ -z "$native" ] || [ ! -f "$tpath" ]; then fail "$label" "transcript fixture not built"; return; fi
  if [ ! -f "$STOP_HOOK" ]; then fail "$label" "hooks/stop-confirm-plan-guard.js absent"; return; fi
  henv=(env -u CLAUDE_PROJECT_DIR "WORKFLOW_PLANS_DIR=${UPG_HOOK_PLANS:-$native}"
    "PLAN_SYNC_REMOTE_URL=${UPG_REMOTE-$PSF_ORIGIN_E2E}" "GITLAB_HOSTNAME=" "GITLAB_SSH_HOSTNAME=")
  if [ -n "${UPG_HOME:-}" ]; then henv+=("HOME=$UPG_HOME" "USERPROFILE=$UPG_HOME"); fi
  out="$(printf '{"session_id":"%s","transcript_path":"%s"%s}' "$sid" "$tpath" "$extra" \
    | "${henv[@]}" bash "$SCRIPT_CHECKOUT_ROOT/bin/run-with-timeout.sh" 60 node "$STOP_HOOK" 2>/dev/null)"
  rc=$?
  left=("$WORKFLOW_STATE_DIR/$sid".confirm-plan-turn-*.json)
  if [ -e "${left[0]}" ]; then UPG_MARKERS_LEFT="${#left[@]}"; fi
  reason="$(printf '%s' "$out" | psf_timeout 30 node -e "
let o = {}; try { o = JSON.parse(require('fs').readFileSync(0, 'utf8') || '{}'); } catch (e) {}
process.stdout.write(o.decision === 'block' && typeof o.reason === 'string' ? o.reason : '');")"
  if [ "$want" = allow ]; then
    if [ "$rc" -ne 0 ] || [ -n "$out" ]; then ok=0; fi
  elif [ "$rc" -ne 2 ] || [ -z "$reason" ] || [ "${reason#"$prefix"}" = "$reason" ]; then
    ok=0
  fi
  if [ "$ok" -eq 1 ]; then pass "$label"; else fail "$label" "want=$want prefix='$prefix' rc=$rc stdout=$out"; fi
  if [ "$want" = block ] && [ "$prefix" = "$PL_PREFIX" ] && [ -z "$reason" ]; then
    fail "$label — reason content checks" "no block reason to inspect"
  elif [ "$want" = block ] && [ "$prefix" = "$PL_PREFIX" ]; then
    if printf '%s' "$reason" | grep -qE 'https?://'; then fail "$label — reason names no URL" "$reason"; else pass "$label — reason names no URL"; fi
    if printf '%s' "$reason" | grep -qF 'bin/plan-link'; then pass "$label — reason points at bin/plan-link"; else fail "$label — reason points at bin/plan-link" "$reason"; fi
    if printf '%s' "$reason" | grep -qE 'GitHub|Layer [0-9]|never a local path'; then fail "$label — reason carries none of the retired wording" "$reason"
    else pass "$label — reason carries none of the retired wording"; fi
  fi
  rm -f "$WORKFLOW_STATE_DIR/$sid".confirm-plan-turn-*.json
}
