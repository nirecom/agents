#!/usr/bin/env bash
# Shared helpers for the feature-2527-release-phase split suite (sourced, not run).
# Tests: tests/bin/feature-2527-release-phase.sh
# Tags: scope:issue-specific, workflow, release-phase
[ -n "${_RP_LIB_LOADED:-}" ] && return 0
_RP_LIB_LOADED=1

_rp_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_HELPERS_SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck source=../../lib/harness.sh
source "$_HELPERS_SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

RP_FIXTURE_JS="$(np "$_rp_here/fixture.js")"
RP_SCRIPT_CHECKOUT_ROOT="$(np "$_HELPERS_SCRIPT_CHECKOUT_ROOT")"
export RP_SCRIPT_CHECKOUT_ROOT
NEXT_STEP="$_HELPERS_SCRIPT_CHECKOUT_ROOT/bin/workflow/next-step"
GATE_JS="$RP_SCRIPT_CHECKOUT_ROOT/hooks/workflow-gate.js"
MARK_JS="$RP_SCRIPT_CHECKOUT_ROOT/hooks/workflow-mark.js"

check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "want=[$3] got=[$2]"; fi; }
check_contains() {
  case "$2" in *"$3"*) pass "$1" ;; *) fail "$1" "missing [$3] in: $(printf '%s' "$2" | head -c 600)" ;; esac
}
check_not_contains() {
  case "$2" in *"$3"*) fail "$1" "unexpected [$3] in: $(printf '%s' "$2" | head -c 600)" ;; *) pass "$1" ;; esac
}

# field <output> <key> — value of the first key=... line with one layer of single
# quotes stripped; absent key yields a <no KEY: ...> marker carrying the raw head.
field() {
  local v
  v="$(printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -n 1)"
  if [ -z "$v" ] && ! printf '%s\n' "$1" | grep -q "^$2="; then
    v="<no $2: $(printf '%s' "$1" | head -c 300 | tr '\n' ' ')>"
  fi
  v="${v#\'}"; v="${v%\'}"
  printf '%s' "$v"
}

# rp_fake_gh <dir> — a gh stub driven by RP_GH_MODE (OPEN|MERGED|CLOSED|NONE|fail) that
# logs every argv to RP_GH_LOG; `pr list` reports RP_GH_HEAD as the PR's headRefOid, `pr view`
# RP_GH_VIEW_HEAD (default: the HEAD of the repo it runs in). gh.cmd lets cmd.exe (execSync on Windows) reach it too.
rp_fake_gh() {
  mkdir -p "$1"
  cat > "$1/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${RP_GH_LOG:-/dev/null}"
mode="${RP_GH_MODE:-NONE}"
if [ "$mode" = "fail" ]; then echo "HTTP 502: Bad Gateway" >&2; exit 2; fi
case "$1 $2" in
  "pr view")
    if [ "$mode" = "NONE" ]; then echo "no pull requests found for branch" >&2; exit 1; fi
    case " $* " in
      *" -q "*|*" --jq "*) echo "$mode" ;;
      *) printf '{"state":"%s","number":42,"mergeStateStatus":"CLEAN","url":"https://github.com/example/repo/pull/42","headRefOid":"%s"}\n' "$mode" "${RP_GH_VIEW_HEAD-$(git rev-parse HEAD 2>/dev/null)}" ;;
    esac ;;
  "pr list")
    if [ "$mode" = "NONE" ]; then echo "[]"; exit 0; fi
    printf '[{"number":42,"title":"Fixture PR 2527","url":"https://github.com/example/repo/pull/42","state":"%s","headRefOid":"%s"}]\n' "$mode" "${RP_GH_HEAD:-}" ;;
  *) echo "fake gh: unsupported: $*" >&2; exit 2 ;;
esac
EOF
  chmod +x "$1/gh"
  printf '@bash "%%~dp0gh" %%*\r\n' > "$1/gh.cmd"
}

# rp_path_without_gh — PATH minus every dir holding a real gh, so a missed stub
# surfaces as an empty arg log instead of a live network query.
rp_path_without_gh() {
  local out="" d IFS=:
  for d in $PATH; do
    [ -e "$d/gh" ] || [ -e "$d/gh.exe" ] || [ -e "$d/gh.cmd" ] && continue
    out="${out:+$out:}$d"
  done
  printf '%s' "$out"
}

# rp_path_without <name>... — PATH minus every dir holding any <name>(.exe|.cmd), so a missed
# stub surfaces as a stub-less answer instead of a live forge query.
rp_path_without() {
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

# rp_fake_forge <dir> <name>... — node-copy gh / glab stubs answered by fake-forge.js (reachable
# with and without a shell, Windows included); PATH = the stubs + PATH minus any real gh / glab.
# Sets RP_FORGE_PATH_BARE (PATH without any forge CLI) and FAKE_FORGE_LOG.
rp_fake_forge() {
  local d="$1"
  shift
  # shellcheck source=../../lib/cli-stub.sh
  source "$_HELPERS_SCRIPT_CHECKOUT_ROOT/tests/lib/cli-stub.sh"
  cli_stub_make "$d" "$@" || return 1
  RP_FORGE_PATH_BARE="$(rp_path_without gh glab)"
  export PATH="$CLI_STUB_DIR:$RP_FORGE_PATH_BARE"
  export NODE_OPTIONS="--require \"$(np "$_rp_here/fake-forge.js")\""
  export FAKE_FORGE_LOG="$(np "$RP_TMP/forge.log")"
  : > "$RP_TMP/forge.log"
  unset FAKE_FORGE_STATE FAKE_FORGE_MERGE FAKE_GLAB_MERGE FAKE_GLAB_DRAFT FAKE_FORGE_NUMBER
  # Default: the PR/MR is built from the HEAD of the repo asked about, so OPEN / MERGED stand.
  export FAKE_FORGE_HEAD=@cwd
}

# rp_setup — isolated state dirs, an AGENTS_MAIN_ROOT holding only an empty .env, a fake gh first on PATH, pinned
# env, and a fixture repo (github origin, origin/main ref, feature branch, no network).
# Reuses a caller's RP_TMP (a readonly tmp-root pinned at top level) when one is set.
rp_setup() {
  [ -n "${RP_TMP:-}" ] || RP_TMP="$(make_tmp)"
  harness_isolate "$RP_TMP"
  export WORKFLOW_STATE_DIR="$(np "$WORKFLOW_STATE_DIR")"
  export WORKFLOW_PLANS_DIR="$(np "$WORKFLOW_PLANS_DIR")"
  mkdir -p "$RP_TMP/cfg" "$RP_TMP/transcripts"
  : > "$RP_TMP/cfg/.env"
  export AGENTS_MAIN_ROOT="$(np "$RP_TMP/cfg")"
  export CLAUDE_TRANSCRIPT_BASE_DIR="$(np "$RP_TMP/transcripts")"
  export ENFORCE_WORKTREE=on ENFORCE_WORKTREE_EXCLUDE=""
  export CONFIRM_INTENT=on CONFIRM_OUTLINE=on CONFIRM_DETAIL=on CONFIRM_TESTS=on CONFIRM_CODE=on CONFIRM_DOCS=on CONFIRM_WORKTREE=on
  unset DEFAULT_BRANCHES GITLAB_HOSTNAME GITLAB_SSH_HOSTNAME
  rp_fake_gh "$RP_TMP/bin"
  export PATH="$RP_TMP/bin:$(rp_path_without_gh)"
  export RP_GH_LOG="$RP_TMP/gh-args.log" RP_GH_MODE=NONE
  : > "$RP_GH_LOG"
  RP_REPO="$RP_TMP/repo"
  harness_git_init "$RP_REPO"
  git -C "$RP_REPO" config user.email t@example.com
  git -C "$RP_REPO" config user.name t
  git -C "$RP_REPO" config protocol.https.allow never
  git -C "$RP_REPO" config core.autocrlf false
  printf 'base\n' > "$RP_REPO/README.md"
  git -C "$RP_REPO" add README.md
  git -C "$RP_REPO" commit -q -m base
  git -C "$RP_REPO" branch -M main
  git -C "$RP_REPO" remote add origin https://github.com/example/repo.git
  git -C "$RP_REPO" update-ref refs/remotes/origin/main HEAD
  git -C "$RP_REPO" checkout -q -b feature/2527-rp
  RP_REPO_M="$(np "$RP_REPO")"
  export CLAUDE_PROJECT_DIR="$RP_REPO_M"
  cd "$RP_REPO" || return 1
}

rp_teardown() {
  cd / || true
  [ -n "${RP_TMP:-}" ] && rm -rf "$RP_TMP"
}

# rp_ahead — one local commit not on origin/main (the branch is "ahead").
rp_ahead() {
  printf 'change %s\n' "$RANDOM" >> "$RP_REPO/src.txt"
  git -C "$RP_REPO" add src.txt
  git -C "$RP_REPO" commit -q -m change
}

# rp_worktree — a linked worktree of RP_REPO on feature/2527-wt (RP_WT / RP_WT_M).
rp_worktree() {
  RP_WT="$RP_TMP/wt"
  git -C "$RP_REPO" worktree add -q -b feature/2527-wt "$RP_WT" main
  RP_WT_M="$(np "$RP_WT")"
}

# mk_state <spec-json> — fixture.js state file; cwd defaults to the fixture repo.
mk_state() {
  local spec="$1"
  case "$spec" in *'"cwd"'*) ;; *) spec="${spec%\}},\"cwd\":\"$RP_REPO_M\"}" ;; esac
  node "$RP_FIXTURE_JS" "$spec" || fail "fixture" "fixture.js rejected spec: $1"
}

run_next_step() { run_with_timeout 60 node "$NEXT_STEP" --session "$@" 2>&1; }

# ev_query <sid> <expr> — evaluates <expr> over the RAW state file (events = e);
# independent of the code under test, so v5 files stay readable today.
ev_query() {
  run_with_timeout 30 node -e '
    const fs = require("fs");
    let s; try { s = JSON.parse(fs.readFileSync(process.env.WORKFLOW_STATE_DIR + "/" + process.argv[1] + ".json", "utf8")); }
    catch (e) { console.log("<unreadable>"); process.exit(0); }
    const e = Array.isArray(s.events) ? s.events : [];
    const last = (step) => { const r = e.filter((x) => x.kind === "step_status" && x.step === step); return r.length ? r[r.length - 1].status : "<none>"; };
    const reset = (step) => { const r = e.filter((x) => x.kind === "step_annotation" && x.step === step && x.key === "reset_reason"); return r.length ? r[r.length - 1].value : "<none>"; };
    const count = (step) => e.filter((x) => x.step === step).length;
    console.log(String(eval(process.argv[2])));
  ' "$1" "$2" 2>&1
}
last_status() { ev_query "$1" "last(\"$2\")"; }
last_reset() { ev_query "$1" "reset(\"$2\")"; }
ev_count() { ev_query "$1" "count(\"$2\")"; }

# hook_json <sid> <cwd> <command> [exit] — a Bash tool payload for a hook's stdin.
hook_json() {
  node -e 'process.stdout.write(JSON.stringify({ tool_name: "Bash", session_id: process.argv[1],
    tool_input: { command: process.argv[3], cwd: process.argv[2], description: "test" },
    tool_response: { exit_code: Number(process.argv[4] || 0) } }))' "$1" "$2" "$3" "${4:-0}"
}
gate_bash() { hook_json "$@" | run_with_timeout 60 node "$GATE_JS" 2>&1; }
mark_bash() { hook_json "$@" | run_with_timeout 60 node "$MARK_JS" 2>&1; }

# hook_decision <hook-output> — the "decision" of the last JSON line in a hook's output
# (approve|block), or <none> when no line parses; an allow is asserted positively, not
# inferred from the absence of block wording.
hook_decision() {
  printf '%s\n' "$1" | run_with_timeout 30 node -e '
    let buf = "";
    process.stdin.on("data", (c) => { buf += c; }).on("end", () => {
      let d = "<none>";
      for (const line of buf.split(/\r?\n/)) {
        try { const j = JSON.parse(line); if (j && typeof j.decision === "string") d = j.decision; } catch (_) {}
      }
      console.log(d);
    });
  ' 2>&1
}
