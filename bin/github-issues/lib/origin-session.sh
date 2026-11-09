#!/bin/bash
# bin/github-issues/lib/origin-session.sh — the origin-session marker of an issue body (#2668).
# Sourced; defines origin_session_marker. The reader is bin/find-peer.d/origin.js; the format is
# pinned by both sides' tests (docs/architecture/cross-session-messaging.md).

# origin_session_marker <sid> — print "<!-- origin-session: <sid> -->". A sid outside
# [A-Za-z0-9_-]+ could close the HTML comment early, so it prints nothing and returns 1.
origin_session_marker() {
    local sid="${1-}"
    if [[ -z "$sid" || "$sid" == *[!A-Za-z0-9_-]* ]]; then
        return 1
    fi
    printf '<!-- origin-session: %s -->\n' "$sid"
}
