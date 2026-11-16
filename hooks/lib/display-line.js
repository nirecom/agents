"use strict";
// One value shown inside a multi-line permission prompt (#2852): control characters become spaces,
// so a value cannot add or forge a line, and the value is cut to a fixed length.

const DISPLAY_LINE_MAX = 200;

function toDisplayLine(value) {
  // eslint-disable-next-line no-control-regex -- replacing control characters is the purpose
  return String(value).replace(/[\x00-\x1f\x7f]/g, " ").slice(0, DISPLAY_LINE_MAX);
}

module.exports = { toDisplayLine, DISPLAY_LINE_MAX };
