#!/usr/bin/env bash
# SSOT for test frontmatter validation constants.
# Source this file (do not export — env vars don't cross independent process boundaries).
# Returns 1 (one stderr line from the loader) when the test-language registry is unreadable.
FRONTMATTER_TOKEN_VALID_RE='^[A-Za-z0-9._/-]+$'
# Position contract from skills/_shared/test-design.md: the header lives within the registry's
# headerMaxLines. Read by the --dup-groups structural check.
# shellcheck source=test-language-registry.sh
_tfc_dir="${BASH_SOURCE[0]}"
case "$_tfc_dir" in */*) _tfc_dir="${_tfc_dir%/*}" ;; *) _tfc_dir=. ;; esac
. "$_tfc_dir/test-language-registry.sh" || return 1
tlr_load || return 1
FRONTMATTER_HEADER_MAX_LINE="$TLR_HEADER_MAX_LINES"
