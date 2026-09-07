"use strict";

// Tests: hooks/lib/bash-write-targets/recursive-delete-scan/interpreter-bodies.js
// Tags: scope:issue-specific, recursive-delete, bash-write-targets, guard, TL1
//
// A non-shell body is matched against LANGUAGE_DELETE_SHAPES, never re-parsed
// as shell text; one block/allow pair per wired language family.

const { runTable } = require("./harness");

runTable("interpreter-language-bodies (round9 C6)", [
  { label: "python -c shutil.rmtree(...) blocks", cmd: "python -c \"import shutil; shutil.rmtree('/tmp/x')\"", want: true },
  { label: "python -c harmless body approves", cmd: "python -c \"print('hello')\"", want: false },
  { label: "python3 -c os.removedirs(...) blocks (python3 alias)", cmd: "python3 -c \"os.removedirs('/tmp/x')\"", want: true },
  { label: "perl -e rmtree(...) blocks", cmd: "perl -e \"rmtree('/tmp/x')\"", want: true },
  { label: "perl -e harmless body approves", cmd: "perl -e \"print 1\"", want: false },
  { label: "ruby -e FileUtils.rm_rf(...) blocks", cmd: "ruby -e \"FileUtils.rm_rf('/tmp/x')\"", want: true },
  { label: "ruby -e harmless body approves", cmd: "ruby -e \"puts 1\"", want: false },
  { label: "node -e fs.rmSync(path, {recursive: true}) blocks", cmd: "node -e \"fs.rmSync('/tmp/x', {recursive: true})\"", want: true },
  { label: "node -e harmless body approves", cmd: "node -e \"console.log(1)\"", want: false },
  { label: "bun -e rimraf(...) blocks (bun aliases node's spec)", cmd: "bun -e \"require('rimraf')('/tmp/x')\"", want: true },
  { label: "php -r shelling out to rm -rf blocks (no php-specific shape, falls to SHELL_DELETE_SHAPES)", cmd: "php -r \"system('rm -rf /tmp/x')\"", want: true },
  { label: "php -r harmless body approves", cmd: "php -r \"echo 1;\"", want: false },
  { label: "lua -e os.execute('rm -rf ...') blocks (SHELL_DELETE_SHAPES)", cmd: "lua -e \"os.execute('rm -rf /tmp/x')\"", want: true },
  { label: "lua -e harmless body approves", cmd: "lua -e \"print(1)\"", want: false },
  { label: "Rscript -e unlink(path, recursive = TRUE) blocks", cmd: "Rscript -e \"unlink('/tmp/x', recursive = TRUE)\"", want: true },
  { label: "Rscript -e harmless body approves", cmd: "Rscript -e \"print(1)\"", want: false },
  { label: "tclsh -c file delete -force blocks", cmd: "tclsh -c \"file delete -force /tmp/x\"", want: true },
  { label: "tclsh -c harmless body approves", cmd: "tclsh -c \"puts hi\"", want: false },
  { label: "awk BEGIN{system(\"rm -rf ...\")} blocks (SHELL_DELETE_SHAPES)", cmd: "awk 'BEGIN{system(\"rm -rf /tmp/x\")}'", want: true },
  { label: "awk harmless BEGIN block approves", cmd: "awk 'BEGIN{print 1}'", want: false },
]);
