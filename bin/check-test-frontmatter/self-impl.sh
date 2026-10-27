# shellcheck shell=bash
# bin/check-test-frontmatter/self-impl.sh — the --staged parent lookup and self-implemented harness
# check of bin/check-test-frontmatter.sh. Source only; needs SCRIPT_DIR (the bin directory).
# ctf_parents_load <mp-file-or-empty> <rel>... — merge-parents records (one CLI call with no file) and
# every baseline blob through one git cat-file --batch. ctf_in_parent <rel> — rc 0 when a parent has rel.
# ctf_self_impl_add <rel> <content> — queues the staged copy with its baselines (nothing when equal to
# a parent; an unreadable baseline judges it as new). ctf_self_impl_run — one bin/check-self-impl.sh
# over the queue; rc 1 on a HIGH, never on a WARN or the check's own failure.

# shellcheck source=../lib/merge-parents.sh
. "$SCRIPT_DIR/lib/merge-parents.sh" || return 1

CTF_SI_DIR=""
CTF_SI_N=0
CTF_SI_RC=0
CTF_PAR_I=0
CTF_PAR_RELS=(); CTF_PAR_SAME=()
CTF_PAR_O1=(); CTF_PAR_O2=(); CTF_PAR_OB=()
CTF_PAR_C1=(); CTF_PAR_C2=(); CTF_PAR_CB=()

_ctf_si_dir() {
  [[ -n "$CTF_SI_DIR" ]] && return 0
  CTF_SI_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ctf-self-impl.XXXXXX")" || { CTF_SI_DIR=""; return 1; }
  trap 'rm -rf "$CTF_SI_DIR"' EXIT
}

# _ctf_par_put <rel> — registers rel's baseline oids from the records; copies are filled later.
_ctf_par_put() {
  mp_baselines "$1"
  CTF_PAR_RELS+=("$1"); CTF_PAR_SAME+=("$MP_OUT_SAME")
  CTF_PAR_O1+=("$MP_OUT_B1"); CTF_PAR_O2+=("$MP_OUT_B2"); CTF_PAR_OB+=("$MP_OUT_BASE")
  CTF_PAR_C1+=(""); CTF_PAR_C2+=(""); CTF_PAR_CB+=("")
}

# _ctf_par_oid <i> <slot> / _ctf_par_set <i> <slot> <copy> — slot is b1, b2 or base.
_ctf_par_oid() {
  case "$2" in b1) _CTF_OID="${CTF_PAR_O1[$1]}" ;; b2) _CTF_OID="${CTF_PAR_O2[$1]}" ;; *) _CTF_OID="${CTF_PAR_OB[$1]}" ;; esac
}
_ctf_par_set() {
  case "$2" in b1) CTF_PAR_C1[$1]="$3" ;; b2) CTF_PAR_C2[$1]="$3" ;; *) CTF_PAR_CB[$1]="$3" ;; esac
}

# _ctf_par_one <i> <slot> — the per-file read of one baseline blob, for one the batch did not give.
_ctf_par_one() {
  local i="$1" slot="$2" copy
  _ctf_par_oid "$i" "$slot"
  [[ -n "$_CTF_OID" ]] && _ctf_si_dir || return 0
  copy="$CTF_SI_DIR/$i/$slot/${CTF_PAR_RELS[$i]##*/}"
  if mkdir -p "$CTF_SI_DIR/$i/$slot" && git cat-file blob "$_CTF_OID" >"$copy" 2>/dev/null; then
    _ctf_par_set "$i" "$slot" "$copy"
  fi
}

ctf_parents_load() {
  local mpf="$1" rel i slot hdr size copy batch j done_n=0
  local -a job_i=() job_slot=() oids=()
  shift
  if [[ -n "$mpf" ]]; then
    mp_load_file "$mpf"
    mp_note --fallback-only
  elif [[ "$#" -gt 0 ]] && _ctf_si_dir; then
    mp_run "$SCRIPT_DIR" "$CTF_SI_DIR/parents.mp" "$@" || true
    mp_load_file "$CTF_SI_DIR/parents.mp"
    mp_note
  fi
  for rel in "$@"; do
    i="${#CTF_PAR_RELS[@]}"
    _ctf_par_put "$rel"
    [[ "${CTF_PAR_SAME[$i]}" != 1 ]] || continue
    for slot in b1 b2 base; do
      _ctf_par_oid "$i" "$slot"
      [[ -n "$_CTF_OID" ]] || continue
      job_i+=("$i"); job_slot+=("$slot"); oids+=("$_CTF_OID")
    done
  done
  [[ "${#oids[@]}" -gt 0 ]] && _ctf_si_dir || return 0
  batch="$CTF_SI_DIR/parents.batch"
  if printf '%s\n' "${oids[@]}" | git cat-file --batch >"$batch" 2>/dev/null; then
    # Each entry is "<oid> blob <size>\n<size bytes>\n" or "<oid> missing\n"; a dd of one <size>
    # block on the shared fd 4 copies the blob byte for byte. Anything else stops the parse.
    exec 4<"$batch"
    for ((j = 0; j < ${#oids[@]}; j++)); do
      i="${job_i[j]}"; slot="${job_slot[j]}"
      IFS= read -r hdr <&4 || break
      if [[ "$hdr" == "${oids[j]} missing" ]]; then done_n=$((j + 1)); continue; fi
      [[ "$hdr" =~ ^[0-9a-f]+\ blob\ ([0-9]+)$ ]] || break
      size="${BASH_REMATCH[1]}"
      copy="$CTF_SI_DIR/$i/$slot/${CTF_PAR_RELS[$i]##*/}"
      mkdir -p "$CTF_SI_DIR/$i/$slot" || break
      if [[ "$size" -eq 0 ]]; then
        : >"$copy" || break
      elif ! dd bs="$size" count=1 <&4 >"$copy" 2>/dev/null; then
        break
      fi
      IFS= read -r hdr <&4 && [[ -z "$hdr" ]] || break
      _ctf_par_set "$i" "$slot" "$copy"
      done_n=$((j + 1))
    done
    exec 4<&-
  fi
  for ((j = done_n; j < ${#oids[@]}; j++)); do _ctf_par_one "${job_i[j]}" "${job_slot[j]}"; done
  return 0
}

# _ctf_par_find <rel> — sets CTF_PAR_I to rel's entry, registering and reading it when none exists.
_ctf_par_find() {
  local i slot
  for ((i = 0; i < ${#CTF_PAR_RELS[@]}; i++)); do
    [[ "${CTF_PAR_RELS[i]}" == "$1" ]] && { CTF_PAR_I="$i"; return 0; }
  done
  CTF_PAR_I="${#CTF_PAR_RELS[@]}"
  _ctf_par_put "$1"
  [[ "${CTF_PAR_SAME[$CTF_PAR_I]}" != 1 ]] || return 0
  for slot in b1 b2 base; do _ctf_par_one "$CTF_PAR_I" "$slot"; done
}

ctf_in_parent() {
  mp_in_parent "$1"
}

ctf_self_impl_add() {
  local rel="$1" i dir copy h1 h2 b out rc=0
  _ctf_si_dir || return 0
  _ctf_par_find "$rel"
  i="$CTF_PAR_I"
  # Equal to a parent's blob: nothing the parents lack, so nothing is queued.
  [[ "${CTF_PAR_SAME[$i]}" != 1 ]] || return 0
  dir="$CTF_SI_DIR/$i"
  # The copies keep the original basename, so every reader of them sees the same name.
  copy="$dir/${rel##*/}"
  mkdir -p "$dir" && printf '%s\n' "$2" >"$copy" || return 0
  h1="${CTF_PAR_C1[$i]}"; h2="${CTF_PAR_C2[$i]}"; b="${CTF_PAR_CB[$i]}"
  # A 3-way needs every baseline it names; short of one, head1 alone is the stricter judgment.
  if [[ -z "$h1" || -z "$h2" || ( -n "${CTF_PAR_OB[$i]}" && -z "$b" ) ]]; then
    h2=""; b=""
  fi
  if [[ "$rel" != *[$'\t\n']* ]]; then
    if [[ -n "$h2" ]]; then
      printf '%s\t%s\t%s\t%s\t%s\n' "$rel" "$copy" "$h1" "$h2" "$b" >>"$CTF_SI_DIR/manifest" || return 0
    else
      printf '%s\t%s\t%s\n' "$rel" "$copy" "$h1" >>"$CTF_SI_DIR/manifest" || return 0
    fi
    CTF_SI_N=$((CTF_SI_N + 1))
    return 0
  fi
  # A tab or newline cannot ride a manifest line; such a rel is checked on its own.
  out="$(bash "$SCRIPT_DIR/check-self-impl.sh" --rel "$rel" ${h1:+--head "$h1"} ${h2:+--head "$h2"} \
    ${b:+--base "$b"} "$copy" 2>&1)" || rc=$?
  [[ -z "$out" ]] || printf '%s\n' "$out" >&2
  [[ "$rc" -ne 1 ]] || CTF_SI_RC=1
  return 0
}

ctf_self_impl_run() {
  local rc=0 out
  if [[ "$CTF_SI_N" -gt 0 ]]; then
    out="$(bash "$SCRIPT_DIR/check-self-impl.sh" --manifest "$CTF_SI_DIR/manifest" 2>&1)" || rc=$?
    [[ -z "$out" ]] || printf '%s\n' "$out" >&2
  fi
  [[ -z "$CTF_SI_DIR" ]] || rm -rf "$CTF_SI_DIR"
  CTF_SI_DIR=""; CTF_SI_N=0
  CTF_PAR_RELS=(); CTF_PAR_SAME=(); CTF_PAR_O1=(); CTF_PAR_O2=(); CTF_PAR_OB=()
  CTF_PAR_C1=(); CTF_PAR_C2=(); CTF_PAR_CB=()
  [[ "$rc" -eq 1 || "$CTF_SI_RC" -eq 1 ]] && { CTF_SI_RC=0; return 1; }
  return 0
}
