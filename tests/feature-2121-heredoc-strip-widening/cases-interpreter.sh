# Tests: hooks/lib/strip-quoted-args.js
# Tags: heredoc, strip-quoted-args, security, table-driven, scope:issue-specific
# H3 — interpreter-prefixed openers: the body is a PROGRAM, never strippable.
# Sourced by feature-2121-heredoc-strip-widening.sh.

run_H3() {
    # Security case. RED if the fix takes the issue's literal "drop the cat prefix"
    # wording; GREEN if it drops cat-ONLY while keeping an interpreter guard.
    local label cmd got
    while IFS='|' read -r label cmd; do
        [[ -z "$label" || "$label" =~ ^[[:space:]]*# ]] && continue
        label="${label//[[:space:]]/}"
        got="$(stripped "$cmd")"
        assert_eq "H3 $label: executed body is NOT stripped" "false" "$got"
    done <<'TABLE'
bash-quoted     | bash <<'EOF'\nrm -rf /repo/x\nEOF\n
sh-quoted       | sh <<'EOF'\nrm -rf /repo/x\nEOF\n
zsh-quoted      | zsh <<'EOF'\nrm -rf /repo/x\nEOF\n
dash-quoted     | dash <<'EOF'\nrm -rf /repo/x\nEOF\n
python3-quoted  | python3 <<'PY'\nimport os\nPY\n
node-quoted     | node <<'JS'\nrequire("fs").rmSync("x")\nJS\n
perl-quoted     | perl <<'PL'\nunlink "x"\nPL\n
ruby-quoted     | ruby <<'RB'\nFile.delete("x")\nRB\n
pwsh-quoted     | pwsh <<'PS'\nRemove-Item x\nPS\n
abs-path-bash   | /bin/bash <<'EOF'\nrm -rf /repo/x\nEOF\n
env-prefix-bash | env FOO=1 bash <<'EOF'\nrm -rf /repo/x\nEOF\n
sudo-bash       | sudo bash <<'EOF'\nrm -rf /repo/x\nEOF\n
fish-quoted     | fish <<'EOF'\nrm -rf /repo/x\nEOF\n
powershell-q    | powershell <<'EOF'\nRemove-Item x\nEOF\n
cmd-quoted      | cmd <<'EOF'\ndel x\nEOF\n
command-bash    | command bash <<'EOF'\nrm -rf /repo/x\nEOF\n
exec-bash       | exec bash <<'EOF'\nrm -rf /repo/x\nEOF\n
bare-env-bash   | FOO=1 bash <<'EOF'\nrm -rf /repo/x\nEOF\n
after-semi      | echo hi; bash <<'EOF'\nrm -rf /repo/x\nEOF\n
after-and       | echo hi && bash <<'EOF'\nrm -rf /repo/x\nEOF\n
after-newline   | echo hi\nbash <<'EOF'\nrm -rf /repo/x\nEOF\n
# --- NON-HEAD sink word: `cat` is an ARGUMENT, not the head of its segment ----
# The rows above are stopped by the interpreter sitting BEFORE the opener. These
# are the complementary shape the sink-anchoring lookbehind
# `(?<=(?:^|[\n;&|])[ \t]*)` exists for: a literal `cat` appears, but only as an
# argument, so no sink owns the redirection. `bash -s cat` hands the heredoc to
# an interpreter; `git cat-file` is stopped one layer earlier by the `(?![\w-])`
# word boundary. Both must leave the body visible to the write scanners.
bash-s-cat-arg  | bash -s cat <<'EOF'\nrm -rf /repo/x\nEOF\n
echo-cat-arg    | echo cat <<'EOF' > out.txt\nrm -rf /repo/x\nEOF\n
git-cat-file    | git cat-file -p HEAD <<'EOF'\nrm -rf /repo/x\nEOF\n
TABLE

    # Change-detection cannot tell "anchored out" from "matched nothing": pin the
    # body TEXT for both non-head shapes, and pin the CONTROL where the very same
    # `cat` really is a segment head — so the refusals are attributable to the
    # anchor, not to a matcher that simply failed on this payload shape.
    assert_eq "H3 non-head sink (bash -s cat): body text survives" "false" \
        "$(body_gone "bash -s cat <<'EOF'\\nRMPAYLOAD\\nEOF\\n" "RMPAYLOAD")"
    assert_eq "H3 non-head sink (git cat-file): body text survives" "false" \
        "$(body_gone "git cat-file -p HEAD <<'EOF'\\nRMPAYLOAD\\nEOF\\n" "RMPAYLOAD")"
    assert_eq "H3 control: after a real newline boundary cat IS the head and the body IS stripped" "true" \
        "$(body_gone "bash -s\\ncat <<'EOF' > out.txt\\nRMPAYLOAD\\nEOF\\n" "RMPAYLOAD")"
}
