# Todo

## Policy

### force-push 方針

- `git push --force-with-lease` を **feature branch / worktree 側のリモート ref に対しては許可**。
  ただし実行前に毎回理由を明示すること（例: rebase で SHA が書き換わったため非 fast-forward）。
- **main / master への force push は緊急時のみ**。手順:
  ユーザが `ENFORCE_WORKTREE=off` を一時設定 → CC が force-push を実行 →
  完了後にユーザが `ENFORCE_WORKTREE=on` に戻す。
- 現状の settings.json は `git push --force*` を一律 auto-deny しているため、feature branch 側でも
  CC が直接実行できない。下記の検討タスクで運用化する。
  - [ ] `git push --force-with-lease origin feature/*` を settings.json allow rule に追加可否を検討
    （/main や /master を明示的に deny にしつつ feature/* のみ allow にできるか pattern 設計）
  - [ ] worktree 側への force-with-lease を CC が直接実行できる安全な仕組みを設計
    （案: enforce-worktree hook 経由でブランチ名チェック、または bin/safe-force-push ラッパ作成）

## Current Work

### CC workflow 確認フラグ追加 (CONFIRM_OUTLINE / DETAIL / WORKTREE / TESTS) — Verifying

4 つの `CONFIRM_*=on/off` フラグを導入し、off 時に各スキル (make-outline-plan / make-detail-plan / worktree-start / write-tests) の確認プロンプトを抑制して自動続行できるようにした。planner↔reviewer ループの中間ドラフト・per-round 自然言語サマリーも chat から削除 (debug.log にのみ出力)。

- [x] `bin/get-config-var` (POSIX + PowerShell) を新規追加。`--is-off` サブコマンドで OFF 判定を `hooks/enforce-worktree.js` と parity させた
- [x] `install/linux/dotfileslink.sh` と `install/win/dotfileslink.ps1` に shim 配置
- [x] `.env.example` に 4 フラグを追加 (`AUTO_MERGE_PR=on` 直後)
- [x] 4 SKILL.md にゲート追加 + 中間ドラフト emit を debug.log への append に置換
- [x] `agents/{outline,detail}-reviewer.md` の fallback notice 文言を更新
- [x] tests: `feature-confirm-flags-helper.sh` + `feature-confirm-flags-static.sh` 全 PASS
- [ ] **ユーザ検証**: 実際にどれかのフラグを off にしてフロー全体 (make-outline-plan → make-detail-plan → worktree-start → write-tests) を1回通す
- [ ] 検証 OK 後、history.md に移動 + CHANGELOG 追記 (FEATURE)

### settings.json: `Bash(git push -u origin *)` allow rule が `-C` 無し form で未登録

PR #2 以来、push の allow rule は `-C` あり版 (`Bash(git -C * push -u origin *)`) と
`-C` 無し・`-u` 無し版 (`Bash(git push origin *)`) のみで、`-C` 無し・`-u` あり版
(`Bash(git push -u origin *)`) が抜けている。

**今まで顕在化しなかった理由**: `rules/git.md` の「CWD 外の git repo は `-C` で操作せよ」
原則に従い、過去のセッションは main worktree CWD から `git -C <wt> push -u origin <br>` を
実行していたため `-C` あり版にマッチして自動許可されていた。

**今回露出した経緯**: `EnterWorktree` でセッション CWD が worktree 内に切り替わると、
`-C` 不要が `rules/git.md` 的にも自然になり、`git push -u origin <branch>` (no -C) が
発行される。対応 allow rule が未登録のため interactive permission dialog が出る。

- [ ] `settings.json` の allow に `Bash(git push -u origin *)` を追加
- [ ] 同様に `Bash(git push origin *)` (既存) と並んで `git fetch origin *` / `git pull origin *` の
      `-u` 系統との整合性も点検する (push に限らず EnterWorktree-friendly な allow set への棚卸し)
- [ ] `Bash(git push -u origin */*)`  の必要性確認 (`*` がスラッシュをマッチするかの実機検証)

### global-gitignore Pester テスト — CI 設定（将来タスク）

`install/win/global-gitignore.ps1` の Pester テスト (`tests/feature-parallel-sessions-worktree-installer-ignore.Tests.ps1`、T01-T15) は PR #14 で追加済み。bash 版 (`global-gitignore.sh`) は既存の `.sh` テストでカバー済み。残タスクは CI のみ。

- [ ] CI で Windows 上で実行されるよう設定（GitHub Actions windows-latest 等）

**Verifying** — ユーザー確認待ち

### commit gate の「commit 前ステップが commit 後の状態に依存する」設計矛盾

**根本原因**: workflow-gate は commit 前に全ステップ（review → user_verification）の完了を要求する。しかし一部のステップは commit 後の状態に依存するため、鶏と卵の問題が発生する。

**前提の整理**:
- `review-code-codex` (`git diff BASE...HEAD`): **commit 必要**、push 不要
- `gh pr create`: **commit + push 両方必要**（push なしでは branch がリモートに存在しない）

**既知の発生パターン**:

1. **review-code-codex が実行できない**: commit 済み差分のみ対象だが、commit には user_verification が必要で、user_verification は review 後に行うもの。
   - 発生条件: 実装完了まで一度もコミットしない場合
   - 当面の回避策: `git diff --cached` を直接 codex に流す

2. **fixup commit でも user_verification が再要求される**: 本実装 commit 後に小さな修正（SKILL.md 誤削除の復元等）を加えると、同一セッション内でも commit gate が user_verification を再度要求する。review-code-codex も同様に再実行が必要になる。
   - 発生条件: 同一セッション内で複数回 commit が必要になった場合

3. **PR 作成（`gh pr create`）には commit だけでなく push まで必要**: commit gate を突破して commit した後、さらに `git push` を実行して初めて PR が作れる。/worktree-end の手順では push タイミングが「PR 解決ステップ（Step 2）内で push する」と定義されているが、commit gate との順序関係（commit → user_verification → push → gh pr create）がワークフロー全体として明文化されていない。
   - 発生条件: /worktree-end 実行時に branch がリモートに未 push の場合

4. **worktree commit skip が `git -C <path>` なしだと効かない**: `resolveRepoDir` が `CLAUDE_PROJECT_DIR`（dotfiles 等）にフォールバックし `isWorktreeContext` が false を返すため user_verification が要求される。
   - 発生条件: worktree 内で素の `git commit`（`-C` なし）を実行した場合
   - 当面の回避策: `git -C <worktree-path> commit` を明示する

5. ~~**`git branch -d` が enforce-worktree にブロックされる**~~ — 解決済み（marker file 方式）：
   bash-write-patterns.js は `git branch -d/-D` を write 分類のままだが、`/worktree-end` が
   `<git-common-dir>/info/pending-branch-delete` に target branch + worktree path を書き出し、
   enforce-worktree.js が marker と一致した場合のみ削除を許可する。直接の ad-hoc 実行は引き続きブロック。
   ※ marker 方式は prompt 依存で偽造耐性が弱い → 強化案を別エントリ「enforce-worktree marker の二重検証強化」に記載。

**解決候補**:
- [x] `review-code-codex` に staged diff フォールバックを追加 — PR #7 で実装済み（commit なし時は `git diff --cached` を自動使用）
- [ ] 中間 commit / fixup commit は `user_verification` gate を免除するモードを追加（`--wip` フラグ等）
- [ ] ワークフロー手順に「実装ステップごとに WIP commit を積む」を明記（運用回避）
- [ ] `resolveRepoDir` に worktrees ディレクトリのスキャンを追加（staged 変更検出の精度向上）
- [x] `git branch -d/-D` のブロック解消 — PR #17 (`fix/enforce-worktree-merge-gate`) で `git branch -d` を read 扱いに変更 → PR #20 で `-D` も同様に → PR #21 で read 分類自体を撤回し、`/worktree-end` の marker file 認可方式に置換（最終形は本セクション パターン 5 の取り消し線エントリ参照）

### enforce-worktree marker の二重検証強化

現状の `git branch -d/-D` の marker file 認可（PR #21）は prompt 依存：
`/worktree-end` SKILL の指示に従って Claude が Write tool で
`<git-common-dir>/info/pending-branch-delete` を作成しているだけで、
別 session の Claude も同じパスに任意の (branch, path) ペアを書けば
gate を回避できる。accidental ミスは防げるが、意図的 bypass は防げない。

**強化案（accidental は完全防御、intentional は多重偽造を要求）**:
- (a) 既存：marker target == cmd target
- (b) 既存：marker worktree path が `WORKTREE_BASE_DIR` 配下
- (c) 新規：marker worktree path が `git worktree list --porcelain` に**現存**
- (d) 新規：`session-start.js` が SessionStart で
  `<state-dir>/<session-id>.worktree` に「この session が居る worktree path」を
  記録 → hook stdin の `session_id` で引いて marker worktree path と一致確認

**副作用**：worktree 撤去後の orphan local branch の事後 cleanup は
marker 経由不能 → ENFORCE_WORKTREE=off + 手動削除が唯一の道に。
intentional な register file 上書き bypass は依然可能だが、
multi-file 偽造を要求できる。

**実装範囲**:
- [ ] `hooks/session-start.js`：worktree binding 記録（main worktree 内なら何も書かない＝branch 削除権限なし）
- [ ] `hooks/enforce-worktree.js`：`isAllowedBranchDeleteViaMarker` 拡張で (c) (d) を追加
- [ ] `skills/worktree-end/SKILL.md`：register 検査の言及
- [ ] tests/feature-marker-session-binding.sh：unit + e2e


### worktree-end: pending-branch-delete マーカー Write 許可 — 別 session と合わせて検討

`/worktree-end` が `<git-common-dir>/info/pending-branch-delete` を書くたびに Write 確認プロンプトが出る。
`settings.json` の `permissions.allow` に追加すれば解消するが、パターン選択に要検討事項がある。

**セキュリティレビュー結果（2026-05-10）**:
- `Write(**/.git/info/pending-branch-delete)`: リスクなし（用途固定・特定ファイル名）
- `Write(**/.git/info/**)`: 中〜高リスク
  - `exclude` 書き換え → git tracking から機密ファイルを隠せる（scan-outbound をすり抜けるベクター）
  - `attributes` 書き換え → 既存 filter ドライバと組み合わせると任意コード実行につながる

**推奨**: 特定ファイル名の narrow パターン `Write(**/.git/info/pending-branch-delete)` を採用。

**ブロッカー**: 別 session でワークフロー修正中。settings.json 変更はそちらのセッションと合わせて実施。
- [ ] 別 session のワークフロー修正が落ち着いたら `Write(**/.git/info/pending-branch-delete)` を `settings.json` の allow に追加
- [ ] stale マーカーを手動削除: `Remove-Item C:\git\agents\.git\info\pending-branch-delete`

### awesome-lists 投稿（agents repo split プロジェクトの残作業）
- [x] [hesreallyhim/awesome-claude-code](https://github.com/hesreallyhim/awesome-claude-code) へエントリ追加 PR — [issue #1750](https://github.com/hesreallyhim/awesome-claude-code/issues/1750)
- [x] [rohitg00/awesome-claude-code-toolkit](https://github.com/rohitg00/awesome-claude-code-toolkit) へエントリ追加 PR — [PR #363](https://github.com/rohitg00/awesome-claude-code-toolkit/pull/363)
- [ ] [travisvn/awesome-claude-skills](https://github.com/travisvn/awesome-claude-skills) へエントリ追加 PR — 10 stars 到達後
- [ ] [VoltAgent/awesome-agent-skills](https://github.com/VoltAgent/awesome-agent-skills) へエントリ追加 PR — 見送り

### scan-inbound 拡張候補 — 要検討
- [ ] **Read** 対象追加: git clone した悪意ファイルの injection 検出。誤検知（HTML/XML/コード）とのトレードオフを評価してから判断
- [ ] **Bash** 対象追加: git log / npm install 等の stdout injection 検出。誤検知（ビルド出力・テスト結果）が多いため慎重に評価

### セキュリティスキャンツール統合検討
- [ ] Gitleaks: git history 対応シークレットスキャン。scan-outbound.sh との役割分担を評価 (https://github.com/gitleaks/gitleaks)
- [ ] Semgrep: 構文認識型静的解析（shell, Python, JS）。review-code-security の手動パターンを自動化できるか評価 (https://github.com/semgrep/semgrep)
- [ ] detect-secrets: エントロピーベースの汎用シークレット検出。openssl rand -hex 32 系ジェネリック乱数をカバーできるか評価 (https://github.com/Yelp/detect-secrets)

### SSOT 参照ルールの設計 — 検討中
ポート・URL・ホスト名を推測せず SSOT を確認させる仕組みの設計:
- [ ] claude-global/rules/ に汎用行動ルール追加（「SSOT を確認してから提示」— ファイル名は含めない）
- [ ] my-specs-repo/CLAUDE.md の Infrastructure SSOT セクションに行動指示を追記
- [ ] docs-convention.md の Standard Files が nirecom PJ 前提である点の整理（他 doc 体系との分離）

### history.md 全エントリへの通し番号付与 — 将来タスク
- [ ] 現状: `### #N: ...` 形式は INCIDENT カテゴリのみ
- [ ] 動機: JIRA 移行・エントリ数増加時に、commit や別セッションから「前回の Task #N の続き」と参照できるようにしたい
- [ ] 検討: `doc-append` による自動採番、既存エントリの一括番号振りスクリプト
- docs-only short-circuit 導入により当面の必須条件ではない

### Gemini CLI — クロスプロバイダレビュー統合

Codex CLI と同様に、`review-code-gemini` / `review-plan-gemini` を実装してワークフロー step 6 に並列で乗せる。
- [ ] `bin/review-code-gemini` スクリプト作成（`review-code-codex` を参照）
- [ ] `bin/review-plan-gemini` スクリプト作成（`review-plan-codex` を参照）
- [ ] `skills/review-code-gemini` / `skills/review-plan-gemini` SKILL.md 作成
- [ ] `CLAUDE.md` の step 6 に Gemini レビューを追加
- [ ] README.md 更新（Gemini CLI supported に変更）
- 前提: `gemini` CLI インストール済み・API キー設定済み（Google AI Studio）

### AWS IAM ポリシー設定（server-side enforcement）

- [ ] personal / work 各アカウントに読み取り専用 IAM ポリシーを作成（`docs/architecture/claude-code/settings.md` 参照）
- [ ] aws-scan-* スキル動作確認を IAM 制限下で実施
- [ ] AWS_WORK_DIR と AWS_STATE_DIR を各マシンのローカル設定に追記

### enforce-worktree.js の AGENT_AUTO_BRANCH migration ブロック削除

`hooks/enforce-worktree.js` の `--- BEGIN/END temporary: AGENT_AUTO_BRANCH → ENFORCE_WORKTREE migration ---` ブロック（コメント + backward compat コード）は全マシンの移行完了後に削除する。
- [ ] 全マシンの agents config が `ENFORCE_WORKTREE` / `DEFAULT_BRANCHES` を使うよう更新されたことを確認
- [ ] `isEnforceWorktreeOn()` の `AGENT_AUTO_BRANCH` fallback 削除
- [ ] `getProtectedBranches()` の `AGENT_DEFAULT_BRANCHES` fallback 削除
- [ ] 対応する migration コメントブロック削除

### Workflow Step 6 のテスト実行を専任 subagent に分離 — 検討

**動機（context window の分離）**：今回の AGENT_AUTO_BRANCH 実装で、**code を直す側と動作確認する側を別 CC session に分けた**結果、F1〜F4 の production bug を効率良く発見・修正できた。最大の理由は context window の分離：「code を書く文脈」と「動作確認する文脈」を同一 context window に詰め込むと、片方が溢れて他方を阻害する。検証側は試行錯誤の log・再現手順・前回の失敗パターンを context に保持し続ける必要があり、main session が抱えると実装側の思考領域を圧迫する。subagent として閉じ込めれば、main conversation は実装と bug fix の思考に集中でき、subagent は検証の試行錯誤を context-isolate できる。

**現状**：
- Step 6（Run tests & Security review）で `review-code-security` と `review-code-codex` は subagent / parallel で動いている
- しかし **テスト実行（`bash tests/...`）は main conversation 自身が走らせている**
- 自動テスト 37/37 pass でも production-shape の bug が漏れたケース（今回の R1〜F4）では、別人格の検証者が必要

**提案**：
- [ ] Step 6 に `/run-tests` skill（仮称）を導入し、subagent で：
  - 自動テスト実行（既存の bash tests/...）
  - production-shape の動作確認手順 `.md` を生成（手動検証用 → 別 session で実行）または subagent 内で simulate
  - 結果を構造化レポートで返却（pass/fail サマリ + 再現手順 + stderr 抜粋）
- [ ] main conversation は report を受け取って bug fix に専念（context window を実装側に温存）
- [ ] CLAUDE.md Step 6 を「`/run-tests` をデフォルト経路に」と更新
- [ ] 既存の `workflow-run-tests.js` PostToolUse hook（exit code から auto-mark）との関係整理

**前提（CC subagent 機構）**：
- Claude Code の subagent は **context-isolate を提供する**（main の context window を消費しない）
- subagent 内から bash 実行 + 結果 grep / parse は可能
- ただし production 環境で人手が必要な動作確認（実 push、UI 操作、別 PC 切替、CC 再起動など）は subagent では完結しない → そういうケースは「別 CC session 用の検証 doc」を生成して main に返す責務にとどめる
- 今回の F1〜F4 のうち、subagent で完結可能だったのは F2〜F4（環境設定 + 自動 invoke で再現可能）。F1（CC 自身が出力する additionalContext を見る）は実 CC session が必要

### dotenv ファイルの初回 git 追加

`ENFORCE_WORKTREE_EXCLUDE` はメイン checkout ゲートをバイパスするが、pre-commit の dotenv ブロック（`--diff-filter=A`）は独立して動作するため、新規追加コミットは別途ブロックされる。

- [ ] 対応策を選択・実装: (1) リモートが private repo と確認できる場合は dotenv ブロックをスキップ、(2) ワンタイムで worktree から初回コミット、(3) per-repo allowlist 機構の追加


### worktree-start でのファイルコピー制限緩和（B-Hybrid Phase 1 実装中 → Verifying）

`worktree-start` 時に `.env` / `.private-info-allowlist` 等を main worktree から worktree へ cp しようとすると、enforce-worktree.js の Bash write ブロックに引っかかる。Write tool でも block-dotenv フックに阻まれる。

**採択方針**: B-Hybrid（Phase 1）→ B-Pure（Phase 2）。詳細プラン: `~/.claude/plans/20260510-103459-detail.md`

**Phase 1 実装スコープ（B-Hybrid）**:
- `bin/worktree-copy-include.js`（stdin JSON → stdout JSON、Node）
- `hooks/lib/worktree-include-match.js`（ignore@^5.3.2 ラッパ）
- `hooks/lib/worktree-copy.js`（gitignore 列挙・照合・denylist・copy）
- `package.json`（ignore@^5.3.2 依存、新規作成）
- `.worktreeinclude`（.env / .env.local / .env.development / .env.test / .private-info-allowlist）
- `.worktreecopyexclude`（denylist: .env.production / *.pem 等）
- `skills/worktree-start/SKILL.md` — 手順 9 のみ `echo {...} | node bin/worktree-copy-include.js` に置換
- `settings.json` 変更なし（B-Hybrid では WorktreeCreate hook 不使用）

- [x] B-Hybrid Phase 1 実装完了 — Verifying（ユーザー確認待ち）

### worktree-start B-Pure Phase 2（将来タスク）

B-Hybrid（Phase 1）完了後に着手する。`hooks/lib/worktree-copy.js` 等の共通ライブラリは変更不要。

**Phase 2 実装スコープ（B-Pure）**:
3 工程のみ:
1. `hooks/worktree-create.js` — `WorktreeCreate` フック本体
   - stdin: `{"name": "<type>-<task-name>"}` の JSON（例: `{"name":"feature-my-task"}`）
   - stdout: worktree 絶対パスを 1 行
   - 名前デコード正規表現: `^(feature|fix|refactor|docs|chore)-(.+)$`
   - `repoName` = `path.basename(git rev-parse --show-toplevel)`
   - `worktreePath` = `buildWorktreePath(taskName, repoName)` from `hooks/lib/worktree-config.js`
   - `git worktree add <path> -b <type>/<taskName>` を spawnSync（shell:false）
   - `hooks/lib/worktree-copy.js` を呼ぶ（Phase 1 共通ライブラリ）
   - 注意: `WorktreeCreate` フックは `EnterWorktree` ツール経由でのみ発火（Bash の `git worktree add` では発火しない）
2. `settings.json` — `WorktreeCreate` フック登録のみ追加
3. `skills/worktree-start/SKILL.md` — 手順 7〜10 を `EnterWorktree(name="<type>-<task-name>")` 呼び出しに全面書き換え

- [ ] Phase 2 実装（B-Hybrid 完了・動作確認後に別セッションで実施）

### worktree-end: Step 6h に git pull が抜けている

Step 6h は `git fetch --prune origin` のみ。squash-merge 後にローカル main が origin/main に fast-forward されないため、新ファイルが VS Code 等に表示されない。

- [ ] Step 6h を `git fetch --prune origin` → `git pull --ff-only origin main` に変更（または fetch 後に `git merge --ff-only origin/main` を追加）

### worktree-end: marker ファイルの自動削除不可

`/worktree-end` Step 6g で `<git-common-dir>/info/pending-branch-delete` を削除しようとすると、`rm` / `Remove-Item` が bash-write-patterns.js に write 分類され、enforce-worktree.js にブロックされる（main worktree CWD から）。

**実害**: ブランチ削除済みなので stale marker が機能的に悪用されることはないが、cleanup が不完全になる。

- [ ] 対応策を選択・実装: (1) marker ファイル削除を `isAllowedWorktreeCommand` の例外として追加（marker path が `.git/info/pending-branch-delete` に一致し、かつ記録された branch が存在しない場合のみ許可）、(2) marker を worktree の `.git` ファイル隣（例 `<worktree>/.git-pending-branch-delete`）に置いて worktree removal で自動消去、(3) ENFORCE_WORKTREE_EXCLUDE に `.git/info/pending-branch-delete` glob を追加



### worktree-end: allow Write for pending-branch-delete marker

`/worktree-end` writes a marker file at `.git/info/pending-branch-delete` to authorise the branch deletion. The path is not in the allow list, so each run produces a permission prompt.

- [ ] Add `"Write(**/.git/info/pending-branch-delete)"` to `settings.json` allow list
- [ ] Document the stale marker manual cleanup (next /worktree-end overwrites it, so non-blocking): `del C:\gitgents\.git\info\pending-branch-delete`

### doc-append-plain: missing bash launcher (POSIX-side gap)

`~/.local/bin/` has `doc-append-plain.cmd` (Windows) but no POSIX shell launcher. Bash callers must invoke via `uv run C:/git/agents/bin/doc-append-plain.py` instead of the bare `doc-append-plain` command. The sibling `doc-append` ships both launchers; the new `doc-append-plain` should match.

- [ ] Add `doc-append-plain` POSIX launcher generation to `install/linux/dotfileslink.sh`
- [ ] Verify POSIX launcher generation matches `doc-append` shape (uv run wrapper)

### Known FP: `$'...'` ANSI-C quoting eats letter after backslash in Windows paths

When passing Windows paths inside bash `$'...'` quoting, sequences like `\a` (intended as ``) get the alert escape applied and the literal letter after `\` is lost. Example today: `C:\git\agents\.git\info\pending-branch-delete` rendered as `C:\gitgents\.git\info\...` (the `a` after `\` was eaten). Avoid by using forward slashes or single-quoted strings instead. Possible doc-only fix: note this caveat in rules covering shell command construction.

- [ ] Decide: doc-only caveat or wrap doc-append-plain to normalize Windows paths
