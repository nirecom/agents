# shellcheck shell=bash
# Tests: hooks/workflow-run-tests.js
# Tags: workflow, tests, runner, hook, detection-matrix, TL2, scope:common
# Case group: Table-driven detection matrix (DM-group) — issue #1330 C1.
# Systematically covers every READ_ONLY_CMDS entry, every GIT_NON_EXEC_SUBCMDS
# entry, and every test-runner regex branch in isTestCommand().
# Sourced by main-workflow-run-tests.sh; relies on helpers from common.sh.
#
# Columns: label | command | expected
#   expected=absent  → read-only / git-non-exec / sentinel path: hook must not
#                      write state (check_state_file_absent).
#   expected=pending → runner detected: with write_tests seeded complete, a bare
#                      runner (no run-all.sh contract) actively demotes to pending.

run_detection_matrix_tests() {
    echo ""
    echo "=== workflow-run-tests: Detection matrix (#1330 C1) ==="

    while IFS='|' read -r label cmd expected; do
        # Skip blank lines and comment rows in the heredoc table
        case "$label" in
            ''|'#'*) continue ;;
        esac

        # Trim surrounding whitespace from the three fields
        label="${label#"${label%%[![:space:]]*}"}"; label="${label%"${label##*[![:space:]]}"}"
        cmd="${cmd#"${cmd%%[![:space:]]*}"}"; cmd="${cmd%"${cmd##*[![:space:]]}"}"
        expected="${expected#"${expected%%[![:space:]]*}"}"; expected="${expected%"${expected##*[![:space:]]}"}"

        # Sanitize label into a filesystem-safe SID fragment
        local safe_label="${label//[^a-zA-Z0-9_-]/_}"
        local SID="dm-$$-$RANDOM-$safe_label"

        if [ "$expected" = "pending" ]; then
            # Runner rows: seed write_tests=complete so a detected command demotes
            # run_tests to pending (active demotion path).
            seed_write_tests "$SID" "complete"
            run_run_tests_hook "$cmd" 0 "$SID"
            local STATUS
            STATUS=$(get_run_tests_status "$SID")
            if [ "$STATUS" = "pending" ]; then
                pass "DM/$label. $cmd -> run_tests=pending (runner detected)"
            else
                fail "DM/$label. $cmd -> expected pending (runner detected), got run_tests=$STATUS"
            fi
        else
            # absent rows: do NOT seed — hook must leave state untouched.
            run_run_tests_hook "$cmd" 0 "$SID"
            if check_state_file_absent "$SID"; then
                pass "DM/$label. $cmd -> state absent (read-only / non-exec)"
            else
                local STATUS
                STATUS=$(get_run_tests_status "$SID")
                fail "DM/$label. $cmd -> expected absent (read-only / non-exec), got run_tests=$STATUS"
            fi
        fi
    done <<'TABLE'
# --- READ_ONLY_CMDS entries (every entry; command references tests/) ---
ro-ls        | ls tests/                       | absent
ro-cat       | cat tests/foo.sh                | absent
ro-head      | head tests/foo.sh               | absent
ro-tail      | tail tests/foo.sh               | absent
ro-grep      | grep x tests/                   | absent
ro-rg        | rg x tests/                     | absent
ro-find      | find tests/ -name foo           | absent
ro-wc        | wc -l tests/foo.sh              | absent
ro-file      | file tests/foo.sh               | absent
ro-stat      | stat tests/foo.sh               | absent
ro-echo      | echo tests/foo.sh               | absent
ro-printf    | printf tests/foo.sh             | absent
ro-which     | which pytest                    | absent
ro-type      | type pytest                     | absent
ro-pwd       | pwd tests/                       | absent
# --- GIT_NON_EXEC_SUBCMDS entries (every entry; git <sub> tests/foo.sh) ---
git-diff       | git diff tests/foo.sh       | absent
git-log        | git log tests/foo.sh        | absent
git-show       | git show tests/foo.sh       | absent
git-status     | git status tests/foo.sh     | absent
git-blame      | git blame tests/foo.sh      | absent
git-ls-files   | git ls-files tests/foo.sh   | absent
git-ls-tree    | git ls-tree tests/foo.sh    | absent
git-cat-file   | git cat-file tests/foo.sh   | absent
git-rev-parse  | git rev-parse tests/foo.sh  | absent
git-fetch      | git fetch tests/foo.sh      | absent
git-remote     | git remote tests/foo.sh     | absent
git-add        | git add tests/foo.sh        | absent
git-commit     | git commit tests/foo.sh     | absent
git-push       | git push tests/foo.sh       | absent
git-merge      | git merge tests/foo.sh      | absent
git-rebase     | git rebase tests/foo.sh     | absent
git-pull       | git pull tests/foo.sh       | absent
git-stash      | git stash tests/foo.sh      | absent
git-tag        | git tag tests/foo.sh        | absent
git-gitdir-sep   | git --git-dir .git diff tests/foo.sh | absent
git-C-nosub      | git -C tests/                       | absent
git-worktree-nosub | git --work-tree tests/             | absent
# --- Test-runner branches (each regex branch; runner detected -> pending) ---
run-pytest        | pytest tests/                 | pending
run-jest          | jest tests/                   | pending
run-vitest        | vitest tests/                 | pending
run-mocha         | mocha tests/                  | pending
run-pester        | pester tests/                 | pending
run-invoke-pester | invoke-pester tests/          | pending
run-uv-pytest     | uv run pytest tests/          | pending
run-bash          | bash tests/foo.sh             | pending
run-sh            | sh tests/foo.sh               | pending
run-node          | node tests/foo.js             | pending
run-pwsh          | pwsh tests/foo.ps1            | pending
run-powershell     | powershell tests/foo.ps1     | pending
run-powershell-exe | powershell.exe tests/foo.ps1 | pending
run-tests-ps1      | x.Tests.ps1                  | pending
# --- C1: singular test/ directory (regex tests?/ covers both singular and plural) ---
c1-cat-test        | cat test/foo.sh                | absent
c1-bash-test       | bash test/foo.sh               | pending
c1-pytest-test     | pytest test/                   | pending
# --- C2: word-boundary false-positive (tests substring inside another word) ---
c2-node-contest    | node script.js contest/foo.sh  | absent
c2-cat-contest     | cat src/contest/foo.sh         | absent
# --- C-subshell: subshell parens (parser strips leading `(`) ---
subshell-cat    | (cat tests/foo.sh)  | absent
subshell-pytest | (pytest tests/)     | pending
subshell-bash   | (bash tests/foo.sh) | pending
# --- C4: git grep (now in GIT_NON_EXEC_SUBCMDS) ---
c4-git-grep-path   | git grep tests/foo             | absent
c4-git-grep-runner | git grep pytest tests/         | absent
# --- C5: inline --opt=value git global options (single token; next token NOT consumed) ---
git-inline-worktree  | git --work-tree=/x diff tests/foo.sh   | absent
git-inline-namespace | git --namespace=ns log tests/           | absent
git-inline-execpath  | git --exec-path=/p status tests/        | absent
git-inline-superpfx  | git --super-prefix=pre/ diff tests/     | absent
# #1273: `git archive tests/` executes nothing — it writes an archive of that
# path. The old `pending` expectation froze a false positive of the substring
# matcher; under the execution-position model `tests/` here is an argument value.
git-archive-tests    | git archive tests/                      | absent
# --- #1273 / #1798: execution-position model (detail plan S2-5) -------------
# Only the head, an interpreter's script/module operand, and a known
# dispatcher's worker name are execution positions.
wd-test-runner     | node /r/bin/worker-dispatch.js test-runner /r /p/s-worker-test-runner.json | pending
# Same dispatcher, different worker: nothing here runs a test suite.
wd-other-worker    | node /r/bin/worker-dispatch.js doc-append /r /p/s-worker-doc-append.json   | absent
py-m-pytest        | python -m pytest tests/                 | pending
py-m-unittest      | python -m unittest discover tests/      | pending
timeout-bash       | timeout 120 bash tests/foo.sh           | pending
timeout-k-bash     | timeout -k 5 120 bash tests/foo.sh      | pending
env-bash           | env FOO=1 bash tests/foo.sh             | pending
command-v-pytest   | command -v pytest                       | absent
invoke-pester-real | Invoke-Pester tests/X.Tests.ps1         | pending
powershell-file    | PowerShell.exe -File tests/X.ps1        | pending
# BODY form: the whole command is folded into one argv token and is never
# recursed into — parsing inside a token would reintroduce the substring axis.
pwsh-command-body  | pwsh -Command "Invoke-Pester tests/X.Tests.ps1"  | absent
# `--require` takes a VALUE; the script operand is the next token.
node-require-target | node --require ./setup.js tests/foo.js | pending
node-require-value  | node --require tests/setup.js app.js   | absent
# Also a BODY form: `-x`'s argument is a single argv token whose basename is in
# no head table. The asymmetry with `git bisect run bash tests/foo.sh` (detected)
# is deliberate — there the executed command occupies SEPARATE argv tokens, so
# recursion is well-defined without reading inside a token.
git-rebase-exec    | git rebase -x "bash tests/foo.sh" main  | absent
TABLE
}
