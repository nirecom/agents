# Part of tests/feature-1812-worker-dispatch-uv-no-project.sh — sourced, not run.
# Tests: bin/compose-doc-append-entry
# Tags: worker-dispatch, doc-append, compose, uv, supply-chain, credential-exposure, security, adversarial, canary, TL2, scope:issue-specific
# The hostile PEP 517 fixture, the offline `gh`, the unpatched mutant and the
# shared assertions (rules/coding/file-split.md Pattern A).

# The hostile artifact (protection-fix-tests.md Pattern 2, step 1). A PEP 517
# backend resolved through `backend-path = ["."]` needs no network and no
# declared build requirement: `uv run` imports it out of the worktree the moment
# it decides a project is in play. The canary is written from the MODULE BODY,
# because import alone is already arbitrary code execution.
plant_hostile_project() {
    local dir="$1"
    cat > "$dir/pyproject.toml" <<'PYPROJECT'
[project]
name = "branch-under-review"
version = "0.0.1"
requires-python = ">=3.8"

[build-system]
requires = []
build-backend = "hostile_backend"
backend-path = ["."]
PYPROJECT
    cat > "$dir/hostile_backend.py" <<'BACKEND'
import os

# Executed on IMPORT: reaching this line at all means the branch's own code ran
# inside the compose step, holding whatever that step's environment carried.
_out = os.environ.get("CANARY_OUT")
if _out:
    with open(_out, "a", encoding="utf-8") as fh:
        fh.write("CANARY_EXECUTED\n")
        fh.write("GH_TOKEN=%s\n" % os.environ.get("GH_TOKEN"))
        fh.write("GITHUB_TOKEN=%s\n" % os.environ.get("GITHUB_TOKEN"))


def get_requires_for_build_wheel(config_settings=None):
    return []


def get_requires_for_build_editable(config_settings=None):
    return []


def build_wheel(wheel_directory, config_settings=None, metadata_directory=None):
    raise RuntimeError("hostile backend")


def build_editable(wheel_directory, config_settings=None, metadata_directory=None):
    raise RuntimeError("hostile backend")
BACKEND
}

# The gh stub: serves the shapes compose-doc-append-entry and bin/lib/github-*.sh
# actually issue, and RECORDS every invocation so an arm can prove it reached the
# write stage rather than dying early.
STUB_BIN="$TMPD/stubbin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/gh" <<'GHSTUB'
#!/usr/bin/env bash
# Offline `gh` stand-in. GH_CALL_LOG records argv; GH_PUT_DIR captures --input
# bodies. GH_REMOTE_HISTORY / GH_REMOTE_CHANGELOG are the files served as the
# default branch's current content.
set -u
printf '%s\n' "$*" >> "${GH_CALL_LOG:-/dev/null}"

b64() { base64 "$1" | tr -d '\r\n'; }

case "${1:-}" in
  auth)
      echo "  - token scopes: 'repo', 'workflow'"
      exit 0
      ;;
  repo)
      # `gh repo view --json owner,name --jq ...` — the owner/repo resolution.
      echo "${GH_STUB_NWO:-testowner/testrepo}"
      exit 0
      ;;
  api)
      shift
      METHOD="GET"; ENDPOINT=""; INPUT=""
      while [ $# -gt 0 ]; do
          case "$1" in
              -X) METHOD="$2"; shift 2 ;;
              --input) INPUT="$2"; shift 2 ;;
              --jq|-q) shift 2 ;;
              -*) shift ;;
              *) [ -z "$ENDPOINT" ] && ENDPOINT="$1"; shift ;;
          esac
      done
      if [ "$METHOD" = "PUT" ] && [ -n "$INPUT" ]; then
          mkdir -p "${GH_PUT_DIR:-$TMPDIR}"
          cp "$INPUT" "${GH_PUT_DIR}/put-$(date +%s%N)-$$.json"
          echo '{"commit":{"sha":"0000000000000000000000000000000000000000"}}'
          exit 0
      fi
      case "$ENDPOINT" in
          *contents/docs/history.md*)
              [ -f "${GH_REMOTE_HISTORY:-}" ] || exit 1
              printf '{"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","content":"%s"}\n' "$(b64 "$GH_REMOTE_HISTORY")"
              exit 0 ;;
          *contents/CHANGELOG.md*)
              [ -f "${GH_REMOTE_CHANGELOG:-}" ] || exit 1
              printf '{"sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","content":"%s"}\n' "$(b64 "$GH_REMOTE_CHANGELOG")"
              exit 0 ;;
          *contents/*)
              exit 1 ;;
          repos/*/*/git/*)
              # Git Data API (the rotation write): refused on purpose — the A3
              # arm measures what happened BEFORE it.
              echo "gh-stub: git-data endpoint not served" >&2
              exit 1 ;;
          repos/*/*)
              echo "main"
              exit 0 ;;
      esac
      exit 1
      ;;
esac
exit 1
GHSTUB
chmod +x "$STUB_BIN/gh"

# The mutant: the "unpatched code" baseline of protection-fix-tests.md Pattern 2
# — a verbatim copy with `--no-project` removed from all three uv call sites,
# re-anchored so its SCRIPT_DIR still finds doc-append.py. Its only job is to
# prove the hostile fixture is live; if M1 went green too, A1-A3 would be vacuous.
MUTANT="$TMPD/compose-doc-append-entry.no-fix"
sed -e 's|uv run --no-project|uv run|g' \
    -e "s|^SCRIPT_DIR=.*|SCRIPT_DIR=\"$AGENTS_DIR/bin\"|" \
    "$CLI" > "$MUTANT"
MUTANT_UV_SITES="$(grep -c 'uv run --no-project' "$MUTANT" || true)"
REAL_UV_SITES="$(grep -c 'uv run --no-project' "$CLI" || true)"

assert_eq "0/real-cli-declares-three-no-project-call-sites" "3" "$REAL_UV_SITES"
assert_eq "0/mutant-has-no-no-project-call-site-left" "0" "$MUTANT_UV_SITES"

# Fixture builder. Each arm gets its own worktree so a `.venv` uv materialised in
# one arm cannot silence the next.
ARM_N=0
setup_arm() {
    ARM_N=$((ARM_N + 1))
    ARM_DIR="$TMPD/arm$ARM_N"
    WORK="$ARM_DIR/worktree"
    STAGING="$ARM_DIR/plans"
    REMOTE="$ARM_DIR/remote"
    CANARY="$ARM_DIR/canary.txt"
    CALLLOG="$ARM_DIR/gh-calls.log"
    PUTDIR="$ARM_DIR/puts"
    mkdir -p "$WORK" "$STAGING" "$REMOTE" "$PUTDIR"
    : > "$CALLLOG"

    git -C "$WORK" init -q -b main >/dev/null 2>&1
    git -C "$WORK" config core.hooksPath /dev/null
    git -C "$WORK" config user.email "test@example.com"
    git -C "$WORK" config user.name "Test"
    echo init > "$WORK/README.md"
    git -C "$WORK" add README.md >/dev/null 2>&1
    git -C "$WORK" commit -q --no-verify -m initial >/dev/null 2>&1

    plant_hostile_project "$WORK"

    # The "remote" default-branch content the gh stub serves back.
    local want="${1:-40}" i=1
    {
        echo "# History"
        echo ""
        while [ "$i" -le "$want" ]; do
            echo "## 2020-01-01 FEATURE: filler entry $i"
            echo ""
            i=$((i + 1))
        done
    } > "$REMOTE/history.md"
    printf '# Changelog\n\n' > "$REMOTE/CHANGELOG.md"

    NOTES="$ARM_DIR/WORKTREE_NOTES.md"
    cat > "$NOTES" <<'NOTESEOF'
# WORKTREE NOTES

## History Notes
- Add the uv no-project canary arm to the compose entry test suite

## Changelog Notes
- Add the uv no-project canary arm to the compose entry test suite
NOTESEOF
}

# run_compose <script> [args...] — always from inside the worktree, the cwd the
# real dispatcher hands the compose child (doc-append.js passes payload.cwd).
RUN_OUT=""
RUN_RC=0
run_compose() {
    local script="$1"; shift
    RUN_RC=0
    RUN_OUT="$(cd "$WORK" && env \
        -u CLAUDE_CODE_SESSION_ID \
        "PATH=$STUB_BIN:$PATH" \
        "AGENTS_CONFIG_DIR=$AGENTS_DIR" \
        "WORKFLOW_PLANS_DIR=$STAGING" \
        "CLAUDE_WORKFLOW_DIR=$ARM_DIR/workflow" \
        "CLAUDE_SESSION_ID=uvnp-arm$ARM_N" \
        "CANARY_OUT=$CANARY" \
        "GH_CALL_LOG=$CALLLOG" \
        "GH_PUT_DIR=$PUTDIR" \
        "GH_REMOTE_HISTORY=$REMOTE/history.md" \
        "GH_REMOTE_CHANGELOG=$REMOTE/CHANGELOG.md" \
        "GH_TOKEN=$FAKE_GH_TOKEN" \
        "GITHUB_TOKEN=$FAKE_GITHUB_TOKEN" \
        bash "$script" \
        --notes "$NOTES" \
        --branch "feature/1812-uv-no-project" \
        --pr "1812" \
        --merge-commit "0123456789abcdef0123456789abcdef01234567" \
        --background "uv --no-project canary arm" \
        "$@" 2>&1)" || RUN_RC=$?
}

# Pattern 1 — negative assertions on the RESOURCE (the canary, the materialised
# project), never on the exit code alone.
assert_no_execution() {
    local tag="$1"
    if [ -e "$CANARY" ]; then
        fail "$tag/hostile-backend-did-not-execute" "canary present: $(tr '\n' ' ' < "$CANARY")"
    else
        pass "$tag/hostile-backend-did-not-execute"
    fi
    # uv writes neither until it has decided a project is in play.
    if [ -e "$WORK/.venv" ] || [ -e "$WORK/uv.lock" ]; then
        fail "$tag/no-project-environment-was-materialised" \
            "venv=$([ -e "$WORK/.venv" ] && echo yes || echo no) lock=$([ -e "$WORK/uv.lock" ] && echo yes || echo no)"
    else
        pass "$tag/no-project-environment-was-materialised"
    fi
}

# Name-agnostic leak sweep: the token VALUE must appear in nothing the run
# printed and in no file it produced. A name check would miss a backend that
# copied the value out under a name of its own choosing.
assert_no_token_leak() {
    local tag="$1" hits
    if printf '%s' "$RUN_OUT" | grep -qF "$FAKE_GH_TOKEN" || \
       printf '%s' "$RUN_OUT" | grep -qF "$FAKE_GITHUB_TOKEN"; then
        fail "$tag/token-absent-from-compose-output"
    else
        pass "$tag/token-absent-from-compose-output"
    fi
    hits="$(grep -rlF "$FAKE_GH_TOKEN" "$WORK" "$STAGING" "$PUTDIR" 2>/dev/null | head -5)"
    hits="$hits$(grep -rlF "$FAKE_GITHUB_TOKEN" "$WORK" "$STAGING" "$PUTDIR" 2>/dev/null | head -5)"
    if [ -n "$hits" ]; then
        fail "$tag/token-absent-from-worktree-and-staging" "$(printf '%s' "$hits" | tr '\n' ' ')"
    else
        pass "$tag/token-absent-from-worktree-and-staging"
    fi
}

# The decoded Contents-API PUT body: the durable evidence that doc-append.py
# really produced the appended document.
put_body_text() {
    local f
    for f in "$PUTDIR"/put-*.json; do
        [ -f "$f" ] || continue
        jq -r '.content' "$f" 2>/dev/null | tr -d '\r\n' | base64 -d 2>/dev/null
    done
}

