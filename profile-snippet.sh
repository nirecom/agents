#!/usr/bin/env bash
# Sourced from dotfiles' .profile_common (sibling-detected) or directly from ~/.bashrc.
# Idempotent — safe to source twice.
if [ -n "${ZSH_VERSION-}" ]; then
    _agents_root="$(cd "$(dirname "${(%):-%x}")" && pwd)"
else
    _agents_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi
export AGENTS_CONFIG_DIR="$_agents_root"
export AGENTS_DIR="$_agents_root"

_agent_broken=0
for _f in "$HOME/.claude/CLAUDE.md" "$HOME/.claude/settings.json"; do
    if [ -e "$_f" ] && [ ! -L "$_f" ]; then _agent_broken=1; break; fi
done
if [ "$_agent_broken" = "1" ]; then
    echo "Repairing agents symlink(s)..."
    "$_agents_root/install/linux/dotfileslink.sh"
fi
unset _agents_root _agent_broken _f
