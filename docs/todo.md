# Todo

## Current Work

### research ステップの commit ゲート除外 — 動作確認

- [ ] 小規模タスクで `<<WORKFLOW_RESEARCH_NOT_NEEDED:` の確認ダイアログが出なくなったことを確認する
- [ ] `clarify_intent` 完了後に `[workflow] Invoke survey-code or deep-research ...` の NEXT ヒントが引き続き表示されることを確認する
- [ ] research が pending のまま commit まで進んでも workflow-gate にブロックされないことを確認する


### intent-log.md の Write パーミッションダイアログ抑制 — 動作確認

- [ ] clarify-intent を実行し、intent-log.md 書き込み時にパーミッションダイアログが出ないことを確認する
- [ ] ダイアログが出る場合は `**/.claude/plans/*-intent-log.md` のグロブパターンを再検討する

### Stop hook による branch/worktree 後始末リマインダー

- [ ] 実際のワークフローで動作確認する（worktree または branch を使うタスクで end-to-end 検証）
- [ ] うまくいかず revert する場合は commit hash `590d8a1` を巻き戻せ
