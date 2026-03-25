# パイプライン実行フロー

GitHub Issue に `auto-implement` ラベルが付与されてから PR が作成されるまでの、全ステップの詳細仕様です。

各ステップで実行される **プロンプト**（Claude Code CLI に渡される指示）と、**プロンプト以外の処理**（Git 操作・通知・ジョブ管理など）を分けて記載しています。

## 目次

1. [全体フロー概要](#1-全体フロー概要)
2. [Step 0: リポジトリのクローン](#2-step-0-リポジトリのクローン)
3. [Step 0.5: スキル発見・CLAUDE.md 合成](#3-step-05-スキル発見claudemd-合成)
4. [Step 1: implement（初回実装）](#4-step-1-implement初回実装)
5. [Step 2: [テスト → レビュー → 再実装] ループ](#5-step-2-テスト--レビュー--再実装-ループ)
6. [Step 3: docs（ドキュメント更新）](#6-step-3-docsドキュメント更新)
7. [Step 4: Push & PR 作成](#7-step-4-push--pr-作成)
8. [失敗時の処理](#8-失敗時の処理)
9. [モデル解決の優先順位](#9-モデル解決の優先順位)
10. [プロンプト変数一覧](#10-プロンプト変数一覧)
11. [ブランチ指定の仕様](#11-ブランチ指定の仕様)
12. [プロンプト・レスポンス履歴](#12-プロンプトレスポンス履歴)

---

## 1. 全体フロー概要

```
GitHub Issue (auto-implement ラベル)
       │
       ▼ poller.sh（定期ポーリング）
  Issue を検出 → ジョブキューに登録
       │
       ▼ scheduler.sh（同一リポジトリ直列 / 別リポジトリ並列）
  ジョブをスケジューリング
       │
       ▼ runner.sh（パイプライン実行エンジン）
       ├─ Step 0    : リポジトリのクローン & ブランチ決定
       ├─ Step 0.5  : スキル発見 & CLAUDE.md 合成
       ├─ Step 1    : implement（初回実装）         ← Claude Code CLI
       ├─ Step 2    : [テスト → レビュー → 再実装] ループ（レビュー差し戻し最大3回）
       │    ├─ テストコード実装 & テスト実施        ← Claude Code CLI
       │    │    └─ テスト失敗 → 実装修正 & 再テスト（最大5回リトライ）
       │    │    └─ 5回失敗 → パイプライン失敗終了
       │    ├─ レビュー（指摘のみ、読取専用）       ← Claude Code CLI
       │    └─ NEEDS_FIX → 再実装 → 次のイテレーションへ
       ├─ Step 3    : docs（ドキュメント更新）       ← Claude Code CLI
       └─ Step 4    : Push & PR 作成
       │
       ▼ notifier.sh
  Discord 通知（成功 / 失敗）
```

**関連ファイル:**

| ファイル | 役割 |
|----------|------|
| `daemon/runner.sh` | パイプライン実行エンジン本体 |
| `pipelines/default.yaml` | ステップのプロンプト定義 |
| `daemon/poller.sh` | GitHub Issue のポーリング |
| `daemon/scheduler.sh` | ジョブのスケジューリング・排他制御 |
| `daemon/skill-discovery.sh` | 技術スタック検出・スキル選定 |
| `daemon/notifier.sh` | Discord Webhook 通知 |

---

## 2. Step 0: リポジトリのクローン & ブランチ戦略

> プロンプトなし — Git 操作のみ

### 2.1 クローン

| 処理 | コマンド・内容 |
|------|----------------|
| クローン | `git clone https://github.com/{owner/repo}.git {workspace_dir}` |

### 2.2 ブランチ戦略

作業ブランチは以下の 2 パターンで決定されます:

#### パターン A: Issue 内でブランチが指定されている場合

Issue の本文に以下のいずれかの形式でブランチが記載されていると、そのブランチをそのまま使用します:

```
branch: feature/my-custom-branch
```
```
ブランチ: feature/my-custom-branch
```

- リモートに既に存在する場合 → `git checkout {specified_branch}`
- リモートに存在しない場合 → `git checkout {base_branch}` してから `git checkout -b {specified_branch}`

#### パターン B: ブランチ指定がない場合（デフォルト）

`develop` ブランチ（`base_branch`）から `feature/{作業内容}` ブランチを自動生成します。
ベースブランチは Web UI またはCLI でリポジトリ登録時に変更可能です（デフォルト: `develop`）。
ブランチプレフィックスは `feature/` 固定です。

| 処理 | 内容 |
|------|------|
| ベースブランチ切替 | `git checkout {base_branch}`（デフォルト: `develop`） |
| feature ブランチ作成 | `git checkout -b feature/{title_slug}` |

ブランチ名の生成ルール:
- Issue タイトルを小文字化し、英数字とハイフンに正規化（最大 50 文字）
- 日本語タイトル等でスラッグが空になる場合は `issue-{number}` をフォールバック

**例:**
- Issue タイトル `Add user authentication` → `feature/add-user-authentication`
- Issue タイトル `ユーザー認証の追加` → `feature/issue-42`
- Issue 本文に `branch: hotfix/urgent-fix` → `hotfix/urgent-fix`（そのまま使用）

---

## 3. Step 0.5: スキル発見・CLAUDE.md 合成

> プロンプトなし（runner.sh 内）— スキル発見とファイル合成処理

### 3.1 スキル発見（skill-discovery.sh）

| 処理 | 内容 |
|------|------|
| 技術スタック検出 | `package.json`, `go.mod`, `requirements.txt`, `Cargo.toml` 等からフレームワークを特定 |
| 検索クエリ生成 | Claude に技術スタック情報を渡し、スキル検索クエリを生成 |
| スキル検索 | `npx skills find {query}` で候補を取得 |
| スキル選定 | Claude が候補から上位 N 件（デフォルト 5）を選定 |
| キャッシュ | 結果を `skills/cache/{repo_name}.yaml` に保存（TTL: 7 日） |

### 3.2 CLAUDE.md 合成

以下の要素を結合して `.claude/CLAUDE.md` に配置します:

1. リポジトリ既存の `CLAUDE.md`（あればそのまま保持）
2. `config.yaml` の `repositories[].context`（プロジェクト固有コンテキスト）
3. pinned_skills + discovered_skills の `SKILL.md` 内容

---

## 4. Step 1: implement（初回実装）

### プロンプト

```
あなたはソフトウェアエンジニアです。
以下のGitHub Issueの要件を実装してください。

## Issue #{issue_number}: {issue_title}
{issue_body}

## 指示
- まずリポジトリの構造とコードを読んで理解してください
- 既存のコーディングスタイル・規約に従ってください
- CLAUDE.md があればそのルールに従ってください
- Antigravity の rule.md があればそのルールにも従ってください
- 必要最小限の変更で実装してください
- 新規ファイルは必要な場合のみ作成してください
- セキュリティ脆弱性を作り込まないでください
```

| 項目 | 値 |
|------|-----|
| `commit_prefix` | `feat` |
| `allowed_tools` | `Edit,Write,Bash,Glob,Grep,Read` |
| `max_turns` | `50` |
| 推奨モデル | グローバル設定に従う |

---

## 5. Step 2: [テスト → レビュー → 再実装] ループ

実装後、**テスト → レビュー → 再実装** をループします。
**レビュー差し戻しは最大 3 回**、**テスト失敗時の実装修正は最大 5 回**リトライします。
テスト修正が 5 回失敗した場合、パイプラインを失敗終了します（レビューは実行しません）。

```
イテレーション 1:
    テストコード実装 & テスト実施
        │
        ├─ テスト通過 → レビューへ進む
        └─ テスト失敗 → 実装修正 & 再テスト（最大5回リトライ）
        │       └─ 5回失敗 → パイプライン失敗終了
        ▼
    レビュー（問題点を指摘、コード修正なし）
        │
        ├─ LGTM → ループ終了、次のステップ（docs）へ
        └─ NEEDS_FIX → 再実装
             │
             ▼
イテレーション 2:
    再実装後のテストコード実装 & テスト実施
        │  ...（同上: テスト通過まで無制限リトライ）
        ▼
    レビュー
        │
        ├─ LGTM → ループ終了
        └─ NEEDS_FIX → 再実装
             │
             ▼
イテレーション 3（最終）:
    テストコード実装 & テスト実施 → レビュー
        │
        └─ LGTM でも NEEDS_FIX でもループ終了
           （最終イテレーションでは再実装しない）
```

### 5.1 テストコード実装 & テスト実施プロンプト

```
あなたはテストエンジニアです。
以下の変更に対するテストコードを作成し、テストを実行してください。

## 変更差分（mainブランチからの差分）
{git_diff_from_main}

## 指示
- 既存のテストフレームワーク・テストパターンに従ってください
- テストフレームワークが存在しない場合は、言語に適したものをセットアップしてください
- 正常系・異常系・境界値をカバーしてください
- テストを実行して全てパスすることを確認してください
- テストが失敗した場合はその内容を報告してください（テストコード自体は正しい前提で）
```

| 項目 | 値 |
|------|-----|
| `test_commit_prefix` | `test` |
| `test_allowed_tools` | `Edit,Write,Bash,Glob,Grep,Read` |
| `test_max_turns` | `40` |
| 推奨モデル | Sonnet（テスト生成は Sonnet で十分） |

### 5.2 テスト失敗時の実装修正プロンプト

テストが失敗した場合、実装コードを修正してテストをパスさせます（最大 5 回リトライ、超過でパイプライン失敗終了）。

```
あなたはソフトウェアエンジニアです。
テストが失敗しています。実装コードを修正してテストをパスさせてください。

## 元の Issue #{issue_number}: {issue_title}
{issue_body}

## 現在の変更差分（ベースブランチからの差分）
{git_diff_from_main}

## 前回のテスト結果
{test_output}

## 指示
- テストコードは正しい前提で、実装コードを修正してください
- テストコードの変更は最小限にしてください（テスト自体のバグの場合のみ）
- 修正後、テストを再実行して全てパスすることを確認してください
- CLAUDE.md があればそのルールに従ってください
- Antigravity の rule.md があればそのルールにも従ってください
```

| 項目 | 値 |
|------|-----|
| `test_fix_commit_prefix` | `fix` |
| `test_fix_allowed_tools` | `Edit,Write,Bash,Glob,Grep,Read` |
| `test_fix_max_turns` | `40` |
| `test_fix_max_retries` | `5`（超過でパイプライン失敗終了） |
| モデル | implement ステップと同じモデルを使用 |

### 5.3 レビュープロンプト（問題点の指摘のみ）

```
あなたはシニアコードレビュアーです。
以下の変更差分をレビューし、問題点を書き出してください。
コードの修正は行わないでください。レビューコメントのみを出力してください。

## レビュー対象（ベースブランチからの差分）
{git_diff_from_main}

## チェック項目
1. バグ・ロジックエラー
2. セキュリティ脆弱性（OWASP Top 10）
3. パフォーマンス問題
4. エッジケースの未処理
5. コーディング規約違反
6. 不要なコード・デバッグコードの残留

## 出力フォーマット
問題がない場合は、1行目に以下のみを出力してください:
LGTM

問題がある場合は、以下の形式で問題点を列挙してください:
NEEDS_FIX
- [重要度: high/medium/low] ファイル名:行番号 - 問題の説明と修正案
- [重要度: high/medium/low] ファイル名:行番号 - 問題の説明と修正案
...
```

| 項目 | 値 |
|------|-----|
| `review_mode` | `feedback_only` |
| `allowed_tools` | `Glob,Grep,Read`（**読み取り専用**） |
| `max_turns` | `30` |
| `max_iterations` | `3` |
| 推奨モデル | Opus（深い推論ができるモデル推奨） |

### 5.4 再実装プロンプト（レビュー指摘に基づく再実装）

レビューで `NEEDS_FIX` が返された場合、以下のプロンプトで実装モデルを再実行します:

```
あなたはソフトウェアエンジニアです。
以下のレビュー指摘事項に基づいて、コードを修正してください。

## 元の Issue #{issue_number}: {issue_title}
{issue_body}

## 現在の変更差分（ベースブランチからの差分）
{git_diff_from_main}

## レビュー指摘事項
{review_feedback}

## 指示
- レビューで指摘された問題点を全て修正してください
- 指摘されていない箇所は変更しないでください
- CLAUDE.md があればそのルールに従ってください
- Antigravity の rule.md があればそのルールにも従ってください
- セキュリティ脆弱性を作り込まないでください
```

| 項目 | 値 |
|------|-----|
| `allowed_tools` | `Edit,Write,Bash,Glob,Grep,Read`（implement と同じ） |
| `max_turns` | `50`（implement と同じ） |
| コミット | `feat(#{N}): implement (review fix {iteration}) - {title}` |

### 5.5 ループの動作まとめ

| イテレーション | 動作 |
|---------------|------|
| 1 回目 | テスト実施(失敗→実装修正、最大5回) → review → LGTM ならループ終了、NEEDS_FIX なら re-implement → コミット |
| 2 回目 | テスト実施(失敗→実装修正、最大5回) → review → LGTM ならループ終了、NEEDS_FIX なら re-implement → コミット |
| 3 回目（最終） | テスト実施(失敗→実装修正、最大5回) → review → LGTM でも NEEDS_FIX でもループ終了（最終イテレーションでは再実装しない） |

> テスト修正が 5 回失敗した場合、レビューは実行せずパイプラインを失敗終了します。
> レビュー差し戻し最大イテレーション到達時に指摘が残っている場合、警告ログを出力して次のステップへ進みます。

---

## 6. Step 3: docs（ドキュメント更新）

### プロンプト

```
以下の変更に伴い、ドキュメントの更新が必要か判断してください。

## 変更差分（mainブランチからの差分）
{git_diff_from_main}

## 判断基準
- 新しいAPIエンドポイントが追加された → API docsを更新
- 設定項目が追加された → READMEを更新
- 使い方が変わった → 関連ドキュメントを更新
- 上記に該当しない → 何もしない

必要な場合のみドキュメントを更新してください。
```

### プロンプト以外の処理

| 処理 | 内容 |
|------|------|
| Claude 実行 | `claude -p "$PROMPT" --model {model} --allowedTools "Edit,Write,Bash,Glob,Grep,Read" --max-turns 20` |
| skip 判定 | `skip_if_no_changes: true` — 変更がなければコミットをスキップ |
| コミット | 変更があれば `git commit -m "docs(#{N}): docs - {title}"` |

### 設定値

| 項目 | 値 |
|------|-----|
| `commit_prefix` | `docs` |
| `allowed_tools` | `Edit,Write,Bash,Glob,Grep,Read` |
| `max_turns` | `20` |
| `skip_if_no_changes` | `true` |
| 推奨モデル | Haiku（ドキュメント更新は軽量モデルで十分、YAML コメントより） |

---

## 7. Step 4: Push & PR 作成

> プロンプトなし — Git 操作と GitHub API のみ

### 処理一覧

| 処理 | 内容 |
|------|------|
| Push | `git push origin {branch_name}` |
| PR 作成 | `gh pr create` で PR を作成（本文は自動生成） |
| ラベル更新 | Issue の `auto-implement` ラベルを `auto-implemented` に差し替え |
| ジョブ完了記録 | ジョブ JSON の `status` を `completed` に更新、`pr_url` を記録 |
| Discord 通知 | 成功通知（コミット一覧 + PR URL） |
| クリーンアップ | ワークスペースディレクトリを削除 |

### PR 本文テンプレート

```markdown
## 概要
Issue #{issue_number} の自動実装

## 変更内容
- feat(#N): implement - {title}
- test(#N): test - {title}
- fix(#N): test-fix - {title}
- docs(#N): docs - {title}
（git log から最大20件のコミットメッセージを一覧）

## パイプライン
- **パイプライン**: {pipeline}
- **デフォルトモデル**: {model}
- **実行日時**: {datetime}

---
🤖 claude-pipeline で自動生成

Closes #{issue_number}
```

---

## 8. 失敗時の処理

任意のステップで失敗が発生すると、`trap cleanup EXIT` により以下が実行されます:

| 処理 | 内容 |
|------|------|
| ジョブ記録 | `status` を `failed` に更新 |
| ラベル付与 | Issue に `auto-implement-failed` ラベルを追加 |
| Issue コメント | 失敗ステップ名・パイプライン名・時刻をコメントとして投稿 |
| Discord 通知 | 失敗通知（失敗ステップ名を含む） |
| ロック解放 | リポジトリロックファイルを削除 |

### Issue に投稿されるコメント例

```markdown
## ⚠️ 自動実装パイプラインが失敗しました

**失敗ステップ**: review
**パイプライン**: default
**時刻**: 2026-03-25 14:30:00

ログを確認して再試行してください。
```

---

## 9. モデル解決の優先順位

各ステップの Claude モデルは、以下の優先順位で決定されます（上が最優先）:

| 優先度 | 設定元 | 例 |
|--------|--------|-----|
| 1 | ステップ YAML の `model` | `pipelines/default.yaml` の `steps[].model` |
| 2 | 環境変数 `CLAUDE_MODEL_{STEP}` | `CLAUDE_MODEL_IMPLEMENT`, `CLAUDE_MODEL_REVIEW`, `CLAUDE_MODEL_TEST` 等 |
| 3 | リポジトリ固有設定 | `config.yaml` の `repositories[].claude_model` |
| 4 | 環境変数 `CLAUDE_MODEL` | `.env` の `CLAUDE_MODEL` |
| 5 | グローバル設定 | `config.yaml` の `global.claude.model` |
| 6 | ハードコードデフォルト | `claude-sonnet-4-6` |

---

## 10. プロンプト変数一覧

プロンプトテンプレート内で使用できるプレースホルダと、その展開タイミング:

| 変数 | 展開元 | 使用ステップ |
|------|--------|--------------|
| `{issue_number}` | ジョブ JSON の `issue_number` | implement, reimpl, test-fix |
| `{issue_title}` | ジョブ JSON の `issue_title` | implement, reimpl, test-fix |
| `{issue_body}` | ジョブ JSON の `issue_body` | implement, reimpl, test-fix |
| `{git_diff}` | `git diff HEAD~1` | （未使用だが利用可能） |
| `{git_diff_from_main}` | `git diff {base_branch}...HEAD` | test, test-fix, review, reimpl, docs |
| `{review_feedback}` | review ステップの出力（レビュー指摘事項） | reimpl |
| `{test_output}` | test ステップの出力（テスト結果） | test-fix |

> `{git_diff_from_main}` は各ステップ・各イテレーション実行直前に再取得されるため、直前のコミット内容が反映されます。

---

## 11. ブランチ指定の仕様

### Issue 本文でのブランチ指定フォーマット

Issue 本文の行頭に以下のいずれかの形式で記載すると、パイプラインはそのブランチ上で作業します:

```
branch: <ブランチ名>
ブランチ: <ブランチ名>
```

- 大文字小文字は区別しません（`Branch:` も有効）
- 区切り文字は `:` と `：`（全角）の両方に対応
- 複数行ある場合は最初の一致が使用されます

### ジョブ JSON のフィールド

| フィールド | 内容 |
|-----------|------|
| `branch_prefix` | 固定: `feature/` |
| `base_branch` | デフォルト: `develop`（Web UI / CLI で変更可能） |
| `specified_branch` | Issue 本文から抽出されたブランチ名（なければ空文字） |

### Issue 記載例

```markdown
## 概要
ユーザー認証機能を追加してください。

branch: feature/user-auth

## 詳細
- JWT ベースの認証
- ログイン / ログアウト API
```

---

## 12. プロンプト・レスポンス履歴

パイプライン実行時の Claude への全プロンプトとレスポンスは、自動的にファイルとして保存されます。

### 12.1 保存先

```
workspace/.history/{repo_name}/
  {timestamp}_issue-{N}_{step}_{label}.json
```

**例:**
```
workspace/.history/my-app/
  20260325-143022_issue-42_implement.json
  20260325-143155_issue-42_test_iteration-1.json
  20260325-143250_issue-42_test-fix_iteration-1-retry-1.json
  20260325-143330_issue-42_review_iteration-1.json
  20260325-143422_issue-42_reimpl_iteration-1.json
  20260325-143500_issue-42_test_iteration-2.json
  20260325-143545_issue-42_review_iteration-2.json
  20260325-143612_issue-42_docs.json
```

### 12.2 ファイル形式

```json
{
  "timestamp": "2026-03-25T14:30:22Z",
  "repo": "owner/my-app",
  "repo_name": "my-app",
  "issue_number": 42,
  "issue_title": "ユーザー認証の追加",
  "step": "implement",
  "label": "",
  "model": "claude-sonnet-4-6",
  "exit_code": 0,
  "prompt": "あなたはソフトウェアエンジニアです。...",
  "response": "まずリポジトリの構造を確認します。..."
}
```

### 12.3 保存上限

- リポジトリごとに **最大 100 件**
- 101 件目の保存時に、最も古いファイルから自動削除

### 12.4 Web UI での閲覧

「履歴」タブからリポジトリを選択すると、実行履歴の一覧が表示されます。
各エントリの「詳細」ボタンで、プロンプト全文とレスポンス全文を閲覧できます。

### 12.5 API エンドポイント

| エンドポイント | 内容 |
|---------------|------|
| `GET /api/history` | 履歴が存在するリポジトリ名一覧 |
| `GET /api/history/:repo` | リポジトリの履歴サマリー一覧（新しい順） |
| `GET /api/history/:repo/:file` | 個別履歴の全データ（プロンプト・レスポンス含む） |
