# Row pairing rationale — sections I and D

Why each row in `cases-interpreter.sh` exists and which row it is paired against.
Extracted from the inline headers so each block stays under the comment-block
threshold (`rules/coding/file-split.md`, Pattern A); the tables themselves remain
the SSOT for what is asserted.

## Section I — `hooks/block-clearance-token-write/interpreter-scan.js`

Identity ("is this word an interpreter, and of which kind?") and proof ("does this
argv word show the program is on argv, so stdin carries data?").

The two alternations point in OPPOSITE directions and must never be merged:
`INTERPRETER_RE` is an EXTRACTION alternation (over-matching = read more text =
safe), `INLINE_PROGRAM_FLAG_RE` is a PERMISSION predicate (over-matching = clear
more = unsafe). Sections I and D are where that split is observable.

| Rows | Why |
|---|---|
| `I-re-node` vs `I-re-script` | a `-c`/`-e`-family FLAG is what makes the shape |
| `I-re-nodex` vs `I-re-node` | word boundary: `nodex` is not `node` |
| `I-re-echoe` | `echo -e` carries the flag but no interpreter |
| `I-re-pwshCo` / `I-re-case` | pwsh accepts every unambiguous prefix of `-Command`, in any casing, and so must this |
| `I-bf-awk` / `I-bf-php` vs `I-bf-node` | the body-FIRST family needs no flag at all (`awk 'BEGIN{print > "<marker>"}'`), which is exactly why it is a second regex |
| `I-kind-*` / `I-pwsh-*` | identity is path-insensitive, `.exe`-tolerant and case-folded (Windows executable lookup) |
| `I-flag-*` vs `I-flag-p` / `I-flag-E` | `-p` / `-E` are LOOKALIKES — round-7: a flag that merely resembles a program flag is not proof |
| `I-proof-pwsh` vs `I-proof-nonpwsh` | round-8 fix A: `-Command` is proof for pwsh and meaningless for node, so proof is kind-SCOPED |
| `I-ro-read` vs `I-ro-write` | #1709: an anchored, provably side-effect-free read shape is approved; everything else is a write until proven otherwise |
| `I-ro-read` vs `I-ro-ruby` / `I-ro-unknown` | #1821: the SAME body, delivered by a language with no read-only shape (`ruby`) or by an unrecognized word, is not approved — read-only shapes are language-SCOPED and fail closed |
| `I-deliv-flagval` vs `I-deliv-runner` | #1821: which language a body is judged in is resolved FORWARD from command position, not by back-scanning for the last interpreter-looking word. `ruby -I python3` is ruby (the flag VALUE is attacker-chosen and must not name the language), while `uv run python` is still python (a runner prefix must keep resolving) |
| `I-deliv-optarg` vs `I-deliv-wrapper` | a name directly after a dash-word may be that flag's ARGUMENT; flag arity is not decidable here, so `uvx --from python3 ruby` resolves to unknown (fail closed) while `command node` resolves |
| `I-hits-spoof` vs `I-hits-runner` | the same split at whole-hook level: the spoofed `python3` no longer lends python's `open(p)` shape to a ruby body (`Kernel#open` with a leading `\|` runs a SHELL COMMAND), and the genuine runner-delivered python read stays approved |

## Section D — `hooks/block-clearance-token-write/nested-bodies.js`

The routes by which COMMAND TEXT reaches a shell without being written as a
command: `eval`, here-strings, heredocs, pipelines.

| Rows | Why |
|---|---|
| `D-eval-yes` / `D-eval-wrap` vs `D-eval-no` | `eval` is found through the command wrappers (command/builtin/exec/nohup/time) and only there |
| `D-hs-raw` vs `D-hs-val` | the SAME here-string in both spellings. Raw keeps the outer quotes (the shell scanner re-tokenizes it); the value is quote-stripped (the only form the anchored read-only shapes can match). Feeding the raw form to those shapes would fail-closed block `node <<< "…"` while its `-e` sibling is approved — the #1709 asymmetry |
| `D-stdin-bare` vs `D-stdin-flag` | `node` reading stdin is a PROGRAM route; `node -e '…'` proves the program is on argv, so stdin is data |
| `D-stdin-script` | accepted over-block: a bare file operand cannot be proven without flag-arity knowledge, so it stays a program route |
| `D-routes-heredoc` vs `D-routes-assign` | the same heredoc with and without a leading `VAR=1` — the row that `ASSIGN_WORD_RE` is keyed on (Section M) |
| `D-routes-pipe` | an upstream pipeline into a bare interpreter is OPAQUE (o=1): it cannot be analysed, so it is not cleared |
| `D-lang-hd-node` vs `D-lang-hd-ruby` | the `lang` TAG itself, not the route count: `bash-scan/scan.js` hands it to `interpreterBodyHitsProtected` as the delivering interpreter's identity, and the read-only shapes are scoped per language — a swapped tag silently re-scopes them |
| `D-lang-hd-path` / `D-lang-hd-assign` / `D-lang-hd-wrap` | the tag survives an absolute path, a leading `VAR=1`, and a `command` wrapper — the three spellings `deliveringInterpreterOf` has to see through |
| `D-lang-hd-shell` / `D-lang-hd-cat` vs `D-lang-hd-node` | a shell and a non-interpreter get NO body route at all, so there is no tag to scope — the pair that stops `-` from being read as "tag missing" |
| `D-lang-hd-argv` | `node -e "y" <<EOF` proves the program is on argv, so the heredoc is data, not a program body — the `D-stdin-flag` distinction restated at route level |
| `D-lang-hs-node` / `D-lang-hs-ruby` vs `D-lang-hs-shell` | the same three verdicts on the here-string route, because the tag is derived per route and not once per command |
