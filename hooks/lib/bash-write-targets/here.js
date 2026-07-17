"use strict";
// hooks/lib/bash-write-targets/here.js
// here-doc / here-string / PowerShell here-string IR read/write boundary (#1402 canary-7).
//
// CONTRACT: here-doc (<<EOF), here-string (<<<), and pwsh here-strings
// (@'...'@ / @"..."@) supply a multi-line STRING to a command's stdin or an
// argument position. They are NOT file writes by themselves. A write only
// occurs when the SAME segment also carries a write redirect (> / >> / &>),
// which isPosixRedirWriteIR already owns.
//
// This predicate does NOT retire the WRITE_PATTERNS here-* entries: those remain
// as QUOTING_ONLY_NAMES markers that classify()'s Group A override and
// isSafeHeredocOnly gate depend on (original-cmd scan constraint, intent.md).
// isHereWriteIR is the IR-side companion used by the fast-allow / segment-exclude
// pipeline, and it deliberately returns false for pure here-shapes so that the
// redirect predicate (not this one) accounts for any co-located write.

// Detects a here-input construct (<<<, <<EOF, pwsh @'...'@ / @"..."@) in a segment.
function segHasHereInput(seg) {
  if (seg && Array.isArray(seg.redirects)) {
    if (seg.redirects.some((r) => r.op === "<<<")) return true;
  }
  const raw = (seg && seg.rawText) || "";
  if (/(?:^|[\s;|&])\d*<<-?['"]?\w/.test(raw)) return true; // here-doc anchor
  if (/@'[\s\S]*?'@|@"[\s\S]*?"@/.test(raw)) return true;   // pwsh here-string
  return false;
}

/**
 * isHereWriteIR: pure here-shapes are stdin/argument data (read); a co-located
 * write redirect (if any) is owned by isPosixRedirWriteIR. This predicate verifies
 * the shape and returns false, keeping the read/write boundary in one place (CPR-2).
 * @param {object} ir
 * @returns {boolean}
 */
function isHereWriteIR(ir) {
  if (!ir || ir.parseFailure === true) return false;
  if (!Array.isArray(ir.segments)) return false;
  for (const seg of ir.segments) {
    if (!segHasHereInput(seg)) continue;
    // here-shape segment: any write is via a co-located redirect (isPosixRedirWriteIR)
    // or a pwsh cmdlet (isPwshWriteIR). Return false to avoid double-counting.
    return false;
  }
  return false;
}

module.exports = { isHereWriteIR, segHasHereInput };
