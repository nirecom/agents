# C12 (#2500): a broken or missing test-language registry table aborts the selection with
# exit 4 and nothing on stdout (an empty list would read as all-green). The registry is loaded
# lazily, so a docs-only diff stays an empty exit-0 selection even then. A valid table is the
# control. Sourced by tests/bin/feature-689-select-tests.sh (make_fake_selector, has_suffix_line).

# c12_repo <repo> <changed-path> — base commit + one HEAD commit that touches <changed-path>.
c12_repo() {
    local repo="$1"
    mkdir -p "$repo"
    git -C "$repo" init -q
    git -C "$repo" config user.email "test@example.com"
    git -C "$repo" config user.name  "Test"
    : > "$repo/README.md"
    git -C "$repo" add -A
    git -C "$repo" -c core.hooksPath= commit -q -m "base"
    git -C "$repo" branch -f base HEAD
    mkdir -p "$repo/$(dirname "$2")"
    echo "change" > "$repo/$2"
    git -C "$repo" add -A
    git -C "$repo" -c core.hooksPath= commit -q -m "head"
}

# c12_run <mode:valid|invalid-json|missing> <changed-path> — sets C12_OUT / C12_ERR / C12_RC.
c12_run() {
    local mode="$1" changed="$2" tag
    tag="$mode-${changed//\//_}"
    local fake="$TMPDIR_BASE/c12-agents-$tag" repo="$TMPDIR_BASE/c12-repo-$tag"
    make_fake_selector "$fake"
    : > "$fake/tests/bin/widget-probe.sh"
    case "$mode" in
        invalid-json) printf '%s\n' '{ "schema": 1, "entries": [' > "$fake/hooks/lib/test-language-registry.json" ;;
        missing) rm -f "$fake/hooks/lib/test-language-registry.json" ;;
    esac
    c12_repo "$repo" "$changed"
    C12_RC=0
    C12_OUT="$(cd "$repo" && run_with_timeout 120 bash "$fake/bin/select-tests.sh" base HEAD 2>"$TMPDIR_BASE/c12-err-$tag")" || C12_RC=$?
    C12_ERR="$(cat "$TMPDIR_BASE/c12-err-$tag")"
}

test_C12_registry_unreadable_aborts() {
    local mode
    c12_run valid bin/widget-probe.sh
    if [ "$C12_RC" = "0" ] && has_suffix_line "$C12_OUT" "/tests/bin/widget-probe.sh"; then
        pass "C12_registry_unreadable_aborts: control — valid table selects widget-probe.sh (exit 0)"
    else
        fail "C12_registry_unreadable_aborts: control — rc=$C12_RC out='$C12_OUT' err='$C12_ERR'"
    fi
    for mode in invalid-json missing; do
        c12_run "$mode" bin/widget-probe.sh
        if [ "$C12_RC" = "4" ] && [ -z "$C12_OUT" ] \
            && [[ "$C12_ERR" == *"the test language registry is not readable"*"test selection aborted."* ]]; then
            pass "C12_registry_unreadable_aborts: $mode table + code diff → exit 4, empty stdout, registry named"
        else
            fail "C12_registry_unreadable_aborts: $mode table + code diff — rc=$C12_RC out='$C12_OUT' err='$C12_ERR'"
        fi
        c12_run "$mode" docs/notes.md
        if [ "$C12_RC" = "0" ] && [ -z "$C12_OUT" ]; then
            pass "C12_registry_unreadable_aborts: $mode table + docs-only diff → registry not loaded, empty exit 0"
        else
            fail "C12_registry_unreadable_aborts: $mode table + docs-only diff — rc=$C12_RC out='$C12_OUT' err='$C12_ERR'"
        fi
    done
}
