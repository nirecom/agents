#!/usr/bin/env bash
# Tests: settings.json, hooks/lib/jev/registry.js
# Tags: TL2, hooks, jev, settings-registration, registry, static, scope:issue-specific, pwsh-not-required

# The hooks only run if settings.json registers them, on their own Agent|Task groups so
# the existing Agent|Task|Skill step-in-flight group keeps its 5 s budget untouched. The
# registry is the data the broker trusts for the complexity-judge point; its paths must
# resolve to files that exist, or the broker would silently never map anything.

# TL3 gap (what this test does NOT catch): that the host actually fires these groups for
# a real Agent dispatch; TL3-hook-agent-jev-shadow.sh T1/T3 observes that.

. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

SETTINGS="$REPO_N/settings.json"
# groups <event> <needle>: "matcher|command|timeout" per hook whose command contains <needle>.
groups() {
  run_with_timeout 30 node -e '
    const s = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    const out = [];
    for (const g of (s.hooks && s.hooks[process.argv[2]]) || []) {
      for (const h of g.hooks || []) {
        if (String(h.command).includes(process.argv[3])) out.push([g.matcher, h.command, h.timeout, g.hooks.length].join("|"));
      }
    }
    process.stdout.write(out.join("\n"));
  ' "$SETTINGS" "$1" "$2" 2>/dev/null
}

echo "=== settings.json registration ==="
case_begin "j-settings-pre-group" "settings.json"
check "PreToolUse: one dedicated Agent|Task group for jev-shadow-pre.js, timeout 15" \
  'Agent|Task|node "$AGENTS_CONFIG_DIR/hooks/jev-shadow-pre.js"|15|1' "$(groups PreToolUse jev-shadow-pre.js)"
case_end
case_begin "j-settings-post-group" "settings.json"
check "PostToolUse: one dedicated Agent|Task group for jev-shadow-post.js, timeout 15" \
  'Agent|Task|node "$AGENTS_CONFIG_DIR/hooks/jev-shadow-post.js"|15|1' "$(groups PostToolUse jev-shadow-post.js)"
case_end
case_begin "j-settings-existing-agent-group-unchanged" "settings.json"
check "the existing Agent|Task|Skill step-in-flight group is unchanged (regression)" \
  'Agent|Task|Skill|node "$AGENTS_CONFIG_DIR/hooks/postuse-step-in-flight-mark.js"|5|1' \
  "$(groups PostToolUse postuse-step-in-flight-mark.js)"
check "neither jev hook is attached to the Skill matcher" "" \
  "$( { groups PreToolUse jev-shadow; groups PostToolUse jev-shadow; } | grep -F 'Skill')"
case_end
case_begin "j-registered-hooks-exist" "settings.json"
check "both registered hook scripts exist" "present|present" \
  "$([ -f "$AGENTS_DIR/hooks/jev-shadow-pre.js" ] && echo present || echo absent)|$([ -f "$AGENTS_DIR/hooks/jev-shadow-post.js" ] && echo present || echo absent)"
case_end

echo "=== registry entry ==="
case_begin "j-registry-complexity-judge" "hooks/lib/jev/registry.js"
REG_OUT="$(run_with_timeout 30 node -e '
  const path = require("path"), fs = require("fs");
  try {
    const m = require(process.argv[1]);
    const reg = m.REGISTRY || m.registry || m;
    const e = reg["complexity-judge"];
    if (!e) { process.stdout.write("NO-ENTRY"); process.exit(0); }
    const repo = process.argv[2];
    const exists = (p) => typeof p === "string" && fs.existsSync(path.isAbsolute(p) ? p : path.join(repo, p));
    process.stdout.write([exists(e.adapter), exists(e.normalizer), e.confidence_threshold, e.mode,
      e.sampling_rate, e.fallback, e.subagent_type].join("|"));
  } catch (err) { process.stdout.write("THREW:" + (err.code || err.message)); }
' "$REGISTRY_JS" "$REPO_N" 2>/dev/null)"
check "adapter/normalizer resolve to files; threshold, mode, sampling, fallback, subagent" \
  "true|true|0.75|shadow|1|S0-undecidable|complexity-judge" "$REG_OUT"
case_end

finish
