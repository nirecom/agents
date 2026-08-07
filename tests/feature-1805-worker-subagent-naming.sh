#!/usr/bin/env bash
# tests/feature-1805-worker-subagent-naming.sh
# Tests: skills/_shared/worker-dispatch.md, hooks/lib/worker-dispatch-registry.js
# Tags: worker-dispatch, naming, skill-orchestration, static, prompt-contract, TL1, scope:issue-specific
#
# Issue #1805 — "dispatch `X`" is ambiguous: X may be a plain-script worker, an
# LLM subagent, or a skill, and the three are dispatched by completely different
# mechanisms. A reader (human or model) that guesses wrong spawns the wrong thing.
# The fix is a naming convention with one visible marker per form:
#
#   worker    the word "worker" adjacent to the name  — `doc-append` worker
#   subagent  the word "subagent" adjacent to the name — `skip-verifier` subagent
#   skill     the slash form                           — /commit-push
#
# The worker roster is read from the registry SSOT (hooks/lib/worker-dispatch-
# registry.js), so a tenth worker inherits the check automatically.
#
# TL1 (static): the subject is prompt text plus a pure-data registry.
#
# RED before write-code: worker-dispatch.md has no ## Naming section yet and
# several callers still write a bare "dispatch `<name>`".

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
nodepath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi; }

REGISTRY_JS="$AGENTS_DIR/hooks/lib/worker-dispatch-registry.js"
SHARED_REL="skills/_shared/worker-dispatch.md"
SHARED_MD="$AGENTS_DIR/$SHARED_REL"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; [ -n "${2:-}" ] && echo "    detail: $2"; FAIL=$((FAIL + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

TMPD="$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/wd-naming-$$")"
mkdir -p "$TMPD"
trap 'rm -rf "$TMPD"' EXIT

# Lines that legitimately pair a dispatch verb with a backticked entity name but
# are NOT an entity dispatch (prose, field names, script names). Matched as
# literal substrings of the line. Keep this list short — every addition weakens
# the check.
ALLOWLIST=(
    'Dispatch by `type`'
    'Dispatch on `ACTION=`'
    'issue-create-dispatch.sh'
    'run-bulk-dispatch.sh'
    # resume-session describes MARKER names it detects (`workflow-state`,
    # `worktree-end`), then dispatches "to the matching skill" generically — no
    # entity is being named as a dispatch target on this line.
    'then dispatches to the matching skill'
)

is_allowlisted() {
    local line="$1" a
    for a in "${ALLOWLIST[@]}"; do
        case "$line" in *"$a"*) return 0 ;; esac
    done
    return 1
}

# The two shared-protocol filenames contain the very words the convention
# requires, so a line that merely cites them would pass without ever naming the
# form. Strip them before asking whether the line says "worker" / "subagent".
sanitize() {
    printf '%s' "$1" \
        | sed -e 's#skills/_shared/worker-dispatch\.md##g' \
              -e 's#worker-dispatch##g' \
              -e 's#skills/_shared/subagent-concurrency\.md##g' \
              -e 's#subagent-concurrency##g'
}

DISPATCH_VERB='[Dd]ispatch(es|ed|ing)?'

# Prompt files that can dispatch something.
prompt_files() {
    ls "$AGENTS_DIR"/skills/*/SKILL.md 2>/dev/null
    ls "$AGENTS_DIR"/skills/*/scripts/*.md 2>/dev/null
}

WORKER_NAMES=""
load_worker_names() {
    WORKER_NAMES="$(run_with_timeout 30 node -e '
      const reg = require(process.argv[1]);
      process.stdout.write(reg.WORKER_NAMES.join("\n"));
    ' "$(nodepath "$REGISTRY_JS")" 2>&1)"
    [ -n "$WORKER_NAMES" ]
}

# ===========================================================================
# Group A — the convention itself is written down
# ===========================================================================
group_naming_section() {
    if [ ! -f "$SHARED_MD" ]; then
        fail "A1: $SHARED_REL missing"
        return
    fi
    local section
    section="$(awk '
        /^## / { inb = ($0 ~ /^## Naming/) ; if (inb) { print; next } }
        inb { print }
    ' "$SHARED_MD")"
    if [ -z "$section" ]; then
        fail "A1: $SHARED_REL has no '## Naming' section"
        return
    fi
    local missing=""
    printf '%s\n' "$section" | grep -q 'worker'   || missing="$missing worker-form"
    printf '%s\n' "$section" | grep -q 'subagent' || missing="$missing subagent-form"
    # Skill form: the slash-prefixed name.
    printf '%s\n' "$section" | grep -qE '(^|[^a-zA-Z0-9_-])/[a-z][a-z0-9-]+' \
        || missing="$missing skill-slash-form"
    if [ -z "$missing" ]; then
        pass "A1: $SHARED_REL '## Naming' defines the worker / subagent / /skill forms"
    else
        fail "A1: '## Naming' section incomplete" "missing:$missing"
    fi
}

# ===========================================================================
# Group B — every registry worker is named as a worker at its dispatch sites
# ===========================================================================
group_worker_sites_say_worker() {
    if ! load_worker_names; then
        fail "B1: could not read WORKER_NAMES from the registry" "$WORKER_NAMES"
        return
    fi
    # One alternation instead of a per-worker pass: the naive nested loop ran the
    # whole prompt tree once per worker and took minutes.
    local worker_re
    worker_re="\`($(printf '%s\n' "$WORKER_NAMES" | grep -v '^$' | paste -sd'|' -))\`"

    local f line clean bad="" sites=0
    while IFS= read -r f; do
        [ -f "$f" ] || continue
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            is_allowlisted "$line" && continue
            sites=$((sites + 1))
            clean="$(sanitize "$line")"
            printf '%s' "$clean" | grep -q 'worker' && continue
            bad="$bad
    ${f#"$AGENTS_DIR/"}: $line"
        done < <(grep -E "$DISPATCH_VERB" "$f" 2>/dev/null | grep -E "$worker_re" || true)
    done < <(prompt_files)

    if [ "$sites" -eq 0 ]; then
        fail "B1: no worker dispatch sites found at all — the scan is broken, not clean"
        return
    fi
    if [ -z "$bad" ]; then
        pass "B1: all $sites worker dispatch sites name the entity as a worker"
    else
        fail "B1: worker dispatch site(s) without the word 'worker'" "$bad"
    fi
}

# ===========================================================================
# Group C — the marker on a dispatch line must match the entity's actual kind
# ===========================================================================
# "Carries some marker" is not the convention. The whole point of #1805 is that
# the reader can tell WHICH mechanism will run, so a subagent labelled "worker",
# a worker labelled "subagent", or a line carrying two markers at once is just as
# misleading as no marker at all — and a check that accepts any marker cannot
# distinguish them.
#
# Kind is derived from three SSOTs: the registry roster (worker),
# agents/*.md (subagent), skills/*/ (skill). A name present in two of them —
# e.g. an agent and a same-named skill directory — legitimately has two allowed
# kinds, so either marker is accepted for it; what is never accepted is a marker
# for a kind the name does not have.
#
# ENT_KINDS_FILE holds one "<name> <kind>[ <kind>...]" row per entity.
ENT_KINDS_FILE=""

build_entity_kinds() {
    ENT_KINDS_FILE="$TMPD/entity-kinds.txt"
    : > "$TMPD/kind-worker.txt"; : > "$TMPD/kind-subagent.txt"; : > "$TMPD/kind-skill.txt"
    printf '%s\n' "$WORKER_NAMES" | grep -vE '^[[:space:]]*$' | sort -u > "$TMPD/kind-worker.txt"
    ls "$AGENTS_DIR"/agents/*.md 2>/dev/null | while IFS= read -r f; do basename "$f" .md; done \
        | sort -u > "$TMPD/kind-subagent.txt"
    ls -d "$AGENTS_DIR"/skills/*/ 2>/dev/null | while IFS= read -r d; do basename "$d"; done \
        | sort -u > "$TMPD/kind-skill.txt"

    : > "$ENT_KINDS_FILE"
    local n kinds
    cat "$TMPD/kind-worker.txt" "$TMPD/kind-subagent.txt" "$TMPD/kind-skill.txt" \
        | sort -u | grep -vE '^[[:space:]]*$' | while IFS= read -r n; do
        kinds=""
        grep -qxF "$n" "$TMPD/kind-worker.txt"   && kinds="$kinds worker"
        grep -qxF "$n" "$TMPD/kind-subagent.txt" && kinds="$kinds subagent"
        grep -qxF "$n" "$TMPD/kind-skill.txt"    && kinds="$kinds skill"
        printf '%s%s\n' "$n" "$kinds" >> "$ENT_KINDS_FILE"
    done
    [ -s "$ENT_KINDS_FILE" ]
}

kinds_of() {
    local row
    row="$(grep -E "^$1( |$)" "$ENT_KINDS_FILE" 2>/dev/null | head -1)"
    printf '%s' "${row#"$1"}"
}

# marker_verdict <line> <entity> <allowed-kinds>
#   ok | unmarked | ambiguous:<a>+<b> | wrong-marker:<found>(want<allowed>)
marker_verdict() {
    local line="$1" ent="$2" allowed="$3" clean found="" n=0
    clean="$(sanitize "$line")"
    printf '%s' "$clean" | grep -q 'worker'   && { found="worker"; n=$((n + 1)); }
    printf '%s' "$clean" | grep -q 'subagent' && { found="${found:+$found+}subagent"; n=$((n + 1)); }
    case "$clean" in *"/$ent"*) found="${found:+$found+}skill"; n=$((n + 1)) ;; esac

    if [ "$n" -eq 0 ]; then printf 'unmarked'; return; fi
    if [ "$n" -gt 1 ]; then printf 'ambiguous:%s' "$found"; return; fi
    case " $allowed " in
        *" $found "*) printf 'ok' ;;
        *) printf 'wrong-marker:%s(want%s)' "$found" "$allowed" ;;
    esac
}

# --- C0: the oracle itself, in both directions -----------------------------
# The reject rows are the mutation probe: loosening marker_verdict to accept any
# marker turns every one of them red.
group_marker_oracle_cases() {
    ENT_KINDS_FILE="$TMPD/oracle-kinds.txt"
    cat > "$ENT_KINDS_FILE" <<'KINDS'
doc-append worker
skip-verifier subagent
commit-push skill
survey-code subagent skill
KINDS

    local name ent want line got fails=0
    while IFS='|' read -r name ent want line; do
        [ -z "$name" ] && continue
        case "$name" in \#*) continue ;; esac
        got="$(marker_verdict "$line" "$ent" "$(kinds_of "$ent")")"
        case "$got" in ok) got="ok" ;; *) got="reject" ;; esac
        if [ "$got" = "$want" ]; then
            pass "C0/$name: $want"
        else
            fail "C0/$name: got $got, want $want" "line=$line"
            fails=$((fails + 1))
        fi
    done <<'TABLE'
worker-correct|doc-append|ok|WE-21. Dispatch the `doc-append` worker to append the entry.
subagent-correct|skip-verifier|ok|Dispatch the `skip-verifier` subagent for the verdict.
skill-correct|commit-push|ok|Dispatch /commit-push once the gate clears (`commit-push`).
dual-kind-either-marker|survey-code|ok|Dispatch the `survey-code` subagent to map the callsites.
subagent-mislabelled-worker|skip-verifier|reject|Dispatch the `skip-verifier` worker for the verdict.
worker-mislabelled-subagent|doc-append|reject|Dispatch the `doc-append` subagent to append the entry.
skill-mislabelled-worker|commit-push|reject|Dispatch the `commit-push` worker when the gate clears.
both-markers-ambiguous|doc-append|reject|Dispatch the `doc-append` worker via the subagent path.
no-marker-at-all|doc-append|reject|WE-21. Dispatch `doc-append` per the protocol.
TABLE
    ENT_KINDS_FILE=""
    return $fails
}

entity_names() {
    printf '%s\n' "$WORKER_NAMES"
    ls "$AGENTS_DIR"/agents/*.md 2>/dev/null | while IFS= read -r f; do
        basename "$f" .md
    done
    ls -d "$AGENTS_DIR"/skills/*/ 2>/dev/null | while IFS= read -r d; do
        basename "$d"
    done
}

group_no_bare_dispatch_residual() {
    if [ -z "$WORKER_NAMES" ] && ! load_worker_names; then
        fail "C1: could not read WORKER_NAMES from the registry"
        return
    fi
    if ! build_entity_kinds; then
        fail "C1: entity-kind table could not be built from the three SSOTs"
        return
    fi
    local entities ent_re f line e verdict bad="" checked=0
    entities="$(grep -c '' "$ENT_KINDS_FILE" 2>/dev/null || echo 0)"
    if [ "${entities:-0}" -lt 5 ]; then
        fail "C1: entity table is only ${entities:-0} rows — enumeration broken"
        return
    fi
    ent_re="\`($(cut -d' ' -f1 "$ENT_KINDS_FILE" | paste -sd'|' -))\`"

    while IFS= read -r f; do
        [ -f "$f" ] || continue
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            is_allowlisted "$line" && continue
            # Judge the line against the entity it actually names.
            while IFS= read -r e; do
                [ -z "$e" ] && continue
                case "$line" in *"\`$e\`"*) ;; *) continue ;; esac
                checked=$((checked + 1))
                verdict="$(marker_verdict "$line" "$e" "$(kinds_of "$e")")"
                [ "$verdict" = "ok" ] && continue
                bad="$bad
    ${f#"$AGENTS_DIR/"} [$e → $verdict]: $line"
            done < <(cut -d' ' -f1 "$ENT_KINDS_FILE")
        done < <(grep -E "$DISPATCH_VERB" "$f" 2>/dev/null | grep -E "$ent_re" || true)
    done < <(ls "$AGENTS_DIR"/skills/*/SKILL.md 2>/dev/null)

    if [ "$checked" -eq 0 ]; then
        fail "C1: no dispatch-plus-entity line found at all — the scan is broken, not clean"
        return
    fi
    if [ -z "$bad" ]; then
        pass "C1: every dispatch line in skills/*/SKILL.md carries the marker matching its entity's kind ($checked entity mentions checked)"
    else
        fail "C1: dispatch line(s) whose marker does not match the entity's kind" "$bad"
    fi
}

group_naming_section
group_worker_sites_say_worker
group_marker_oracle_cases
group_no_bare_dispatch_residual

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $((FAIL > 0 ? 1 : 0))
