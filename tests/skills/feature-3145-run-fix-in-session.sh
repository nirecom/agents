#!/usr/bin/env bash
# feature-3145-run-fix-in-session.sh — #3145 S5: fix-in-session hand-back and Phase 5 --finding-key.
# Tests: skills/issue-create/scripts/run-fix-in-session.sh, skills/issue-create/scripts/run-phase5-record.sh
# Tags: TL2, scope:issue-specific, issue-create, fix-in-session, finding-key, worktree-notes, this-pr, fail-closed, pwsh-not-required
# TL2: both scripts run as real subprocesses against a throwaway git repo (feature branch) holding
# WORKTREE_NOTES.md; the notes are read back through the real worktree-notes-triage.js open-this-pr.
# No forge is reached: Phase 5 reads a fixed dispatch URL from --input-file.
set -uo pipefail
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

# TL3 gap (not caught here): /issue-create choosing the fix-in-session verdict from a live survey,
# and the skill relaying the script's lines to the user and stopping.
# Closest-to-action mitigation: validate-review-verdict.js grammar (T7) and the write_code this-pr refusal (T4).
# category: skill-orchestration.

readonly T_ROOT="$(make_tmp)"
harness_isolate "$T_ROOT"
trap 'cd /; rm -rf "$T_ROOT"' EXIT
unset CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID
export ENFORCE_WORKTREE=on DEFAULT_BRANCHES=main
unset GITLAB_HOSTNAME GITLAB_SSH_HOSTNAME

ROOT_M="$(np "$SCRIPT_CHECKOUT_ROOT")"
FIX_SH="$SCRIPT_CHECKOUT_ROOT/skills/issue-create/scripts/run-fix-in-session.sh"
P5_SH="$SCRIPT_CHECKOUT_ROOT/skills/issue-create/scripts/run-phase5-record.sh"
TRIAGE_JS="$ROOT_M/bin/worktree-notes-triage.js"

REPO="$T_ROOT/repo"
harness_git_init "$REPO"
git -C "$REPO" config user.email t@example.com
git -C "$REPO" config user.name t
git -C "$REPO" config core.autocrlf false
printf 'base\n' > "$REPO/README.md"
git -C "$REPO" add README.md
git -C "$REPO" commit -q -m base
git -C "$REPO" branch -M main
git -C "$REPO" checkout -q -b feature/3145-fx
HEAD_SHA="$(git -C "$REPO" rev-parse HEAD)"
NOTES="$REPO/WORKTREE_NOTES.md"
NOTES_M="$(np "$NOTES")"
cd "$REPO" || exit 1

check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "want=[$3] got=[$2]"; fi; }
check_contains() { case "$2" in *"$3"*) pass "$1" ;; *) fail "$1" "missing [$3] in: $(printf '%s' "$2" | head -c 600)" ;; esac; }
check_not_contains() { case "$2" in *"$3"*) fail "$1" "unexpected [$3] in: $(printf '%s' "$2" | head -c 600)" ;; *) pass "$1" ;; esac; }

# key <section> <body> — the finding key: first 8 hex of sha256("<section>\n<body>").
key() { node -e 'process.stdout.write(require("crypto").createHash("sha256").update(process.argv[1]+"\n"+process.argv[2]).digest("hex").slice(0,8))' "$1" "$2"; }
# open_keys <notes> — comma-joined keys open-this-pr reports, or ERR:<...> when it cannot answer.
open_keys() {
  local out
  out="$(run_with_timeout 60 node "$TRIAGE_JS" open-this-pr "$1" 2>&1)"
  printf '%s' "$out" | node -e 'let b="";process.stdin.on("data",c=>b+=c).on("end",()=>{try{const j=JSON.parse(b);process.stdout.write((j.open||[]).map(o=>o.key).join(","))}catch(_){process.stdout.write("ERR:"+b.slice(0,200).replace(/\n/g," "))}})'
}
sha() { node -e 'process.stdout.write(require("crypto").createHash("sha256").update(require("fs").readFileSync(process.argv[1])).digest("hex"))' "$1"; }
count_lines() { grep -cF -- "$2" "$1" || true; }

write_notes() { printf '# Worktree Notes\n\n## BugsFound\n%s\n\n## RelatedTasks\n' "$1" > "$NOTES"; }

# art <file> <closes_session of #20> — a schema-3 final artifact: verdict fix-in-session, target #20;
# #10 is a plain search hit.
art() {
  node -e '
    const cs = process.argv[2] === "absent" ? {} : { closes_session: process.argv[2] === "true" };
    const cand = (n, x) => Object.assign({ number: n, title: "c" + n, state: "open", labels: [], body: "b" + n,
      relation_status: "resolved", parent_number: null, parent_is_meta: false, has_sub_issues: false }, x || {});
    require("fs").writeFileSync(process.argv[1], JSON.stringify({
      schema_version: 3, proposal: { title: "P", background: "B", changes: "C" },
      verdict: "fix-in-session", target: 20, children: [], related: [], reason: "goal of #20", same_fix: true,
      relations_mode: "batched", relation_errors: [], candidates: [cand(10), cand(20, cs)] }, null, 2));
  ' "$1" "$2"
}
ART_OK="$(np "$T_ROOT/art-ok.json")";        art "$ART_OK" true
ART_FALSE="$(np "$T_ROOT/art-false.json")";  art "$ART_FALSE" false
ART_ABSENT="$(np "$T_ROOT/art-absent.json")"; art "$ART_ABSENT" absent

fix() { run_with_timeout 60 bash "$FIX_SH" "$@" >"$T_ROOT/fix.out" 2>&1; echo "$?"; }

RESCOPED_BODY="Parser drops trailing marker"
RESCOPED_LINE="- $RESCOPED_BODY <!-- severity: medium --> <!-- pr-scope: other --> <!-- rescoped-from: this-pr -->"
K_RESCOPED="$(key BugsFound "$RESCOPED_BODY")"

case_begin "run-fix-in-session: --finding-key unrescopes the entry back to this-pr" "skills/issue-create/scripts/run-fix-in-session.sh"
write_notes "$RESCOPED_LINE"
rc="$(fix "$ART_OK" "$NOTES_M" --closes 20,21 --title "Fix parser" --finding-key "$K_RESCOPED")"
check "keyed: exit 0" "$rc" "0"
body="$(cat "$NOTES")"
check_contains "keyed: entry is pr-scope this-pr again" "$body" "- $RESCOPED_BODY <!-- severity: medium --> <!-- pr-scope: this-pr -->"
check_not_contains "keyed: rescoped-from marker removed" "$body" "rescoped-from"
check "keyed: no goal entry appended" "$(count_lines "$NOTES" "(goal of #20)")" "0"
check "keyed: the entry is open as this-pr" "$(open_keys "$NOTES_M")" "$K_RESCOPED"
# Adversarial: a key that names no entry writes nothing and does not succeed.
write_notes "$RESCOPED_LINE"
before="$(sha "$NOTES")"
rc="$(fix "$ART_OK" "$NOTES_M" --closes 20 --title "Fix parser" --finding-key deadbeef)"
check "unknown key: non-zero exit" "$( [ "$rc" != "0" ] && echo yes || echo "no (rc=$rc)")" "yes"
check "unknown key: notes unchanged" "$(sha "$NOTES")" "$before"
case_end

case_begin "run-fix-in-session: without a key it appends one this-pr goal entry (body, base, idempotent)" "skills/issue-create/scripts/run-fix-in-session.sh"
write_notes "- Something else <!-- severity: low --> <!-- pr-scope: other -->"
rc="$(fix "$ART_OK" "$NOTES_M" --closes 20,21 --title "Handle empty input" --severity high)"
check "append: exit 0" "$rc" "0"
line="$(grep -F "Handle empty input (goal of #20)" "$NOTES" || true)"
check_contains "append: body names the goal issue" "$line" "- Handle empty input (goal of #20) <!--"
check_contains "append: severity kept" "$line" "<!-- severity: high -->"
check_contains "append: pr-scope this-pr" "$line" "<!-- pr-scope: this-pr -->"
check_contains "append: base is the notes repo HEAD" "$line" "<!-- base: $HEAD_SHA -->"
sect="$(awk '/^## /{s=$0} index($0,"(goal of #20)"){print s}' "$NOTES")"
check "append: written under RelatedTasks" "$sect" "## RelatedTasks"
check "append: the goal entry is open" "$(open_keys "$NOTES_M")" "$(key RelatedTasks "Handle empty input (goal of #20)")"
rc="$(fix "$ART_OK" "$NOTES_M" --closes 20,21 --title "Handle empty input" --severity high)"
check "append rerun: exit 0" "$rc" "0"
check "append rerun: still exactly one entry" "$(count_lines "$NOTES" "Handle empty input (goal of #20)")" "1"
# `auto` resolves the notes from the git toplevel of $PWD (the fixture repo).
rc="$(fix "$ART_OK" auto --closes 20 --title "Second goal item")"
check "auto: exit 0" "$rc" "0"
check "auto: entry written to the toplevel notes" "$(count_lines "$NOTES" "Second goal item (goal of #20)")" "1"
case_end

# Rows: <name> | <artifact> | <--closes value> — each refuses with exit 2 and leaves the notes alone.
case_begin "run-fix-in-session: target outside the session's closes set exits 2 without writing" "skills/issue-create/scripts/run-fix-in-session.sh"
while IFS='|' read -r name artv closes; do
  [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
  name="${name//[[:space:]]/}"; artv="${artv//[[:space:]]/}"; closes="${closes//[[:space:]]/}"
  case "$artv" in ok) a="$ART_OK" ;; false) a="$ART_FALSE" ;; *) a="$ART_ABSENT" ;; esac
  write_notes "$RESCOPED_LINE"
  before="$(sha "$NOTES")"
  rc="$(fix "$a" "$NOTES_M" --closes "$closes" --title "Refused item")"
  check "$name: exit 2" "$rc" "2"
  check "$name: notes unchanged" "$(sha "$NOTES")" "$before"
  rc="$(fix "$a" "$NOTES_M" --closes "$closes" --title "Refused item" --finding-key "$K_RESCOPED")"
  check "$name (keyed): exit 2" "$rc" "2"
  check "$name (keyed): notes unchanged" "$(sha "$NOTES")" "$before"
done <<'TABLE'
closes-session-false  | false  | 20,21
closes-session-absent | absent | 20
target-not-in-closes  | ok     | 21,22
closes-empty          | ok     |
closes-prefix-only    | ok     | 200
TABLE
case_end

case_begin "run-fix-in-session: a failed notes write exits 1" "skills/issue-create/scripts/run-fix-in-session.sh"
BAD="$T_ROOT/notes-dir"
mkdir -p "$BAD"
rc="$(fix "$ART_OK" "$(np "$BAD")" --closes 20 --title "Cannot write")"
check "notes path is a directory: exit 1" "$rc" "1"
check "notes path is a directory: still a directory" "$( [ -d "$BAD" ] && echo yes || echo no)" "yes"
case_end

URLS="$T_ROOT/dispatch.txt"
printf 'https://github.com/example/repo/issues/77\n' > "$URLS"
URLS_M="$(np "$URLS")"
p5() { run_with_timeout 60 bash "$P5_SH" none "$NOTES_M" "Follow-up title" "" --input-file "$URLS_M" "$@" 2>&1; echo "RC=$?"; }

case_begin "run-phase5-record: --finding-key annotates the rescoped entry and appends no pointer" "skills/issue-create/scripts/run-phase5-record.sh"
write_notes "$RESCOPED_LINE"
check "precondition: rescoped-unfiled entry is open" "$(open_keys "$NOTES_M")" "$K_RESCOPED"
out="$(p5 --finding-key "$K_RESCOPED")"
check_contains "keyed: exit 0" "$out" "RC=0"
check_contains "keyed: entry carries the promoted marker" "$(grep -F "$RESCOPED_BODY" "$NOTES" || true)" "<!-- promoted: #77 -->"
check "keyed: #77 named on exactly one line (no pointer)" "$(count_lines "$NOTES" "#77")" "1"
check_not_contains "keyed: no unsettled line" "$out" "finding-key unsettled"
check "keyed: nothing left open" "$(open_keys "$NOTES_M")" ""
case_end

case_begin "run-phase5-record: an unresolvable --finding-key prints a settle command that works" "skills/issue-create/scripts/run-phase5-record.sh"
# The user edited the entry after rescope, so the recorded key no longer resolves.
EDITED_BODY="Parser drops trailing marker (edited)"
write_notes "- $EDITED_BODY <!-- severity: medium --> <!-- pr-scope: other --> <!-- rescoped-from: this-pr -->"
K_EDITED="$(key BugsFound "$EDITED_BODY")"
out="$(p5 --finding-key "$K_RESCOPED")"
check_contains "unsettled: exit 0" "$out" "RC=0"
uline="$(printf '%s\n' "$out" | grep -F 'finding-key unsettled:' | head -n 1)"
check_contains "unsettled: names key, issue and reason" "$uline" "finding-key unsettled: key=$K_RESCOPED issue=#77 reason=not-found"
check_contains "unsettled: settle command" "$uline" "/bin/worktree-notes-triage.js\" annotate "
check "unsettled: Mode A pointer appended" "$(count_lines "$NOTES" "(#77) <!-- promoted: #77 -->")" "1"
check "unsettled: edited entry still open" "$(open_keys "$NOTES_M")" "$K_EDITED"
# Run the printed command with the root and the entry ref filled in.
lineno="$(grep -nF -- "- $EDITED_BODY" "$NOTES" | head -n 1 | cut -d: -f1)"
settle="$(printf '%s' "$uline" | sed -n 's/^.*settle: //p')"
settle="${settle//\$AGENTS_MAIN_ROOT/$ROOT_M}"
settle="$(printf '%s' "$settle" | sed -E "s/<lineNumber\|key=[0-9a-f]{8}>|key=[0-9a-f]{8}|<lineNumber[^>]*>/$lineno/")"
check_contains "unsettled: settle command targets the notes file" "$settle" "$NOTES_M"
if [ -n "$settle" ]; then
  srun="$(eval "run_with_timeout 60 $settle" 2>&1; echo "RC=$?")"
  check_contains "settle: exit 0" "$srun" "RC=0"
fi
check "settle: nothing left open" "$(open_keys "$NOTES_M")" ""
case_end

case_begin "run-phase5-record: a --finding-key matching two entries is reported ambiguous, never guessed" "skills/issue-create/scripts/run-phase5-record.sh"
# The same section + body twice gives one key for two entries; annotating either would be a guess.
write_notes "$(printf '%s\n%s' "$RESCOPED_LINE" "$RESCOPED_LINE")"
out="$(p5 --finding-key "$K_RESCOPED")"
check_contains "ambiguous: exit 0" "$out" "RC=0"
uline="$(printf '%s\n' "$out" | grep -F 'finding-key unsettled:' | head -n 1)"
check_contains "ambiguous: unsettled line names reason=ambiguous" "$uline" "finding-key unsettled: key=$K_RESCOPED issue=#77 reason=ambiguous"
check "ambiguous: Mode A pointer appended" "$(count_lines "$NOTES" "(#77) <!-- promoted: #77 -->")" "1"
check "ambiguous: neither duplicate annotated" "$(grep -F -- "- $RESCOPED_BODY <!--" "$NOTES" | grep -cF 'promoted' || true)" "0"
case_end

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
exit "$FAIL"
