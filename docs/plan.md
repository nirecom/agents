# 再発防止策: Worktree 運用 rule + skill 化（INCIDENT #2 起因）

## Context

2026-04-28、Phase 5 Step 1 (Langfuse v3) のセットアップで、worktree から main への
移行時に `.env`（gitignored）が失われ、Langfuse 用 Docker ボリュームのパスワードが
復旧不能になった。

| # | 出来事 | Claude の責任 |
|---|---|---|
| 1 | `LANGFUSE_POSTGRES_PASSWORD` に base64 生成 PowerShell を提示 | base64 の `+/=` は Prisma の `DATABASE_URL` パーサで `invalid port number` |
| 2 | worktree → main マージ後、worktree 削除を提案 | gitignored ファイルの保全を **先行確認しなかった** |
| 3 | `.env` 消失後の対処として `docker volume rm` をチャットで提示 | データ破壊提案を **初手** で出した |
| 4 | ミス時に謝罪より説明を優先 | `feedback_apologize_first.md` 記銘済 |

本質: **worktree → main 移行プロトコルの欠落**。同時並行セッション時代に向け
worktree 運用は継続したいので、適切な分類と手順化が必要。

---

## 構成（rule + skill + 既存 rule 拡張）

### A. 新規 rule: `C:\git\agents\rules\worktree.md`

**スコープ**: 「いつ worktree を使うか」の判断基準のみ。
具体的手順は skill 側に encapsulate する（後述 B）。

#### A.1 Worktree が fit するタスク

| シーン | 理由 |
|---|---|
| 同時並行セッション（複数機能を並行開発） | 各 worktree が独立 checkout、互いに非干渉 |
| Main の running service を止めずに新機能を開発（Docker / DB / 長時間プロセス） | Main の作業ツリーを変更しない |
| 長期 feature ブランチ（多数コミット + マイルストーン） | Main の checkout 切替不要 |
| 大量の gitignored state を生成する作業（`.env` 切替、新 `data/`、別 venv 等） | Main の state を汚さない |
| 高リスク refactor で main を known-good rollback target に保ちたい時 | Main をいつでも参照可能 |

**fit しない**: 単一ファイル修正・タイポ・docs 変更・read-only 調査・30 分以下の作業
（隔離コスト > メリット）。これらは main で直接編集する。

#### A.2 入口・出口は skill 経由

Worktree 運用に着手する場合は **必ず** 以下の skill を使う:

- 開始: `/worktree-start`
- 終了（マージ・cleanup）: `/worktree-end`

直接 `git worktree add` / `git worktree remove` を提案/実行することは禁止。
理由: Phase 5 Langfuse の cascade（gitignored 消失）は手順を skill 化していなかったため。

---

### B. 新規 skill 2 件

実装は `C:\git\agents\skills\` 配下（既存の他 skill と同様の構造）。
DOs/DONTs は skill の手順そのものに encapsulate。

#### B.1 `worktree-start` skill

**目的**: Worktree 設定 + 必要な gitignored ファイルの初期コピーを安全に実施。

**実行手順**（skill が誘導）:
1. タスクが worktree fit か rules/worktree.md A.1 表で確認
2. パス・ブランチ名を確定（ユーザー確認）
3. `git worktree list --porcelain` で既存 worktree を確認（衝突防止）
4. `git worktree add <path> -b <branch>`
5. Main 側で gitignored / untracked を完全列挙（`-z` 前提で空白・日本語パス対応）:
   - `git -C <main> ls-files --others --ignored --exclude-standard -z`
   - `git -C <main> ls-files --others --exclude-standard -z`
6. 列挙結果を **コピー分類** に分けてユーザーに提示:
   - **copy 推奨**: `.env.local`, `.env.development`, dev 用 credential, 開発用設定
   - **copy 原則禁止**: `.env.production`, cloud credential, deploy key, prod token, 顧客データ access key
   - **代替推奨**: `.env.example` をベースに worktree 用の dev credential を新規作成する
     — skill は生成コマンド（hex 生成等）を提示するのみ。`.env` の実際の作成・記入はユーザーが行う
     （Claude は `.env` への直接書き込み不可）
7. ユーザー指示でコピー実行（候補は自動提示、承認は最小限）
8. Worktree 直下に `WORKTREE_NOTES.md`（gitignored）を作成し、コピーした gitignored state を記録
9. 完了レポート（どの worktree にどの gitignored が入ったか）

#### B.2 `worktree-end` skill

**目的**: Worktree 削除前の inventory と保全、サービス bind mount 切替、最終削除。

**実行手順**（skill が誘導）:
1. `git worktree list --porcelain` で対象 worktree の存在確認
2. Worktree のコミット・push 状態確認
3. Main へのマージ/PR 状態確認
4. **Inventory（自動処理向け、`-z` 前提で完全列挙）**:
   - ignored: `git -C <worktree> ls-files --others --ignored --exclude-standard -z`
   - untracked non-ignored: `git -C <worktree> ls-files --others --exclude-standard -z`
   - tracked dirty: `git -C <worktree> status --porcelain=v1 -z`
5. **Backup manifest 生成** — 削除対象の path / size / mtime / sha256 を一覧化
   （secret 本文は manifest に含めない、メタデータのみ）
6. **Docker bind mount 影響検出**（running + stopped 両方を走査）:
   - `docker ps -a` 全コンテナで `.Mounts.Source` を確認
   - `docker compose config`（worktree 内に compose file がある場合）で bind / `env_file` 実効設定を確認
   - WSL/Windows path 正規化（MSYS形式 ↔ Windows形式 ↔ WSL形式）後に worktree path 接頭辞一致で判定
   - 検出時は「停止中コンテナ含む」「未検出時も image 化されていない開発スクリプトは別途要確認」とレポート
7. **DRY RUN summary をユーザーに提示**:
   - 削除予定 path / 未追跡件数 / ignored 件数 / 保全対象 / Docker mount 影響 / 実行予定コマンド
   - 保全先候補: main checkout / 別バックアップディレクトリ / 削除可（保全先は **ユーザー指定**）
8. ユーザー承認後、保全コピー実行
9. Bind mount しているプロセスを停止 → main パスから再起動（mount source 切替）
10. `git worktree remove <path>` 実行（`--force` は **原則禁止**、必要時はステップ 4-8 完了 + 明示再承認後のみ）
11. 完了レポート（backup manifest の保存先含む）

---

### C. 既存 rule 拡張 — Secrets

#### C.1 `C:\git\agents\rules\coding.md` に「Secret Generation」節追加

（新規 rule ファイル `secrets.md` は作らない。`coding.md` の既存ルールに合流）

**本質**: URL の password component に未エンコードの特殊文字（`+/=` 等）を入れると
URL parser が破壊される（Prisma で `invalid port number` 実例）。よって URL-safe な
secret 形式を選ぶか、percent-encode する必要がある。

**接続 URL に埋め込む password**（DATABASE_URL, REDIS_URL, AMQP URL 等）:

許容される選択肢（URL-safe であること）:
- `hex`: `openssl rand -hex 32` / PowerShell: `-join ((1..32)|%{'{0:x2}' -f (Get-Random -Max 256)})`
- `base64url no padding`: `openssl rand -base64 32 | tr '+/' '-_' | tr -d '='`
- 任意文字列を使う場合: password 部分を **percent-encode** すること

**禁止**: 標準 base64（`+/=` 含む）を URL の password component に未エンコードで埋め込むこと。

**変数分離が可能なら併用推奨**: `DATABASE_URL` 単独ではなく、
`POSTGRES_PASSWORD` / `POSTGRES_USER` / `POSTGRES_HOST` 等の分離変数も用意できるなら併用すると、
URL escaping の問題自体を回避できる。

**URL に入らない opaque secret**（NextAuth secret, salt, JWT secret 等）:
- base64 / hex どちらも可
- `openssl rand -base64 32` 可

**Secret 表示と保管 — Claude はチャットに表示した時点で漏洩リスクが残る**:
- チャット表示時点で会話ログ・スクリーンショット・端末履歴・スクロールバック等に残存し得る
- よって **「Claude が生成して提示」中心の運用は最小化** し、可能な限り以下を優先:
  1. **ユーザー環境で生成**（Claude は生成コマンドを提示するに留める）
  2. **secret manager 経由**（1Password CLI, Docker secrets, age-sops, doppler 等）
  3. やむを得ず Claude が生成提示する場合は **開発用 secret に限定**、prod secret は禁止
- 提示時は **永続保管先（パスワードマネージャ等）に必ず控えること** をユーザーに促す
- `.env` への書き込みのみで安心せず、worktree 削除等で消失するリスクをユーザーに伝える

#### C.2 Gitignored secret 保全について

具体的な保全先パスは **rule に書かない**（Claude が勝手に決めてユーザーが知らない場所に
保存するのは不適切）。代わりに `worktree-end` skill 内でユーザーに保全先を確認する。

---

### D. データ破壊提案の判断ルール

**新規ファイル `destructive-ops.md` は作らない**（命名が連想しにくい + 既存ルールと重複）。
代わりに以下に分散:

#### D.1 原則の所在 — `coding.md` を一次ソースに

ユーザーから直接読める rule ファイルに原則を置く。Claude Code システムプロンプトの
"Executing actions with care" セクションにも同趣旨の記述（"Destructive operations…",
"do not use destructive actions as a shortcut… identify root causes" 等）があるが、
これは Claude に注入される指示であり、ユーザーの設定ファイルや UI からは直接見えない。
透明性に欠けるため、**`rules/coding.md` の新節「Risky Operations Decision Path」(D.2)
を一次ソース** として位置づけ、システムプロンプト側の記述は補強として扱う。

#### D.2 `rules/coding.md` に「Risky Operations Decision Path」節を追加

既存 "Public GitHub Rules" や "Migration Code Blocks" と並ぶ節として追加（本節が D.1 の一次ソース）:

> **High-risk cleanup operations** — 以下は同じ decision path で扱う:
>
> - `docker volume rm` / `docker compose down -v`
> - `DROP TABLE` / destructive schema migration / volume 再作成
> - `Remove-Item -Recurse -Force`（PowerShell）
> - `rm -rf`（POSIX）
> - `git clean -fdx`（untracked + ignored を全削除）
> - `git worktree remove --force`（unclean worktree でも強制削除）
>
> 上記を提案する前に:
>
> 1. 復旧オプションを **必ず先に列挙** してユーザーに選択させる
>    - 例（DB の場合）: `POSTGRES_HOST_AUTH_METHOD=trust` 経由のパスワードリセット、
>      `docker exec` での DB 直接操作、別ノードへの dump → restore、スナップショットからの復元
>    - 例（worktree の場合）: ステップ B.2 の inventory + backup manifest を先行実施
> 2. 全て不可と判明した場合のみ「最終手段」として削除を提案
> 3. 削除提案時は理由（なぜ復旧不能か）と影響範囲を明示

具体的な復旧コマンドは project ごとの `ops.md` に runbook として書く（rule には書かない、
project context に依存するため）。

---

### E. PreToolUse hook → **採用しない方針**

#### E.1 deny で実現可能な範囲の再評価

**deny でできること**:
- 削除パターン全般を Bash tool 経由でブロック（コマンド文字列パターンマッチ）
- 例: `Bash(*Remove-Item*-Recurse*-Force*)` で PowerShell 再帰削除を全ブロック

**deny でできないこと**:
- 「対象パス配下に `.env` が存在する場合のみブロック」のような **動的判定**
- カスタムエラーメッセージ（理由 + 対処手順の提示）

#### E.2 結論: 粗い deny で十分

- Claude が直接 Bash tool で `Remove-Item -Recurse -Force` を実行する場面は **そもそも稀**
- 稀な使用頻度に対して動的判定の hook（80 行 + メンテ + 誤検知リスク）は過剰
- 必要時は `git worktree remove` を使う（追跡外ファイルがあると標準で拒否）か、ユーザーに依頼すれば足りる

**採用する deny エントリ** (user settings.json):

```jsonc
"Bash(*Remove-Item*-Recurse*-Force*)",
"Bash(*Remove-Item*-Force*-Recurse*)"
```

**Deny の限界（既知）**:
- alias、変数展開、`powershell -Command "..."` 経由、スクリプトファイル経由、`Invoke-Expression` などは拾えない
- パターンマッチは静的なので動的コンテキスト判定不可
- これらの限界は許容する（粗い deny の趣旨そのもの）

**設定階層の留意**:
- user settings (`~/.claude/settings.json`) に入れる deny は project / managed settings との
  優先関係を理解しておく。組織的に固定したい場合は managed settings の方が強い。
  本プランでは個人環境想定のため user settings に追加する。

**Honesty 注記 — 業界標準ではない独自追加**:
公開されている主要 framework（Cursor / Cline / Aider / Continue / Roo 等）の deny 設定
consensus は POSIX 系 (`rm -rf /`, `sudo`, `git push --force`, `curl | bash` 等) が
中心で、PowerShell の `Remove-Item -Recurse -Force` を deny する公開設定例は
現時点で確認できていない。本採用は INCIDENT #2 (Windows 環境で発生) を踏まえた
**独自判断** であり、業界 best practice の踏襲ではない点を明記する。

`docker volume rm` は業界 consensus 外 + 本 cascade 防止に直接寄与せずのため採用しない。
`git worktree remove` は標準で安全網がある + skill 経由で使うため deny 不要。
`rm -rf` は既存 deny で既にカバー済（`Bash(*rm -rf *)`、`Bash(*rm -fr *)`）。

#### E.3 Hook を作らない判断の理由

| 項目 | Hook | 粗い deny |
|---|---|---|
| 実装コスト | 中（80 行 + テスト） | 小（settings.json 2 行） |
| 運用コスト | 中（誤検知時の調査） | 小 |
| 真陽性カバー | 高（`.env` 検出時のみ） | 中（全 Recurse Force ブロック） |
| 偽陽性 | 低 | 中（必要な削除も拒否） |
| Claude の Bash 直接実行頻度 | **稀** | **稀** |

Claude の Bash 直接実行頻度が稀である以上、偽陽性が出てもダメージ小、
かつチャットテキスト経由（cascade の主経路）には deny も hook も発火しない以上、
hook の追加価値は限定的。**粗い deny + rule + skill** で十分。

---

### F. Incident 記録

`c:\LLM\my-specs-repo\projects\engineering\langchain\history.md` に
`#2: Worktree 削除で .env 消失、Langfuse ボリューム復旧不能 (2026-04-28)` を `doc-append` で追加。

```bash
doc-append c:/LLM/my-specs-repo/projects/engineering/langchain/history.md \
  --category INCIDENT \
  --subject "Worktree 削除で .env 消失、Langfuse ボリューム復旧不能" \
  --date 2026-04-28 \
  --cause "Worktree (langchain-stack-langfuse) を main にマージ後、削除前に gitignored ファイル (.env) の保全確認を怠った。git merge は追跡ファイルのみを移すため、.env は worktree にのみ存在し、削除と同時に消滅。Langfuse 4 サービスのパスワードが復旧不能となった。" \
  --fix "(1) Phase 5 Step 1 の Langfuse 環境を再構築（パスワード再生成、ボリューム再作成、Public/Secret Key 再発行）。試行した復旧手段: docker volume の inspect、bind mount path 切替、コンテナ再起動 — いずれも .env 消失で password 不明のため失敗、最終的にボリューム再作成を選択。(2) 再発防止: rules/worktree.md 新設、worktree-start/worktree-end skill 新設、coding.md に Secret Generation/Risky Operations 節追加、settings.json に Remove-Item -Recurse -Force の deny 追加。詳細は agents/docs/plan.md。"
```

---

## 実装範囲（最終）

| ファイル | 変更 | 種別 |
|---|---|---|
| `C:\git\agents\rules\worktree.md` | 新規（A.1 + A.2 の方針表明）。手順は書かない | rule |
| `C:\git\agents\rules\coding.md` | 既存ファイルに「Secret Generation」「Risky Operations Decision Path」2 節を追加 | rule 拡張 |
| `C:\git\agents\skills\worktree-start\` | 新規 skill（B.1） | skill |
| `C:\git\agents\skills\worktree-end\` | 新規 skill（B.2） | skill |
| `agents/settings.json` | `permissions.deny` に `Remove-Item -Recurse -Force` パターン 2 件追加 | config |
| `c:\LLM\my-specs-repo\projects\engineering\langchain\history.md` | INCIDENT #2 追加（`doc-append`） | doc |

**作らないもの**:
- `rules/secrets.md`（coding.md に合流）
- `rules/destructive-ops.md`（既存 system prompt + coding.md で代替）
- `hooks/guard-env-preservation.js`（粗い deny で代替）
- 新規 memory（rule で代替）

## 検証

| 項目 | 手順 | 期待結果 |
|---|---|---|
| `rules/worktree.md` 作成 | `Read C:/git/agents/rules/worktree.md` | A.1 fit するタスク表 + A.2 skill 経由の方針 |
| `rules/coding.md` 拡張 | 同 Read | "Secret Generation" "Risky Operations Decision Path" 節が追加済 |
| `worktree-start` skill | `Read C:/git/agents/skills/worktree-start/SKILL.md` | B.1 手順が記載 |
| `worktree-end` skill | 同 | B.2 手順が記載 |
| deny 動作 | テスト用 dir に対し `Remove-Item -Recurse -Force` を Bash tool で試行 | permission denied |
| `rm -rf` 既存 deny 影響なし | 既存 `Bash(*rm -rf *)` deny の挙動確認 | 変化なし |
| INCIDENT #2 追記 | `tail -30 c:/LLM/my-specs-repo/projects/engineering/langchain/history.md` | `### #2: ...` が末尾に存在、`Cause:`/`Fix:` 行あり |
| Skill invocation | 次回 worktree 作業時に `/worktree-start` を実行 | A.2 の skill 経由方針が機能 |

## ユーザー判断結果（2026-04-28）

| 論点 | 判断 |
|---|---|
| Worktree 手順を rule に書くか skill に書くか | **skill** に encapsulate（rule は判断基準のみ） |
| Secrets の 2 重保管・保全先を rule に書くか | **書かない**（保管先はユーザー指定、skill 内で確認） |
| `destructive-ops.md` 新設 | **しない**（system prompt + coding.md で代替） |
| Hook vs deny | **粗い deny を採用、hook は不採用** |
| D.1 の依拠先 | システムプロンプトではなく coding.md を一次ソースに |
| Secret generation | hex 限定 → URL-safe（hex / base64url / percent-encode）が本質 |
| Codex review | gpt-5.5 レビュー 13 件指摘を全件反映済 |
