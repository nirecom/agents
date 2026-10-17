# shellcheck shell=bash
# bin/lib/run-all-report.sh — the report layer of tests/run-all.sh; source only, needs nothing at source time.
# neutralize_stream <file>          replay a child stream, prefixing every line shaped like a report line.
# rar_unit <script> <resultdir> <rc> [<state> <missing> <timeout>]
#                                   one unit's file-level line, then its case-level lines; sets RAR_STATE.
# rar_missing [<arg>...]            one UNRUNNABLE line per explicit argument that named no test file.
# rar_hits                          the collected hits: late test ids as named FAILs, the rest as HIT lines.
# rar_tail [<unsupported-file>...]  UNSUPPORTED list, Missing runtimes, Results and RUN_CONTRACT.
# Contract: docs/architecture/claude-code/test-runner-parallelism.md.

RAR_PASS=0 RAR_FAIL=0 RAR_SKIP=0 RAR_UNRUNNABLE=0 RAR_TIMEOUT=0 RAR_UNSUPPORTED=0 RAR_HITS=0 RAR_STATE=""
_RAR_LABELS=()
_RAR_LABEL_N=()
# Every unit as rar_unit saw it (raw name, state, rc, runtime label), for rar_hits; indexed, as bash 3 has no maps.
_RAR_UNIT_RAW=()
_RAR_UNIT_ST=()
_RAR_UNIT_RC=()
_RAR_UNIT_MISS=()
# The FAIL: alternative mirrors test-runner.js FAIL_LINE_RE, so a plain harness "FAIL: msg" passes through.
_RAR_REPORT_RE='^[[:blank:]]*(RUN_CONTRACT:|UNRUNNABLE:|TIMEOUT:|HIT:|Missing runtimes:|Results:|FAIL:[[:space:]]+.*[[:space:]][(]exit[[:space:]]+-?[0-9]+[)][[:space:]]*$|(PASS|FAIL|SKIP|XFAIL|XPASS) .*::)'

# Shell builtins only — a fork per line would outcost the run on MSYS. A lone CR splits a line for a
# CR-splitting reader, so each CR segment is tested too; a hit prints its CRs as spaces (trailing CR kept).
rar_neutralize() {
  local line body cr rest seg hit
  [ -s "$1" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    body="${line%$'\r'}" cr="${line:${#body}}" hit=0
    if [[ $body =~ $_RAR_REPORT_RE ]]; then
      hit=1
    else
      rest="$body"
      while [[ $rest == *$'\r'* ]]; do
        seg="${rest%%$'\r'*}" rest="${rest#*$'\r'}"
        if [[ $seg =~ $_RAR_REPORT_RE || $rest =~ $_RAR_REPORT_RE ]]; then hit=1; break; fi
      done
    fi
    if [[ $hit -eq 1 ]]; then
      printf '[run-all:neutralized] %s%s\n' "${body//$'\r'/ }" "$cr"
    else
      printf '%s\n' "$line"
    fi
  done <"$1"
  return 0
}
neutralize_stream() { rar_neutralize "$@"; }

# _rar_disp <var> <text> — <text> with every control character as a space (the cases.tsv writers'
# convention), so a name holding LF or CR can never split or forge a line the report prints.
_rar_disp() { printf -v "$1" '%s' "${2//[[:cntrl:]]/ }"; }

# _rar_state <rc> <state> — the launcher's state into RAR_STATE; a launcher that set none (an old or
# stub one) is classified from its rc alone, where 79 without a marker is an ordinary failure.
_rar_state() {
  case "$2" in
    PASS | FAIL | SKIP | TIMEOUT | UNRUNNABLE | UNSUPPORTED) RAR_STATE="$2"; return 0 ;;
  esac
  case "$1" in
    U) RAR_STATE=UNSUPPORTED ;;
    0) RAR_STATE=PASS ;;
    77) RAR_STATE=SKIP ;;
    *) RAR_STATE=FAIL ;;
  esac
}

_rar_label() {
  local i
  for ((i = 0; i < ${#_RAR_LABELS[@]}; i++)); do
    if [ "${_RAR_LABELS[i]}" = "$1" ]; then
      _RAR_LABEL_N[i]=$((_RAR_LABEL_N[i] + 1))
      return 0
    fi
  done
  _RAR_LABELS+=("$1")
  _RAR_LABEL_N+=(1)
}

# A unit rar_hits turned into a FAIL no longer needs its runtime: 'Missing runtimes:' drops a label at 0.
_rar_unlabel() {
  local i
  for ((i = 0; i < ${#_RAR_LABELS[@]}; i++)); do
    if [ "${_RAR_LABELS[i]}" = "$1" ]; then
      _RAR_LABEL_N[i]=$((_RAR_LABEL_N[i] - 1))
      return 0
    fi
  done
}

# _rar_cases <script> <unit-state PASS|FAIL|SKIP> <cases.tsv> — one line per seq, its last record
# (the rule _rac_resolved classifies by), so interleaved records never print a case twice.
_rar_cases() {
  local s ust="$2" f="$3" seq st name tgt i n=0 failrec=0
  local -a seqs=() sts=() names=() tgts=() at=()
  _rar_disp s "$1"
  if [ -s "$f" ]; then
    while IFS=$'\t' read -r seq st name tgt; do
      [ -n "$seq" ] || continue
      # Every writer numbers its cases, so a seq is its own index; the scan is for anything else.
      if [[ "$seq" =~ ^(0|[1-9][0-9]{0,8})$ ]]; then
        i="${at[seq]:-${#seqs[@]}}"
        at[seq]=$i
      else
        for ((i = 0; i < ${#seqs[@]}; i++)); do
          if [ "${seqs[i]}" = "$seq" ]; then break; fi
        done
      fi
      seqs[i]="$seq" sts[i]="$st" names[i]="${name//$'\r'/}" tgts[i]="${tgt//$'\r'/}"
    done <"$f"
  fi
  for ((i = 0; i < ${#seqs[@]}; i++)); do
    st="${sts[i]}"
    # The state heads the printed line, so only the case-state allowlist is ever printed.
    case "$st" in
      PASS | FAIL | SKIP | XFAIL | XPASS) ;;
      OPEN) [ "$ust" = FAIL ] || continue; st=FAIL ;;
      *) continue ;;
    esac
    [ "$st" = FAIL ] && failrec=1
    _rar_disp name "${names[i]}"
    _rar_disp tgt "${tgts[i]}"
    printf '%s %s::%s target=%s\n' "$st" "$s" "$name" "$tgt"
    n=$((n + 1))
  done
  if [ "$n" -eq 0 ] || { [ "$ust" = FAIL ] && [ "$failrec" -eq 0 ]; }; then
    printf '%s %s::(file) target=%s\n' "$ust" "$s" "$s"
  fi
  return 0
}

rar_unit() {
  local s dir="$2" rc="${3:-1}" missing eff="${6:--}" cst
  _rar_disp s "$1"
  _rar_disp missing "${5:--}"
  _rar_state "$rc" "${4:--}"
  case "$rc" in U | '' | *[!0-9]*) rc=1 ;; esac
  _RAR_UNIT_RAW+=("$1")
  _RAR_UNIT_ST+=("$RAR_STATE")
  _RAR_UNIT_RC+=("$rc")
  [ "$missing" != - ] || missing=unknown
  _RAR_UNIT_MISS+=("$missing")
  case "$RAR_STATE" in
    PASS) echo "PASS: $s"; RAR_PASS=$((RAR_PASS + 1)) ;;
    SKIP) echo "SKIP: $s"; RAR_SKIP=$((RAR_SKIP + 1)) ;;
    FAIL) echo "FAIL: $s (exit $rc)"; RAR_FAIL=$((RAR_FAIL + 1)) ;;
    TIMEOUT)
      echo "FAIL: $s (exit 124)"
      if [[ "$eff" =~ ^[0-9]+$ ]]; then echo "TIMEOUT: $s (${eff}s)"; else echo "TIMEOUT: $s"; fi
      RAR_FAIL=$((RAR_FAIL + 1)) RAR_TIMEOUT=$((RAR_TIMEOUT + 1))
      ;;
    UNRUNNABLE)
      echo "UNRUNNABLE: $s (missing: $missing)"
      RAR_UNRUNNABLE=$((RAR_UNRUNNABLE + 1))
      _rar_label "$missing"
      return 0
      ;;
    *) RAR_UNSUPPORTED=$((RAR_UNSUPPORTED + 1)); return 0 ;; # its UNSUPPORTED line came with the stdout
  esac
  cst="$RAR_STATE"
  [ "$cst" = TIMEOUT ] && cst=FAIL
  _rar_cases "$s" "$cst" "$dir/cases.tsv"
}

# A missing file counts as UNRUNNABLE but carries no runtime label, so 'Missing runtimes:' never names it.
rar_missing() {
  local a d
  for a in "$@"; do
    _rar_disp d "$a"
    echo "UNRUNNABLE: $d (missing: test file)"
    RAR_UNRUNNABLE=$((RAR_UNRUNNABLE + 1))
  done
  return 0
}

rar_tail() {
  local f i line="" d
  for f in "$@"; do
    tlr_match "$f"
    _rar_disp d "$f"
    printf 'UNSUPPORTED: %s (language: %s; not run)\n' "$d" "${TLR_ID:-unknown}"
  done
  echo ""
  if [ "${#_RAR_LABELS[@]}" -gt 0 ]; then
    for ((i = 0; i < ${#_RAR_LABELS[@]}; i++)); do
      [ "${_RAR_LABEL_N[i]}" -gt 0 ] || continue
      f="files"
      [ "${_RAR_LABEL_N[i]}" -eq 1 ] && f="file"
      line="$line${line:+, }${_RAR_LABELS[i]} (${_RAR_LABEL_N[i]} $f)"
    done
    [ -z "$line" ] || echo "Missing runtimes: $line"
  fi
  # HITS is written only when there is one, so a run without hits prints what it always printed.
  d=""
  [ "${RAR_HITS:-0}" -gt 0 ] && d="$RAR_HITS"
  echo "Results: PASS=$RAR_PASS  FAIL=$RAR_FAIL  SKIP=$RAR_SKIP  UNRUNNABLE=$RAR_UNRUNNABLE  TIMEOUT=$RAR_TIMEOUT${d:+  HITS=$d}"
  echo "RUN_CONTRACT: PASS=$RAR_PASS FAIL=$RAR_FAIL SKIP=$RAR_SKIP EXECUTED=$((RAR_PASS + RAR_FAIL + RAR_SKIP)) UNRUNNABLE=$RAR_UNRUNNABLE TIMEOUT=$RAR_TIMEOUT${d:+ HITS=$d}"
}

# rar_hits — applies what run_all_hit_collect (bin/lib/run-all-hits.sh) left: each late test id
# makes its unit one named FAIL (once; a FAIL or TIMEOUT already is one), and every other hit,
# with a late id that names no unit, is counted into RAR_HITS and printed as a column-0 HIT line.
rar_hits() {
  local k i s d st max=20 shown=0 nf=0
  local -a lines=(${RUN_ALL_HIT_LINES[@]+"${RUN_ALL_HIT_LINES[@]}"})
  for ((k = 0; k < ${#RUN_ALL_LATE_IDS[@]}; k++)); do
    s="${RUN_ALL_LATE_IDS[k]}"
    for ((i = 0; i < ${#_RAR_UNIT_RAW[@]}; i++)); do
      [ "${_RAR_UNIT_RAW[i]}" = "$s" ] && break
    done
    if [ "$i" -ge "${#_RAR_UNIT_RAW[@]}" ]; then
      lines+=("${RUN_ALL_LATE_LINES[k]:-$s}")
      nf=$((nf + 1))
      continue
    fi
    st="${_RAR_UNIT_ST[i]}"
    case "$st" in
      FAIL | TIMEOUT) continue ;;
      PASS) RAR_PASS=$((RAR_PASS - 1)) ;;
      SKIP) RAR_SKIP=$((RAR_SKIP - 1)) ;;
      UNRUNNABLE) RAR_UNRUNNABLE=$((RAR_UNRUNNABLE - 1)); _rar_unlabel "${_RAR_UNIT_MISS[i]}" ;;
      *) RAR_UNSUPPORTED=$((RAR_UNSUPPORTED - 1)) ;;
    esac
    _RAR_UNIT_ST[i]=FAIL
    RAR_FAIL=$((RAR_FAIL + 1))
    _rar_disp d "$s"
    echo "FAIL: $d (exit ${_RAR_UNIT_RC[i]})"
  done
  RAR_HITS=$((${RAR_HITS:-0} + ${RUN_ALL_HITS:-0} + nf))
  for ((k = 0; k < ${#lines[@]}; k++)); do
    if [ "$shown" -ge "$max" ]; then
      echo "HIT: (+$((${#lines[@]} - shown)) more)"
      break
    fi
    _rar_disp d "${lines[k]}"
    echo "HIT: $d"
    shown=$((shown + 1))
  done
  return 0
}
