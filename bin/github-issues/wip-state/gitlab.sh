#!/bin/bash
# bin/github-issues/wip-state/gitlab.sh — GitLab label-based WIP verbs (#2308).
# Sourced by ../wip-state.sh when FORGE=gitlab. Uses status:wip / status:done
# labels + wip-fp:<hash> fingerprint label (defined in labels.yml / sync-labels).
# Globals: GL_ENC, GL_PROJECT, SID_SET, INJECTED_SID.
# Functions: validate_n, compute_fingerprint, effective_session_id,
#   write_lock_file, delete_lock_file.

# Read an issue's labels, one per line. Uses glab issue view --json labels.
_gl_read_labels() {
    local raw
    raw=$(glab issue view "$1" --json labels 2>/dev/null) || return 1
    printf '%s' "$raw" | tr ',' '\n' | sed -n 's/.*"name":"\([^"]*\)".*/\1/p'
}

# Read an issue's state ("opened" | "closed" | "" on failure).
_gl_read_state() {
    glab api "projects/$GL_ENC/issues/$1" --jq '.state' 2>/dev/null | tr -d '\r'
}

# Comma-join the existing wip-fp:* labels of an issue (for clear/abandon, which
# do not receive --session-id and so must discover the fingerprint label).
_gl_existing_wip_fp() {
    _gl_read_labels "$1" | tr -d '\r' | grep '^wip-fp:' | paste -sd, - 2>/dev/null
}

# Verb: set <N> — status:wip + wip-fp:<fp>, drop status:done. Hard-fail exit 1.
gl_cmd_set() {
    local n="$1"
    validate_n "$n"
    local sid
    if ! sid=$(effective_session_id); then
        exit 2
    fi
    local fp
    fp=$(compute_fingerprint "$sid" "$n")
    if ! glab issue edit "$n" --label "status:wip,wip-fp:$fp" \
            --remove-label "status:done" >/dev/null 2>&1; then
        echo "[wip-state: label set failed for #$n]" >&2
        exit 1
    fi
    if ! write_lock_file "$n" "$sid"; then
        echo "[wip-state: lock-file write failed for #$n (continuing)]" >&2
    fi
    exit 0
}

# Verb: check <N> — prints same|other|none. Exit 1 on read failure, 2 on sid.
gl_cmd_check() {
    local n="$1"
    validate_n "$n"
    local sid
    if ! sid=$(effective_session_id); then
        exit 2
    fi
    local labels
    if ! labels=$(_gl_read_labels "$n"); then
        echo "warn: glab api failed for #$n check" >&2
        exit 1
    fi
    labels=$(printf '%s' "$labels" | tr -d '\r')
    if ! printf '%s\n' "$labels" | grep -qx 'status:wip'; then
        echo none
        exit 0
    fi
    local expected
    expected=$(compute_fingerprint "$sid" "$n")
    if printf '%s\n' "$labels" | grep -qx "wip-fp:$expected"; then
        echo "same"
    else
        echo "other"
    fi
    exit 0
}

# Verb: clear <N> — status:done, drop status:wip + wip-fp:*. Warn-and-continue.
gl_cmd_clear() {
    local n="$1"
    validate_n "$n"
    local remove="status:wip"
    local fps
    fps=$(_gl_existing_wip_fp "$n")
    [ -n "$fps" ] && remove="$remove,$fps"
    if ! glab issue edit "$n" --label "status:done" \
            --remove-label "$remove" >/dev/null 2>&1; then
        echo "[wip-state: label clear failed for #$n (continuing)]" >&2
    fi
    delete_lock_file "$n"
    exit 0
}

# Verb: abandon <N> — drop status:wip + wip-fp:* (back to todo). Hard-fail.
# Only operates on OPEN issues; closed/error exits 1.
gl_cmd_abandon() {
    local n="$1"
    validate_n "$n"
    local state
    state=$(_gl_read_state "$n")
    if [ "$state" = "closed" ]; then
        echo "[wip-state: abandon on CLOSED issue #$n — skipping (use clear instead)]" >&2
        exit 1
    fi
    if [ "$state" != "opened" ]; then
        echo "[wip-state: cannot determine state for #$n — skipping abandon]" >&2
        exit 1
    fi
    local remove="status:wip"
    local fps
    fps=$(_gl_existing_wip_fp "$n")
    [ -n "$fps" ] && remove="$remove,$fps"
    if ! glab issue edit "$n" --remove-label "$remove" >/dev/null 2>&1; then
        echo "[wip-state: label abandon failed for #$n]" >&2
        exit 1
    fi
    delete_lock_file "$n"
    exit 0
}

# Verb: setup — no field IDs on GitLab; labels are the SSOT. Informational.
gl_cmd_setup() {
    echo "info: GitLab WIP uses labels, not Projects v2 field IDs — no setup needed." >&2
    echo "info: ensure status:wip / status:done exist via 'sync-labels.sh' (labels.yml SSOT)." >&2
    exit 0
}
