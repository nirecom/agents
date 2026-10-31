#!/usr/bin/env bash
# bin/lib/codex-context-marker.sh — the single definition of the context section marker (#2814):
# bin/build-codex-context writes it, bin/lib/review-plan-codex/inputs.sh splits on it.
# A marker counts only in the exact written form, with a role from CCM_ROLES (in that order,
# each once) and a source whose basename is the role's plan artifact (<sid>-<role>.md).
# Every other line that starts like a marker is rewritten by ccm_defang_stream. Markers are
# split only in a file whose provenance record ccm_is_built finds (see the Provenance block).
# Sourced; no `set -e` (a sourced library).
# shellcheck disable=SC2034  # CCM_ROLE / CCM_SOURCE are read by the caller

CCM_PREFIX='<!-- codex-context-section:'
CCM_DEFANGED='<!-- (codex-context-section)'
CCM_ROLES='intent outline'
CCM_RE='^<!-- codex-context-section: ([a-z]+) source=([^[:cntrl:]]+) -->$'

# ccm_marker_line <role> <source> — the marker line, without the newline.
ccm_marker_line() { printf '%s %s source=%s -->' "$CCM_PREFIX" "$1" "$2"; }

# ccm_parse_marker <line> — rc 0 and CCM_ROLE / CCM_SOURCE when the line is a qualifying marker.
ccm_parse_marker() {
  local l="${1%[[:cntrl:]]}" role src base
  CCM_ROLE=""; CCM_SOURCE=""
  [[ "$l" =~ $CCM_RE ]] || return 1
  role="${BASH_REMATCH[1]}"; src="${BASH_REMATCH[2]}"
  case " $CCM_ROLES " in *" $role "*) ;; *) return 1 ;; esac
  [[ "$src" != *"-->"* ]] || return 1
  base="${src##*[/\\]}"
  [[ "$base" == "$role.md" || "$base" == ?*"-$role.md" ]] || return 1
  CCM_ROLE="$role"; CCM_SOURCE="$src"
}

# ccm_role_rank <role> — the 1-based position of the role in CCM_ROLES, or 0.
ccm_role_rank() {
  local r i=0
  for r in $CCM_ROLES; do i=$((i + 1)); [[ "$r" == "$1" ]] && { printf '%s' "$i"; return 0; }; done
  printf '0'
}

# ccm_defang_stream — stdin to stdout, every line that starts like a marker made inert.
ccm_defang_stream() { sed "s/^${CCM_PREFIX}/${CCM_DEFANGED}/"; }

# Provenance: a file counts as build output only while the sha256 of its bytes is recorded under
# <state root>/codex-context-built/ (bin/workflow-state-dir --global owns the root). A same-named
# file elsewhere cannot reproduce that record, so its markers are never split.
CCM_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"

# ccm_registry_dir — the provenance directory; rc 1 when the state root cannot be resolved.
ccm_registry_dir() {
  local root
  root="$(node "$CCM_LIB_DIR/../workflow-state-dir" --global 2>/dev/null)" || return 1
  root="${root%[[:cntrl:]]}"
  [[ -n "$root" ]] || return 1
  printf '%s/codex-context-built' "$root"
}

# ccm_file_hash <file> — sha256 of the file's bytes; rc 1 without a sha256 tool or file.
ccm_file_hash() {
  local out
  [[ -f "$1" ]] || return 1
  if command -v sha256sum >/dev/null 2>&1; then out="$(sha256sum < "$1")" || return 1
  elif command -v shasum >/dev/null 2>&1; then out="$(shasum -a 256 < "$1")" || return 1
  else return 1
  fi
  out="${out%% *}"
  [[ "$out" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf '%s' "$out"
}

# ccm_record_built <file> — record the file's bytes as build output; rc 1 on any failure.
ccm_record_built() {
  local d h
  d="$(ccm_registry_dir)" && h="$(ccm_file_hash "$1")" || return 1
  mkdir -p -- "$d" && touch -- "$d/$h" && [[ -f "$d/$h" && ! -L "$d/$h" ]]
}

# ccm_forget_built <hash> — drop one record (an empty hash is a no-op).
ccm_forget_built() {
  local d
  [[ "$1" =~ ^[0-9a-f]{64}$ ]] || return 0
  d="$(ccm_registry_dir)" || return 1
  rm -f -- "$d/$1"
}

# ccm_is_built <file> — rc 0 only when the file's current bytes are recorded as build output.
ccm_is_built() {
  local d h
  d="$(ccm_registry_dir)" && h="$(ccm_file_hash "$1")" || return 1
  [[ -f "$d/$h" && ! -L "$d/$h" ]]
}

:  # load-success rc for the caller's source check
