#!/usr/bin/env bash
# tests/lib/script-checkout-fixture.sh — sourced.
# script_checkout_fixture_copy <dest_dir> [prefix...] copies the tracked files (git ls-files) of
# the checkout this library lives in that fall under the given repo-relative prefixes (default:
# bin hooks skills) into <dest_dir> at the same relative paths, keeping the executable bit.
# Renamed code finds its siblings from its own real path, so a test that wants a stub or a
# broken sibling to be reached must launch the code from such a copy.
# Order of use: copy first, then place stubs. A file already present in <dest_dir> is never
# overwritten, so a stub survives a later copy of an overlapping prefix.

_SCRIPT_CHECKOUT_FIXTURE_SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

script_checkout_fixture_copy() {
  local dest="${1:-}" src="$_SCRIPT_CHECKOUT_FIXTURE_SCRIPT_CHECKOUT_ROOT"
  if [[ -z "$dest" ]]; then
    echo "script_checkout_fixture_copy: destination directory required" >&2
    return 1
  fi
  shift
  if [[ "$#" -eq 0 ]]; then set -- bin hooks skills; fi
  mkdir -p "$dest" || return 1
  if command -v cygpath >/dev/null 2>&1; then
    dest="$(cygpath -m "$dest")"
    src="$(cygpath -m "$src")"
  fi
  node - "$src" "$dest" "$@" <<'COPY_JS'
"use strict";
const fs = require("fs");
const path = require("path");
const { execFileSync } = require("child_process");
const [src, dest, ...prefixes] = process.argv.slice(2);
let listing;
try {
  listing = execFileSync("git", ["-C", src, "ls-files", "-z", "--", ...prefixes], {
    encoding: "utf8",
    maxBuffer: 64 * 1024 * 1024,
    stdio: ["ignore", "pipe", "pipe"],
  });
} catch (err) {
  process.stderr.write(`script_checkout_fixture_copy: cannot list tracked files of ${src}: ${String(err.message).split("\n")[0]}\n`);
  process.exit(1);
}
const made = new Set();
for (const rel of listing.split("\0")) {
  if (rel === "") continue;
  const parts = rel.split("/");
  if (path.isAbsolute(rel) || parts.includes("..")) {
    process.stderr.write(`script_checkout_fixture_copy: refusing a path that escapes the tree: ${rel}\n`);
    process.exit(1);
  }
  const from = path.join(src, ...parts);
  const to = path.join(dest, ...parts);
  let st;
  try {
    st = fs.statSync(from);
  } catch (_) {
    continue;
  }
  if (!st.isFile()) continue;
  const dir = path.dirname(to);
  if (!made.has(dir)) {
    fs.mkdirSync(dir, { recursive: true });
    made.add(dir);
  }
  try {
    fs.copyFileSync(from, to, fs.constants.COPYFILE_EXCL);
    fs.chmodSync(to, st.mode & 0o777);
  } catch (err) {
    if (err.code !== "EEXIST") {
      process.stderr.write(`script_checkout_fixture_copy: cannot copy ${rel}: ${err.message}\n`);
      process.exit(1);
    }
  }
}
COPY_JS
}
