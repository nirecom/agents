#!/usr/bin/env bash
# SSOT for test frontmatter validation constants.
# Source this file (do not export — env vars don't cross independent process boundaries).
FRONTMATTER_TOKEN_VALID_RE='^[A-Za-z0-9._/-]+$'
# Position contract from skills/_shared/test-design.md: a tests/*.sh header must
# appear within the first 10 lines. Read by the --dup-groups structural check.
FRONTMATTER_HEADER_MAX_LINE=10
