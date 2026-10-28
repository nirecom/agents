#!/usr/bin/env bash
# Language line for codex prompts (#2731 R3): the CODEX_FREE_TEXT directive rendered by
# hooks/lib/lang-directive.js, the SSOT for the wording and the language-name guard.
# Source: source "$(dirname "$0")/lib/codex-lang.sh" (lib/codex-core.sh re-exports it).
# Provides: codex_lang_line

# codex_lang_line <conv|plan>
# Echoes the directive for the CONV_LANG (conv) or PLAN_LANG (plan) surface, or nothing
# when the language is a noop or node/the reader is unavailable (fail-open, always rc 0).
codex_lang_line() {
  local _dir
  _dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
  node "$_dir/../../hooks/lib/lang-directive.js" --codex "${1:-}" 2> /dev/null < /dev/null || true
}
