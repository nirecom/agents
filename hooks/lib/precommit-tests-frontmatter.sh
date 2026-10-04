#!/bin/bash
# Sourced by hooks/pre-commit. Staged tests/ entrypoint gates (frontmatter / case markers).
# Frontmatter (#1834, #2392): validates staged test entrypoints and rejects newly-added flat
# ones; the CAUSE-SPECIFIC message is keyed on check-test-frontmatter.sh stderr codes
# (FLAT_TEST*_REJECTED = location, MISSING_*/INVALID_* = shape); both may fire in one run.
# Case markers (#2388): docs/architecture/claude-code/case-marker-gate.md.

# _precommit_tlr_ready — loads $_cfg_dir's test language registry (once per _cfg_dir);
# rc 1 when it is unreadable. Called only once a staged tests/ path is known.
_precommit_tlr_ready() {
    if [ "${_PRECOMMIT_TLR_CFG-}" != "$_cfg_dir" ]; then
        # shellcheck source=bin/lib/test-language-registry.sh
        . "$_cfg_dir/bin/lib/test-language-registry.sh" 2>/dev/null || return 1
        _PRECOMMIT_TLR_CFG="$_cfg_dir"
    fi
    tlr_load 2>/dev/null
}

# _precommit_tlr_unreadable <gate> — the single stderr line of an unreadable registry.
_precommit_tlr_unreadable() {
    echo "pre-commit: test language registry not readable — $1 skipped (commit continues)" >&2
}

# _precommit_is_suite_subfile <rel> — under a tests/<category>/<dir>/ (a split test's sub-file).
_precommit_is_suite_subfile() {
    case "$1" in
        tests/hooks/*/*|tests/bin/*/*|tests/skills/*/*|tests/agents/*/*|tests/install/*/*|tests/tests/*/*) return 0 ;;
    esac
    return 1
}

# _precommit_is_case_marker_target <rel> — case-marker entrypoint SSOT (mirrored by
# hooks/block-case-markers.js isCaseMarkerTarget; parity-tested): a placed file whose
# registry entry is supported with a caseMarkerReader. rc 0 = target, rc 1 = excluded
# (archive/lib/run-all/suite sub-file), rc 2 = unclassified (or registry unreadable).
_precommit_is_case_marker_target() {
    case "$1" in
        tests/_archive/*|tests/lib/*|tests/run-all.sh) return 1 ;;
    esac
    _precommit_tlr_ready || return 2
    tlr_match "$1" && [ "$TLR_STATUS" = supported ] && _tlr_get "$TLR_ID" caseMarkerReader.file || return 2
    _precommit_is_suite_subfile "$1" && return 1
    case "$1" in
        tests/hooks/*|tests/bin/*|tests/skills/*|tests/agents/*|tests/install/*|tests/tests/*) return 0 ;;
        tests/*/*) return 2 ;;
        tests/*) return 0 ;;  # flat tests/<name>
        *) return 2 ;;
    esac
}

# _precommit_check_tests_frontmatter — reads $_cfg_dir (ambient, as load-env.sh does).
# rc 0 = ok / nothing staged; rc 1 = block the commit.
_precommit_check_tests_frontmatter() {
    local -a _staged_tests=()
    local f _out _rc=0 _id _labels=""
    while IFS= read -r -d '' f; do
        case "$f" in
            tests/_archive/*|tests/lib/*|tests/run-all.sh) continue ;;
            tests/*) ;;
            *) continue ;;
        esac
        _precommit_tlr_ready || { _precommit_tlr_unreadable "frontmatter check"; return 0; }
        # Any supported test name under tests/ except a suite sub-file; unclassified
        # directories and flat files are forwarded so the checker can reject them (#1834, #2392).
        tlr_match "$f" || continue
        _precommit_is_suite_subfile "$f" && continue
        if [ "$TLR_STATUS" != supported ]; then
            case "$f" in
                tests/hooks/*|tests/bin/*|tests/skills/*|tests/agents/*|tests/install/*|tests/tests/*)
                    echo "UNSUPPORTED: $f (language: $TLR_ID; not checked)" >&2 ;;
            esac
            continue
        fi
        _staged_tests+=("$f")
    done < <(git diff --cached --name-only -z -- 'tests/' 2>/dev/null || true)

    [ "${#_staged_tests[@]}" -eq 0 ] && return 0

    # Capture stderr so the cause can be classified; the checker prints only
    # diagnostics (no stdout), so 2>&1 collects the per-file CODE: lines.
    # _cfg_dir is the ambient contract var set by the sourcing hooks/pre-commit.
    # shellcheck disable=SC2154
    _out="$("$_cfg_dir/bin/check-test-frontmatter.sh" --staged "${_staged_tests[@]}" 2>&1)" || _rc=$?
    [ "$_rc" -eq 0 ] && return 0

    # Re-display the checker's per-file diagnostics (file + reason).
    [ -n "$_out" ] && printf '%s\n' "$_out"
    echo ""

    # Cause-specific summaries, keyed on the checker's stderr codes (both may fire).
    if printf '%s\n' "$_out" | grep -qE '^FLAT_TEST_[A-Z_]*REJECTED:'; then
        while IFS= read -r _id; do
            _tlr_get "$_id" diagnostics.nameLabel || continue
            _labels="${_labels:+$_labels / }$_TLR_V"
        done < <(tlr_ids supported)
        echo "Commit blocked: new test entrypoint placed directly under tests/."
        echo "A test entrypoint ($_labels) must live under tests/<category>/ (categories: hooks bin skills agents install tests)."
        echo "Move it into the matching category dir, e.g. tests/hooks/<name>.sh."
    fi
    if printf '%s\n' "$_out" | grep -qE 'MISSING_TESTS_HEADER|INVALID_TESTS_TOKEN|MISSING_SCOPE_TAG|MISSING_HARNESS_SOURCE'; then
        echo "Commit blocked: staged test file(s) fail frontmatter validation."
        echo "Each file must have '# Tests: <path>' (comma-separated tokens) and '# Tags: ... scope:...'."
    fi
    return 1
}

# _precommit_check_tests_case_markers — judges the STAGED blob of every new (HEAD-absent,
# renames included) case-marker entrypoint with bin/check-case-markers.sh, in repos carrying
# its entry's helperLibrary. Checker infra errors fail open with a stderr diagnostic.
# rc 0 = ok / not applicable; rc 1 = block the commit.
_precommit_check_tests_case_markers() {
    local repo_top rel tmp="" n=0 tmpfile out rc line
    local -a rels=() high=()
    local missing=0 malformed=0 tried=0

    repo_top="$(git rev-parse --show-toplevel 2>/dev/null || true)"
    [ -n "$repo_top" ] || return 0

    # A process substitution hides git's exit status, so probe it first: a failed
    # lookup must say so rather than read as "no new tests".
    if ! git diff --cached --name-only -- 'tests/' >/dev/null 2>&1; then
        echo "pre-commit: cannot list staged tests — case-marker check skipped (commit continues)" >&2
        return 0
    fi
    while IFS= read -r -d '' rel; do
        [ -n "$rel" ] || continue
        if [ "$tried" -eq 0 ]; then
            tried=1
            _precommit_tlr_ready || { _precommit_tlr_unreadable "case-marker check"; return 0; }
        fi
        _precommit_is_case_marker_target "$rel" || continue
        # Staged view, like the blobs judged below: an unstaged add/delete must not flip applicability.
        _tlr_get "$TLR_ID" helperLibrary.path && git cat-file -e ":$_TLR_V" 2>/dev/null || continue
        git cat-file -e "HEAD:$rel" 2>/dev/null && continue
        rels+=("$rel")
    done < <(git diff --cached --name-only -z --diff-filter=ACMR -- 'tests/' 2>/dev/null || true)
    [ "${#rels[@]}" -eq 0 ] && return 0

    if ! tmp="$(mktemp -d 2>/dev/null)" || [ -z "$tmp" ]; then
        echo "pre-commit: mktemp failed — case-marker check skipped (commit continues)" >&2
        return 0
    fi

    for rel in "${rels[@]}"; do
        n=$((n + 1))
        mkdir -p "$tmp/$n"
        tmpfile="$tmp/$n/${rel##*/}"
        if ! git show ":$rel" > "$tmpfile" 2>/dev/null; then
            echo "pre-commit: cannot read staged blob for $rel — case-marker check skipped for it" >&2
            continue
        fi
        rc=0
        out="$(bash "$_cfg_dir/bin/check-case-markers.sh" "$tmpfile" 2>&1)" || rc=$?
        out="${out//"$tmpfile"/$rel}"
        if [ "$rc" -eq 1 ] && printf '%s\n' "$out" | grep -qE '^HIGH: .* code='; then
            while IFS= read -r line; do
                case "$line" in
                    HIGH:*code=MISSING_CASE_MARKERS*) high+=("$line"); missing=1 ;;
                    HIGH:*code=MALFORMED_CASE_MARKER*) high+=("$line"); malformed=1 ;;
                    HIGH:*) high+=("$line") ;;
                    *) ;;
                esac
            done <<< "$out"
        elif [ "$rc" -eq 0 ]; then
            [ -n "$out" ] && printf '%s\n' "$out" >&2
        else
            echo "pre-commit: check-case-markers rc=$rc for $rel — case-marker check incomplete (commit continues)" >&2
            [ -n "$out" ] && printf '%s\n' "$out" >&2
        fi
    done
    rm -rf "$tmp"

    [ "${#high[@]}" -eq 0 ] && return 0
    printf '%s\n' "${high[@]}"
    echo ""
    echo "Commit blocked: new test file(s) fail the case-marker gate."
    [ "$missing" -eq 1 ] && echo "Wrap each case in case_begin/case_end (tests/lib/harness.sh)."
    [ "$malformed" -eq 1 ] && echo "Fix marker placement — see skills/_shared/test-design/case-markers.md."
    return 1
}
