"use strict";
// The ids that Step 2 (the parser swap) deliberately moves in expected.json, and why. One per line.
// snapshot.sh --update refuses to write an expected-value diff for an id not listed here -- a
// manually-confirmed ledger meant to close off the "test is red, so fix the expected value"
// path (no automatic classification).
// Shape: { id: "<corpus id>", reason: "<why the current output is wrong and the new output is right>" }
// Initial state (at the Step 1 commit) is empty -- the current implementation is the sole
// source of truth, and there is no moving expected value yet.

module.exports = [
  { id: "g01-cat-eof", reason: "Result of fixing command-ir/heredoc.js to match the S2 requirement (treat the heredoc body as an opaque literal, do not re-lex it as separators/redirects). The old output was wrong in that it lexed the heredoc body's lines into argv/segments, leaking them in ('body' '<tag>' showing up in argv); the new output parses only the opener line and keeps the body verbatim at the end of rawText (the top-level rawText keeps the full text, while segments[].rawText is the opener line only)." },
  { id: "g02-python", reason: "Same as above (see g01). The old output wrongly split the heredoc body `print(1)` into a pipeline as an independent command (kind: pipeline, 3 segments), so the single command python3 was fractured into 3 spurious segments. The new output de-syntaxes the heredoc body and treats it as a single simple segment." },
  { id: "g03-node", reason: "Same as above (see g01). The old output misdetected the `(` `)` in the heredoc body `console.log(1)` as separators. The new output de-syntaxes the body." },
  { id: "g04-gh-body-file", reason: "Same as above (see g01). The old output lexed the --body-file heredoc body's line, leaking it into argv. The new output de-syntaxes the body." },
  { id: "g05-body-operators", reason: "The core S2 case. For an input whose heredoc body contains `&& ; > '`, the old output parsed these as real separators/redirects and split it into multiple segments (a known bug from before heredoc opacity, exactly the target of #2121). The new output treats the entire body as a single opaque text and does not interpret it as separators." },
  { id: "g06-dash-tag", reason: "Same as above (see g01). Body de-syntaxing applies consistently even for the <<-TAG form." },
  { id: "g07-punctuated-tag", reason: "Same as above (see g01). Body de-syntaxing applies consistently even when the tag contains `.` `-`." },
  { id: "g08-unquoted-tag", reason: "Same as above (see g01). Body de-syntaxing applies consistently even when the tag is unquoted." },
  { id: "g09-heredoc-to-file", reason: "Same as above (see g01). Body de-syntaxing applies consistently even in the form where a redirect and a heredoc coexist on one line." },
];
