"use strict";
// lang-check: ignore — the UTF-8 rows carry CJK on purpose.
// Staged-blob corpus for the pre-commit binary skip (#2507 G2). Each entry is staged into a
// fixture index under `mode`; the golden records what today's
// `git show ":$file" | file --mime - | grep -q binary` decides for it.

const B = (...bytes) => Buffer.from(bytes);
const s = (str, enc) => Buffer.from(str, enc || "utf8");
const fill = (n, ch) => Buffer.alloc(n, ch);

// file(1) scans at most `encoding`=65536 bytes for the charset (file -P), so a NUL is seen only
// within the first 65536 bytes. The boundary entries pin that window.
const WINDOW = 65536;

const BINARY_CASES = [
  { name: "empty", mode: "100644", content: s("") },
  { name: "ascii-line", mode: "100644", content: s("abc\n") },
  { name: "ascii-no-newline", mode: "100644", content: s("abc") },
  { name: "nul-in-middle", mode: "100644", content: Buffer.concat([s("a"), B(0), s("b\n")]) },
  { name: "utf8-bom", mode: "100644", content: Buffer.concat([B(0xef, 0xbb, 0xbf), s("abc\n")]) },
  { name: "utf8-multibyte", mode: "100644", content: s("café あ\n") },
  { name: "utf16le-bom", mode: "100644", content: Buffer.concat([B(0xff, 0xfe), s("ab\n", "utf16le")]) },
  { name: "latin1-high-byte", mode: "100644", content: Buffer.concat([s("caf"), B(0xe9), s("\n")]) },
  { name: "control-bytes", mode: "100644", content: B(1, 2, 3, 4, 5, 6) },
  { name: "escape-sequence-text", mode: "100644", content: Buffer.concat([B(0x1b), s("[31mred\n")]) },
  { name: "del-byte", mode: "100644", content: Buffer.concat([s("a"), B(0x7f), s("b\n")]) },
  { name: "shebang-script", mode: "100755", content: s("#!/bin/sh\necho hi\n") },
  { name: "png-header", mode: "100644", content: Buffer.concat([B(0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a), B(0, 0, 0, 13), s("IHDR"), B(0, 0, 0, 1, 0, 0, 0, 1, 8, 2, 0, 0, 0)]) },
  { name: "gzip-header", mode: "100644", content: B(0x1f, 0x8b, 0x08, 0x00, 0, 0, 0, 0, 0, 0x03, 0x03, 0, 0, 0, 0, 0, 0, 0, 0, 0) },
  { name: "pdf-header", mode: "100644", content: s("%PDF-1.4\n%âã\n1 0 obj\n<<>>\nendobj\n", "latin1") },
  { name: "json-text", mode: "100644", content: s('{"a":1}\n') },
  { name: "nul-last-byte-of-window", mode: "100644", content: Buffer.concat([fill(WINDOW - 1, 0x61), B(0)]) },
  { name: "nul-first-byte-after-window", mode: "100644", content: Buffer.concat([fill(WINDOW, 0x61), B(0)]) },
  { name: "nul-far-after-window", mode: "100644", content: Buffer.concat([fill(WINDOW * 2, 0x61), B(0), s("tail\n")]) },
  { name: "invalid-utf8", mode: "100644", content: Buffer.concat([s("ab"), B(0xc3, 0x28), s("cd\n")]) },
  { name: "utf8-truncated-sequence", mode: "100644", content: Buffer.concat([s("ab"), B(0xe3, 0x81), s("\n")]) },
  { name: "utf16be-bom", mode: "100644", content: Buffer.concat([B(0xfe, 0xff), B(0, 0x61, 0, 0x62, 0, 0x0a)]) },
  { name: "utf32le-bom", mode: "100644", content: B(0xff, 0xfe, 0, 0, 0x61, 0, 0, 0, 0x0a, 0, 0, 0) },
  { name: "cr-only-newlines", mode: "100644", content: s("a\rb\rc\r") },
  { name: "crlf-newlines", mode: "100644", content: s("a\r\nb\r\n") },
  { name: "zip-header", mode: "100644", content: Buffer.concat([s("PK"), B(3, 4, 20, 0, 0, 0, 8, 0), fill(18, 0)]) },
  { name: "high-bytes-0x80-0x9f", mode: "100644", content: Buffer.concat([s("ab"), B(0x81, 0x8d, 0x9f), s("\n")]) },
  { name: "symlink-to-text-name", mode: "120000", content: s("../target/file.txt") },
  { name: "symlink-to-utf8-name", mode: "120000", content: s("café/あ.txt") },
  { name: "gitlink", mode: "160000", content: null },
];

// One entry per C0 control byte and DEL, embedded in an otherwise plain ASCII line: the
// text-vs-binary table of libmagic's encoding.c decides each one.
for (const b of [...Array(32).keys(), 0x7f]) {
  const hex = b.toString(16).padStart(2, "0");
  BINARY_CASES.push({ name: `control-0x${hex}`, mode: "100644", content: Buffer.concat([s("ab"), B(b), s("cd\n")]) });
}

module.exports = { BINARY_CASES, WINDOW };
