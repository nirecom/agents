# bin/lib/session-sync-markers.sh
#
# SSOT for the two startup progress lines profile-snippet.sh echoes. The wording
# is shared: profile-snippet.sh prints them, and bin/sweep-shell-snapshots.sh
# matches them to recognise a shell snapshot whose PATH line was corrupted by
# that same stray output (issue #2160). A copy in either place would drift
# silently, so both read these values from here.
#
# Source-only; no shebang, not executable. The last line is a plain assignment,
# so `.`-ing this file always returns 0 and a `set -e` caller survives it.

AGENTS_SESSION_SYNC_FETCH_MARKER='git fetch Claude session sync ...'
AGENTS_SYMLINK_REPAIR_MARKER='Repairing agents symlink(s)...'
