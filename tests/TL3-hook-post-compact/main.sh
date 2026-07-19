# shellcheck shell=bash
# TL3 seam body for post-compact.js (PostCompact) — TL3 gap only.
# Sourced by ../TL3-hook-post-compact.sh.
#
# TL3 gap: PostCompact fires only when a long conversation is compacted. A short
# `claude -p` session never accumulates enough context to trigger compaction, so
# the hook cannot be exercised in an automated TL3 seam test. No deterministic side-effect
# file exists to assert against. Real coverage would require a live, long-running
# session with forced compaction — out of scope for automated CI.
#
# This body performs no real invocation; the entry point exits 77 (skipped)
# before sourcing when RUN_E2E=off, and this comment documents the residual gap.
echo "SKIP: post-compact.js TL3 gap — PostCompact unfireable in a short claude -p session"
