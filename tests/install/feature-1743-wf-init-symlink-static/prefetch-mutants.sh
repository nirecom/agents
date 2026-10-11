# shellcheck shell=bash
# Sourced by tests/install/feature-1743-wf-init-symlink-static.sh inside a case span.
# --- P5: mutation probes — the pre-fetch detectors must discriminate, not merely be red today ---
# Reads PREFETCH_MUT_KIND: sh or ps.

# _pf_mut <name> <body> — a synthetic installer: a repo-visibility launcher line, then <body>.
_pf_mut() {
    local f="$TMP_DIR/prefetch-$1"
    printf '%s\n' 'set -euo pipefail' 'printf "Generated: ~/.local/bin/repo-visibility\n"' "$2" 'echo next-section' >"$f"
    printf '%s' "$f"
}

if [ "$PREFETCH_MUT_KIND" = sh ]; then
    _m="$(_pf_mut sh-if-warn 'if ! uv run --no-project --with pytest python -c "import pytest"; then
    printf "${C_YELLOW}Warning: pytest pre-fetch failed (exit 1); tests will fetch it later${C_RESET}\n" >&2
fi')"
    _prefetch_probe P5a _prefetch_warn_only_sh "$_m" 1 "if ! … then warning fi (a quoted 'exit' in the message is not an exit)"
    _prefetch_probe P5a2 _prefetch_after_launcher "$_m" 1 "pre-fetch after the launcher line"
    _m="$(_pf_mut sh-or-warn 'uv run --no-project --with pytest python -c "import pytest" || printf "Warning: pytest pre-fetch failed\n" >&2')"
    _prefetch_probe P5b _prefetch_warn_only_sh "$_m" 1 "|| printf warning"
    _m="$(_pf_mut sh-bare 'uv run --no-project --with pytest python -c "import pytest"')"
    _prefetch_probe P5c _prefetch_warn_only_sh "$_m" 0 "bare call aborts under set -e"
    _m="$(_pf_mut sh-or-true 'uv run --no-project --with pytest python -c "import pytest" || true')"
    _prefetch_probe P5d _prefetch_warn_only_sh "$_m" 0 "|| true swallows the failure silently"
    _m="$(_pf_mut sh-if-exit 'if ! uv run --no-project --with pytest python -c "import pytest"; then
    printf "Warning: pytest pre-fetch failed\n" >&2
    exit 1
fi')"
    _prefetch_probe P5e _prefetch_warn_only_sh "$_m" 0 "warning then exit 1 aborts the installer"
    _m="$(_pf_mut sh-or-exit 'uv run --no-project --with pytest python -c "import pytest" || { echo "Warning: no pytest" >&2; exit 1; }')"
    _prefetch_probe P5f _prefetch_warn_only_sh "$_m" 0 "|| { warning; exit 1; } aborts the installer"
    _m="$(_pf_mut sh-commented '# uv run --no-project --with pytest python -c "import pytest" || echo "Warning"')"
    _prefetch_probe P5g _prefetch_after_launcher "$_m" 0 "a commented-out pre-fetch is not a pre-fetch"
    _m="$TMP_DIR/prefetch-sh-early"
    printf '%s\n' 'uv run --no-project --with pytest python -c "import pytest" || echo "Warning: no pytest" >&2' \
        'printf "Generated: ~/.local/bin/repo-visibility\n"' >"$_m"
    _prefetch_probe P5h _prefetch_after_launcher "$_m" 0 "pre-fetch before the repo-visibility launcher"
    _m="$(_pf_mut sh-pinned 'uv run --no-project --with "pytest>=7.0" python -c "import pytest" || echo "Warning: no pytest" >&2')"
    _prefetch_probe P5i _prefetch_after_launcher "$_m" 0 "a different --with spec is not the agreed pre-fetch command"
else
    _m="$(_pf_mut ps-warn '& uv run --no-project --with pytest python -c "import pytest"
if ($LASTEXITCODE -ne 0) { Write-Warning "pytest pre-fetch failed (exit $LASTEXITCODE); tests will fetch it later" }')"
    _prefetch_probe P5j _prefetch_warn_only_ps "$_m" 1 "\$LASTEXITCODE check + Write-Warning (a quoted 'exit' is not an exit)"
    _m="$(_pf_mut ps-bare 'uv run --no-project --with pytest python -c "import pytest"')"
    _prefetch_probe P5k _prefetch_warn_only_ps "$_m" 0 "unchecked \$LASTEXITCODE"
    _m="$(_pf_mut ps-throw 'uv run --no-project --with pytest python -c "import pytest"
if ($LASTEXITCODE -ne 0) { throw "pytest pre-fetch failed" }')"
    _prefetch_probe P5l _prefetch_warn_only_ps "$_m" 0 "throw instead of Write-Warning"
    _m="$(_pf_mut ps-warn-throw 'uv run --no-project --with pytest python -c "import pytest"
if ($LASTEXITCODE -ne 0) { Write-Warning "pytest pre-fetch failed"; throw "stop" }')"
    _prefetch_probe P5m _prefetch_warn_only_ps "$_m" 0 "Write-Warning followed by throw"
fi
