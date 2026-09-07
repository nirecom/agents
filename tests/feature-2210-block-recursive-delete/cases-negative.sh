# tests/feature-2210-block-recursive-delete/cases-negative.sh
# Tests: hooks/block-recursive-delete.js, hooks/lib/bash-write-targets/recursive-delete-scan.js
# Tags: scope:issue-specific, recursive-delete, hook, false-positive, negative, TL2, pwsh-not-required
#
# Zero false positives is the reason #2210 moves off the settings.json substring
# globs at all: a glob cannot tell an actual delete from a MENTION of one, and
# `git log -S "Bash(*rm -rf *)"` was really auto-denied while investigating this
# issue (#424 is the same class). Every case here must approve. Also covers the
# non-recursive deletes that stay legal and the sanctioned cleanup route.
# TL3 gap: text-only — no real shell process runs these payloads (see dispatcher).

run_negative_cases() {
    echo ""
    echo "=== Mentions of a recursive delete must approve (never a delete) ==="

    expect_approve_cmd "gh issue create --body mentioning rm -rf" \
        'gh issue create --title "deny cleanup" --body "drop the rm -rf deny rule"'
    expect_approve_cmd "git log -S \"Bash(*rm -rf *)\" (the real #2210 false positive)" \
        'git log -S "Bash(*rm -rf *)"'
    expect_approve_cmd "grep -r \"rm -rf\" . (searching for the literal)" \
        'grep -r "rm -rf" .'
    expect_approve_cmd "echo mentioning Remove-Item -Recurse" \
        'echo "use Remove-Item -Recurse -Force on Windows"'
    expect_approve_cmd "git commit -m mentioning rmdir /s" \
        'git commit -m "document cmd.exe rmdir /s coverage"'

    # Heredoc body: the mention is DATA the shell feeds to a command, not a
    # statement. stripHeredocBody exists exactly so the newline scan cannot
    # mistake body lines for injected statements.
    expect_approve_cmd "heredoc body mentioning rm -rf" \
        $'git commit -m "$(cat <<\'EOF\'\ndrop the rm -rf deny rule\nEOF\n)"'

    # A file whose NAME contains the literal must not implicate the command.
    expect_approve_cmd "path containing 'rm -rf' in its name" \
        'cat "docs/rm -rf-migration.md"'

    # C10: a single-quoted or backslash-escaped $(...) is text, not a real
    # command substitution — the shell that later runs this text would print
    # it literally, never execute it.
    expect_approve_cmd 'echo single-quoted $(rm -rf x) — literal, never substituted' \
        "echo '\$(rm -rf x)'"
    expect_approve_cmd 'echo escaped \$(rm -rf x) inside double quotes — literal, never substituted' \
        'echo "\$(rm -rf x)"'

    echo ""
    echo "=== Non-recursive deletes stay available ==="

    expect_approve_cmd "rm -f dir (non-recursive)" "rm -f dir"
    expect_approve_cmd "rm file.txt (plain single-file delete)" "rm file.txt"
    expect_approve_cmd "rm \"\$file\" (variable single-file target)" 'rm "$file"'
    expect_approve_cmd "Remove-Item -Force dir (no -Recurse)" "Remove-Item -Force dir"
    expect_approve_cmd "Remove-Item -Path \$x (no -Recurse)" 'Remove-Item -Path $x'
    expect_approve_cmd "Remove-Item -Recurse:\$false dir (explicitly disabled)" \
        'Remove-Item -Recurse:$false dir'
    expect_approve_cmd "Remove-Item -Recurse:\$FALSE dir (explicitly disabled, uppercase, round-4 C3)" \
        'Remove-Item -Recurse:$FALSE dir'
    expect_approve_cmd "cmd /c del file.txt (no /s)" "cmd /c del file.txt"

    echo ""
    echo "=== Adjacent shapes that must not over-block ==="

    # Variable name mismatch: the assignment is unrelated to the rm reference.
    expect_approve_cmd "FLAGS=-rf; rm \$OTHER x (name mismatch)" \
        'FLAGS=-rf; rm $OTHER x'
    # Scope guard: this hook is not a general write gate.
    expect_approve_cmd "bash -c 'echo hi > out.txt' (non-recursive write via wrapper)" \
        "bash -c 'echo hi > out.txt'"
    # The sanctioned route must never be blocked by the guard that replaces it.
    expect_approve_cmd "node hooks/cleanup-orphan-dir.js --force-if-not-registered (sanctioned route)" \
        "node hooks/cleanup-orphan-dir.js --force-if-not-registered /tmp/orphan"
    # Out of scope for #2210 (detail.md Out of scope): other destructive verbs.
    expect_approve_cmd "git clean -fd (out of scope)" "git clean -fd"
    expect_approve_cmd "git worktree remove --force (out of scope)" \
        "git worktree remove --force /tmp/wt"
    expect_approve_cmd "ls -R dir (recursive LIST, not delete)" "ls -R dir"
    expect_approve_cmd "grep -r pattern . (-r on a read command)" "grep -r pattern ."
    expect_approve_cmd "cp -r src dst (-r on a copy)" "cp -r src dst"
}
