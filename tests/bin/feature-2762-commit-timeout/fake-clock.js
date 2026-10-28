"use strict";
// Fake clocks for tests/bin/feature-2762-commit-timeout.js (#2762). gate.js runGit measures a git
// call's elapsed time on the monotonic clock (performance.now), so the fakes move that clock; the
// wall clock (Date.now) is stubbed beside it so a case can step it backwards or forwards on its own
// and prove the elapsed time ignores it. Every stub is undone by the returned restore / finally.
const { performance } = require("node:perf_hooks");

function swap(target, key, fn) {
  const own = Object.getOwnPropertyDescriptor(target, key);
  target[key] = fn;
  return () => {
    if (own) Object.defineProperty(target, key, own);
    else delete target[key];
  };
}

// Both clocks answer what they answered before plus st.mono / st.wall, read at each call.
function offsetClocks() {
  const prevMono = performance.now.bind(performance);
  const prevWall = Date.now;
  const st = { mono: 0, wall: 0 };
  const undoMono = swap(performance, "now", () => prevMono() + st.mono);
  const undoWall = swap(Date, "now", () => prevWall() + st.wall);
  st.restore = () => { undoWall(); undoMono(); };
  return st;
}

// Both clocks stand still inside fn, so an elapsed time is exactly the offsets fn adds.
function withFrozenClocks(fn) {
  const mono = performance.now();
  const wall = Date.now();
  const undoMono = swap(performance, "now", () => mono);
  const undoWall = swap(Date, "now", () => wall);
  try { return fn(); } finally { undoWall(); undoMono(); }
}

module.exports = { offsetClocks, withFrozenClocks };
