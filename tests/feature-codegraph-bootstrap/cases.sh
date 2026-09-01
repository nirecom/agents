# shellcheck shell=bash
# Tests: install/codegraph-mcp.js, install/linux/codegraph.sh
# Tags: codegraph, installer, mcp-registration, env-flag, fail-safe-off, usage-error, TL2, pwsh-not-required, scope:issue-specific, dup-group-keep:size-hard-limit
# The single ST-19 case table (B1-B18) plus the post-conditions asserted after every
# case. Sourced last; the dispatcher's `# Serial:` justification holds unchanged.

# Columns: name | entry | flag | envfile | mcp-pre | codegraph | npm | claude | node |
# claude-md | want. `npm`/`claude` carry the stub's exit code, or `no` to take that
# binary off PATH. `want` composes exit code, `npm install -g` calls, `claude mcp add`
# / `remove` / any-`mcp` calls and stderr line count into one string.
while IFS='|' read -r name entry flag envfile mcp_pre with_cg npm_mode claude_mode with_node md_kind want; do
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name//[[:space:]]/}"; entry="${entry//[[:space:]]/}"; flag="${flag//[[:space:]]/}"
    envfile="${envfile//[[:space:]]/}"; mcp_pre="${mcp_pre//[[:space:]]/}"
    with_cg="${with_cg//[[:space:]]/}"; npm_mode="${npm_mode//[[:space:]]/}"
    claude_mode="${claude_mode//[[:space:]]/}"; with_node="${with_node//[[:space:]]/}"
    md_kind="${md_kind//[[:space:]]/}"
    want="${want#"${want%%[![:space:]]*}"}"; want="${want%"${want##*[![:space:]]}"}"

    run_case "$name" "$entry" "$flag" "$envfile" "$mcp_pre" "$with_cg" \
        "$npm_mode" "$claude_mode" "$with_node" "$md_kind"
    assert_eq "$name: observable outcome" "$want" "$SUMMARY"

    # Exact argv, not a substring: a renamed scope flag or a reordered `--` writes the
    # server into the wrong scope and fails silently (detail plan R-1).
    case "$name" in
        B3|B14) assert_eq "$name: claude argv" "$WANT_MCP_REMOVE" \
                    "$(grep -m1 '^mcp ' "$CASE_DIR/claude.log" || true)" ;;
        B4|B13|B15) assert_eq "$name: claude argv" "$WANT_MCP_ADD" \
                    "$(grep -m1 '^mcp ' "$CASE_DIR/claude.log" || true)" ;;
    esac

    # C16: each sentinel is planted whenever its carrier file exists, so the expected
    # count is derived from this row rather than assumed — a fixture that silently
    # stopped writing one would otherwise turn the leak check green for free.
    want_planted=0
    [ "$envfile" = "absent" ] || want_planted=$((want_planted + 1))
    [ "$mcp_pre" = "missing" ] || want_planted=$((want_planted + 1))
    assert_eq "$name: post/secrets planted in fixtures, absent from every output" \
        "planted=$want_planted leaked=" "$SENTINEL_STATE"

    # Common post-conditions (C1 regression) — asserted after every case.
    assert_eq "$name: post/no codegraph install|uninstall subcommand" "0" "$CG_INSTALL"
    assert_eq "$name: post/settings.json byte-identical" "$PRE_SETTINGS_SHA" "$(digest "$FAKE_HOME/.claude/settings.json")"
    assert_eq "$name: post/CLAUDE.md byte-identical" "$PRE_MD_SHA" "$(digest "$FAKE_HOME/.claude/CLAUDE.md")"
    # C10: the helper only reads ~/.claude.json; `claude mcp add|remove` owns every
    # write and is a recording stub here, so identity must hold in all 18 rows.
    assert_eq "$name: post/.claude.json byte-identical (writes delegated to the claude CLI)" \
        "$PRE_JSON_SHA" "$(digest "$FAKE_HOME/.claude.json")"
    if [ "$md_kind" = "symlink" ] && [ "$PRE_MD_KIND" != "symlink" ]; then
        skip_env "$name: post/CLAUDE.md file type — this shell cannot create a real symlink; only byte identity was checked"
    else
        assert_eq "$name: post/CLAUDE.md file type unchanged" "$PRE_MD_KIND" "$(file_kind "$FAKE_HOME/.claude/CLAUDE.md")"
    fi
    assert_eq "$name: post/no Cursor|Codex|Copilot config" "" \
        "$(find "$FAKE_HOME" \( -name '.cursor' -o -name '.codex' -o -path '*/.config/github-copilot*' \) -print 2>/dev/null | head -3 | tr '\n' ' ' | sed 's/ *$//')"
done <<'TABLE'
# B1/B2/B7 pin fail-safe OFF, B3 the on->off transition, B4 registration, B5
# idempotency, B6/B8/B9 the plan's three failure paths, B10-B16 the error paths the
# review found missing, B17/B18 the usage errors that alone exit 64 rather than 0.
# name | entry  | flag    | envfile | mcp-pre | cg  | npm | claude | node | claude-md | want
B1     | sh     |         | absent  | none    | no  | 0   | 0      | yes  | file      | rc=0 npmi=0 add=0 rm=0 mcp=0 err=0
B2     | sh     | off     | present | none    | no  | 0   | 0      | yes  | file      | rc=0 npmi=0 add=0 rm=0 mcp=0 err=0
B3     | sh     | off     | present | present | no  | 0   | 0      | yes  | symlink   | rc=0 npmi=0 add=0 rm=1 mcp=1 err=0
B4     | sh     | on      | present | none    | no  | 0   | 0      | yes  | symlink   | rc=0 npmi=1 add=1 rm=0 mcp=1 err=0
B5     | sh     | on      | present | present | yes | 0   | 0      | yes  | file      | rc=0 npmi=0 add=0 rm=0 mcp=0 err=0
B6     | sh     | on      | present | none    | no  | 1   | 0      | yes  | file      | rc=0 npmi=1 add=0 rm=0 mcp=0 err=1
B7     | sh     | garbage | present | none    | no  | 0   | 0      | yes  | file      | rc=0 npmi=0 add=0 rm=0 mcp=0 err=0
B8     | sh     | on      | present | none    | no  | 0   | 0      | no   | file      | rc=0 npmi=0 add=0 rm=0 mcp=0 err=1
B9     | sh     | on      | present | broken  | yes | 0   | 0      | yes  | file      | rc=0 npmi=0 add=0 rm=0 mcp=0 err=1
B10    | sh     | on      | present | none    | no  | 0   | no     | yes  | file      | rc=0 npmi=1 add=0 rm=0 mcp=0 err=1
B11    | sh     | off     | present | present | no  | 0   | no     | yes  | file      | rc=0 npmi=0 add=0 rm=0 mcp=0 err=1
B12    | sh     | on      | present | none    | no  | no  | 0      | yes  | file      | rc=0 npmi=0 add=0 rm=0 mcp=0 err=1
B13    | sh     | on      | present | none    | no  | 0   | 1      | yes  | file      | rc=0 npmi=1 add=1 rm=0 mcp=1 err=1
B14    | sh     | off     | present | present | no  | 0   | 1      | yes  | symlink   | rc=0 npmi=0 add=0 rm=1 mcp=1 err=1
B15    | sh     | on      | present | missing | no  | 0   | 0      | yes  | file      | rc=0 npmi=1 add=1 rm=0 mcp=1 err=0
B16    | sh     | off     | present | missing | no  | 0   | 0      | yes  | file      | rc=0 npmi=0 add=0 rm=0 mcp=0 err=0
B17    | bogus  | on      | present | none    | no  | 0   | 0      | yes  | file      | rc=64 npmi=0 add=0 rm=0 mcp=0 err=1
B18    | noverb | on      | present | none    | no  | 0   | 0      | yes  | file      | rc=64 npmi=0 add=0 rm=0 mcp=0 err=1
TABLE
