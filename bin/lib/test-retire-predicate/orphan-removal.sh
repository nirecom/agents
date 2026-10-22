# shellcheck shell=bash
# bin/lib/test-retire-predicate/orphan-removal.sh — trp_remove_orphan_cases, the --apply helper of
# bin/lib/test-retire-predicate.sh (which sources this file). Source only.
# The cut is language-neutral (line ranges); the rewrite is checked with the entry's caseEmbedRules
# `syntax-check` op, so every language with a part is cut the same way.

# trp_remove_orphan_cases <repo-root> <file> — excise every orphan case's [begin,end] lines. Needs the
# TRP_CASE_* state of the immediately preceding trp_case_refcount_verdict (caller contract). Fail-closed.
# TRP_CASE_FILE_HASH is checked before the copy and right before the replace (a changed file is
# skipped); not atomic — an edit landing between that final hash and the mv is still lost.
_trp_warn_changed() {
  echo "WARNING: trp_remove_orphan_cases: $1 changed since the verdict — skipping $1" >&2
}

trp_remove_orphan_cases() {
  local repo_root="${1:?trp_remove_orphan_cases: repo root required}"
  local file="${2:?trp_remove_orphan_cases: test file required}"
  if [[ "$_TRP_MARKER_MALFORMED" -eq 1 ]]; then return 1; fi
  if [[ ! "$TRP_CASE_COUNT" =~ ^[0-9]+$ || "$TRP_CASE_COUNT" -le 0 || "${#TRP_ORPHAN_CASE_IDX[@]}" -eq 0 ]]; then
    echo "WARNING: trp_remove_orphan_cases: no orphan case state — skipping ${file}" >&2
    return 1
  fi
  if ! tlr_match "$file" || ! _tlr_get "$TLR_ID" caseEmbedRules.file; then
    echo "WARNING: trp_remove_orphan_cases: no caseEmbedRules part to check the rewrite — skipping ${file}" >&2
    return 1
  fi
  local id="$TLR_ID"
  local abs="$file"
  [[ "$abs" != /* ]] && abs="$repo_root/$file" || true

  # Mark every line inside an orphan [begin,end] range for skipping (original
  # line numbers, resolved before any rewrite, so ranges cannot shift).
  local -A skip=()
  local idx b e ln
  local -a removed_names=()
  for idx in "${TRP_ORPHAN_CASE_IDX[@]}"; do
    b="${TRP_CASE_BEGIN_LINES[$idx]}"
    e="${TRP_CASE_END_LINES[$idx]}"
    removed_names+=("${TRP_CASE_NAMES[$idx]}")
    for ((ln = b; ln <= e; ln++)); do skip["$ln"]=1; done
  done
  # A live case sharing a line with an orphan range (two cases on one line) would be cut too.
  for ((idx = 0; idx < TRP_CASE_COUNT; idx++)); do
    [[ "${TRP_CASE_ALIVE[$idx]:-0}" == 1 ]] || continue
    for ((ln = TRP_CASE_BEGIN_LINES[idx]; ln <= TRP_CASE_END_LINES[idx]; ln++)); do
      if [[ -n "${skip[$ln]:-}" ]]; then
        echo "WARNING: trp_remove_orphan_cases: live case ${TRP_CASE_NAMES[$idx]} shares line $ln with an orphan case — skipping ${file}" >&2
        return 1
      fi
    done
  done

  # The rewrite keeps the original basename (so its extension) inside a private temp dir beside
  # the original: node --check and the PowerShell parser read the extension, and node takes the
  # module type from the nearest package.json, which a system temp dir would not see.
  local tmpdir tmp orig
  tmpdir="$(mktemp -d "${abs%/*}/.trp-orphan.XXXXXX")" || return 1
  tmp="$tmpdir/${file##*/}"
  # The cut reads a private copy whose hash matched the verdict's, so a later edit cannot slip in.
  orig="$tmpdir/.orig"
  if ! cp -- "$abs" "$orig" 2>/dev/null || [[ -z "$TRP_CASE_FILE_HASH" || "$(_trp_file_hash "$orig")" != "$TRP_CASE_FILE_HASH" ]]; then
    _trp_warn_changed "$file"
    rm -rf "$tmpdir"
    return 1
  fi
  local lineno=0 line
  while IFS= read -r line || [[ -n "$line" ]]; do
    lineno=$((lineno + 1))
    if [[ -n "${skip[$lineno]:-}" ]]; then continue; fi
    printf '%s\n' "$line" >> "$tmp"
  done < "$orig"

  local rc=0
  tlr_call_part "$id" caseEmbedRules syntax-check "$tmp" >/dev/null 2>&1 || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    echo "WARNING: trp_remove_orphan_cases: rewrite failed the $id syntax-check (rc=$rc) — skipping ${file}" >&2
    rm -rf "$tmpdir"
    return 1
  fi

  local mode
  mode="$(stat -c '%a' "$abs" 2>/dev/null || stat -f '%Lp' "$abs" 2>/dev/null || true)"
  if [[ -n "$mode" ]]; then chmod "$mode" "$tmp" 2>/dev/null || true; fi
  [[ -x "$abs" ]] && { chmod +x "$tmp" 2>/dev/null || true; }

  if [[ "$(_trp_file_hash "$abs")" != "$TRP_CASE_FILE_HASH" ]]; then
    _trp_warn_changed "$file"
    rm -rf "$tmpdir"
    return 1
  fi
  if ! mv "$tmp" "$abs"; then
    echo "WARNING: trp_remove_orphan_cases: mv failed — ${file}" >&2
    rm -rf "$tmpdir"
    return 1
  fi
  rm -rf "$tmpdir"
  if ! { git -C "$repo_root" add -- "$file" 2>/dev/null || git add -- "$abs" 2>/dev/null; }; then
    echo "WARNING: trp_remove_orphan_cases: git add failed — ${file}" >&2
    return 1
  fi
  local name
  for name in "${removed_names[@]}"; do printf '%s\n' "$name"; done
}
