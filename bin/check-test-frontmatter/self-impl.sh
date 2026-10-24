# shellcheck shell=bash
# bin/check-test-frontmatter/self-impl.sh — the --staged HEAD lookup and self-implemented harness
# check of bin/check-test-frontmatter.sh. Source only; needs SCRIPT_DIR (the bin directory).
# ctf_head_load <rel>... — reads every rel's HEAD blob with one git cat-file --batch into a temp dir.
# ctf_head_has <rel> — rc 0 when HEAD has rel (as git cat-file -e HEAD:<rel>).
# ctf_self_impl_add <rel> <content> — queues a copy of the staged content, with its HEAD copy when
# HEAD has rel (a HEAD blob git cannot give is judged as a new file; a copy identical to HEAD is not
# queued). ctf_self_impl_run — runs bin/check-self-impl.sh once over the queue, prints its lines on
# stderr and removes the temp dir; rc 1 when it reports a HIGH; a WARN, or the check itself failing
# (its exit 2, printed with its reason), never blocks the commit.

CTF_SI_DIR=""
CTF_SI_N=0
CTF_SI_RC=0
CTF_HEAD_I=0
CTF_HEAD_RELS=()
CTF_HEAD_HAS=()
CTF_HEAD_COPY=()
CTF_HEAD_SIZE=()

_ctf_si_dir() {
  [[ -n "$CTF_SI_DIR" ]] && return 0
  CTF_SI_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ctf-self-impl.XXXXXX")" || { CTF_SI_DIR=""; return 1; }
  trap 'rm -rf "$CTF_SI_DIR"' EXIT
}

# _ctf_head_put <rel> <has> <copy> <size> — registers one rel's HEAD lookup result.
_ctf_head_put() {
  CTF_HEAD_RELS+=("$1"); CTF_HEAD_HAS+=("$2"); CTF_HEAD_COPY+=("$3"); CTF_HEAD_SIZE+=("$4")
}

# _ctf_head_one <rel> — the per-file lookup, for a rel the batch did not register.
_ctf_head_one() {
  local i="${#CTF_HEAD_RELS[@]}" copy=""
  if ! git cat-file -e "HEAD:$1" 2>/dev/null; then _ctf_head_put "$1" 0 "" ""; return 0; fi
  if _ctf_si_dir && mkdir -p "$CTF_SI_DIR/$i/head" \
     && git show "HEAD:$1" >"$CTF_SI_DIR/$i/head/${1##*/}" 2>/dev/null; then
    copy="$CTF_SI_DIR/$i/head/${1##*/}"
  fi
  _ctf_head_put "$1" 1 "$copy" ""
}

ctf_head_load() {
  local rel hdr size copy i batch
  local -a batched=()
  for rel in "$@"; do [[ "$rel" == *$'\n'* ]] || batched+=("$rel"); done
  [[ "${#batched[@]}" -gt 0 ]] && _ctf_si_dir || return 0
  batch="$CTF_SI_DIR/head.batch"
  printf 'HEAD:%s\n' "${batched[@]}" | git cat-file --batch >"$batch" 2>/dev/null || return 0
  # Each entry is "<sha> <type> <size>\n<size bytes>\n" or "HEAD:<rel> missing\n"; a dd of one
  # <size> block on the shared fd 4 copies the blob byte for byte. Anything else stops the parse.
  exec 4<"$batch"
  for rel in "${batched[@]}"; do
    i="${#CTF_HEAD_RELS[@]}"
    IFS= read -r hdr <&4 || break
    if [[ "$hdr" == "HEAD:${rel} missing" ]]; then _ctf_head_put "$rel" 0 "" ""; continue; fi
    [[ "$hdr" =~ ^[0-9a-f]+\ [a-z]+\ ([0-9]+)$ ]] || break
    size="${BASH_REMATCH[1]}"
    copy="$CTF_SI_DIR/$i/head/${rel##*/}"
    mkdir -p "$CTF_SI_DIR/$i/head" || break
    if [[ "$size" -eq 0 ]]; then
      : >"$copy" || break
    elif ! dd bs="$size" count=1 <&4 >"$copy" 2>/dev/null; then
      break
    fi
    IFS= read -r hdr <&4 && [[ -z "$hdr" ]] || break
    _ctf_head_put "$rel" 1 "$copy" "$size"
  done
  exec 4<&-
}

# _ctf_head_find <rel> — sets CTF_HEAD_I to rel's lookup entry, looking it up when none exists.
_ctf_head_find() {
  local i
  for ((i = 0; i < ${#CTF_HEAD_RELS[@]}; i++)); do
    [[ "${CTF_HEAD_RELS[i]}" == "$1" ]] && { CTF_HEAD_I="$i"; return 0; }
  done
  _ctf_head_one "$1"
  CTF_HEAD_I=$((${#CTF_HEAD_RELS[@]} - 1))
}

ctf_head_has() {
  _ctf_head_find "$1"
  [[ "${CTF_HEAD_HAS[CTF_HEAD_I]}" -eq 1 ]]
}

# _ctf_size_differs <size> <content> — the copy of content (plus its newline) is not size bytes.
_ctf_size_differs() {
  local LC_ALL=C
  [[ -n "$1" && "$1" -ne $((${#2} + 1)) ]]
}

ctf_self_impl_add() {
  local rel="$1" dir copy head out rc=0
  _ctf_si_dir || return 0
  _ctf_head_find "$rel"
  dir="$CTF_SI_DIR/$CTF_HEAD_I"
  # The copies keep the original basename, so every reader of them sees the same name.
  copy="$dir/${rel##*/}"
  mkdir -p "$dir" && printf '%s\n' "$2" >"$copy" || return 0
  head="${CTF_HEAD_COPY[CTF_HEAD_I]}"
  # A copy identical to HEAD has nothing HEAD lacks; queue nothing.
  if [[ -n "$head" ]] && ! _ctf_size_differs "${CTF_HEAD_SIZE[CTF_HEAD_I]}" "$2" && cmp -s "$head" "$copy"; then
    return 0
  fi
  if [[ "$rel" != *[$'\t\n']* ]]; then
    printf '%s\t%s\t%s\n' "$rel" "$copy" "$head" >>"$CTF_SI_DIR/manifest" && CTF_SI_N=$((CTF_SI_N + 1))
    return 0
  fi
  # A tab or newline cannot ride a manifest line; such a rel is checked on its own.
  out="$(bash "$SCRIPT_DIR/check-self-impl.sh" --rel "$rel" ${head:+--head "$head"} "$copy" 2>&1)" || rc=$?
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
  CTF_HEAD_RELS=(); CTF_HEAD_HAS=(); CTF_HEAD_COPY=(); CTF_HEAD_SIZE=()
  [[ "$rc" -eq 1 || "$CTF_SI_RC" -eq 1 ]] && { CTF_SI_RC=0; return 1; }
  return 0
}
