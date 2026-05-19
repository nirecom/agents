#!/usr/bin/env bash
# state.sh — .migration-state.json helpers for migrate-repo workflow.
# Source this file: source "$(dirname "$0")/state.sh"
# NOTE: do NOT `set -e` here — this file is sourced. Functions return non-zero
# as part of normal semantics (state_is_migrated, state_should_resume).

_state_file() { echo "${1:?repo_dir required}/.migration-state.json"; }

state_init() {
  local repo_dir="$1"
  local f; f="$(_state_file "$repo_dir")"
  [ -f "$f" ] && return 0
  local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local abs; abs="$(cd "$repo_dir" && pwd)"
  local tmp; tmp="${f}.tmp"
  jq -n \
    --arg ts "$ts" \
    --arg repo "$abs" \
    '{schema_version:1,repo_dir:$repo,started_at:$ts,current_step:0,
      history:{total_entries:0,migrated:[]},
      todo:{total_entries:0,migrated:[],todo_md_rewritten:false},
      project:{number:null,node_id:null,field_ids:{}}}' \
    > "$tmp"
  mv "$tmp" "$f"
}

state_load() {
  local repo_dir="$1"
  export STATE_FILE; STATE_FILE="$(_state_file "$repo_dir")"
  [ -f "$STATE_FILE" ] || { echo "ERROR: state file not found: $STATE_FILE" >&2; return 1; }
  local ver; ver="$(jq -r '.schema_version' "$STATE_FILE")"
  [ "$ver" = "1" ] || { echo "ERROR: unsupported schema_version=$ver" >&2; return 1; }
}

state_is_migrated() {
  local kind="$1" entry_id="$2"
  : "${STATE_FILE:?call state_load first}"
  jq -e --arg k "$kind" --arg id "$entry_id" \
    '.[$k].migrated[] | select(.entry_id == $id)' "$STATE_FILE" >/dev/null 2>&1
}

state_record_migrated() {
  local kind="$1" entry_id="$2" issue_num="$3" title="$4"
  : "${STATE_FILE:?call state_load first}"
  # No-op if already recorded (idempotent).
  state_is_migrated "$kind" "$entry_id" 2>/dev/null && return 0
  local tmp; tmp="${STATE_FILE}.tmp"
  jq --arg k "$kind" --arg id "$entry_id" --argjson n "$issue_num" --arg t "$title" \
    '.[$k].migrated += [{entry_id:$id,issue_number:$n,title:$t}]' \
    "$STATE_FILE" > "$tmp"
  mv "$tmp" "$STATE_FILE"
}

state_count_migrated() {
  local kind="$1"
  : "${STATE_FILE:?call state_load first}"
  jq -r --arg k "$kind" '.[$k].migrated | length' "$STATE_FILE"
}

state_set_step() {
  local n="$1"
  : "${STATE_FILE:?call state_load first}"
  local tmp; tmp="${STATE_FILE}.tmp"
  jq --argjson n "$n" '.current_step = $n' "$STATE_FILE" > "$tmp"
  mv "$tmp" "$STATE_FILE"
}

state_set_project() {
  local number="$1" node_id="$2" field_ids_json="$3"
  : "${STATE_FILE:?call state_load first}"
  local tmp; tmp="${STATE_FILE}.tmp"
  jq --argjson num "$number" --arg nid "$node_id" --argjson fids "$field_ids_json" \
    '.project = {number:$num,node_id:$nid,field_ids:$fids}' \
    "$STATE_FILE" > "$tmp"
  mv "$tmp" "$STATE_FILE"
}

state_get_project_field_id() {
  local name="$1"
  : "${STATE_FILE:?call state_load first}"
  jq -r --arg n "$name" '.project.field_ids[$n] // empty' "$STATE_FILE"
}

state_cleanup() {
  local repo_dir="$1"
  local f; f="$(_state_file "$repo_dir")"
  [ -f "$f" ] && rm -f "$f"
  return 0
}

state_should_resume() {
  local kind="$1" total="$2"
  local migrated threshold
  migrated=$(state_count_migrated "$kind")
  threshold=$(( total / 20 ))
  [ "$threshold" -eq 0 ] && threshold=1
  [ "$migrated" -ge "$threshold" ]
}
