# #2594: <sid>-session-progress.md rides the same project-host record and plan-sync as a final plan,
# but it is not a plan to confirm: no confirm-plan turn marker and nothing shown to the user.
# Sourced by ../feature-2513-plan-sync-send-selection.sh inside its case block. Self-contained
# fixture (own plans dir and bare destination), so it does not depend on project-host-record.sh.
# A record is judged only through readProjectHostState (psf_record_state), never parsed here.

PG="$PSF_ROOT/pg-plans"
PG_BARE="$PSF_ROOT/pg-bare.git"
psf_make_bare "$PG_BARE"
setup_ssh_stub "$PG_BARE"
export PLAN_SYNC_REMOTE_URL="$PSF_ORIGIN_E2E"
PG_GH="$PSF_ROOT/pg-github"; psf_make_project "$PG_GH" "$PSF_ORIGIN_GH"
PG_GL="$PSF_ROOT/pg-gitlab"; psf_make_project "$PG_GL" "$PSF_ORIGIN_GL"

# pg_write <sid> <project> <decoy> — writes $PG/<sid>-session-progress.md and runs the hook on it with
# <project> as the hook input's cwd. Sets PG_OUT.
pg_write() {
  local rel="$1-session-progress.md"
  printf '## Current state\nprogress %s%s\n' "$1" "${PG_SUFFIX:-}" > "$PG/$rel"
  PG_OUT="$(export WORKFLOW_PLANS_DIR="$PG"; cd "$3" || exit 1
    psf_hook "$3" show-plan-link.js "$(psf_write_json "$(psf_np "$PG/$rel")" "$1" "$(psf_np "$2")")" 2>/dev/null)"
}
pg_remote() { git -C "$PG_BARE" show "refs/heads/main:$1-session-progress.md" 2>/dev/null || printf 'absent'; }
# pg_history <sid> — every version of <sid>-session-progress.md on the remote's main, oldest first, joined by "|".
pg_history() {
  local c out=""
  for c in $(git -C "$PG_BARE" rev-list --reverse refs/heads/main -- "$1-session-progress.md" 2>/dev/null); do
    out="$out$(git -C "$PG_BARE" show "$c:$1-session-progress.md" 2>/dev/null | tr '\n' ' ')|"
  done
  printf '%s' "$out"
}
# pg_turn_markers <sid> — count of <sid>.confirm-plan-turn-* files anywhere under the state dir.
pg_turn_markers() { find "$WORKFLOW_STATE_DIR" "$PG" -name "$1.confirm-plan-turn-*" 2>/dev/null | wc -l | tr -d ' '; }

if ! psf_make_provisioned "$PG" "$PSF_ORIGIN_E2E" >/dev/null 2>&1; then
  fail "progress sync" "fixture: psf_make_provisioned failed"
else
  echo "=== PG1: session-progress.md written from a project on the destination host ==="
  pg_write pg01 "$PG_GH" "$PG_GL"
  expect_eq "PG1 a project-host record exists and matches the destination" \
    "$(psf_record_state "$PG" pg01-session-progress.md "$PSF_ORIGIN_E2E")" "match"
  expect_eq "PG1 session-progress.md is sent (not skipped)" "$(pg_remote pg01)" "$(printf '## Current state\nprogress pg01')"
  expect_eq "PG1 no confirm-plan turn marker is dropped" "$(pg_turn_markers pg01)" "0"
  expect_eq "PG1 no additionalContext is shown" "$(psf_hso "$PG_OUT" additionalContext)" ""
  expect_eq "PG1 no systemMessage is shown" "$(psf_sysmsg "$PG_OUT")" ""
  case "$PG_OUT" in
    *"/blob/"*|*"pg01-session-progress.md"*) fail "PG1 the hook output names no plan link" "out=$PG_OUT" ;;
    *) pass "PG1 the hook output names no plan link" ;;
  esac

  echo "=== PG1b: a second edit of the same session-progress.md is sent too, and git keeps both ==="
  PG_SUFFIX=" v2" pg_write pg01 "$PG_GH" "$PG_GL"
  expect_eq "PG1b the remote holds the second version" "$(pg_remote pg01)" "$(printf '## Current state\nprogress pg01 v2')"
  expect_eq "PG1b the remote history holds both versions, oldest first" "$(pg_history pg01)" \
    "## Current state progress pg01 |## Current state progress pg01 v2 |"

  echo "=== PG2: session-progress.md written from a project on another host ==="
  pg_write pg02 "$PG_GL" "$PG_GH"
  expect_eq "PG2 the record says host-mismatch" \
    "$(psf_record_state "$PG" pg02-session-progress.md "$PSF_ORIGIN_E2E")" "host-mismatch"
  expect_eq "PG2 session-progress.md is not sent" "$(pg_remote pg02)" "absent"
  expect_eq "PG2 no confirm-plan turn marker is dropped" "$(pg_turn_markers pg02)" "0"

  echo "=== PG3: the progress record does not rename the plan records ==="
  printf 'plan pg03\n' > "$PG/pg03-intent.md"
  PG_OUT="$(export WORKFLOW_PLANS_DIR="$PG"; cd "$PG_GL" || exit 1
    psf_hook "$PG_GL" show-plan-link.js "$(psf_write_json "$(psf_np "$PG/pg03-intent.md")" pg03 "$(psf_np "$PG_GH")")" 2>/dev/null)"
  expect_eq "PG3 the intent record keeps its name (<sid>-note-project-host-intent.json)" \
    "$([ -f "$PG/pg03-note-project-host-intent.json" ] && echo present || echo absent)" "present"
  expect_eq "PG3 the progress record sits beside it under its own kind" \
    "$([ -f "$PG/pg01-note-project-host-session-progress.json" ] && echo present || echo absent)" "present"
  expect_eq "PG3 the intent still drops its turn marker" "$([ "$(pg_turn_markers pg03)" -ge 1 ] && echo yes || echo no)" "yes"

  # PG4/PG5 run from a project on the destination host, so only the path boundary can stop the send.
  pg_records_of() { find "$PSF_ROOT" -name "$1-note-project-host-*" 2>/dev/null | wc -l | tr -d ' '; }

  echo "=== PG4: a <sid>-session-progress.md outside the plans dir is neither recorded nor sent ==="
  PG_OUTSIDE="$PSF_ROOT/pg-outside"
  mkdir -p "$PG_OUTSIDE"
  printf '## Current state\nprogress pg04 outside\n' > "$PG_OUTSIDE/pg04-session-progress.md"
  PG_OUT="$(export WORKFLOW_PLANS_DIR="$PG"; cd "$PG_GL" || exit 1
    psf_hook "$PG_GL" show-plan-link.js "$(psf_write_json "$(psf_np "$PG_OUTSIDE/pg04-session-progress.md")" pg04 "$(psf_np "$PG_GH")")" 2>/dev/null)"
  expect_eq "PG4 no project-host record is written anywhere" "$(pg_records_of pg04)" "0"
  expect_eq "PG4 the outside file is not sent" "$(pg_remote pg04)" "absent"
  expect_eq "PG4 the hook shows nothing" "$PG_OUT" ""

  echo "=== PG5: a symlink named <sid>-session-progress.md in the plans dir is neither recorded nor sent ==="
  PG_TARGET="$PSF_ROOT/pg-link-target"
  mkdir -p "$PG_TARGET"
  printf '## Current state\nprogress pg05 linked secret\n' > "$PG_TARGET/elsewhere.md"
  (export MSYS=winsymlinks:nativestrict; ln -s "$PG_TARGET/elsewhere.md" "$PG/pg05-session-progress.md") 2>/dev/null || true
  if [ ! -L "$PG/pg05-session-progress.md" ]; then
    rm -f "$PG/pg05-session-progress.md"
    skip "PG5 symlink cases: this host cannot create a symlink (Windows without Developer Mode)"
  else
    PG_OUT="$(export WORKFLOW_PLANS_DIR="$PG"; cd "$PG_GL" || exit 1
      psf_hook "$PG_GL" show-plan-link.js "$(psf_write_json "$(psf_np "$PG/pg05-session-progress.md")" pg05 "$(psf_np "$PG_GH")")" 2>/dev/null)"
    expect_eq "PG5 no project-host record is written for the symlink" "$(pg_records_of pg05)" "0"
    expect_eq "PG5 the symlink is not sent" "$(pg_remote pg05)" "absent"
    case "$(git -C "$PG_BARE" log --all -p 2>/dev/null)" in
      *"linked secret"*) fail "PG5 the link target's content never reaches the remote" "found on the bare remote" ;;
      *) pass "PG5 the link target's content never reaches the remote" ;;
    esac
  fi
fi

export PLAN_SYNC_REMOTE_URL=""
unset GIT_SSH_COMMAND GIT_SSH_VARIANT GIT_SSH_STUB_BARE
