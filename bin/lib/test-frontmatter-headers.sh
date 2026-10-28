# shellcheck shell=bash
# bin/lib/test-frontmatter-headers.sh — source-only. The one reader of a test file's `Tests:`
# and `Tags:` header lines, in the comment prefix of the file's registry entry (#2502 S4-6).
# Sourced by bin/check-test-frontmatter.sh and bin/lib/test-language-match.sh; both callers
# load the test language registry (tlr_comment_prefix) before calling.

# Both readers stop at the registry headerMaxLines: a `Tags:` line further down is body text,
# and must not declare a test-lang-exception for the file.
_EXT_HEADER_AWK='NR > m { exit } index($0, p) == 1 { print; exit }'

# extract_headers <content> <path> — sets EXT_TESTS / EXT_TAGS from a content
# string; <path> picks the registry header.commentPrefix, matched as a fixed string.
extract_headers() {
  local content="$1"
  tlr_comment_prefix "$2" >/dev/null
  EXT_TESTS="$(printf '%s\n' "$content" | awk -v m="$TLR_HEADER_MAX_LINES" -v p="$TLR_COMMENT_PREFIX Tests:" "$_EXT_HEADER_AWK" || true)"
  EXT_TAGS="$(printf '%s\n' "$content" | awk -v m="$TLR_HEADER_MAX_LINES" -v p="$TLR_COMMENT_PREFIX Tags:" "$_EXT_HEADER_AWK" || true)"
}

# extract_headers_file <file> [<match-path>] — sets EXT_TESTS / EXT_TAGS by reading a file
# directly (fewer subprocesses than cat|awk — matters for the --all repo scan). <match-path>
# picks the comment prefix when <file> is a temp copy; it defaults to <file>.
extract_headers_file() {
  local file="$1"
  tlr_comment_prefix "${2:-$file}" >/dev/null
  EXT_TESTS="$(awk -v m="$TLR_HEADER_MAX_LINES" -v p="$TLR_COMMENT_PREFIX Tests:" "$_EXT_HEADER_AWK" "$file" 2>/dev/null || true)"
  EXT_TAGS="$(awk -v m="$TLR_HEADER_MAX_LINES" -v p="$TLR_COMMENT_PREFIX Tags:" "$_EXT_HEADER_AWK" "$file" 2>/dev/null || true)"
}
