#!/usr/bin/env bash
# tests/lib/spawn-record.sh — sourced. Reads the JSONL that tests/fixtures/spawn-record-preload.js
# writes (#2590).
#   spawn_record_count <file> [cmd]   number of records, or of records whose "cmd" is <cmd>;
#                                     0 when <file> does not exist

spawn_record_count() {
  local file="${1:-}" cmd="${2:-}" line n=0
  [[ -n "$file" ]] || { echo "spawn_record_count: file required" >&2; return 2; }
  if [[ -f "$file" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ -n "${line//[[:space:]]/}" ]] || continue
      if [[ -z "$cmd" || "$line" == *"\"cmd\":\"$cmd\""* ]]; then n=$((n + 1)); fi
    done <"$file"
  fi
  printf '%s\n' "$n"
}
