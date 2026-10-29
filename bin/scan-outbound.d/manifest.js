"use strict";
// RS-framed --manifest stream: RS + path + RS + byte length + LF + bytes, repeated.
// parseManifest(buf) -> { frames: [{ path, body }] } | { broken: reason }
// Frames bash read sanely (zero length with no body, a missing leading RS, a last body cut short
// by EOF) parse as bash read them; any other malformed frame is reported broken (rc 4), where
// bash dropped or mis-attributed it.

const RS = 0x1e;
const LF = 0x0a;
// A frame header anywhere inside a cut-short body, after a LF or mid-line (the swallowed body
// had no trailing LF): the body swallowed the frames after it.
const RS_CHAR = String.fromCharCode(RS);
const SWALLOWED_HEADER = new RegExp(`${RS_CHAR}[^${RS_CHAR}\\n]+${RS_CHAR}[0-9]+\\n`);

function parseManifest(buf) {
  const frames = [];
  let pos = 0;
  while (pos < buf.length) {
    const at = pos;
    const nl = buf.indexOf(LF, pos);
    if (nl < 0) return { broken: `frame header at byte ${at} has no line end` };
    let header = buf.subarray(pos, nl);
    pos = nl + 1;
    if (header[0] === RS) header = header.subarray(1);
    const sep = header.indexOf(RS);
    if (sep < 0 || header.indexOf(RS, sep + 1) >= 0) return { broken: `frame header at byte ${at} does not have one path / length separator` };
    const path = header.subarray(0, sep).toString("utf8");
    const lenText = header.subarray(sep + 1).toString("utf8");
    if (path === "") return { broken: `frame at byte ${at} has an empty path` };
    if (!/^[0-9]+$/.test(lenText)) return { broken: `frame at byte ${at} has a length that is not a byte count` };
    const len = Number(lenText);
    const body = buf.subarray(pos, Math.min(buf.length, pos + len));
    if (body.length < len) {
      if (len > buf.length || SWALLOWED_HEADER.test(body.toString("utf8"))) {
        return { broken: `frame at byte ${at} declares more bytes than the stream holds` };
      }
    }
    pos += body.length;
    frames.push({ path, body });
  }
  return { frames };
}

module.exports = { parseManifest };
