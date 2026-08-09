# tests/feat-1699-meta-parent-guard/label-preflight.sh
# Tests: bin/github-issues/issue-create-preflight.sh
# Tags: issue-create, preflight, labels, validation, injection, scope:issue-specific, pwsh-not-required, TL2
# TL3 gap (what this test does NOT catch):
# - Whether real `gh label list` accepts or normalises a name the regex lets through
#   (GitHub's own label charset is not published as a regex).
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: skill-orchestration.
#
# Group L — --label validation, as a matrix
#
# The dispatcher passes `--label meta` into this script before make-parent, so the value
# is a constant today. It will not stay one: --check-labels is the generic existence
# probe, and the value it is handed is compared with `grep -qxF` against repo data. The
# validation therefore has two jobs, and they fail differently:
#   (a) semantic — an unanchored or empty name would MATCH labels it does not name
#       (`.*` would report "exists" against any repo, sending the dispatcher on),
#   (b) transport — the value reaches a `gh` command line.
# Both are only defences if they land BEFORE the gh call, so every rejection row asserts
# an empty args log, not merely rc=2.

setup_mock
export GH_MOCK_REPO_LABELS="type:task,meta,status:migrated,area/docs,v1.2.3,a"

# pf_run <args…> — preflight with stdout/stderr/rc captured, args log reset first.
pf_run() {
    : > "$GH_MOCK_ARGS_LOG"
    PF_OUT="$(bash "$RWT" 30 bash "$PREFLIGHT" "$@" 2>"$TMP/pf-err.txt")"
    PF_RC=$?
    PF_ERR="$(cat "$TMP/pf-err.txt")"
}

gh_call_count() { grep -c . "$GH_MOCK_ARGS_LOG" 2>/dev/null || true; }

# assert_label_rejected <label-for-case-name> <value>
assert_label_rejected() {
    local case_id="$1" value="$2" n
    pf_run --check-labels --label "$value"
    n=$(gh_call_count)
    if [ "$PF_RC" -eq 2 ]; then
        pass "L-${case_id}-rejected-rc2"
    else
        fail "L-${case_id}-rejected-rc2" "want rc=2 (invalid argv) for --label '$value' (got: $PF_RC) — rc=1 would be read by the caller as 'label absent' and rc=0 as 'label exists'"
    fi
    # The point of validating at all. rc=2 after the call already went out would still
    # have put an unvalidated string on a gh command line.
    if [ "${n:-0}" -eq 0 ]; then
        pass "L-${case_id}-no-gh-call"
    else
        fail "L-${case_id}-no-gh-call" "want 0 gh invocations before rejection (got: ${n:-0}); log: $(cat "$GH_MOCK_ARGS_LOG")"
    fi
    # A rejection that does not say what it rejected leaves the operator guessing which
    # of several labels on the command line was the bad one.
    if printf '%s' "$PF_ERR" | grep -qi 'invalid --label'; then
        pass "L-${case_id}-names-the-offending-flag"
    else
        fail "L-${case_id}-names-the-offending-flag" "stderr must identify the rejected --label value (got: '$PF_ERR')"
    fi
}

# assert_label_accepted <case-id> <value> <want-rc>
# want-rc distinguishes the two legitimate verdicts: 0 = present in the repo, 1 = absent.
# Neither is 2, and both mean the value survived validation and a gh call was made.
assert_label_accepted() {
    local case_id="$1" value="$2" want_rc="$3" n
    pf_run --check-labels --label "$value"
    n=$(gh_call_count)
    if [ "$PF_RC" -eq "$want_rc" ]; then
        pass "L-${case_id}-accepted-rc${want_rc}"
    else
        fail "L-${case_id}-accepted-rc${want_rc}" "want rc=$want_rc for the valid label '$value' (got: $PF_RC; stderr: $PF_ERR)"
    fi
    if [ "${n:-0}" -ge 1 ]; then
        pass "L-${case_id}-reached-gh"
    else
        fail "L-${case_id}-reached-gh" "a valid label must reach the gh existence probe (got ${n:-0} gh calls)"
    fi
}

# --- L1: names GitHub actually uses in this repo must pass ------------------------------
# Charset coverage, one row per character class the regex admits: bare word, colon,
# slash, dot+digits, single character. `meta` is the one the dispatcher itself sends.
while IFS='|' read -r cid value; do
    [ -z "$cid" ] && continue
    assert_label_accepted "$cid" "$value" 0
done <<'ACCEPT_TABLE'
1a|meta
1b|type:task
1c|status:migrated
1d|area/docs
1e|v1.2.3
1f|a
ACCEPT_TABLE

# A well-formed name that simply is not in the repo: rc=1, distinct from rc=2. This row
# is what keeps the accept/reject axis from collapsing — without it, "rejected" could be
# satisfied by any non-zero rc.
assert_label_accepted "1g-well-formed-but-absent" "no-such-label" 1

# --- L2: malformed values must be refused before gh sees them ---------------------------
# Rows are grouped by WHY they are dangerous, not by how they look:
#   regex payloads   — would match labels they do not name (`grep -qxF` mitigates, but the
#                      validation is the layer that must not rely on that)
#   shell payloads   — reach a command line
#   structural       — empty, leading dash (parsed as a flag by anything downstream)
while IFS='|' read -r cid value; do
    [ -z "$cid" ] && continue
    assert_label_rejected "$cid" "$value"
done <<'REJECT_TABLE'
2a-regex-wildcard|.*
2b-regex-anchor|^meta$
2c-shell-semicolon|meta;rm -rf /
2d-shell-substitution|$(id)
2e-shell-backtick|`id`
2f-shell-pipe|meta|x
2g-shell-glob|meta*
2h-space|meta foo
2i-leading-dash|-meta
2j-double-dash-flag|--repo
2k-leading-dot|.meta
2l-quote|meta"x
2m-backslash|meta\x
REJECT_TABLE

# The empty string cannot be expressed as a table row (a blank cid is the loop's own
# terminator), and it is the row that matters most: an unset-looking value that would
# make `grep -qxF ""` match any blank line in the label list.
assert_label_rejected "2o-empty-string" ""

# An embedded newline is the one payload a line-oriented table cannot express at all, and
# the one the anchors exist for: bash's =~ with ^…$ matches per-line unless the whole
# string is anchored, so "meta\nrm -rf /" must not pass on the strength of its first line.
assert_label_rejected "2p-embedded-newline" "$(printf 'meta\nrm -rf /')"
# $'…', not "$(printf …)": command substitution strips the trailing newline, which would
# silently turn this row into a duplicate of the valid `meta` row above.
assert_label_rejected "2q-trailing-newline" $'meta\n'

# --- L3: length is NOT constrained — pinned as observed ---------------------------------
# GitHub caps label names at 50 characters; the regex does not. A 300-character name in
# the admitted charset therefore passes validation and is sent to `gh label list`, where
# it simply fails to match and returns rc=1 ("absent"). That is harmless — the value is
# still charset-clean — so this is pinned rather than reported as a defect. If a length
# bound is added later, this case fails and is the place to record the new limit.
LONG_LABEL="$(printf 'a%.0s' $(seq 1 300))"
pf_run --check-labels --label "$LONG_LABEL"
if [ "$PF_RC" -eq 1 ]; then
    pass "L3-over-long-name-is-not-length-checked"
else
    fail "L3-over-long-name-is-not-length-checked" "want rc=1 (charset-valid, simply absent) for a 300-char label (got: $PF_RC) — if a length cap was added, re-pin this case to rc=2"
fi

# --- L4: the flag's own argv contract ----------------------------------------------------
# `--label` with nothing after it must not silently fall back to the `type:task` default:
# a caller asking about `meta` and receiving an answer about `type:task` is the worst
# possible outcome of this script, because it is a plausible-looking rc=0.
pf_run --check-labels --label
if [ "$PF_RC" -eq 2 ]; then
    pass "L4-dangling-label-flag-rejected"
else
    fail "L4-dangling-label-flag-rejected" "want rc=2 for a trailing --label with no value (got: $PF_RC)"
fi
n=$(gh_call_count)
if [ "${n:-0}" -eq 0 ]; then
    pass "L4b-dangling-label-flag-makes-no-gh-call"
else
    fail "L4b-dangling-label-flag-makes-no-gh-call" "want 0 gh invocations (got: ${n:-0})"
fi

# The `--label=NAME` spelling reaches the same validation. It is a separate parser branch
# in the source, so a fix applied to one form and not the other would go unnoticed.
pf_run --check-labels --label=meta
if [ "$PF_RC" -eq 0 ]; then
    pass "L4c-equals-form-accepted"
else
    fail "L4c-equals-form-accepted" "want rc=0 for --label=meta (got: $PF_RC; stderr: $PF_ERR)"
fi
pf_run --check-labels "--label=.*"
n=$(gh_call_count)
if [ "$PF_RC" -eq 2 ] && [ "${n:-0}" -eq 0 ]; then
    pass "L4d-equals-form-validated-too"
else
    fail "L4d-equals-form-validated-too" "want rc=2 with 0 gh calls for --label=.* (got rc=$PF_RC, ${n:-0} gh calls)"
fi

# Omitting --label entirely keeps the documented default. Asserted so the validation
# above can never be "fixed" by making the flag mandatory without anyone noticing that
# every existing caller of --check-labels passes no label at all.
pf_run --check-labels
if [ "$PF_RC" -eq 0 ] && gh_called_with "label list"; then
    pass "L4e-default-label-still-type-task"
else
    fail "L4e-default-label-still-type-task" "want rc=0 (type:task exists in the mock repo) with a gh label list call (got: $PF_RC)"
fi

teardown_mock
