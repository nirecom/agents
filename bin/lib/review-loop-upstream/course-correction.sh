#!/usr/bin/env bash
# bin/lib/review-loop-upstream/course-correction.sh — the record file of decide --choice
# course-correction (#2814 R6). Sourced by bin/review-loop-upstream only (reads its SELF_DIR);
# no `set -e` (a sourced library). Extraction itself: bin/course-correction-record extract.

# rlu_cc_own_transcript <sid> <transcript> — rc 0 only when <transcript> is the file `locate
# --session <sid>` resolves, printing that located path (fail-closed): rc 3 none located,
# rc 2 another file, rc 1 locate failed. Callers read the printed path, never <transcript>.
rlu_cc_own_transcript() {
    local loc rc=0
    loc="$(node "$SELF_DIR/course-correction-record" locate --session "$1")" || rc=$?
    case "$rc" in 0) ;; 3) return 3 ;; *) return 1 ;; esac
    [ -n "$loc" ] || return 3
    # shellcheck disable=SC2016 # a JavaScript program, expanded by node, not by the shell
    node -e '
const path = require("path");
const win = process.platform === "win32";
const norm = (s) => {
  let p = win ? s.trim().replace(/\\/g, "/") : s.trim();
  const m = /^\/([a-zA-Z])(\/.*)?$/.exec(p);
  if (win && m) p = `${m[1].toUpperCase()}:${m[2] || "/"}`;
  p = path.resolve(p).replace(/\\/g, "/");
  return win ? p.toLowerCase() : p;
};
process.exit(norm(process.argv[1]) === norm(process.argv[2]) ? 0 : 2);
' -- "$2" "$loc" || return 2  # `--`: a leading-dash <transcript> is never a node option
    printf '%s' "$loc"
}

# rlu_cc_write_record <ctl> <fmt> <cycle> <id> <transcript> <uuid> — writes
# <ctl>/<fmt>-course-correction-c<cycle>-<id>.md and prints its path; rc 3 when the transcript
# holds no real user prompt with that uuid, rc 1 on any other failure.
rlu_cc_write_record() {
    local rec="$1/$2-course-correction-c$3-$4.md" rc=0
    node "$SELF_DIR/course-correction-record" extract --transcript "$5" --uuid "$6" --out "$rec" >&2 || rc=$?
    case "$rc" in
        0) printf '%s' "$rec" ;;
        3) return 3 ;;
        *) return 1 ;;
    esac
}
