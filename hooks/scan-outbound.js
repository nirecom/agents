#!/usr/bin/env node
// Claude Code PreToolUse hook: check Edit/Write content for private information
// Skips scanning for private repos (detected dynamically via GitHub API)

const { spawnSync } = require("child_process");
const fs = require("fs");
const path = require("path");
const { isPrivateRepo, resolveRepoDir, shouldScanAsPublicTarget, listPrivateRepoNames } = require("./lib/is-private-repo");
const { isForgeScanTarget, extractTexts, extractRepoFlag } = require("./lib/forge-write-extract");
const { parseGitCArg } = require("./lib/parse-git-args");

// Read stdin (cross-platform: fs.readSync for Windows compatibility)
function readStdin() {
  const chunks = [];
  const buf = Buffer.alloc(4096);
  let bytesRead;
  try {
    while (true) {
      bytesRead = fs.readSync(0, buf, 0, buf.length);
      if (bytesRead === 0) break;
      chunks.push(buf.slice(0, bytesRead));
    }
  } catch (e) {
    // EOF or error
  }
  return Buffer.concat(chunks).toString("utf8");
}

function approve() {
  console.log(JSON.stringify({ decision: "approve" }));
  process.exit(0);
}

function block(reason) {
  console.log(JSON.stringify({ decision: "block", reason }));
  process.exit(0);
}

// Normalize path for shell commands (Windows backslashes → forward slashes)
function shellPath(p) {
  return p.split(path.sep).join("/");
}

// Normalize Unix-style paths to native paths on Windows (Git Bash mktemp etc.)
function normalizePath(fp) {
  if (process.platform !== "win32") return fp;
  // /c/path or /C/path -> C:/path
  const driveMatch = fp.match(/^\/([a-z])\/(.*)$/i);
  if (driveMatch) return `${driveMatch[1].toUpperCase()}:/${driveMatch[2]}`;
  // /tmp/... -> resolve via TEMP env
  if (fp.startsWith("/tmp/")) {
    const tmpDir = process.env.TEMP || process.env.TMP || "C:/Windows/Temp";
    return fp.replace(/^\/tmp\//, `${tmpDir.replace(/\\/g, "/")}/`);
  }
  return fp;
}

// This script lives in agents/hooks/; scanner is at agents/bin/
const AGENTS_DIR = path.resolve(__dirname, "..");
const SCANNER = path.join(AGENTS_DIR, "bin", "scan-outbound.sh");
const OFFENSIVE_SCANNER = path.join(AGENTS_DIR, "bin", "scan-offensive");

// Escape regex metacharacters in a string
function escapeRegex(s) {
  return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

// Main async logic wrapped in an IIFE to allow await on Promise-returning stubs
(async function main() {
  // Parse stdin
  const input = JSON.parse(readStdin());

  // Session-scoped WORKFLOW override: bypass outbound scan for this session.
  const { isWorkflowOff } = require("./lib/session-markers");
  if (isWorkflowOff(input.session_id)) approve();

  const toolName = input.tool_name;
  const toolInput = input.tool_input || {};

  // Only check Edit, Write, and Bash tools
  if (toolName !== "Edit" && toolName !== "Write" && toolName !== "Bash") {
    approve();
  }

  // Extract file path and content to scan
  const filePath = toolInput.file_path || "";
  let content = "";
  let isPrivate = false;

  if (toolName === "Write") {
    content = toolInput.content || "";
  } else if (toolName === "Edit") {
    content = toolInput.new_string || "";
  } else if (toolName === "Bash") {
    const command = toolInput.command || "";
    // Check forge write commands (gh issue/pr create|edit|close|comment|review)
    if (isForgeScanTarget(command)) {
      const { inline, filePaths } = extractTexts(command);
      const parts = [...inline];
      for (const fp of filePaths) {
        const normalizedFp = normalizePath(fp);
        try {
          const stat = fs.statSync(normalizedFp);
          if (stat.size > 1024 * 1024) {
            // File too large to scan inline — fail-open, skip
          } else {
            parts.push(fs.readFileSync(normalizedFp, "utf8"));
          }
        } catch (e) {
          // File missing, unreadable, or stat error — fail-open
        }
      }
      content = parts.join("\n");
      if (!content) {
        approve();
      }

      // Target-visibility resolution for Bash forge-write branch
      const targetRepo = extractRepoFlag(command);
      if (targetRepo !== null) {
        // --repo flag present: resolve visibility from the explicit target
        isPrivate = !(await Promise.resolve(shouldScanAsPublicTarget(targetRepo)));
      } else {
        // No --repo flag: fall back to cwd-based resolution
        let repoDir = null;
        const cPath = parseGitCArg(command);
        if (cPath) {
          repoDir = cPath;
        } else if (toolInput.cwd) {
          repoDir = toolInput.cwd;
        } else if (process.env.HOOK_CWD) {
          repoDir = process.env.HOOK_CWD;
        } else {
          try {
            const r = spawnSync("git", ["rev-parse", "--show-toplevel"], { encoding: "utf8", timeout: 5000 });
            if (r.status === 0) repoDir = r.stdout.trim();
          } catch (_) { /* fall-open */ }
        }
        isPrivate = isPrivateRepo(repoDir);
      }
    } else {
      // Check git commit messages
      const commitMatch = command.match(/git\s+(?:-C\s+\S+\s+)?commit\s/);
      if (!commitMatch) {
        approve();
      }
      // Extract commit message: support -m "msg", -m 'msg', and heredoc $(cat <<'EOF'...EOF)
      const heredocMatch = command.match(/<<'?EOF'?\s*\n([\s\S]*?)\nEOF/);
      if (heredocMatch) {
        content = heredocMatch[1];
      } else {
        const msgMatch = command.match(/(?:-m\s+)(["'])([\s\S]*?)\1/);
        content = msgMatch ? msgMatch[2] : "";
      }
      if (!content) {
        approve();
      }
      // git commit: resolve via existing helper
      const repoDir = resolveRepoDir(command);
      isPrivate = isPrivateRepo(repoDir);
    }
  }

  if (!content) {
    approve();
  }

  // Resolve repo dir and private-status for Edit/Write tools.
  // Bash forge-write already resolved isPrivate above; Bash commit resolved above.
  if (toolName !== "Bash") {
    let repoDir = null;
    if (filePath) {
      // Edit/Write: resolve repo from file path
      try {
        const gitResult = spawnSync("git", ["-C", path.dirname(filePath), "rev-parse", "--show-toplevel"], {
          encoding: "utf8",
          timeout: 5000,
        });
        if (gitResult.status === 0 && gitResult.stdout) {
          repoDir = gitResult.stdout.trim();
        }
      } catch (e) {
        // Not in a git repo — continue with scan
      }
    }
    isPrivate = isPrivateRepo(repoDir);
  }

  // Run private-info scanner (skipped for private repos) and offensive scanner
  // (always), then merge results.
  {
    const label = filePath || "stdin";
    let outboundResult = null;
    if (!isPrivate) {
      outboundResult = spawnSync("bash", [shellPath(SCANNER), "--stdin", shellPath(label)], {
        input: content,
        encoding: "utf8",
        timeout: 10000,
      });
    }
    const offensiveResult = spawnSync("node", [shellPath(OFFENSIVE_SCANNER), "--stdin", shellPath(label)], {
      input: content,
      encoding: "utf8",
      timeout: 10000,
    });

    // Fail-closed: timeout / spawn error / unobservable status (either scanner)
    if (outboundResult && (outboundResult.error || outboundResult.status === null)) {
      const out = ((outboundResult.stdout || "") + (outboundResult.stderr || "")).trim();
      const msg = (outboundResult.error && outboundResult.error.message) || "no exit status";
      block(`Scanner failed (${msg}):\n${out}`);
    }
    if (offensiveResult.error || offensiveResult.status === null) {
      const out = ((offensiveResult.stdout || "") + (offensiveResult.stderr || "")).trim();
      const msg = (offensiveResult.error && offensiveResult.error.message) || "no exit status";
      block(`Offensive scanner failed (${msg}):\n${out}`);
    }

    const outboundStatus = outboundResult ? outboundResult.status : 0;
    const outboundOut = outboundResult
      ? ((outboundResult.stdout || "") + (outboundResult.stderr || "")).trim()
      : "";
    const offensiveStatus = offensiveResult.status;
    const offensiveOut = ((offensiveResult.stdout || "") + (offensiveResult.stderr || "")).trim();

    // Hard-block precedence: private-info hard > offensive hard > usage error >
    // private-info warn > offensive warn > approve.
    if (outboundStatus === 3) {
      block(`Scanner usage error (rc=3):\n${outboundOut}`);
    }
    if (offensiveStatus === 3) {
      block(`Offensive scanner usage error (rc=3):\n${offensiveOut}`);
    }
    if (outboundStatus === 1) {
      block(`Private information detected:\n${outboundOut}`);
    }
    if (offensiveStatus === 1) {
      block(`Offensive content detected:\n${offensiveOut}`);
    }
    if (outboundStatus === 2) {
      block(
        `Possible private information detected (warn-only):\n${outboundOut}\n\n` +
        `These patterns are flagged as likely false-positive-prone. ` +
        `Ask the user whether this content is safe to commit. ` +
        `If the user confirms it is safe, proceed. ` +
        `If genuinely safe long-term, suggest adding to .private-info-allowlist.`
      );
    }
    if (offensiveStatus === 2) {
      block(
        `Possible offensive content (warn-only):\n${offensiveOut}\n\n` +
        `Ask the user whether this content is safe to send. ` +
        `If the user confirms it is safe, proceed.`
      );
    }
    if (outboundStatus !== 0) {
      block(`Scanner unexpected rc=${outboundStatus}:\n${outboundOut}`);
    }
    if (offensiveStatus !== 0) {
      block(`Offensive scanner unexpected rc=${offensiveStatus}:\n${offensiveOut}`);
    }

    // JS dynamic WARN: only run when target is treated as PUBLIC.
    // Check content against known private repo names from listPrivateRepoNames().
    if (!isPrivate) {
      const privateNames = await Promise.resolve(listPrivateRepoNames());
      for (const name of privateNames) {
        const escaped = escapeRegex(name);
        const re = new RegExp("(^|[^\\w/.-])" + escaped + "([^\\w/.-]|$)");
        if (re.test(content)) {
          block(
            `warn: Private repository name detected in outbound content: ${name}\n` +
            `Do not include private repository names in public-facing content.\n` +
            `Remove or replace the private repo reference before proceeding.`
          );
        }
      }
    }

    approve();
  }
})().catch(function (e) {
  // Fail-open on unexpected async errors
  console.log(JSON.stringify({ decision: "approve" }));
  process.exit(0);
});
