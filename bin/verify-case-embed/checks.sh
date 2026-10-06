# shellcheck shell=bash
# bin/verify-case-embed/checks.sh — the static checks 1, 3, 4, 5 of bin/verify-case-embed.sh.
# Source only. vce_static_checks <relpath> <merged-report|""> runs them with the after-file
# already at <relpath> and the caller in the repo root, and sets VCE_LINE1 / VCE_LINE3 /
# VCE_LINE4 / VCE_LINE5 (CHECK<n>\t<status>\t<detail>) plus VCE_EXEMPT (EXEMPT lines).

VCE_STATE="" VCE_ID=""
VCE_NAMES=() VCE_TARGETS=()

_vce_line() { printf 'CHECK%s\t%s\t%s' "$1" "$2" "${3//$'\t'/ }"; }

# _vce_in <word> <list...> — rc 0 when <word> is one of the list.
_vce_in() {
  local w="$1" x
  shift
  for x in "$@"; do [[ "$x" == "$w" ]] && return 0; done
  return 1
}

# Check 1: the reader's state is conforming; a 2+ path header also passes check-case-markers.sh.
_vce_check1() {
  local rel="$1" out rc=0
  if [[ "$VCE_STATE" != conforming ]]; then
    VCE_LINE1="$(_vce_line 1 FAIL "state=$VCE_STATE")"; return 0
  fi
  if [[ "${#TFM_TOKENS[@]}" -ge 2 ]]; then
    out="$(bash "$VCE_TOOL/bin/check-case-markers.sh" "$rel" 2>&1)" || rc=$?
    if [[ "$rc" -ne 0 ]]; then
      VCE_LINE1="$(_vce_line 1 FAIL "check-case-markers rc=$rc: ${out%%$'\n'*}")"; return 0
    fi
  fi
  VCE_LINE1="$(_vce_line 1 PASS "state=conforming")"
}

# Check 3: no top-level function is left that nothing calls.
_vce_check3() {
  local rel="$1" out
  if [[ -z "$VCE_ID" ]] || ! _tlr_get "$VCE_ID" caseEmbedRules.file; then
    VCE_LINE3="$(_vce_line 3 SKIP no-embed-rules)"; return 0
  fi
  if ! out="$(tlr_call_part "$VCE_ID" caseEmbedRules leftover-defs "$VCE_ROOT/$rel")"; then
    VCE_LINE3="$(_vce_line 3 FAIL "leftover-defs op failed")"; return 0
  fi
  if [[ -z "$out" ]]; then
    VCE_LINE3="$(_vce_line 3 PASS "no leftover definitions")"
  else
    out="${out//$'\t'/:}"
    VCE_LINE3="$(_vce_line 3 FAIL "leftover: ${out//$'\n'/, }")"
  fi
}

# Check 4: header tokens H minus MERGED_TARGET exemptions are targets, and every target is in H.
_vce_check4() {
  local report="$1" tag cname kept dropped tok i bad="" missing="" outside="" ok
  local -a exempt=() drops=()
  if [[ -n "$report" ]]; then
    while IFS=$'\t' read -r tag cname kept dropped; do
      [[ "$tag" == MERGED_TARGET ]] || continue
      ok=1
      [[ -n "$cname" && -n "$kept" && -n "$dropped" ]] || ok=0
      if [[ "$ok" -eq 1 ]]; then
        ok=0
        for i in "${!VCE_NAMES[@]}"; do
          [[ "${VCE_NAMES[$i]}" == "$cname" && "${VCE_TARGETS[$i]}" == "$kept" ]] && ok=1
        done
        _vce_in "$kept" ${TFM_TOKENS[@]+"${TFM_TOKENS[@]}"} || ok=0
      fi
      IFS=',' read -r -a drops <<<"$dropped"
      for tok in ${drops[@]+"${drops[@]}"}; do
        _vce_in "$tok" ${TFM_TOKENS[@]+"${TFM_TOKENS[@]}"} || ok=0
        ! _vce_in "$tok" ${VCE_TARGETS[@]+"${VCE_TARGETS[@]}"} || ok=0
      done
      if [[ "$ok" -eq 1 ]]; then
        for tok in "${drops[@]}"; do exempt+=("$tok"); VCE_EXEMPT="${VCE_EXEMPT}EXEMPT"$'\t'"$tok"$'\t'"$cname"$'\n'; done
      else
        bad="${bad:+$bad; }$cname"
      fi
    done <"$report"
  fi
  if [[ -n "$bad" ]]; then
    VCE_LINE4="$(_vce_line 4 FAIL "bad-merge-report: $bad")"; return 0
  fi
  for tok in ${TFM_TOKENS[@]+"${TFM_TOKENS[@]}"}; do
    _vce_in "$tok" ${exempt[@]+"${exempt[@]}"} && continue
    _vce_in "$tok" ${VCE_TARGETS[@]+"${VCE_TARGETS[@]}"} || missing="${missing:+$missing,}$tok"
  done
  for tok in ${VCE_TARGETS[@]+"${VCE_TARGETS[@]}"}; do
    _vce_in "$tok" ${TFM_TOKENS[@]+"${TFM_TOKENS[@]}"} || outside="${outside:+$outside,}$tok"
  done
  if [[ -n "$missing$outside" ]]; then
    VCE_LINE4="$(_vce_line 4 FAIL "header-not-target=[$missing] target-not-in-header=[$outside]")"
  else
    VCE_LINE4="$(_vce_line 4 PASS "every header token is a case target")"
  fi
}

# Check 5: the shared harness is sourced and no self-implemented harness piece is left.
_vce_check5() {
  local rel="$1" re line found=0 out
  if [[ -z "$VCE_ID" ]] || ! _tlr_get "$VCE_ID" helperLibrary.sourceRegex; then
    VCE_LINE5="$(_vce_line 5 SKIP no-helper-library)"; return 0
  fi
  re="$_TLR_V"
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ $re ]]; then found=1; break; fi
  done <"$rel"
  if [[ "$found" -eq 0 ]]; then
    VCE_LINE5="$(_vce_line 5 FAIL "helper library not sourced")"; return 0
  fi
  if _tlr_get "$VCE_ID" caseEmbedRules.file; then
    if ! out="$(tlr_call_part "$VCE_ID" caseEmbedRules self-impl "$VCE_ROOT/$rel")"; then
      VCE_LINE5="$(_vce_line 5 FAIL "self-impl op failed")"; return 0
    fi
    if [[ -n "$out" ]]; then
      out="${out//$'\t'/:}"
      VCE_LINE5="$(_vce_line 5 FAIL "self-impl: ${out//$'\n'/, }")"; return 0
    fi
  fi
  VCE_LINE5="$(_vce_line 5 PASS "helper library sourced")"
}

vce_static_checks() {
  local rel="$1" report="${2:-}" rec tag idx name target rest
  VCE_EXEMPT="" VCE_NAMES=() VCE_TARGETS=() VCE_ID=""
  crr_read "$VCE_ROOT/$rel" >"$VCE_BK/.crr"
  rec="$(cat "$VCE_BK/.crr")"
  rm -f "$VCE_BK/.crr"
  VCE_STATE="$(printf '%s\n' "$rec" | awk -F'\t' '$1 == "FILE" { print $2; exit }')"
  while IFS=$'\t' read -r tag _ name target rest; do
    [[ "$tag" == CASE ]] || continue
    VCE_NAMES+=("$name"); VCE_TARGETS+=("$target")
  done <<<"$rec"
  tlr_match "$rel" && [[ "$TLR_STATUS" == supported ]] && VCE_ID="$TLR_ID"
  tfm_parse_tests_line "$rel"
  _vce_check1 "$rel"
  _vce_check3 "$rel"
  _vce_check4 "$report"
  _vce_check5 "$rel"
  return 0
}
