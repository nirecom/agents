#!/usr/bin/env bash
# Shared scaffolding for the #2527 stage-4 suites (sourced, not run): feature-2527-merge-detect-graphql.sh,
# feature-2527-merge-gate-graphql.sh, feature-2527-auto-merge-pr-fix.sh, feature-2527-release-channel-deny.sh.
# The sourcing test pins the state dirs first (top level): AMP_TMP=..., readonly, harness_isolate.
[ -n "${_AMP_LIB_LOADED:-}" ] && return 0
_AMP_LIB_LOADED=1

_amp_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_AMP_CHECKOUT="$(cd "$_amp_here/../../.." && pwd)"
# shellcheck source=../../lib/harness.sh
source "$_AMP_CHECKOUT/tests/lib/harness.sh"

AMP_ROOT_M="$(np "$_AMP_CHECKOUT")"
export AMP_ROOT_M
AMP_FIXTURE_JS="$(np "$_amp_here/fixture.js")"
AMP_PRELOAD_UNREADABLE="$(np "$_amp_here/preload-unreadable.js")"
GATE_JS="$AMP_ROOT_M/hooks/workflow-gate.js"
MARK_JS="$AMP_ROOT_M/hooks/workflow-mark.js"
RELEASE_CHANNEL="$AMP_ROOT_M/bin/workflow/release-channel"
AMP_PR_URL="https://github.com/example/repo/pull/42"

check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "want=[$3] got=[$2]"; fi; }
check_contains() {
  case "$2" in *"$3"*) pass "$1" ;; *) fail "$1" "missing [$3] in: $(printf '%s' "$2" | head -c 600)" ;; esac
}
check_not_contains() {
  case "$2" in *"$3"*) fail "$1" "unexpected [$3] in: $(printf '%s' "$2" | head -c 600)" ;; *) pass "$1" ;; esac
}

# field <output> <key> — value of the first key=... line; an absent key yields a
# <no KEY: ...> marker carrying the raw head so a red case shows why.
field() {
  local v
  v="$(printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -n 1)"
  if [ -z "$v" ] && ! printf '%s\n' "$1" | grep -q "^$2="; then
    v="<no $2: $(printf '%s' "$1" | head -c 300 | tr '\n' ' ')>"
  fi
  printf '%s' "$v"
}

# AMP_PRELUDE — node prelude: req(rel) prints MISSING:<rel> and exits 0 when a module is
# absent, so a not-yet-implemented module reds each assertion with its reason.
AMP_PRELUDE='const A = process.env.AMP_ROOT_M;
const req = (p) => { try { return require(A + "/" + p); } catch (e) { console.log("MISSING:" + p + " " + (e && (e.code || e.message))); process.exit(0); } };
const out = (k, v) => console.log(k + "=" + (typeof v === "string" ? v : JSON.stringify(v)));'
# amp_node <js> [arg...] — the args reach the script as process.argv[1..].
amp_node() {
  run_with_timeout 30 node -e "$AMP_PRELUDE
$1" "${@:2}" 2>&1
}

# _amp_path_without <name>... — PATH minus every dir holding any <name>(.exe|.cmd), so a
# missed stub surfaces as a stub-less answer instead of a live forge query.
_amp_path_without() {
  local out="" d n skip IFS=:
  for d in $PATH; do
    skip=0
    for n in "$@"; do
      if [ -e "$d/$n" ] || [ -e "$d/$n.exe" ] || [ -e "$d/$n.cmd" ]; then skip=1; fi
    done
    [ "$skip" -eq 1 ] && continue
    out="${out:+$out:}$d"
  done
  printf '%s' "$out"
}

# _amp_fake_gh <dir> — a gh stub: `pr view` answers one OPEN PR (URL only under -q/--jq),
# everything else fails; every argv is logged to AMP_GH_LOG. gh.cmd covers cmd.exe callers.
_amp_fake_gh() {
  mkdir -p "$1"
  cat > "$1/gh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "\${AMP_GH_LOG:-/dev/null}"
case "\$1 \$2" in
  "pr view")
    case " \$* " in
      *" -q "*|*" --jq "*) echo "$AMP_PR_URL" ;;
      *) printf '{"state":"OPEN","number":42,"mergeStateStatus":"CLEAN","url":"$AMP_PR_URL"}\n' ;;
    esac ;;
  *) echo "fake gh: unsupported: \$*" >&2; exit 2 ;;
esac
EOF
  chmod +x "$1/gh"
  printf '@bash "%%~dp0gh" %%*\r\n' > "$1/gh.cmd"
}

# amp_setup — an AGENTS_MAIN_ROOT holding only cfg/.env, pinned config (ENFORCE_WORKTREE=on,
# AUTO_MERGE_PR unset), a fake gh first on PATH, and a fixture repo (github origin,
# origin/main ref, feature branch) with one linked worktree. Sets AMP_REPO(_M) / AMP_WT(_M);
# CLAUDE_PROJECT_DIR is the main repo, where a .env.local overlay is read from.
amp_setup() {
  export WORKFLOW_STATE_DIR="$(np "$WORKFLOW_STATE_DIR")"
  export WORKFLOW_PLANS_DIR="$(np "$WORKFLOW_PLANS_DIR")"
  mkdir -p "$AMP_TMP/cfg" "$AMP_TMP/transcripts"
  export AGENTS_MAIN_ROOT="$(np "$AMP_TMP/cfg")"
  amp_env
  export CLAUDE_TRANSCRIPT_BASE_DIR="$(np "$AMP_TMP/transcripts")"
  export ENFORCE_WORKTREE=on ENFORCE_WORKTREE_EXCLUDE=""
  unset CONFIRM_DETAIL AUTO_MERGE_PR DEFAULT_BRANCHES NODE_OPTIONS GITLAB_HOSTNAME GITLAB_SSH_HOSTNAME
  _amp_fake_gh "$AMP_TMP/bin"
  export PATH="$AMP_TMP/bin:$(_amp_path_without gh glab)"
  export AMP_GH_LOG="$AMP_TMP/gh-args.log"
  : > "$AMP_GH_LOG"
  AMP_REPO="$AMP_TMP/repo"
  harness_git_init "$AMP_REPO"
  git -C "$AMP_REPO" config user.email t@example.com
  git -C "$AMP_REPO" config user.name t
  git -C "$AMP_REPO" config protocol.https.allow never
  git -C "$AMP_REPO" config core.autocrlf false
  printf 'base\n' > "$AMP_REPO/README.md"
  git -C "$AMP_REPO" add README.md
  git -C "$AMP_REPO" commit -q -m base
  git -C "$AMP_REPO" branch -M main
  git -C "$AMP_REPO" remote add origin https://github.com/example/repo.git
  git -C "$AMP_REPO" update-ref refs/remotes/origin/main HEAD
  AMP_REPO_M="$(np "$AMP_REPO")"
  AMP_WT="$AMP_TMP/wt"
  git -C "$AMP_REPO" worktree add -q -b feature/2527-amp "$AMP_WT" main
  AMP_WT_M="$(np "$AMP_WT")"
  export CLAUDE_PROJECT_DIR="$AMP_REPO_M"
  cd "$AMP_REPO" || return 1
}

amp_teardown() {
  cd / || true
  [ -n "${AMP_TMP:-}" ] && rm -rf "$AMP_TMP"
}

# amp_env <line>... — rewrites the global .env with the given lines after a fixed
# CONFIRM_DETAIL=off: the detail-approval gate (waived only from the config FILE) is not
# under test, and BRANCHING_COMPLETE records only once it passes.
amp_env() {
  printf 'CONFIRM_DETAIL=off\n' > "$AMP_TMP/cfg/.env"
  local l
  for l in "$@"; do printf '%s\n' "$l" >> "$AMP_TMP/cfg/.env"; done
}
# amp_env_local <line>... — the project .env.local overlay; no lines removes it.
amp_env_local() {
  rm -f "$AMP_REPO/.env.local"
  [ "$#" -eq 0 ] && return 0
  local l
  for l in "$@"; do printf '%s\n' "$l" >> "$AMP_REPO/.env.local"; done
}

# mk_state <spec-json> — fixture.js state file; cwd defaults to the main fixture repo.
mk_state() {
  local spec="$1"
  case "$spec" in *'"cwd"'*) ;; *) spec="${spec%\}},\"cwd\":\"$AMP_REPO_M\"}" ;; esac
  node "$AMP_FIXTURE_JS" "$spec" || fail "fixture" "fixture.js rejected spec: $1"
}

# hook_json <sid> <cwd> <command> [exit] — a Bash tool payload for a hook's stdin.
hook_json() {
  node -e 'process.stdout.write(JSON.stringify({ tool_name: "Bash", session_id: process.argv[1],
    tool_input: { command: process.argv[3], cwd: process.argv[2], description: "test" },
    tool_response: { exit_code: Number(process.argv[4] || 0) } }))' "$1" "$2" "$3" "${4:-0}"
}
gate_bash() { hook_json "$@" | run_with_timeout 60 node "$GATE_JS" 2>&1; }
mark_bash() { hook_json "$@" | run_with_timeout 60 node "$MARK_JS" 2>&1; }
# *_unreadable — the same hook with AUTO_MERGE_PR unreadable (preload-unreadable.js).
gate_bash_unreadable() { hook_json "$@" | NODE_OPTIONS="--require \"$AMP_PRELOAD_UNREADABLE\"" run_with_timeout 60 node "$GATE_JS" 2>&1; }
mark_bash_unreadable() { hook_json "$@" | NODE_OPTIONS="--require \"$AMP_PRELOAD_UNREADABLE\"" run_with_timeout 60 node "$MARK_JS" 2>&1; }

# hook_json_key <hook-output> <key> — <key> of the last JSON line carrying a "decision"
# (approve|block, or the reason / systemMessage text); <none> when absent.
hook_json_key() {
  printf '%s\n' "$1" | HJ_KEY="$2" run_with_timeout 30 node -e '
    let buf = "";
    process.stdin.on("data", (c) => { buf += c; }).on("end", () => {
      let v = "<none>";
      for (const line of buf.split(/\r?\n/)) {
        try {
          const j = JSON.parse(line);
          if (j && typeof j.decision === "string") v = typeof j[process.env.HJ_KEY] === "string" ? j[process.env.HJ_KEY] : "<none>";
        } catch (_) {}
      }
      console.log(v);
    });
  ' 2>&1
}
hook_decision() { hook_json_key "$1" decision; }

# raw_state <sid> — RAW=<delivery_path>|<auto_merge_pr>|<auto_merge_pr_source> from the raw
# state file, <absent> for a missing key; UV=<last user_verification status>.
raw_state() {
  AMP_SID="$1" amp_node 'const fs = require("fs");
let s; try { s = JSON.parse(fs.readFileSync(process.env.WORKFLOW_STATE_DIR + "/" + process.env.AMP_SID + ".json", "utf8")); } catch (e) { out("RAW", "<unreadable>"); process.exit(0); }
const g = (k) => (Object.prototype.hasOwnProperty.call(s, k) && s[k] !== null ? String(s[k]) : "<absent>");
out("RAW", [g("delivery_path"), g("auto_merge_pr"), g("auto_merge_pr_source")].join("|"));
const e = (s.events || []).filter((x) => x.kind === "step_status" && x.step === "user_verification");
out("UV", e.length ? e[e.length - 1].status : "<none>");
const r = (s.events || []).filter((x) => x.kind === "step_annotation" && x.step === "user_verification" && x.key === "reset_reason");
out("UVRESET", r.length ? r[r.length - 1].value : "<none>");'
}

# release_channel <sid> — the CLI's stdout+stderr with its exit code appended as EXIT=<n>.
release_channel() {
  local o rc
  o="$(run_with_timeout 30 node "$RELEASE_CHANNEL" --session "$1" 2>&1)"
  rc=$?
  printf '%s\nEXIT=%s\n' "$o" "$rc"
}
# channel_triple <release_channel output> — CHANNEL|AUTO_MERGE_PR|SOURCE.
channel_triple() {
  printf '%s|%s|%s' "$(field "$1" CHANNEL)" "$(field "$1" AUTO_MERGE_PR)" "$(field "$1" SOURCE)"
}
