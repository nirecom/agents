#!/usr/bin/env node
'use strict';

//
// bin/sweep-issues/scan-stale-paths.js — SI-2 path-token stale detector AND the
// repository SSOT for what counts as a safe path token.
//
// No network, no `gh`, no writes: the only file I/O is an existence probe under
// --repo-root.
//
//   stdin  : a `gh issue list --json number,title,body` shaped JSON array
//   stdout : headerless TSV — number / status / missing_count / total_count / tokens_csv
//   status : stale     >= 1 token and every token missing  (close candidate)
//            live      >= 1 token and at least one exists  (never a candidate)
//            no-tokens no usable path token at all
//   exit   : 0 normally; 2 on unparseable stdin (diagnostic on stderr)
//
// Flags: --repo-root <dir> (default process.cwd()), --all (emit non-stale rows),
//        --check-tokens <csv> (token-validation mode, see below), -h.
//
// --check-tokens <csv> does not read stdin. It re-applies this file's token
// grammar to a CSV that was produced elsewhere and emits, one row per token:
//     accept<TAB>token          |  reject<TAB>token<TAB>reason
// It exists so that downstream consumers (bin/sweep-issues/verify-candidate.sh)
// re-apply THIS rule instead of hand-rolling a second copy of it (CPR-2). The
// tokens reaching those consumers ultimately derive from attacker-authored
// GitHub issue text, so the invariant must hold at every consumer, not just at
// the point of extraction.
//
// Column 5 (tokens_csv) is a contract seam: it is transcribed verbatim into
// column 2 of the survivors TSV, so it must never contain a TAB.
//

const fs = require('fs');
const path = require('path');

// Parser/regex SSOT for this file (registered in bin/check-table-driven.sh
// PARSER_TARGETS). Only these top-level directories and extensions are
// considered repository path tokens. The scanning form and the anchored
// validation form are derived from ONE pattern so they can never drift.
const TOKEN_PATTERN =
  '(bin|hooks|skills|tests|rules|agents|install|docs)/[A-Za-z0-9._/-]+\\.(js|sh|md|py|ps1|json)';
const TOKEN_RE = new RegExp(`\\b${TOKEN_PATTERN}\\b`, 'g');
const TOKEN_ANCHORED_RE = new RegExp(`^${TOKEN_PATTERN}$`);

// The single definition of "this token is not a usable repository path".
// Returns '' when the token is safe, otherwise a short machine-readable reason.
function tokenRejectReason(token) {
  if (typeof token !== 'string' || token.length === 0) return 'empty';
  if (token.split('/').includes('..')) return 'path-traversal';
  if (!TOKEN_ANCHORED_RE.test(token)) return 'not-a-repository-path-token';
  return '';
}

// Punctuation that commonly trails a token in prose or markdown.
const TRAILING_PUNCT_RE = /[.,)]+$/;

const USAGE = [
  'Usage: scan-stale-paths.js [--repo-root <dir>] [--all]',
  '       scan-stale-paths.js --check-tokens <csv>',
  '',
  'Reads a `gh issue list --json number,title,body` array on stdin and writes',
  'a headerless TSV: number / status / missing_count / total_count / tokens_csv.',
  '',
  '  --repo-root <dir>    Root the path tokens are probed against (default: cwd).',
  '  --all                Also emit `live` and `no-tokens` rows (default: stale only).',
  '  --check-tokens <csv> Validation mode: no stdin; emits accept/reject rows for',
  '                       each CSV token against this file\'s token grammar.',
].join('\n');

function parseArgs(argv) {
  const opts = { repoRoot: process.cwd(), all: false, checkTokens: null };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--repo-root') {
      if (i + 1 >= argv.length) {
        process.stderr.write('ERROR: --repo-root requires an argument\n');
        process.exit(2);
      }
      opts.repoRoot = argv[i + 1];
      i += 1;
    } else if (arg === '--check-tokens') {
      if (i + 1 >= argv.length) {
        process.stderr.write('ERROR: --check-tokens requires an argument\n');
        process.exit(2);
      }
      opts.checkTokens = argv[i + 1];
      i += 1;
    } else if (arg === '--all') {
      opts.all = true;
    } else if (arg === '-h' || arg === '--help') {
      process.stdout.write(`${USAGE}\n`);
      process.exit(0);
    } else {
      process.stderr.write(`ERROR: unknown argument: ${arg}\n`);
      process.exit(2);
    }
  }
  return opts;
}

// Extract unique, traversal-free path tokens from a text blob, preserving
// first-seen order so the caller's TSV is stable.
function extractTokens(text, seen, out) {
  if (typeof text !== 'string' || text.length === 0) return;
  TOKEN_RE.lastIndex = 0;
  let match = TOKEN_RE.exec(text);
  while (match !== null) {
    const token = match[0].replace(TRAILING_PUNCT_RE, '');
    // Same rule the --check-tokens consumers apply — path traversal is never a
    // real repository path, so it is dropped outright at extraction too.
    if (tokenRejectReason(token) === '' && !seen.has(token)) {
      seen.add(token);
      out.push(token);
    }
    match = TOKEN_RE.exec(text);
  }
}

function classify(issue, repoRoot) {
  const seen = new Set();
  const tokens = [];
  extractTokens(issue.title, seen, tokens);
  extractTokens(issue.body, seen, tokens);

  let missing = 0;
  for (const token of tokens) {
    if (!fs.existsSync(path.join(repoRoot, token))) missing += 1;
  }

  let status = 'no-tokens';
  if (tokens.length > 0) status = missing === tokens.length ? 'stale' : 'live';

  return {
    number: issue.number,
    status,
    missing,
    total: tokens.length,
    tokensCsv: tokens.join(','),
  };
}

// --check-tokens: re-apply the grammar to a CSV produced elsewhere. Emits one
// row per non-blank token so the caller can log every rejection instead of
// silently dropping it. Always exit 0 — a rejected token is a finding, not an
// error of this tool.
function checkTokensMode(csv) {
  const lines = [];
  for (const raw of String(csv).split(',')) {
    const token = raw.trim();
    if (token === '') continue;
    const reason = tokenRejectReason(token);
    lines.push(reason === '' ? `accept\t${token}` : `reject\t${token}\t${reason}`);
  }
  if (lines.length > 0) process.stdout.write(`${lines.join('\n')}\n`);
  process.exit(0);
}

function main() {
  const opts = parseArgs(process.argv.slice(2));

  if (opts.checkTokens !== null) checkTokensMode(opts.checkTokens);

  let raw = '';
  try {
    raw = fs.readFileSync(0, 'utf8');
  } catch (err) {
    process.stderr.write(`ERROR: cannot read stdin: ${err.message}\n`);
    process.exit(2);
  }

  let issues;
  try {
    issues = JSON.parse(raw.trim() === '' ? '[]' : raw);
  } catch (err) {
    process.stderr.write(`ERROR: stdin is not valid JSON: ${err.message}\n`);
    process.exit(2);
  }

  if (!Array.isArray(issues)) {
    process.stderr.write('ERROR: stdin JSON must be an array of issues\n');
    process.exit(2);
  }

  const lines = [];
  for (const issue of issues) {
    if (issue === null || typeof issue !== 'object') continue;
    const row = classify(issue, opts.repoRoot);
    if (!opts.all && row.status !== 'stale') continue;
    lines.push(
      [row.number, row.status, row.missing, row.total, row.tokensCsv].join('\t'),
    );
  }

  if (lines.length > 0) process.stdout.write(`${lines.join('\n')}\n`);
  process.exit(0);
}

main();
