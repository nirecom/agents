# tests/feature-2210-block-recursive-delete/cases-protection-fix.sh
# Tests: hooks/block-recursive-delete.js, settings.json
# Tags: scope:issue-specific, recursive-delete, hook, protection-fix, integration, TL2, pwsh-not-required
#
# C2: proves the REGISTERED settings.json entry, not a direct `node "$HOOK"`
# call, blocks a real delete on a real fixture. TL3 gap: bash -c, not the host.

run_protection_fix_cases() {
    echo ""
    echo "=== Integration: the REGISTERED hook blocks a real delete (C2) ==="

    local raw_cmd fx fx_np fx_ps fx_ps_np fx_cmd fx_cmd_np out verdict st

    raw_cmd="$(settings_probe command)"
    if [ "$raw_cmd" = "NONE" ]; then
        fail "settings.json has no registered block-recursive-delete.js entry yet — cannot run the integration check (expected pre-implementation)"
        return 0
    fi

    fx="$(mktemp -d)"
    fx_np="$(np "$fx")"
    mkdir -p "$fx/victim/nested"
    echo canary > "$fx/victim/nested/file.txt"

    # Pattern 2: a REAL fixture path — a failure to block deletes for real.
    out="$(printf '%s' "$(payload_cmd "rm -rf \"$fx_np/victim\"")" | AGENTS_CONFIG_DIR="$AN" run_with_timeout 60 bash -c "$raw_cmd" 2>/dev/null)"; st=$?
    verdict="$(verdict_of "$out")"
    if [ "$verdict" = "block" ]; then
        pass "settings.json-registered hook blocks a real 'rm -rf' via bash -c \$raw_cmd"
    else
        fail "settings.json-registered hook — expected block, got verdict '$verdict' from: $out"
    fi
    # C7: a parseable verdict can also come from a crashing or timing-out run.
    if [ "$st" -eq 0 ]; then
        pass "settings.json-registered hook subprocess exited 0 on the blocking call (C7)"
    else
        fail "settings.json-registered hook subprocess exited $st on the blocking call (C7)"
    fi

    # As Claude Code would: only a non-blocking verdict lets the real rm run.
    if [ "$verdict" != "block" ]; then
        rm -rf "$fx/victim" 2>/dev/null
    fi

    # Pattern 1: assert on the PROTECTED RESOURCE itself, not just the verdict.
    if [ -f "$fx/victim/nested/file.txt" ]; then
        pass "the canary file under the real fixture path survives"
    else
        fail "the canary file was actually deleted — the registered hook failed to protect a real path"
    fi

    # CPR-ORTH: the same wiring must block the PowerShell shape, not only POSIX.
    out="$(printf '%s' "$(payload_cmd "Remove-Item -Recurse \"$fx_np/victim\"")" | AGENTS_CONFIG_DIR="$AN" run_with_timeout 60 bash -c "$raw_cmd" 2>/dev/null)"; st=$?
    verdict="$(verdict_of "$out")"
    if [ "$verdict" = "block" ]; then
        pass "settings.json-registered hook blocks a PowerShell-shaped 'Remove-Item -Recurse' (CPR-ORTH)"
    else
        fail "settings.json-registered hook — expected block for Remove-Item -Recurse, got verdict '$verdict' from: $out"
    fi
    if [ "$st" -eq 0 ]; then
        pass "settings.json-registered hook subprocess exited 0 on the PowerShell-shaped blocking call (C7)"
    else
        fail "settings.json-registered hook subprocess exited $st on the PowerShell-shaped blocking call (C7)"
    fi

    # The verdict-only checks above get a canary fixture here. Still no real
    # pwsh or cmd.exe process — node plus a bash delete-simulation, as POSIX.
    fx_ps="$(mktemp -d)"
    fx_ps_np="$(np "$fx_ps")"
    mkdir -p "$fx_ps/victim/nested"
    echo canary > "$fx_ps/victim/nested/file.txt"
    out="$(printf '%s' "$(payload_cmd "Remove-Item -Recurse \"$fx_ps_np/victim\"")" | AGENTS_CONFIG_DIR="$AN" run_with_timeout 60 bash -c "$raw_cmd" 2>/dev/null)"; st=$?
    verdict="$(verdict_of "$out")"
    if [ "$verdict" = "block" ]; then
        pass "settings.json-registered hook blocks a real PowerShell-shaped delete (fixture, round-4 C5)"
    else
        fail "settings.json-registered hook — expected block for the PowerShell fixture, got verdict '$verdict' from: $out"
    fi
    if [ "$st" -eq 0 ]; then
        pass "settings.json-registered hook subprocess exited 0 on the PowerShell fixture call (round-4 C5)"
    else
        fail "settings.json-registered hook subprocess exited $st on the PowerShell fixture call (round-4 C5)"
    fi
    if [ "$verdict" != "block" ]; then
        rm -rf "$fx_ps/victim" 2>/dev/null
    fi
    if [ -f "$fx_ps/victim/nested/file.txt" ]; then
        pass "the canary file under the PowerShell-route fixture path survives (round-4 C5)"
    else
        fail "the canary file was actually deleted via the PowerShell-shaped route — the registered hook failed to protect a real path"
    fi
    rm -rf "$fx_ps" 2>/dev/null

    fx_cmd="$(mktemp -d)"
    fx_cmd_np="$(np "$fx_cmd")"
    mkdir -p "$fx_cmd/victim/nested"
    echo canary > "$fx_cmd/victim/nested/file.txt"
    out="$(printf '%s' "$(payload_cmd "cmd /c rmdir /s /q \"$fx_cmd_np/victim\"")" | AGENTS_CONFIG_DIR="$AN" run_with_timeout 60 bash -c "$raw_cmd" 2>/dev/null)"; st=$?
    verdict="$(verdict_of "$out")"
    if [ "$verdict" = "block" ]; then
        pass "settings.json-registered hook blocks a real cmd.exe-shaped delete (fixture, round-4 C5)"
    else
        fail "settings.json-registered hook — expected block for the cmd.exe fixture, got verdict '$verdict' from: $out"
    fi
    if [ "$st" -eq 0 ]; then
        pass "settings.json-registered hook subprocess exited 0 on the cmd.exe fixture call (round-4 C5)"
    else
        fail "settings.json-registered hook subprocess exited $st on the cmd.exe fixture call (round-4 C5)"
    fi
    if [ "$verdict" != "block" ]; then
        rm -rf "$fx_cmd/victim" 2>/dev/null
    fi
    if [ -f "$fx_cmd/victim/nested/file.txt" ]; then
        pass "the canary file under the cmd.exe-route fixture path survives (round-4 C5)"
    else
        fail "the canary file was actually deleted via the cmd.exe-shaped route — the registered hook failed to protect a real path"
    fi
    rm -rf "$fx_cmd" 2>/dev/null

    # Pattern 4: the wiring is not a blanket write gate.
    out="$(printf '%s' "$(payload_cmd "rm -f \"$fx_np/victim/nested/file.txt\"")" | AGENTS_CONFIG_DIR="$AN" run_with_timeout 60 bash -c "$raw_cmd" 2>/dev/null)"; st=$?
    verdict="$(verdict_of "$out")"
    if [ "$verdict" = "approve" ]; then
        pass "the same registered hook approves a real non-recursive 'rm -f'"
    else
        fail "the same registered hook — expected approve for a non-recursive delete, got '$verdict'"
    fi
    if [ "$st" -eq 0 ]; then
        pass "settings.json-registered hook subprocess exited 0 on the approving call (C7)"
    else
        fail "settings.json-registered hook subprocess exited $st on the approving call (C7)"
    fi

    rm -rf "$fx" 2>/dev/null

    echo ""
    echo "=== Integration: worst-case nested payload finishes well inside the 5s timeout budget (finding 6) ==="

    # settings.json pins this entry's timeout to 5s; depth 8 is where the scan's
    # fail-closed cutoff sits, so a depth-8 chain is the worst realistic payload.
    local nested_cmd t_start t_end elapsed_ms
    nested_cmd="$(node -e '
let c = "rm -rf x";
for (let i = 0; i < 8; i++) { c = "bash -c \"" + c.replace(/(["\\])/g, "\\$1") + "\""; }
process.stdout.write(c);
')"
    t_start="$(date +%s%N)"
    out="$(printf '%s' "$(payload_cmd "$nested_cmd")" | AGENTS_CONFIG_DIR="$AN" run_with_timeout 60 bash -c "$raw_cmd" 2>/dev/null)"
    t_end="$(date +%s%N)"
    elapsed_ms=$(( (t_end - t_start) / 1000000 ))
    if [ "$elapsed_ms" -lt 4000 ]; then
        pass "worst-case depth-8 nested payload completes in ${elapsed_ms}ms, well under the 5000ms timeout budget"
    else
        fail "worst-case depth-8 nested payload took ${elapsed_ms}ms — too close to (or over) the 5000ms timeout budget"
    fi

    echo ""
    echo "=== Integration: an approved command produces a quiet, side-effect-free response (finding 12) ==="

    out="$(printf '%s' "$(payload_cmd "rm -f dir/file.txt")" | AGENTS_CONFIG_DIR="$AN" run_with_timeout 60 bash -c "$raw_cmd" 2>/dev/null)"
    verdict="$(verdict_of "$out")"
    if [ "$verdict" = "approve" ]; then
        pass "approved command's verdict is approve (quiet-on-approve precondition)"
    else
        fail "approved command — expected approve, got '$verdict' from: $out"
    fi
    if [ "$(printf '%s\n' "$out" | wc -l)" -le 1 ]; then
        pass "approved command's hook stdout is a single line, no extra noise (finding 12)"
    else
        fail "approved command's hook stdout has more than one line, unexpected noise: $out"
    fi
}
