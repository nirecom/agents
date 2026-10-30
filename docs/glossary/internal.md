# Glossary — internal terms
<!-- lang-check: ignore -->

Terms the user never sees but many components reference as design concepts.
Entry criteria and form: [rules/docs/glossary.md](../../rules/docs/glossary.md).

### delivery operation

- **Definition**: The hard-to-undo act of landing the change on the default branch — a PR merge or a direct commit and push — performed by `/merge-to-main` right after the USER_VERIFIED confirmation.
- **Related**: [skills/merge-to-main/SKILL.md](../../skills/merge-to-main/SKILL.md)

### first_session_id

- **Definition**: session chain の第一世代の session id。session-progress.md と plan の名前はこれで決まる。
- **Related**: [architecture/claude-code/progress-file.md](../architecture/claude-code/progress-file.md)

### GATE_ACTION

- **Definition**: The closed-vocabulary confirm-gate verdict `next-step --gate` prints: `proceed`, `ask`, `present-and-stop`, or `none`.
  Skills follow it verbatim and never branch on the display-only `GATE_CONFIRM_<X>` line.
- **Related**: [architecture/claude-code/workflow-runtime.md](../architecture/claude-code/workflow-runtime.md)

### identifier context
- **Definition**: glossary drift check が識別子として扱う文脈 (コードスパン、`_ = $ { }` に隣接する語、大文字語の連続、Tags 行などの固定形式行と固定スキーマ見出し)。識別子の綴りとだけ照合する。
- **Related**: [architecture/claude-code/glossary-check/matching-rules.md](../architecture/claude-code/glossary-check/matching-rules.md)

### in-skill step

- **Definition**: An ID-labelled line of a skill's Procedure (`CI-3`, `WI-10`, …); it is not a workflow step, and its heading carries the ID alone.
- **Related**: [rules/prompt.md](../../rules/prompt.md)

### IR

- **Definition**: The intermediate representation that `hooks/lib/command-ir/` builds by parsing a Bash command string.
  Hooks judge a command through this structure instead of matching the raw text with regular expressions.
- **Related**: [architecture/claude-code/shell-command-parsing.md](../architecture/claude-code/shell-command-parsing.md)

### Jev input

- **Definition**: The text sent to Jev as its state for one judgment: a stage's sections, packed within a budget, and the names of the source copies.
  The two-stage judge's query builds it, and the backup subagent reads it first.
- **Related**: [architecture/jev/two-stage-broker.md](../architecture/jev/two-stage-broker.md)

### pre-commit section marker

- **Definition**: pre-commit が点検の区切りに入ったことを示す、決まった形式の 1 行の出力
- **Related**: [architecture/claude-code/worker-dispatch/commit-push.md](../architecture/claude-code/worker-dispatch/commit-push.md)

### presentation receipt

- **Definition**: The per-stage record the Stop hook writes when a turn closes on a plan's link line: the plan path, the link shown (URL, or the local path where none can be made) and the whole-file content hash.
  The CONFIRM checkpoint lets the echo reach the dialog only when it still matches the plan and spends it; it proves the user was shown the plan, and is not an approval.
- **Related**: [architecture/claude-code/settings/hooks.md](../architecture/claude-code/settings/hooks.md)

### prose context
- **Definition**: glossary drift check が identifier context 以外として扱う文脈。prose の見出し語と照合し、複数形と見出し行の大小だけを同じ語として許容する。
- **Related**: [architecture/claude-code/glossary-check/matching-rules.md](../architecture/claude-code/glossary-check/matching-rules.md)

### review round

- **Definition**: One reviewer run of the shared codex review loop; CAP is the normal ceiling on rounds, and MAX_EXTENSIONS is the extra rounds allowed only while HIGH concerns remain.
  "2+1" means CAP=2 / MAX_EXTENSIONS=1.
- **Related**: [skills/_shared/codex-review-loop.md](../../skills/_shared/codex-review-loop.md)

### SCRIPT_CHECKOUT_ROOT

- **Definition**: The checkout (main or linked worktree) holding the script currently running; each file assigns it once from its own path to find sibling code, never as an environment variable.
- **Related**: [architecture/claude-code/root-names.md](../architecture/claude-code/root-names.md)

### session chain

- **Definition**: 一つのセッションでは足りず、--from で次のセッションを継ぎ足していった連なり。先頭の世代が第一世代。
- **Related**: [architecture/claude-code/progress-file.md](../architecture/claude-code/progress-file.md)

### session-downstream

- **Definition**: 引き継ぎ先のセッション。--from で再開した側の世代。
- **Related**: [skills/resume-session/SKILL.md](../../skills/resume-session/SKILL.md)

### session-upstream

- **Definition**: 引き継ぎ元のセッション。--from で再開されるときの、再開元の世代。
- **Related**: [skills/resume-session/SKILL.md](../../skills/resume-session/SKILL.md)

### state handoff reader

- **Definition**: 指定した session の state handoff record を読み、時刻順に並べて返すコード。`/resume-session --from` と `--list` では、session-downstream が session-upstream の記録を読む。supervisor の codex 入力では、自分の session の記録を読む。移行期間中は、同じ session の旧 handoff.md も合わせて読む(この部分は Migration Code Blocks で囲む)。
- **Related**: [architecture/claude-code/state-handoff-record.md](../architecture/claude-code/state-handoff-record.md)

### step table

- **Definition**: The single source of the step order, which workflow steps each deliverable type requires, which delivery path drops a step, and each step's commit-gate attribute.
- **Related**: [architecture/claude-code/workflow.md](../architecture/claude-code/workflow.md#the-step-table-deliverable-type-x-pm-type)

### TARGET_CHECKOUT_ROOT

- **Definition**: The checkout (main or linked worktree) of the repository a tool operates on, named by the caller; an ordinary variable, never an environment variable.
- **Related**: [architecture/claude-code/root-names.md](../architecture/claude-code/root-names.md)

### TARGET_MAIN_ROOT

- **Definition**: The main worktree of the repository a tool operates on, which need not be the agents repository; an ordinary variable, never an environment variable.
- **Related**: [architecture/claude-code/root-names.md](../architecture/claude-code/root-names.md)

### test case reader
- **Definition**: The per-language part that reads one test file and returns one record per case (name, target, line range, malformed reason); the sweep, the checks, and the retire judgment get these records through the common window, which adds each case's deps.
- **Related**: [architecture/claude-code/test-language-registry.md](../architecture/claude-code/test-language-registry.md)
