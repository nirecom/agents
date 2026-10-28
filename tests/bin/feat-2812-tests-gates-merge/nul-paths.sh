# Tests: bin/lib/merge-parents.sh
# Tags: TL2, bin, merge, merge-parents, tests-gates, scope:issue-specific
# The bash reader of the bin/merge-parents record stream: a path holding a tab or a newline travels
# as its own NUL record, so mp_load_file / mp_in_parent / mp_baselines map every field to the right
# path and a neighbouring plain path is not shifted. No file with such a name is made on disk:
# the reader case uses a printf'd record file, the CLI cases (not merging, and merging with R4 / R6)
# index-only entries. Also: a table of malformed record files (each falls back to HEAD-only) and
# 64-hex oids from a SHA-256 repo.
# Sourced by tests/bin/feat-2812-tests-gates-merge-shapes.sh after fixture.sh.
# shellcheck shell=bash

echo ""
echo "=== merge-parents.sh reader: tab / newline paths ==="

MP_LIB="$SCRIPT_CHECKOUT_ROOT/bin/lib/merge-parents.sh"
TAB=$'\t'
LF=$'\n'

# mp_probe <repo> <record-file|-> <label>:<rel>... — in a subshell (cwd <repo>): source the reader,
# with "-" first run `mp_run` for the rels into a temp record file, then mp_load_file it, and print
# `state=`, `count=` and one `<label>=<in_parent>|<same>|<b1>|<b2>|<base>` line per rel.
mp_probe() {
  local repo="$1" file="$2"
  shift 2
  (
    cd "$repo" || exit 3
    if [ ! -f "$MP_LIB" ]; then echo "lib=missing"; exit 0; fi
    # shellcheck source=/dev/null
    . "$MP_LIB" || { echo "lib=unsourceable"; exit 0; }
    local p rels=()
    for p in "$@"; do rels+=("${p#*:}"); done
    if [ "$file" = "-" ]; then
      file="$TMPBASE/mp-probe.records"
      mp_run "$SCRIPT_CHECKOUT_ROOT/bin" "$file" "${rels[@]}" || echo "run-rc=$?"
    fi
    mp_load_file "$file" || echo "load-rc=$?"
    echo "state=${MP_STATE:-}"
    echo "count=${#MP_RELS[@]}"
    local ip
    for p in "$@"; do
      if mp_in_parent "${p#*:}"; then ip=1; else ip=0; fi
      mp_baselines "${p#*:}"
      echo "${p%%:*}=$ip|${MP_OUT_SAME:-}|${MP_OUT_B1:-}|${MP_OUT_B2:-}|${MP_OUT_BASE:-}"
    done
  ) 2>"$TMPBASE/mp-probe.err"
}
# probe_get <probe-output> <key> — the value of `<key>=` in the probe output ("(absent)" if none).
probe_get() {
  local line
  while IFS= read -r line; do
    [ "${line%%=*}" = "$2" ] && { printf '%s' "${line#*=}"; return; }
  done <<< "$1"
  printf '(absent)'
}
# expect_probe <label> <probe-output> <key> <want>
expect_probe() { assert_eq "$1: $3=$(probe_get "$2" "$3")" "$1: $3=$4"; }

O1=1111111111111111111111111111111111111111
O2=2222222222222222222222222222222222222222
O3=3333333333333333333333333333333333333333
O4=4444444444444444444444444444444444444444
O5=5555555555555555555555555555555555555555
O6=6666666666666666666666666666666666666666
O7=7777777777777777777777777777777777777777
P_TAB="tests/bin/tab${TAB}name.sh"
P_PLAIN="tests/bin/plain.sh"
P_NL="tests/bin/nl${LF}name.sh"
P_BOTH="tests/bin/both${TAB}x${LF}y.sh"
P_LAST="tests/bin/last.sh"

case_begin "reader-maps-tab-and-newline-paths-from-nul-records" "bin/lib/merge-parents.sh"
R="$TMPBASE/mp-reader"
mkrepo "$R"
REC="$TMPBASE/mp-reader.records"
printf '%s\0' "state${TAB}merging${TAB}-" \
  "1${TAB}0${TAB}$O1${TAB}$O2${TAB}$O3" "$P_TAB" \
  "1${TAB}1${TAB}$O4${TAB}-${TAB}-" "$P_PLAIN" \
  "1${TAB}0${TAB}$O5${TAB}-${TAB}-" "$P_NL" \
  "0${TAB}0${TAB}-${TAB}-${TAB}-" "$P_BOTH" \
  "1${TAB}0${TAB}$O6${TAB}$O7${TAB}-" "$P_LAST" > "$REC"
OUT="$(mp_probe "$R" "$REC" "tab:$P_TAB" "plain:$P_PLAIN" "nl:$P_NL" "both:$P_BOTH" "last:$P_LAST" \
  "tabhead:tests/bin/tab" "nlhead:tests/bin/nl" "nltail:name.sh")"
expect_probe "reader" "$OUT" lib "(absent)"
expect_probe "reader" "$OUT" load-rc "(absent)"
expect_probe "reader" "$OUT" state merging
expect_probe "reader: five records, no split on tab or newline" "$OUT" count 5
expect_probe "reader: tab path R6" "$OUT" tab "1|0|$O1|$O2|$O3"
expect_probe "reader: plain path after it not shifted (R1)" "$OUT" plain "1|1|$O4||"
expect_probe "reader: newline path R4" "$OUT" nl "1|0|$O5||"
expect_probe "reader: tab+newline path R2" "$OUT" both "0|0|||"
expect_probe "reader: last plain path keeps its fields (R6, no base)" "$OUT" last "1|0|$O6|$O7|"
expect_probe "reader: text before the tab is not a path" "$OUT" tabhead "0|0|||"
expect_probe "reader: text before the newline is not a path" "$OUT" nlhead "0|0|||"
expect_probe "reader: text after the newline is not a path" "$OUT" nltail "0|0|||"
case_end

# stage_name <repo> <rel> <body> — the blob stored under <rel> in the index only; prints its oid.
stage_name() {
  local oid
  oid="$(printf '%s\n' "$3" | git -C "$1" hash-object -w --stdin)"
  git -C "$1" update-index --add --cacheinfo "100644,$oid,$2"
  printf '%s' "$oid"
}

# Paths carrying shell metacharacters are data end to end: no command substitution, separator or
# backtick in a path runs (each would create its sentinel file in the probe's cwd).
# shellcheck disable=SC2016 # the paths hold literal $(...) and backticks on purpose
P_SUB='tests/bin/$(touch PWNED_SUB).sh'
P_SEMI='tests/bin/a;touch PWNED_SEMI;.sh'
# shellcheck disable=SC2016
P_TICK='tests/bin/`touch PWNED_TICK`.sh'
# no_sentinels <label> <dir>... — none of the PWNED_* files exists in any <dir>.
no_sentinels() {
  local label="$1" d s found=""
  shift
  for d in "$@"; do
    for s in PWNED_SUB PWNED_SEMI PWNED_TICK; do
      [ -e "$d/$s" ] && found="$found $d/$s"
    done
  done
  assert_eq "$label: sentinel files=[${found# }]" "$label: sentinel files=[]"
}

case_begin "reader-and-cli-treat-shell-metacharacter-paths-as-data" "bin/lib/merge-parents.sh"
R="$TMPBASE/mp-meta"
mkrepo "$R"
REC="$TMPBASE/mp-meta.records"
printf '%s\0' "state${TAB}merging${TAB}-" \
  "1${TAB}0${TAB}$O1${TAB}$O2${TAB}$O3" "$P_SUB" \
  "1${TAB}1${TAB}$O4${TAB}-${TAB}-" "$P_SEMI" \
  "1${TAB}0${TAB}$O5${TAB}-${TAB}-" "$P_TICK" \
  "1${TAB}0${TAB}$O6${TAB}$O7${TAB}-" "$P_LAST" > "$REC"
OUT="$(mp_probe "$R" "$REC" "sub:$P_SUB" "semi:$P_SEMI" "tick:$P_TICK" "last:$P_LAST")"
expect_probe "meta reader" "$OUT" load-rc "(absent)"
expect_probe "meta reader" "$OUT" state merging
expect_probe "meta reader: four records" "$OUT" count 4
expect_probe "meta reader: \$(...) path R6" "$OUT" sub "1|0|$O1|$O2|$O3"
expect_probe "meta reader: ; path R1" "$OUT" semi "1|1|$O4||"
expect_probe "meta reader: backtick path R4" "$OUT" tick "1|0|$O5||"
expect_probe "meta reader: plain path after them not shifted" "$OUT" last "1|0|$O6|$O7|"
no_sentinels "meta reader" "$R" "$TMPBASE"
S_OID="$(stage_name "$R" "$P_SUB" sub)"
git -C "$R" commit -q -m "fixture: metacharacter path" >/dev/null 2>&1
stage_name "$R" "$P_SEMI" semi >/dev/null
stage_name "$R" "$P_TICK" tick >/dev/null
OUT="$(mp_probe "$R" - "sub:$P_SUB" "semi:$P_SEMI" "tick:$P_TICK" "plain:bin/a.sh")"
A_OID="$(git -C "$R" rev-parse HEAD:bin/a.sh)"
expect_probe "meta cli" "$OUT" run-rc "(absent)"
expect_probe "meta cli" "$OUT" load-rc "(absent)"
expect_probe "meta cli" "$OUT" state not-merging
expect_probe "meta cli: one record per requested path" "$OUT" count 4
expect_probe "meta cli: \$(...) path equal to HEAD (R1)" "$OUT" sub "1|1|$S_OID||"
expect_probe "meta cli: ; path new (R2)" "$OUT" semi "0|0|||"
expect_probe "meta cli: backtick path new (R2)" "$OUT" tick "0|0|||"
expect_probe "meta cli: plain path after them not shifted (R1)" "$OUT" plain "1|1|$A_OID||"
no_sentinels "meta cli" "$R" "$TMPBASE"
case_end

case_begin "cli-records-for-tab-and-newline-paths-load-through-the-reader" "bin/lib/merge-parents.sh"
R="$TMPBASE/mp-cli"
mkrepo "$R"
# Git for Windows refuses tab / newline index names under core.protectNTFS; no worktree file is made.
git -C "$R" config core.protectNTFS false
T_OID="$(stage_name "$R" "$P_TAB" tab)"
N_OID="$(stage_name "$R" "$P_NL" newline)"
git -C "$R" commit -q -m "fixture: tab and newline paths" >/dev/null 2>&1
stage_name "$R" "$P_NL" "newline edited" >/dev/null
stage_name "$R" "$P_BOTH" new >/dev/null
assert_eq "precondition: HEAD has the tab path=$(git -C "$R" rev-parse -q --verify "HEAD:$P_TAB")" \
  "precondition: HEAD has the tab path=$T_OID"
OUT="$(mp_probe "$R" - "tab:$P_TAB" "nl:$P_NL" "both:$P_BOTH" "plain:bin/a.sh")"
A_OID="$(git -C "$R" rev-parse HEAD:bin/a.sh)"
expect_probe "cli" "$OUT" lib "(absent)"
expect_probe "cli" "$OUT" run-rc "(absent)"
expect_probe "cli" "$OUT" load-rc "(absent)"
expect_probe "cli" "$OUT" state not-merging
expect_probe "cli: one record per requested path" "$OUT" count 4
expect_probe "cli: tab path equal to HEAD (R1)" "$OUT" tab "1|1|$T_OID||"
expect_probe "cli: newline path edited (R3)" "$OUT" nl "1|0|$N_OID||"
expect_probe "cli: tab+newline path new (R2)" "$OUT" both "0|0|||"
expect_probe "cli: plain path after them not shifted (R1)" "$OUT" plain "1|1|$A_OID||"
case_end

# A merge built from plumbing alone (Windows cannot check out these names, so `git merge` is not
# used): base B, HEAD = B + the tab path edited, MERGE_HEAD = B + the tab path edited otherwise and
# the newline path added; MERGE_HEAD is written by hand and the resolution is staged index-only.
case_begin "cli-records-for-tab-and-newline-paths-during-a-merge" "bin/lib/merge-parents.sh"
R="$TMPBASE/mp-merge"
mkrepo "$R"
git -C "$R" config core.protectNTFS false
B_TAB="$(stage_name "$R" "$P_TAB" "tab base")"
git -C "$R" commit -q -m "fixture: base" >/dev/null 2>&1
B_COMMIT="$(git -C "$R" rev-parse HEAD)"
H_TAB="$(stage_name "$R" "$P_TAB" "tab head")"
git -C "$R" commit -q -m "fixture: head" >/dev/null 2>&1
git -C "$R" read-tree "$B_COMMIT"
M_TAB="$(stage_name "$R" "$P_TAB" "tab up")"
M_NL="$(stage_name "$R" "$P_NL" "newline up")"
M_COMMIT="$(git -C "$R" commit-tree "$(git -C "$R" write-tree)" -p "$B_COMMIT" -m "fixture: up")"
git -C "$R" read-tree HEAD
printf '%s\n' "$M_COMMIT" > "$R/$(git -C "$R" rev-parse --git-path MERGE_HEAD)"
stage_name "$R" "$P_TAB" "tab merged" >/dev/null
stage_name "$R" "$P_NL" "newline up, edited in the merge" >/dev/null
stage_name "$R" "$P_BOTH" new >/dev/null
assert_eq "precondition: MERGE_HEAD=$(git -C "$R" rev-parse -q --verify MERGE_HEAD)" "precondition: MERGE_HEAD=$M_COMMIT"
assert_eq "precondition: one merge-base=$(git -C "$R" merge-base --all HEAD MERGE_HEAD)" \
  "precondition: one merge-base=$B_COMMIT"
assert_eq "precondition: HEAD lacks the newline path=$(git -C "$R" cat-file -e "HEAD:$P_NL" 2>/dev/null || echo yes)" \
  "precondition: HEAD lacks the newline path=yes"
OUT="$(mp_probe "$R" - "tab:$P_TAB" "nl:$P_NL" "both:$P_BOTH" "plain:bin/a.sh")"
A_OID="$(git -C "$R" rev-parse HEAD:bin/a.sh)"
expect_probe "cli merge" "$OUT" lib "(absent)"
expect_probe "cli merge" "$OUT" run-rc "(absent)"
expect_probe "cli merge" "$OUT" load-rc "(absent)"
expect_probe "cli merge" "$OUT" state merging
expect_probe "cli merge: one record per requested path" "$OUT" count 4
expect_probe "cli merge: tab path 3-way (R6)" "$OUT" tab "1|0|$H_TAB|$M_TAB|$B_TAB"
expect_probe "cli merge: newline path from MERGE_HEAD only (R4)" "$OUT" nl "1|0|$M_NL||"
expect_probe "cli merge: tab+newline path new (R2)" "$OUT" both "0|0|||"
expect_probe "cli merge: plain path after them not shifted (R1)" "$OUT" plain "1|1|$A_OID||"
case_end

# Malformed record files: every row falls back as a whole (state=fallback, no record kept, even one
# loaded before the bad record), and mp_find then synthesizes the HEAD-only record (R1 / R2).
# Columns: name | mode (nul / no-last-nul / empty / none = no file) | records | want.
# records: comma-separated; H = merging header, G = meta record for O1, X = tests/bin/x.sh, EMPTY = ""
# path, else literal with \t = tab and <O1> <O2> <OA> (O1 uppercase) <OG> (O3, g for 3) substituted.
# want: <state>:<count>:<x>:<y>:<plain> probe fields (/ for |, - = not asserted, <A> = HEAD bin/a.sh);
# FB = fallback with no record kept, x / y synthesized new (R2) and plain HEAD-only (R1).
MB_H="state${TAB}merging${TAB}-"
MB_G="1${TAB}0${TAB}$O1${TAB}-${TAB}-"
MB_X="tests/bin/x.sh"
# mb_write <file> <mode> <records> — the record file one table row describes.
mb_write() {
  local file="$1" mode="$2" rec
  local -a recs=() out=()
  [ "$mode" = none ] && { rm -f "$file"; return; }
  [ "$mode" = empty ] && { : > "$file"; return; }
  IFS=',' read -r -a recs <<< "$3"
  for rec in "${recs[@]}"; do
    case "$rec" in
      H) rec="$MB_H" ;;
      G) rec="$MB_G" ;;
      X) rec="$MB_X" ;;
      EMPTY) rec="" ;;
    esac
    rec="${rec//\\t/$TAB}"
    rec="${rec//<O1>/$O1}"; rec="${rec//<O2>/$O2}"
    rec="${rec//<OA>/${O1//1/A}}"; rec="${rec//<OG>/${O3//3/g}}"
    out+=("$rec")
  done
  if [ "$mode" = no-last-nul ]; then
    printf '%s\0' "${out[@]:0:${#out[@]}-1}" > "$file"
    printf '%s' "${out[${#out[@]}-1]}" >> "$file"
  else
    printf '%s\0' "${out[@]}" > "$file"
  fi
}

case_begin "reader-malformed-records-fall-back-to-head-only" "bin/lib/merge-parents.sh"
R="$TMPBASE/mp-malformed"
mkrepo "$R"
A_OID="$(git -C "$R" rev-parse HEAD:bin/a.sh)"
MB_FB="fallback:0:0/0///:0/0///:1/1/<A>//"
while IFS='|' read -r MB_NAME MB_MODE MB_RECS MB_WANT; do
  [[ -z "$MB_NAME" || "$MB_NAME" =~ ^[[:space:]]*# ]] && continue
  MB_NAME="${MB_NAME//[[:space:]]/}"
  MB_MODE="${MB_MODE//[[:space:]]/}"
  MB_RECS="${MB_RECS//[[:space:]]/}"
  MB_WANT="${MB_WANT//[[:space:]]/}"
  [ "$MB_WANT" = FB ] && MB_WANT="$MB_FB"
  MB_WANT="${MB_WANT//<O1>/$O1}"; MB_WANT="${MB_WANT//<A>/$A_OID}"
  MB_FILE="$TMPBASE/mb-$MB_NAME.records"
  mb_write "$MB_FILE" "$MB_MODE" "$MB_RECS"
  OUT="$(mp_probe "$R" "$MB_FILE" "x:$MB_X" "y:tests/bin/y.sh" "plain:bin/a.sh")"
  IFS=':' read -r MB_W_STATE MB_W_COUNT MB_W_X MB_W_Y MB_W_PLAIN <<< "$MB_WANT"
  expect_probe "$MB_NAME" "$OUT" load-rc "(absent)"
  expect_probe "$MB_NAME" "$OUT" state "$MB_W_STATE"
  [ "$MB_W_COUNT" = - ] || expect_probe "$MB_NAME: records kept" "$OUT" count "$MB_W_COUNT"
  [ "$MB_W_X" = - ] || expect_probe "$MB_NAME: listed path" "$OUT" x "${MB_W_X//\//|}"
  [ "$MB_W_Y" = - ] || expect_probe "$MB_NAME: earlier record" "$OUT" y "${MB_W_Y//\//|}"
  [ "$MB_W_PLAIN" = - ] || expect_probe "$MB_NAME: HEAD-only record (R1)" "$OUT" plain "${MB_W_PLAIN//\//|}"
done <<'TABLE'
control-well-formed   | nul         | H,G,X                                  | merging:1:1/0/<O1>//:-:-
header-word-not-state | nul         | status\tmerging\t-,G,X                 | FB
header-unknown-state  | nul         | state\tbogus\t-,G,X                    | FB
header-without-reason | nul         | state\tmerging,G,X                     | FB
meta-four-fields      | nul         | H,1\t0\t<O1>\t-,X                      | FB
meta-six-fields       | nul         | H,1\t0\t<O1>\t-\t-\t-,X                | FB
meta-inp-not-binary   | nul         | H,2\t0\t<O1>\t-\t-,X                   | FB
meta-same-not-binary  | nul         | H,1\tx\t<O1>\t-\t-,X                   | FB
oid-short             | nul         | H,1\t0\t1234567\t-\t-,X                | FB
oid-41-hex            | nul         | H,1\t0\t<O1>1\t-\t-,X                  | FB
oid-uppercase         | nul         | H,1\t0\t<OA>\t-\t-,X                   | FB
oid-non-hex           | nul         | H,1\t0\t<O2>\t<OG>\t-,X                | FB
path-empty            | nul         | H,G,EMPTY                              | FB
path-missing          | nul         | H,G                                    | FB
good-record-then-bad  | nul         | H,G,tests/bin/y.sh,1\t0\tzz\t-\t-,X    | FB
header-missing        | empty       |                                        | FB
last-nul-missing      | no-last-nul | H,G,X                                  | FB
file-missing          | none        |                                        | FB
TABLE
case_end

# SHA-256 object format: 64-hex oids travel from the CLI through the reader, merging included.
case_begin "sha256-repo-oids-load-through-cli-and-reader" "bin/lib/merge-parents.sh"
R="$TMPBASE/mp-sha256"
if ! git init -q --object-format=sha256 "$R" >/dev/null 2>&1; then
  echo "SKIP: sha256-repo-oids-load-through-cli-and-reader (git init --object-format=sha256 unsupported)"
else
  git -C "$R" config core.hooksPath /dev/null
  git -C "$R" config core.excludesFile "$R/.git/info/exclude"
  git -C "$R" config user.email t@example.com
  git -C "$R" config user.name t
  git -C "$R" config core.autocrlf false
  S_BASE="$(stage_name "$R" tests/bin/s.sh "s base")"
  stage_name "$R" bin/a.sh "a" >/dev/null
  git -C "$R" commit -q -m base >/dev/null 2>&1
  B_COMMIT="$(git -C "$R" rev-parse HEAD)"
  S_HEAD="$(stage_name "$R" tests/bin/s.sh "s head")"
  git -C "$R" commit -q -m head >/dev/null 2>&1
  A_OID="$(git -C "$R" rev-parse HEAD:bin/a.sh)"
  assert_eq "precondition: 64-hex oid length=${#A_OID}" "precondition: 64-hex oid length=64"
  stage_name "$R" tests/bin/s.sh "s edited" >/dev/null
  OUT="$(mp_probe "$R" - "s:tests/bin/s.sh" "plain:bin/a.sh")"
  expect_probe "sha256" "$OUT" run-rc "(absent)"
  expect_probe "sha256" "$OUT" state not-merging
  expect_probe "sha256: edited path (R3)" "$OUT" s "1|0|$S_HEAD||"
  expect_probe "sha256: unchanged path (R1)" "$OUT" plain "1|1|$A_OID||"
  git -C "$R" read-tree "$B_COMMIT"
  S_UP="$(stage_name "$R" tests/bin/s.sh "s up")"
  M_COMMIT="$(git -C "$R" commit-tree "$(git -C "$R" write-tree)" -p "$B_COMMIT" -m up)"
  git -C "$R" read-tree HEAD
  printf '%s\n' "$M_COMMIT" > "$R/$(git -C "$R" rev-parse --git-path MERGE_HEAD)"
  stage_name "$R" tests/bin/s.sh "s merged" >/dev/null
  OUT="$(mp_probe "$R" - "s:tests/bin/s.sh" "plain:bin/a.sh")"
  expect_probe "sha256 merge" "$OUT" run-rc "(absent)"
  expect_probe "sha256 merge: 64-hex MERGE_HEAD accepted" "$OUT" state merging
  expect_probe "sha256 merge: 3-way (R6)" "$OUT" s "1|0|$S_HEAD|$S_UP|$S_BASE"
  expect_probe "sha256 merge: unchanged path (R1)" "$OUT" plain "1|1|$A_OID||"
fi
case_end
