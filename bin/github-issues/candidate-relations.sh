#!/usr/bin/env bash
# candidate-relations.sh <owner/repo> <N,M,...>
#
# Resolve the parent/child relation of each survey candidate so the verdict
# cascade (skills/_shared/issue-verdict-cascade.md) can evaluate IC-C2 (sub-of a
# meta parent) and IC-C3 (aggregate orphans under a new parent).
#
# Default path : ONE aliased GraphQL round-trip per chunk of 25 candidates.
#                The parent's labels are requested inline, so `parent_is_meta`
#                is derived directly from the parent node — never guessed.
# Fallback path: only for candidates the batched response reported `errors` for,
#                one lib/candidate-relation-one.sh call each.
#
# Stdout: JSON array, one complete row per distinct candidate, ordered by number
#         ascending (deterministic — the review allowlist is built from it):
#         [{ "number", "relation_status", "parent_number", "parent_is_meta",
#            "has_sub_issues" }, ...]
# Stderr: "relations_mode: batched|fallback|mixed" + the unresolved numbers.
# Exit:   0 = every candidate resolved, 3 = some unresolved, 4 = none resolved.
#         stdout always carries the complete array — a failure never blocks the
#         survey, it only downgrades what the cascade is allowed to conclude.

set -uo pipefail

CHUNK_SIZE=25

_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RELATION_ONE="$_SELF_DIR/lib/candidate-relation-one.sh"

if [[ $# -lt 2 ]]; then
    echo "Error: usage: candidate-relations.sh <owner/repo> <N,M,...>" >&2
    exit 2
fi

REPO="$1"
NUMBERS_RAW="$2"

if ! printf '%s' "$REPO" | grep -qE '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$'; then
    echo "Error: repo must be in owner/name format, got: $REPO" >&2
    exit 2
fi

OWNER="${REPO%%/*}"
NAME="${REPO##*/}"

# --- parse + validate + dedupe + sort ----------------------------------------
NUMBERS=()
if [[ -n "${NUMBERS_RAW//[[:space:]]/}" ]]; then
    IFS=',' read -ra _RAW_ITEMS <<< "$NUMBERS_RAW"
    for _item in "${_RAW_ITEMS[@]}"; do
        _item="${_item//[[:space:]]/}"
        [[ -z "$_item" ]] && continue
        if ! printf '%s' "$_item" | grep -qE '^[0-9]+$'; then
            echo "Error: candidate numbers must be digits only, got: '$_item'" >&2
            exit 2
        fi
        NUMBERS+=("$_item")
    done
fi

if [[ ${#NUMBERS[@]} -eq 0 ]]; then
    printf '[]\n'
    echo "relations_mode: batched" >&2
    echo "unresolved: (none)" >&2
    exit 0
fi

# Deterministic, duplicate-free candidate set.
mapfile -t NUMBERS < <(printf '%s\n' "${NUMBERS[@]}" | sort -n -u)

if ! command -v gh >/dev/null 2>&1; then
    echo "Error: gh CLI not found" >&2
    exit 4
fi

# Every response below is parsed by node, and the job file itself is assembled from
# node output. Without it the parse produces empty strings that compose into a
# malformed job file and surface as "could not normalize" — a true statement about
# a wrong cause. Say which dependency is actually missing (CPR-ORTH with the gh check).
if ! command -v node >/dev/null 2>&1; then
    echo "Error: node not found — candidate relations cannot be normalized" >&2
    exit 4
fi

TMPDIR_CR_RAW="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_CR_RAW"' EXIT
# node is a native Windows binary under Git Bash: a POSIX-style /tmp path is not
# resolvable there. Normalize once, and use the normalized form everywhere —
# bash accepts the C:/... form for redirection just as well (rules/coding/nodejs.md).
if command -v cygpath >/dev/null 2>&1; then
    TMPDIR_CR="$(cygpath -m "$TMPDIR_CR_RAW")"
else
    TMPDIR_CR="$TMPDIR_CR_RAW"
fi

# --- the normalizer (shared by the post-batch and post-fallback passes) -------
NORMALIZER="$TMPDIR_CR/normalize.js"
cat > "$NORMALIZER" <<'NODEJS'
"use strict";
// argv[2] = job file: { numbers: [n...], chunks: [{path, numbers:[n...]}], ones: {n: path} }
const fs = require("fs");

function readJson(p) {
  try { return JSON.parse(fs.readFileSync(p, "utf8")); } catch (e) { return null; }
}

function row(number, node) {
  if (!node || typeof node !== "object" || typeof node.number !== "number") {
    return {
      number: number,
      relation_status: "unresolved",
      parent_number: null,
      parent_is_meta: false,
      has_sub_issues: false
    };
  }
  const parent = node.parent && typeof node.parent === "object" ? node.parent : null;
  const labelNodes =
    parent && parent.labels && Array.isArray(parent.labels.nodes) ? parent.labels.nodes : [];
  return {
    number: number,
    relation_status: "resolved",
    parent_number: parent && typeof parent.number === "number" ? parent.number : null,
    parent_is_meta: labelNodes.some(function (l) { return l && l.name === "meta"; }),
    has_sub_issues: !!(node.subIssues && Number(node.subIssues.totalCount) > 0)
  };
}

const job = readJson(process.argv[2]) || { numbers: [], chunks: [], ones: {} };
const resolvedByBatch = new Set();
const rows = new Map();
const fallbackNeeded = [];

(job.chunks || []).forEach(function (chunk) {
  const resp = readJson(chunk.path);
  const repo =
    resp && resp.data && resp.data.repository && typeof resp.data.repository === "object"
      ? resp.data.repository
      : {};
  const hadErrors = !!(resp && Array.isArray(resp.errors) && resp.errors.length > 0);
  (chunk.numbers || []).forEach(function (n) {
    const r = row(n, repo["c" + n]);
    if (r.relation_status === "resolved") {
      resolvedByBatch.add(n);
      rows.set(n, r);
    } else {
      rows.set(n, r);
      if (hadErrors) fallbackNeeded.push(n);
    }
  });
});

Object.keys(job.ones || {}).forEach(function (k) {
  const n = Number(k);
  const resp = readJson(job.ones[k]);
  const node =
    resp && resp.data && resp.data.repository && resp.data.repository.issue
      ? resp.data.repository.issue
      : null;
  const r = row(n, node);
  if (r.relation_status === "resolved") rows.set(n, r);
});

const out = (job.numbers || [])
  .slice()
  .sort(function (a, b) { return a - b; })
  .map(function (n) { return rows.get(n) || row(n, null); });

const unresolved = out.filter(function (r) { return r.relation_status !== "resolved"; });

process.stdout.write(
  JSON.stringify({
    rows: out,
    unresolved: unresolved.map(function (r) { return r.number; }),
    fallback_needed: fallbackNeeded,
    batch_resolved: resolvedByBatch.size
  })
);
NODEJS

json_numbers() { printf '%s\n' "$@" | paste -sd, -; }

# --- batched pass -------------------------------------------------------------
CHUNKS_JSON=""
CHUNK_IDX=0
IDX=0
TOTAL=${#NUMBERS[@]}
while [[ $IDX -lt $TOTAL ]]; do
    CHUNK_IDX=$((CHUNK_IDX + 1))
    CHUNK=("${NUMBERS[@]:$IDX:$CHUNK_SIZE}")
    IDX=$((IDX + CHUNK_SIZE))

    ALIASES=""
    for n in "${CHUNK[@]}"; do
        # labels(first: 100) — the GraphQL page maximum. The page is what decides
        # `parent_is_meta`, so a `meta` label past the end of it reads exactly like no
        # meta label and silently drops the parent out of the sub-of rule.
        ALIASES="${ALIASES} c${n}: issue(number: ${n}) { number state parent { number state labels(first: 100) { nodes { name } } } subIssues(first: 1) { totalCount } }"
    done
    QUERY="{ repository(owner: \"${OWNER}\", name: \"${NAME}\") {${ALIASES} } }"

    RESP_FILE="$TMPDIR_CR/chunk-${CHUNK_IDX}.json"
    gh api graphql -f query="$QUERY" >"$RESP_FILE" 2>/dev/null || true

    CHUNK_NUMS="$(json_numbers "${CHUNK[@]}")"
    CHUNKS_JSON="${CHUNKS_JSON:+$CHUNKS_JSON,}{\"path\":$(printf '%s' "$RESP_FILE" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(JSON.stringify(s)))'),\"numbers\":[${CHUNK_NUMS}]}"
done

ALL_NUMS="$(json_numbers "${NUMBERS[@]}")"
JOB="$TMPDIR_CR/job.json"
printf '{"numbers":[%s],"chunks":[%s],"ones":{}}' "$ALL_NUMS" "$CHUNKS_JSON" > "$JOB"

PASS1="$(node "$NORMALIZER" "$JOB" 2>/dev/null)"

# --- fallback pass (only for candidates the batch reported errors for) --------
FALLBACK_LIST="$(printf '%s' "$PASS1" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{process.stdout.write((JSON.parse(s).fallback_needed||[]).join(" "))}catch(e){}})' 2>/dev/null)"

ONES_JSON=""
FALLBACK_USED=0
if [[ -n "${FALLBACK_LIST// /}" ]]; then
    for n in $FALLBACK_LIST; do
        FALLBACK_USED=1
        ONE_FILE="$TMPDIR_CR/one-${n}.json"
        bash "$RELATION_ONE" "$REPO" "$n" >"$ONE_FILE" 2>/dev/null || true
        ONES_JSON="${ONES_JSON:+$ONES_JSON,}\"${n}\":$(printf '%s' "$ONE_FILE" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(JSON.stringify(s)))')"
    done
    printf '{"numbers":[%s],"chunks":[%s],"ones":{%s}}' "$ALL_NUMS" "$CHUNKS_JSON" "$ONES_JSON" > "$JOB"
fi

FINAL="$(node "$NORMALIZER" "$JOB" 2>/dev/null)"
if [[ -z "$FINAL" ]]; then
    echo "Error: could not normalize candidate relations" >&2
    exit 4
fi

printf '%s' "$FINAL" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{process.stdout.write(JSON.stringify(JSON.parse(s).rows)+"\n")}catch(e){process.stdout.write("[]\n")}})'

UNRESOLVED="$(printf '%s' "$FINAL" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{process.stdout.write((JSON.parse(s).unresolved||[]).join(","))}catch(e){}})' 2>/dev/null)"
BATCH_RESOLVED="$(printf '%s' "$FINAL" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{process.stdout.write(String(JSON.parse(s).batch_resolved||0))}catch(e){process.stdout.write("0")}})' 2>/dev/null)"

MODE="batched"
if [[ "$FALLBACK_USED" -eq 1 ]]; then
    if [[ "${BATCH_RESOLVED:-0}" -gt 0 ]]; then MODE="mixed"; else MODE="fallback"; fi
fi
echo "relations_mode: $MODE" >&2
echo "unresolved: ${UNRESOLVED:-(none)}" >&2

UNRESOLVED_COUNT=0
if [[ -n "$UNRESOLVED" ]]; then
    UNRESOLVED_COUNT=$(printf '%s' "$UNRESOLVED" | tr ',' '\n' | grep -c .)
fi

if [[ "$UNRESOLVED_COUNT" -eq 0 ]]; then exit 0; fi
if [[ "$UNRESOLVED_COUNT" -ge "$TOTAL" ]]; then exit 4; fi
exit 3
