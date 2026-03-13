dotfiles リポジトリの最新変更を、ドキュメント (`docs/history.md`, `docs/architecture.md`, `README.md`) に反映する

## 対象ファイル

すべて dotfiles repo 内に存在する:

- `docs/history.md` — 変更履歴・障害履歴テーブル（主な更新対象）
- `docs/architecture.md` — アーキテクチャ・設計方針・ファイルツリー
- `README.md` — インストール手順・リポジトリ構造ツリー

## 手順

1. **最新コミット取得**: dotfiles repo の `git log --oneline -20` を実行し、最近のコミットを確認する

2. **現在の履歴確認**: `docs/history.md` の Change History, Incident History テーブルを読み込む

3. **差分分析**: git log のコミットと history.md のテーブルを比較し、未記録のコミット・フェーズを特定する

4. **更新提案**: 未記録の変更があれば、以下の形式でユーザに提案する:
   - Change History: フェーズ単位（関連コミットをグループ化）
     - 列: Phase | User Request | Implementation | Key Commits
   - Incident History: 障害が発生した場合のみ 1 件 1 行で追加
     - 列: # | Incident | Cause | Fix | Commit
   - `docs/architecture.md` や `README.md` の更新が必要な場合も併せて提案する
     （例: 新しいプラットフォーム対応、ファイルツリー変更、インストール手順変更）

5. **ユーザ確認後に編集**: 承認を得てからファイルを更新する

## 形式ルール

- ドキュメントは英語で記述する
- GitHub リンクは使用しない（テーブル内はコミットハッシュのみ）
- コミットハッシュは短縮形（7 文字）
- Phase 名は簡潔に（例: "QNAP support", "Claude Code management"）
- Incident 番号は連番を維持する
