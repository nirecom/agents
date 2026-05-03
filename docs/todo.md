# Todo

## Current Work

### /boost + judge-task-complexity — manual smoke test (post-push)

- [x] Invoke `/judge-task-complexity` directly: simple task → `VERDICT: sonnet | none`; multi-file + security task → `VERDICT: opus | S1-multi-file, S3-security`
- [x] Invoke `/boost test task`: confirm Opus subagent launches
- [ ] Run `make-detail-plan`: confirm step 2 calls judge before detail-planner starts

### intent-log.md の Write パーミッションダイアログ抑制 — 動作確認

- [ ] clarify-intent を実行し、intent-log.md 書き込み時にパーミッションダイアログが出ないことを確認する
- [ ] ダイアログが出る場合は `**/.claude/plans/*-intent-log.md` のグロブパターンを再検討する

### AWS IAM ポリシー設定（server-side enforcement）

- [ ] personal / work 各アカウントに読み取り専用 IAM ポリシーを作成（`docs/architecture/claude-code/settings.md` 参照）
- [ ] aws-scan-* スキル動作確認を IAM 制限下で実施
- [ ] AWS_WORK_DIR と AWS_STATE_DIR を各マシンのローカル設定に追記

### agents repo のライセンスを MIT → Apache-2.0 に変更する

- [ ] `LICENSE` ファイルを Apache-2.0 テキストに差し替える
- [ ] `README.md` のバッジ・本文中のライセンス表記を更新する
- [ ] CONTRIBUTING.md があれば Apache-2.0 への言及を追加する
- 背景: Apache-2.0 は MIT にない特許ライセンス付与条項と特許訴訟終了条項を持つ。
  依存先の Apache-2.0 ライブラリ（LightRAG 等）とのライセンス整合性も高まる。

