"use strict";
// Child of feature-2936-turn-tail-read/fixture.js appendLater(): signals ready, waits, then appends the
// payload to the transcript (mode "append") or rewrites the transcript with it (mode "rewrite").
// argv: mode, transcript, payload file, ready file, delay ms.
const fs = require("fs");

const [mode, file, payloadFile, ready, delay] = process.argv.slice(2);
const payload = fs.readFileSync(payloadFile, "utf8");
fs.writeFileSync(ready, "1");
setTimeout(() => {
  if (mode === "rewrite") fs.writeFileSync(file, payload);
  else fs.appendFileSync(file, payload);
}, Number(delay) || 0);
