"use strict";
// isBinary({mode, content}) -> boolean: what `file --mime - | grep -q binary` decided for a
// staged blob, by the charset tests of libmagic's encoding.c over its 65536-byte window.

const WINDOW = 65536;
const GITLINK = "160000";

// libmagic text_chars: T text, F never text, I ISO-8859 high byte, X other high byte.
const T = 1;
const F = 0;
const I = 2;
const X = 3;
const CHAR = new Uint8Array(256).map((_, b) => {
  if ((b >= 0x07 && b <= 0x0d) || b === 0x1b || (b >= 0x20 && b <= 0x7e) || b === 0x85) return T;
  if (b < 0x80) return F;
  return b < 0xa0 ? X : I;
});

const allOf = (buf, ok) => buf.every((b) => ok(CHAR[b]));

// Byte range a continuation byte may take after lead `b` (the first one only), per RFC 3629.
function secondRange(b) {
  if (b === 0xe0) return [0xa0, 0xbf];
  if (b === 0xed) return [0x80, 0x9f];
  if (b === 0xf0) return [0x90, 0xbf];
  if (b === 0xf4) return [0x80, 0x8f];
  return [0x80, 0xbf];
}

const trailOf = (b) => (b >= 0xc2 && b <= 0xdf ? 1 : b >= 0xe0 && b <= 0xef ? 2 : b >= 0xf0 && b <= 0xf4 ? 3 : -1);

// -1 not UTF-8, 1 ASCII-only text, 2 UTF-8 with a multi-byte sequence (cut short at the end is ok).
function looksUtf8(buf) {
  let multi = false;
  for (let i = 0; i < buf.length; i++) {
    const b = buf[i];
    if (b < 0x80) {
      if (CHAR[b] !== T) return -1;
      continue;
    }
    const n = trailOf(b);
    if (n < 0) return -1;
    for (let k = 1; k <= n; k++) {
      if (i + k >= buf.length) return 2;
      const [lo, hi] = k === 1 ? secondRange(b) : [0x80, 0xbf];
      if (buf[i + k] < lo || buf[i + k] > hi) return -1;
    }
    i += n;
    multi = true;
  }
  return multi ? 2 : 1;
}

// UCS-16/UCS-32 with a BOM, every code unit below 0x80 a text char.
function looksUcs(buf, width) {
  if (buf.length < width) return false;
  const le = width === 2 ? buf[0] === 0xff && buf[1] === 0xfe : buf[0] === 0xff && buf[1] === 0xfe && buf[2] === 0 && buf[3] === 0;
  const be = width === 2 ? buf[0] === 0xfe && buf[1] === 0xff : buf[0] === 0 && buf[1] === 0 && buf[2] === 0xfe && buf[3] === 0xff;
  if (!le && !be) return false;
  for (let i = width; i + width - 1 < buf.length; i += width) {
    const unit = width === 2 ? (le ? buf.readUInt16LE(i) : buf.readUInt16BE(i)) : le ? buf.readUInt32LE(i) : buf.readUInt32BE(i);
    if ((width === 2 && unit === 0xfffe) || (unit < 0x80 && CHAR[unit] !== T)) return false;
  }
  return true;
}

// The UTF-7 signature `+/v` followed by one of 8 9 + /.
const looksUtf7 = (buf) => buf.length >= 4 && buf[0] === 0x2b && buf[1] === 0x2f && buf[2] === 0x76 && [0x38, 0x39, 0x2b, 0x2f].includes(buf[3]);

// file_encoding's order; the EBCDIC fallback after it is not ported (no tracked file needs it).
function isText(buf) {
  if (allOf(buf, (c) => c === T)) return true;
  if (buf.length >= 3 && buf[0] === 0xef && buf[1] === 0xbb && buf[2] === 0xbf && looksUtf8(buf.subarray(3)) > 0) return true;
  if (looksUtf7(buf) || looksUcs(buf, 4) || looksUcs(buf, 2)) return true;
  if (looksUtf8(buf) > 1) return true;
  if (allOf(buf, (c) => c === T || c === I)) return true;
  return allOf(buf, (c) => c !== F);
}

// libmagic reports a one-byte buffer as "very short file (no magic)": charset=binary.
function isBinary({ mode, content }) {
  if (mode === GITLINK || content === null || content === undefined || content.length <= 1) return true;
  return !isText(content.subarray(0, WINDOW));
}

module.exports = { isBinary };
