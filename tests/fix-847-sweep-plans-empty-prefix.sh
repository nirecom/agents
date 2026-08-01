#!/bin/bash
# tests/fix-847-sweep-plans-empty-prefix.sh
# Tests: bin/sweep-plans.sh
# Tags: sweep, plans, empty-sid, guard, fix, scope:issue-specific, TL2
#
# Regression tests for issue #847: the empty-prefix bucket in bin/sweep-plans.sh
# groups ANY basename starting with '-', so non-workflow hyphen-prefixed files
# (e.g. "-scratch", "-My Notes.docx") are swept away with real user data.
#
# The fix adds a suffix allowlist SSOT constant EMPTY_PREFIX_ALLOW_RE:
#   ^-[a-z0-9]+([._-][a-z0-9]+)*\.(md|txt|json|jsonl|log|built|tmp|tsv|err|out|status|patch)$
# Basenames that do not match are never collected into the empty-prefix bucket,
# are never deleted, and are counted in a new summary counter
# `files_skipped_unrecognized`.
#
# Table-driven (see skills/_shared/test-design/parser-regex-tests.md): each row
# builds a plans dir from a file spec, runs sweep-plans.sh in one write mode,
# and asserts a list of CI-JSON / filesystem predicates.
#
# TL3 gap (what this test does NOT catch):
# - The real ~/.workflow-plans directory shape on a live machine (artifact kinds
#   produced by concurrent sessions, and files created between scan and rm).
# - Deletion behaviour under a real user's filesystem permissions / locked files.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED
# preflight via bin/check-verification-gate.sh category: skill-orchestration.

set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SWEEP="$AGENTS_DIR/bin/sweep-plans.sh"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

run_with_timeout() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 120 "$@"
    else
        perl -e 'alarm 120; exec @ARGV' -- "$@"
    fi
}

TMPDIR_BASE="$(mktemp -d)"
trap 'chmod -R u+rwX "$TMPDIR_BASE" 2>/dev/null; rm -rf "$TMPDIR_BASE"' EXIT

# Backdate file mtime to look "stale" (60 days ago). Portable across GNU/BSD.
backdate() {
    local f="$1"
    touch -d "60 days ago" "$f" 2>/dev/null || touch -t 202401010000 "$f" 2>/dev/null || true
}

# Extract a field from --ci-mode JSON output (may contain non-JSON noise lines).
ci_field() {
    printf '%s' "$1" | node -e "
        let b='';
        process.stdin.on('data', c => b += c);
        process.stdin.on('end', () => {
            const key = process.argv[1];
            const lines = b.split(/\r?\n/);
            for (const line of lines) {
                const trimmed = line.trim();
                if (!trimmed.startsWith('{')) continue;
                try {
                    const d = JSON.parse(trimmed);
                    if (key in d) { console.log(d[key]); return; }
                } catch (e) { /* skip non-JSON */ }
            }
        });
    " -- "$2" 2>/dev/null
}

# ─────────────────────────────────────────────────────────────────────────────
# Table driver
#
# Columns (IFS='|'):
#   name   — case label, injected into every assertion message
#   files  — comma-separated "<basename>@<old|new>" file specs.
#            '~' in a basename stands for a literal space (the table strips
#            whitespace so spaces cannot be written directly).
#   mode   — dry-run | apply | default  (default = no write-mode flag at all)
#   expect — comma-separated predicates:
#              <json_key>=<int>     exact CI-JSON field value
#              <json_key>>=<int>    CI-JSON field at least <int>
#              exists:<basename>    file still present after the run
#              gone:<basename>      file removed by the run
# ─────────────────────────────────────────────────────────────────────────────

build_plans_dir() {
    local dir="$1" files="$2" spec base age
    mkdir -p "$dir"
    local IFS=','
    for spec in $files; do
        base="${spec%@*}"
        base="${base//\~/ }"
        age="${spec##*@}"
        printf 'fixture content\n' > "$dir/$base"
        if [ "$age" = "old" ]; then
            backdate "$dir/$base"
        fi
    done
}

check_expect() {
    local name="$1" dir="$2" out="$3" expect="$4"
    local pred key want got base ok=1 detail=""
    local IFS=','
    for pred in $expect; do
        case "$pred" in
            exists:*)
                base="${pred#exists:}"; base="${base//\~/ }"
                if [ ! -e "$dir/$base" ]; then
                    ok=0; detail="$detail [missing:$base]"
                fi
                ;;
            gone:*)
                base="${pred#gone:}"; base="${base//\~/ }"
                if [ -e "$dir/$base" ]; then
                    ok=0; detail="$detail [still-present:$base]"
                fi
                ;;
            *'>='*)
                key="${pred%%>=*}"; want="${pred##*>=}"
                got="$(ci_field "$out" "$key")"
                if [ -z "$got" ] || ! [ "$got" -ge "$want" ] 2>/dev/null; then
                    ok=0; detail="$detail [$key=${got:-<absent>} want>=$want]"
                fi
                ;;
            *'='*)
                key="${pred%%=*}"; want="${pred##*=}"
                got="$(ci_field "$out" "$key")"
                if [ "${got:-<absent>}" != "$want" ]; then
                    ok=0; detail="$detail [$key=${got:-<absent>} want=$want]"
                fi
                ;;
            *)
                ok=0; detail="$detail [bad-predicate:$pred]"
                ;;
        esac
    done
    if [ "$ok" -eq 1 ]; then
        pass "$name"
    else
        fail "$name —$detail"
    fi
}

if [ ! -f "$SWEEP" ]; then
    fail "setup: $SWEEP not found"
    echo "Results: $PASS passed, $FAIL failed"
    exit 1
fi

CASE_N=0
while IFS='|' read -r name files mode expect; do
    [[ -z "${name// /}" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name//[[:space:]]/}"
    files="${files//[[:space:]]/}"
    mode="${mode//[[:space:]]/}"
    expect="${expect// /}"

    CASE_N=$((CASE_N + 1))
    plans_dir="$TMPDIR_BASE/case-$CASE_N"
    build_plans_dir "$plans_dir" "$files"

    case "$mode" in
        dry-run) flags=(--dry-run --ci-mode) ;;
        apply)   flags=(--apply --ci-mode) ;;
        default) flags=(--ci-mode) ;;
        *)       fail "$name — unknown mode '$mode'"; continue ;;
    esac

    out="$(WORKFLOW_PLANS_DIR="$plans_dir" SWEEP_AGE_DAYS=30 \
        run_with_timeout bash "$SWEEP" "${flags[@]}" 2>&1)"
    rc=$?
    if [ "$rc" -ne 0 ]; then
        fail "$name — sweep exited $rc, out=$out"
        continue
    fi

    check_expect "$name" "$plans_dir" "$out" "$expect"
done <<'TABLE'
# (1) allowlisted machine artifact in the empty-SID bucket is still a candidate
allowlisted-log-dry-run       | -issue-close-stage-worker-665.log@old                                    | dry-run | groups_candidates=1,exists:-issue-close-stage-worker-665.log
# (1b) …and is actually deleted on the apply-by-default (flagless) run
allowlisted-log-default-apply | -issue-close-stage-worker-665.log@old                                    | default | gone:-issue-close-stage-worker-665.log,files_removed=1
# (2) extension-less user file is NOT deleted and IS counted as unrecognized
no-extension-file-kept        | -scratch@old                                                            | apply   | exists:-scratch,files_skipped_unrecognized>=1,files_removed=0
# (3) unknown-extension user file with spaces/uppercase is NOT deleted
unknown-extension-kept        | -My~Notes.docx@old                                                        | apply   | exists:-My~Notes.docx,files_skipped_unrecognized>=1,files_removed=0
# (4) a normal-SID group in the same dir does not drag (2)/(3) into deletion
normal-sid-coexists           | 20240101-000000-intent.md@old,-scratch@old,-My~Notes.docx@old             | apply   | exists:-scratch,exists:-My~Notes.docx,gone:20240101-000000-intent.md
# (5) a FRESH non-allowlisted file no longer shields the bucket (S1-2(b) change)
fresh-unrecognized-no-shield  | -scratch@new,-issue-close-stage-worker-665.log@old                       | apply   | gone:-issue-close-stage-worker-665.log,exists:-scratch,groups_skipped_revived=0
TABLE

echo ""
echo "─────────────────────────────────────────"
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
