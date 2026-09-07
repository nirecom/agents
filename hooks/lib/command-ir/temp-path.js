"use strict";
// hooks/lib/command-ir/temp-path.js — SSOT predicate for OS temp-path detection.
// Redirects to a temp path are non-persistent, so classifiers may treat them as read.

/**
 * @param {string} target redirect target or path argument
 * @returns {boolean} true when the path is inside an OS temporary directory
 */
function isOsTempPath(target) {
  if (target == null || typeof target !== "string" || target === "") return false;
  // Reject path traversal: `../` can escape the temp root (CWE-22).
  if (/(?:^|[/\\])\.\.(?:[/\\]|$)/.test(target)) return false;
  if (/^\/tmp\//.test(target) || /^\/var\/tmp\//.test(target) || /^\/dev\/shm\//.test(target)) return true;
  if (/appdata[/\\]local[/\\]temp[/\\]/i.test(target)) return true;
  if (/^[a-zA-Z]:[/\\]tmp[/\\]/i.test(target)) return true;
  if (/[/\\]windows[/\\]temp[/\\]/i.test(target)) return true;
  return false;
}

module.exports = { isOsTempPath };
