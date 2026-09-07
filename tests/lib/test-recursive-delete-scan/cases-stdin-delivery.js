"use strict";

// Tests: hooks/lib/bash-write-targets/recursive-delete-scan/stdin-delivery.js
// Tags: scope:issue-specific, recursive-delete, bash-write-targets, guard, TL1
//
// Delivery routes where the script text never lands in argv at all, plus the
// echo/printf literal-text resolution that feeds the pipe route.

const { runTable } = require("./harness");

// Each route is paired with a harmless body so the route itself is never
// mistaken for the verdict.
runTable("stdin-delivery-routes (round9 C7)", [
  { label: 'echo "rm -rf x" | bash (pipe route, shell body)', cmd: 'echo "rm -rf x" | bash', want: true },
  { label: 'echo "ls -la" | bash (pipe route, harmless)', cmd: 'echo "ls -la" | bash', want: false },
  { label: "echo \"...rmtree(...)\" | python (pipe route, language body)", cmd: "echo \"import shutil; shutil.rmtree('x')\" | python", want: true },
  { label: 'echo "print(1)" | python (pipe route, harmless language body)', cmd: 'echo "print(1)" | python', want: false },
  { label: 'bash <<< "rm -rf x" (herestring route, shell body)', cmd: 'bash <<< "rm -rf x"', want: true },
  { label: 'bash <<< "ls -la" (herestring route, harmless)', cmd: 'bash <<< "ls -la"', want: false },
  { label: "python <<< \"...rmtree(...)\" (herestring route, language body)", cmd: "python <<< \"import shutil; shutil.rmtree('x')\"", want: true },
  { label: 'python <<< "print(1)" (herestring route, harmless language body)', cmd: 'python <<< "print(1)"', want: false },
  { label: 'bash <(echo "rm -rf x") (process substitution route)', cmd: 'bash <(echo "rm -rf x")', want: true },
  { label: 'bash <(echo "ls -la") (process substitution route, harmless)', cmd: 'bash <(echo "ls -la")', want: false },
  { label: 'echo "rm -rf x" | source /dev/stdin (shell builtin re-reads its own stdin)', cmd: 'echo "rm -rf x" | source /dev/stdin', want: true },
  { label: 'echo "ls -la" | source /dev/stdin (harmless)', cmd: 'echo "ls -la" | source /dev/stdin', want: false },
  { label: 'echo "rm -rf x" | . /dev/stdin (dot-form alias of source)', cmd: 'echo "rm -rf x" | . /dev/stdin', want: true },
  { label: 'echo "ls -la" | . /dev/stdin (dot-form alias, harmless)', cmd: 'echo "ls -la" | . /dev/stdin', want: false },
  { label: 'echo "Remove-Item -Recurse x" | pwsh -Command - (stdin-fed pwsh, "-" means read stdin)', cmd: 'echo "Remove-Item -Recurse x" | pwsh -Command -', want: true },
  { label: 'echo "Get-ChildItem x" | pwsh -Command - (stdin-fed pwsh, harmless)', cmd: 'echo "Get-ChildItem x" | pwsh -Command -', want: false },
]);

// A naive argv.join(" ") leaked echo's own leading flags and printf's FORMAT
// string into the payload text; the last row proves the unresolvable-format
// branch fails closed instead of falling through.
runTable("stdin-delivery-text-producers (round12 C1)", [
  { label: 'echo -e "rm -rf x" | bash (leading -e flag stripped by echoLiteralText)', cmd: 'echo -e "rm -rf x" | bash', want: true },
  { label: 'echo -e "ls -la" | bash (leading -e flag stripped, harmless)', cmd: 'echo -e "ls -la" | bash', want: false },
  { label: 'echo -ne "rm -rf x" | bash (combined -ne short flag stripped)', cmd: 'echo -ne "rm -rf x" | bash', want: true },
  { label: "printf '%s' 'rm -rf x' | bash (plain %s format resolved to the payload)", cmd: "printf '%s' 'rm -rf x' | bash", want: true },
  { label: "printf '%s' 'ls -la' | bash (plain %s format resolved, harmless)", cmd: "printf '%s' 'ls -la' | bash", want: false },
  { label: "printf '%s\\n' 'rm -rf x' | bash (%s\\n format resolved to the payload)", cmd: "printf '%s\\n' 'rm -rf x' | bash", want: true },
  { label: "printf '%d rm -rf x' | bash (unresolvable format: fails closed via producerTextUnresolvable)", cmd: "printf '%d rm -rf x' | bash", want: true },
]);
