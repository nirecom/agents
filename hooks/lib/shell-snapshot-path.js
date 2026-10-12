"use strict";
// hooks/lib/shell-snapshot-path.js — classify and plan the repair of the PATH line in a
// Claude Code shell snapshot (#2221). A Windows-form value (";"-separated drive paths) makes
// every Bash call exit 127, because /usr/bin is unreachable. Pure functions: no fs, no spawn;
// the converter is injected so the plan is testable without cygpath.

const VERDICTS = Object.freeze({
  OK: "ok",
  WINDOWS_FORM: "windows-form",
  WINDOWS_UNREPAIRABLE: "windows-unrepairable",
  MISSING_CORE: "missing-core",
  NO_PATH_LINE: "no-path-line",
  UNPARSED: "unparsed",
});

// Order matters: these become the head of the repaired PATH, /usr/bin before System32.
const MSYS_HEAD_CANDIDATES = Object.freeze(["/mingw64/bin", "/usr/local/bin", "/usr/bin", "/bin"]);

const DRIVE_EL_RE = /^[A-Za-z]:[\\/][^:;]*$/;
const UNC_EL_RE = /^\\\\[^\\]+\\[^:;]*$/;
const POSIX_ABS_EL_RE = /^\/[^:;]*$/;
const WINDOWS_TRACE_RE = /(^|[;:])([A-Za-z]:[\\/]|\\\\)/;
const PATH_LINE_HEAD_RE = /^export PATH='/m;

// The first `export PATH='` line decides. closed is true only when the value is a simple
// '...' that ends the line (an escaped quote or a multi-line value is not closed).
function parsePathLine(text) {
  const src = String(text);
  const m = PATH_LINE_HEAD_RE.exec(src);
  if (!m) return { found: false };
  const lineStart = m.index;
  const valueStart = lineStart + m[0].length;
  let nl = src.indexOf("\n", lineStart);
  if (nl === -1) nl = src.length;
  const line = src.slice(valueStart, nl);
  const cm = /^([^'\r\n]*)'(\r?)$/.exec(line);
  if (!cm) return { found: true, closed: false, lineStart };
  const eol = cm[2] + (nl < src.length ? "\n" : "");
  return { found: true, closed: true, value: cm[1], lineStart, lineEnd: nl < src.length ? nl + 1 : nl, eol };
}

function hasWindowsSign(value) {
  const v = String(value);
  return v.includes(";") || WINDOWS_TRACE_RE.test(v);
}

function reachesCore(value) {
  return String(value).split(":").some((e) => {
    const t = e.replace(/\/+$/, "");
    return t === "/usr/bin" || t === "/bin";
  });
}

function semicolonElements(value) {
  return String(value).split(";").map((e) => e.trim()).filter((e) => e !== "");
}

function isWindowsEl(e) { return DRIVE_EL_RE.test(e) || UNC_EL_RE.test(e); }

function classifyPathValue(value) {
  const v = String(value);
  if (reachesCore(v)) return VERDICTS.OK;
  if (!hasWindowsSign(v)) return VERDICTS.MISSING_CORE;
  const els = semicolonElements(v);
  const allKnown = els.length > 0 && els.every((e) => isWindowsEl(e) || POSIX_ABS_EL_RE.test(e));
  if (allKnown && els.some(isWindowsEl)) return VERDICTS.WINDOWS_FORM;
  return VERDICTS.WINDOWS_UNREPAIRABLE;
}

function classifySnapshotText(text) {
  const p = parsePathLine(text);
  if (!p.found) return VERDICTS.NO_PATH_LINE;
  if (!p.closed) return VERDICTS.UNPARSED;
  return classifyPathValue(p.value);
}

// deps.toPosixList(";"-list) -> ":"-list (cygpath -u -p); deps.msysHeadExisting() -> heads.
function planRepair(value, deps) {
  if (classifyPathValue(value) !== VERDICTS.WINDOWS_FORM) return { ok: false, reason: "not-windows-form" };
  const els = semicolonElements(value);
  const winEls = els.filter(isWindowsEl);
  const converted = String(deps.toPosixList(winEls.join(";")));
  const parts = converted.split(":");
  if (parts.length !== winEls.length || /[;\n\r']/.test(converted)) return { ok: false, reason: "conversion-mismatch" };
  const heads = Array.from(deps.msysHeadExisting() || []);
  if (!heads.includes("/usr/bin")) return { ok: false, reason: "no-msys-usr-bin" };
  let wi = 0;
  const body = els.map((e) => (isWindowsEl(e) ? parts[wi++] : e));
  const seen = new Set();
  const out = [];
  for (const e of heads.concat(body)) {
    const key = e.replace(/\/+$/, "") || e;
    if (e === "" || seen.has(key)) continue;
    seen.add(key);
    out.push(e);
  }
  return { ok: true, value: out.join(":") };
}

module.exports = {
  VERDICTS,
  MSYS_HEAD_CANDIDATES,
  parsePathLine,
  hasWindowsSign,
  classifyPathValue,
  classifySnapshotText,
  planRepair,
};
