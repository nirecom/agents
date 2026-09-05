# shellcheck shell=bash
# Tests: bin/codegraph-lifecycle.js, bin/codegraph-lifecycle/index-health.js
# Tags: codegraph, lifecycle, index-health, success-path, sqlite, scope:issue-specific
# ST-18 L7b / L9s / L11f: the three ways `init` is allowed to END in a working
# index — first build, in-place rebuild, and rebuild after quarantine. Every
# other index case stops at "which verb was chosen"; these run the chosen verb
# through a stub that really writes a DB, so the exit code, the one-line report,
# the silence on stderr, the final DB state and the launch count are all pinned
# on the same run. Review C5: without them a repair could be "selected" forever
# and never observed to produce anything.

echo "--- L7b: a first build reports once and leaves a valid index ---"
reset_env
export CG_STUB_MAKEDB=healthy
root="$(mkroot "l7b")"
make_db "$root" absent
run_cli init "$root"
assert_reported "L7b"
assert_stub_db_built "L7b"
assert_only "L7b" init
assert_db_valid "L7b" "$root"
if [ -e "$(root_sh l7b)/.codegraph/broken" ]; then
    fail "L7b — a first build must never reach the quarantine slot"
else
    pass "L7b — no quarantine directory was created"
fi

echo "--- L9s: an in-place rebuild reports once and leaves a valid index ---"
reset_env
export CG_STUB_MAKEDB=healthy
root="$(mkroot "l9s")"
make_db "$root" zero
run_cli init "$root"
assert_reported "L9s"
assert_stub_db_built "L9s"
assert_only "L9s" index
assert_db_valid "L9s" "$root"
if [ -e "$(root_sh l9s)/.codegraph/broken" ]; then
    fail "L9s — a successful index -q must not fall through to quarantine"
else
    pass "L9s — the quarantine fallback was not reached"
fi

echo "--- L11f: quarantine then a successful re-init still ends valid ---"
reset_env
export CG_STUB_FAIL=index
export CG_STUB_MAKEDB=healthy
root="$(mkroot "l11f")"
root_p="$(root_sh l11f)"
make_db "$root" zero
run_cli init "$root"
assert_reported "L11f"
assert_stub_db_built "L11f"
assert_eq "L11f — index attempted exactly once" "1" "$(verb_count index)"
assert_eq "L11f — the post-quarantine init -y ran exactly once" "1" "$(verb_count init)"
assert_eq "L11f — sync never ran" "0" "$(verb_count sync)"
assert_eq "L11f — status never ran" "0" "$(verb_count status)"
assert_eq "L11f — codegraph launched exactly twice" "2" "$(verb_calls)"
assert_db_valid "L11f" "$root"
if [ -f "$root_p/.codegraph/broken/codegraph.db" ]; then
    pass "L11f — the unusable DB is still parked in the quarantine slot"
else
    fail "L11f — the quarantined DB is missing, so the rebuild was not the recovery path"
fi

echo "--- L11f/sync: the rebuilt index is one the sync gate accepts ---"
# The success paths above assert the DB against this suite's own definition of
# healthy. This row closes the loop end-to-end: the artifact the repair produced
# is the artifact `sync` will actually run against, which is the whole point of
# repairing it.
reset_logs
unset CG_STUB_FAIL CG_STUB_MAKEDB
run_cli sync "$root"
assert_eq "L11f/sync — exit 0" "0" "$RC"
assert_only "L11f/sync" sync
assert_eq "L11f/sync — sync carries the quiet flag" "sync -q" \
    "$(printf '%s' "$(verb_line sync)" | cut -d' ' -f1-2)"
assert_eq "L11f/sync — sync targets the root" "yes" \
    "$(same_path "$root" "$(printf '%s' "$(verb_line sync)" | cut -d' ' -f3-)")"
