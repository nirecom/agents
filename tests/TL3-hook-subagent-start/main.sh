# shellcheck shell=bash
# TL3 seam body for subagent-start.js (SubagentStart) — TL3 gap only.
# Sourced by ../TL3-hook-subagent-start.sh.
#
# TL3 gap: subagent-start.js injects additionalContext into a spawned sub-agent's
# context, but produces no observable side-effect file. The only observable
# signal is the sub-agent's output language, which is non-deterministic and
# cannot be asserted reliably in an automated TL3 seam test. Real coverage would require
# inspecting the sub-agent transcript for injected context, which is out of scope
# for automated CI. The PLAN_LANG whitelist path is covered at L2 in
# feature-1303-lang-hooks/group2-subagent-start.sh.
#
# This body performs no real invocation; the entry point exits 77 (skipped).
echo "SKIP: subagent-start.js TL3 gap — no observable side-effect file; output-language signal is non-deterministic"
