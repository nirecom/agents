# Todo

## Current Work

### intent-log.md の Write パーミッションダイアログ抑制 — 動作確認

- [ ] clarify-intent を実行し、intent-log.md 書き込み時にパーミッションダイアログが出ないことを確認する
- [ ] ダイアログが出る場合は `**/.claude/plans/*-intent-log.md` のグロブパターンを再検討する

### agents repo のライセンスを MIT → Apache-2.0 に変更する

- [ ] `LICENSE` ファイルを Apache-2.0 テキストに差し替える
- [ ] `README.md` のバッジ・本文中のライセンス表記を更新する
- [ ] CONTRIBUTING.md があれば Apache-2.0 への言及を追加する
- 背景: Apache-2.0 は MIT にない特許ライセンス付与条項と特許訴訟終了条項を持つ。
  依存先の Apache-2.0 ライブラリ（LightRAG 等）とのライセンス整合性も高まる。

