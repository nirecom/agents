#!/usr/bin/env bash
# tests/bin/feature-2455-test-load-control/_cache-fixture.sh — the corpus-cache helpers the
# three cache case files share (cache-cases.sh, cache-rekey-cases.sh, cache-fail-soft-cases.sh).
# Relies on _fixture.sh (mk_repo, add_tf, commit_all, run_ft).

# cc_repo — a small committed corpus used by most cases. Echoes its root.
cc_repo() {
    local r
    r="$(mk_repo)"
    add_tf "$r" bin/a.sh "src/x.js,src/y.js"
    add_tf "$r" bin/b.sh "src/x.js"
    add_tf "$r" hooks/c.sh "src/common.js,src/x.js"
    add_tf "$r" skills/d.sh "src/z.js"
    commit_all "$r" "corpus"
    echo "$r"
}

# cc_run <repo> <cache> <mode:on|off> <args...> — run_ft from the neutral dir.
cc_run() {
    local repo="$1" cache="$2" mode="$3"; shift 3
    local -a extra=("RUN_ALL_CACHE_DIR=$cache" TEST_MAX_JOBS_PER_HOST=4)
    [ "$mode" = "off" ] && extra+=(FIND_TESTS_CORPUS_CACHE=off)
    run_ft "$NEUTRAL_DIR" "${extra[@]}" -- --root "$repo" "$@"
}

CC_R="$(cc_repo)"
QS=(--sources src/x.js --sources src/x.js,src/y.js --sources src/none.js)

grp_done _cache-fixture.sh
