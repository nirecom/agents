# shellcheck shell=bash
# Tests: bin/codegraph-lifecycle/process-identity.js
# Tags: codegraph, lifecycle, process-identity, tokenizer, parser, security, scope:issue-specific
# ST-18 L19g / L19h: tokenizeCommandLine and the matcher it feeds, driven
# directly (L19e covers one quoted path end-to-end via spawn). Ambiguous
# input must land on "do not kill" (ST-11b) — a wrong verdict kills someone
# else's process, so the no-kill rows are the security cases and the kill
# rows are their controls.

echo "--- L19g: tokenizeCommandLine splits on the argument boundaries it claims ---"
while IFS='|' read -r case_id cmdline want; do
    [ -n "$case_id" ] || continue
    case_id="$(trim_field "$case_id")"
    want="$(trim_field "$want")"
    assert_eq "L19g/$case_id" "$want" "$(tok_tokens "$cmdline")"
done <<'TABLE'
plain|a b c|[a][b][c]
space-run|a   b|[a][b]
leading-space| a b|[a][b]
empty-arg|a "" b|[a][][b]
quoted-space|a "b c" d|[a][b c][d]
quote-mid-token|a b"c d"e|[a][bc de]
escaped-quote|a \"b\" c|[a]["b"][c]
equals-form|--path=/r|[--path=/r]
longer-flag|--path-prefix /r|[--path-prefix][/r]
quoted-flag-and-value|"--path /r"|[--path /r]
metachar-value|--path "/r; rm -rf /"|[--path][/r; rm -rf /]
metachar-bare|--path /r&&whoami|[--path][/r&&whoami]
doubled-backslash-before-close|a "C:\repo\\" b|[a][C:\repo\][b]
odd-run-mid-quote|a "x\\\"y" b|[a][x\"y][b]
TABLE

echo "--- L19h: an argument the tokenizer cannot resolve never becomes a kill ---"
# %R% is the real root the matcher is asked about. Rows expecting `kill` are the
# controls: they share the shape of the no-kill rows and differ only in the one
# detail under test, so a matcher that answers "no" to everything fails here
# instead of passing the whole table.
tok_root="$(mkroot "tok")"
while IFS='|' read -r case_id cmdline want; do
    [ -n "$case_id" ] || continue
    case_id="$(trim_field "$case_id")"
    want="$(trim_field "$want")"
    assert_eq "L19h/$case_id" "$want" "$(tok_verdict "${cmdline//%R%/$tok_root}" "$tok_root")"
done <<'TABLE'
control-plain|/opt/cg/codegraph.js serve --mcp --path %R%|kill
control-quoted|/opt/cg/codegraph.js serve --mcp --path "%R%"|kill
control-second-path|/opt/cg/codegraph.js serve --mcp --path /nope --path %R%|kill
root-not-last-path|/opt/cg/codegraph.js serve --mcp --path %R% --path /nope|no-kill
decoy-marker-not-at-script-position|/opt/cg/other.js decoy-arg codegraph.js serve --mcp --path %R%|no-kill
unterminated-open|/opt/cg/codegraph.js serve --mcp --path "%R%|no-kill
unterminated-trailing|/opt/cg/codegraph.js serve --mcp --path "%R% and more|no-kill
quoted-whole-flag|/opt/cg/codegraph.js serve --mcp "--path %R%"|no-kill
equals-form|/opt/cg/codegraph.js serve --mcp --path=%R%|no-kill
flag-substring|/opt/cg/codegraph.js serve --mcp --path-prefix %R%|no-kill
escaped-quote-value|/opt/cg/codegraph.js serve --mcp --path \"%R%\"|no-kill
metachar-value|/opt/cg/codegraph.js serve --mcp --path "%R%; rm -rf /"|no-kill
metachar-appended|/opt/cg/codegraph.js serve --mcp --path %R%&&calc|no-kill
empty-value|/opt/cg/codegraph.js serve --mcp --path "" %R%|no-kill
path-is-last|/opt/cg/codegraph.js serve --mcp --path|no-kill
no-codegraph-token|/opt/cg/other.js serve --mcp --path %R%|no-kill
prefix-sibling|/opt/cg/codegraph.js serve --mcp --path %R%-old|no-kill
child-directory|/opt/cg/codegraph.js serve --mcp --path %R%/sub|no-kill
empty-command-line||no-kill
TABLE

echo "--- L19h extra: a root literally named 'codegraph' must not let an unrelated script match ---"
# namesCodegraph only inspects the argv element immediately before `serve` — this
# proves a --path value's basename can't stand in for it (the C1 impostor shape).
codegraph_named_root="$(mkroot "codegraph")"
assert_eq "L19h/root-named-codegraph-unrelated-script" "no-kill" \
    "$(tok_verdict "/opt/cg/other.js serve --mcp --path $codegraph_named_root" "$codegraph_named_root")"

# `serveAt < 1` guards the case where `serve` has no preceding argv element at
# all (nothing to read a script name from) — proves that boundary independently
# of the impersonation case above, which always has a preceding element.
assert_eq "L19h/serve-as-argv0-no-preceding-element" "no-kill" \
    "$(tok_verdict "serve --mcp --path $codegraph_named_root" "$codegraph_named_root")"
