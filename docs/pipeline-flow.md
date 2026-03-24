# パイプライン実行フロー

GitHub Issue に `auto-implement` ラベルが付与されてから PR が作成されるまでの、全ステップの詳細仕様です。

各ステップで実行される **プロンプト**（Claude Code CLI に渡される指示）と、**プロンプト以外の処理**（Git 操作・通知・ジョブ管理など）を分けて記載しています。

## 目次

1. [全体フロー概要](#1-全体フロー概要)
2. [Step 0: リポジトリのクローン](#2-step-0-リポジトリのクローン)
3. [Step 0.5: スキル発見・CLAUDE.md 合成](#3-step-05-スキル発見claudemd-合成)
4. [Step 1: implement（実装）](#4-step-1-implement実装)
5. [Step 2: review（レビュー）](#5-step-2-reviewレビュー)
6. [Step 3: test（テスト）](#6-step-3-testテスト)
7. [Step 4: docs（ドキュメント更新）](#7-step-4-docsドキュメント更新)
8. [Step 5: Push & PR 作成](#8-step-5-push--pr-作成)
9. [失敗時の処理](#9-失敗時の処理)
10. [モデル解決の優先順位](#10-モデル解決の優先順位)
11. [プロンプト変数一覧](#11-プロンプト変数一覧)

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
       ├─ Step 0    : リポジトリのクローン & ブランチ作成
       ├─ Step 0.5  : スキル発見 & CLAUDE.md 合成
       ├─ Step 1    : implement（実装）        ← Claude Code CLI
       ├─ Step 2    : review（レビュー）       ← Claude Code CLI
       ├─ Step 3    : test（テスト）           ← Claude Code CLI
       ├─ Step 4    : docs（ドキュメント更新） ← Claude Code CLI
       └─ Step 5    : Push & PR 作成
       │
       ▼ notifier.sh
  Discord 通知（成功 / 失敗）
```

**関連ファイル:**

| ファイル | 役割 |
|----------|------|
| `daemon/runner.sh` | パイプライン実行エンジン本体 |
| `pipelines/default.yaml` | 4 ステップのプロンプト定義 |
| `daemon/poller.sh` | GitHub Issue のポーリング |
| `daemon/scheduler.sh` | ジョブのスケジューリング・排他制御 |
| `daemon/skill-discovery.sh` | 技術スタック検出・スキル選定 |
| `daemon/notifier.sh` | Discord Webhook 通知 |

---

## 2. Step 0: リポジトリのクローン

> プロンプトなし — Git 操作のみ

| 処理 | コマンド・内容 |
|------|----------------|
| クローン | `git clone https://github.com/{owner/repo}.git {workspace_dir}` |
| ベースブランチ切替 | `git checkout {base_branch}` |
| feature ブランチ作成 | `git checkout -b {branch_prefix}issue-{number}` |

**例:** `base_branch=main`, `branch_prefix=feat/` の場合 → `feat/issue-42`

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

## 4. Step 1: implement（実装）

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
- 必要最小限の変更で実装してください
- 新規ファイルは必要な場合のみ作成してください
- セキュリティ脆弱性を作り込まないでください
```

### プロンプト以外の処理

| 処理 | 内容 |
|------|------|
| Claude 実行 | `claude -p "$PROMPT" --model {model} --allowedTools "Edit,Write,Bash,Glob,Grep,Read" --max-turns 50` |
| コミット | 変更があれば `git add -A && git commit -m "feat(#{N}): implement - {title}"` |
| diff 更新 | 次ステップ用に `git diff {base_branch}...HEAD` を再取得 |

### 設定値

| 項目 | 値 |
|------|-----|
| `commit_prefix` | `feat` |
| `allowed_tools` | `Edit,Write,Bash,Glob,Grep,Read` |
| `max_turns` | `50` |
| 推奨モデル | （コメントなし。グローバル設定に従う） |

---

## 5. Step 2: review（レビュー）

### プロンプト

```
あなたはシニアコードレビュアーです。
以下の変更差分をレビューし、問題があれば修正してください。

## レビュー対象（mainブランチからの差分）
{git_diff_from_main}

## チェック項目
1. バグ・ロジックエラー
2. セキュリティ脆弱性（OWASP Top 10）
3. パフォーマンス問題
4. エッジケースの未処理
5. コーディング規約違反
6. 不要なコード・デバッグコードの残留

問題を見つけたら修正してください。
問題がなければ何もしないでください。
```

### プロンプト以外の処理

| 処理 | 内容 |
|------|------|
| Claude 実行 | `claude -p "$PROMPT" --model {model} --allowedTools "Edit,Write,Bash,Glob,Grep,Read" --max-turns 30` |
| skip 判定 | `skip_if_no_changes: true` — 変更がなければコミットをスキップ |
| コミット | 変更があれば `git commit -m "refactor(#{N}): review - {title}"` |

### 設定値

| 項目 | 値 |
|------|-----|
| `commit_prefix` | `refactor` |
| `allowed_tools` | `Edit,Write,Bash,Glob,Grep,Read` |
| `max_turns` | `30` |
| `skip_if_no_changes` | `true` |
| 推奨モデル | Opus（深い推論ができるモデル推奨、YAML コメントより） |

---

## 6. Step 3: test（テスト）

### プロンプト

```
あなたはテストエンジニアです。
以下の変更に対するテストを作成・実行してください。

## 変更差分（mainブランチからの差分）
{git_diff_from_main}

## 指示
- 既存のテストフレームワーク・テストパターンに従ってください
- テストフレームワークが存在しない場合は、言語に適したものをセットアップしてください
- 正常系・異常系・境界値をカバーしてください
- テストを実行して全てパスすることを確認してください
- テストが失敗したら修正してください
```

### リトライ時の追加プロンプト（2 回目以降）

```
前回の実行でテストが失敗しました。テストの失敗を修正してください。
```

> リトライ時は元のプロンプトの末尾にこのテキストが追加されます。

### プロンプト以外の処理

| 処理 | 内容 |
|------|------|
| Claude 実行 | `claude -p "$PROMPT" --model {model} --allowedTools "Edit,Write,Bash,Glob,Grep,Read" --max-turns 40` |
| リトライ | Claude 実行が失敗した場合、最大 3 回リトライ（計 4 回試行） |
| コミット | 変更があれば `git commit -m "test(#{N}): test - {title}"` |

### 設定値

| 項目 | 値 |
|------|-----|
| `commit_prefix` | `test` |
| `allowed_tools` | `Edit,Write,Bash,Glob,Grep,Read` |
| `max_turns` | `40` |
| `retry_on_test_failure` | `3` |
| 推奨モデル | Sonnet（テスト生成は Sonnet で十分、YAML コメントより） |

---

## 7. Step 4: docs（ドキュメント更新）

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

## 8. Step 5: Push & PR 作成

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
- refactor(#N): review - {title}
- test(#N): test - {title}
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

## 9. 失敗時の処理

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

## 10. モデル解決の優先順位

各ステップの Claude モデルは、以下の優先順位で決定されます（上が最優先）:

| 優先度 | 設定元 | 例 |
|--------|--------|-----|
| 1 | ステップ YAML の `model` | `pipelines/default.yaml` の `steps[].model` |
| 2 | 環境変数 `CLAUDE_MODEL_{STEP}` | `CLAUDE_MODEL_IMPLEMENT`, `CLAUDE_MODEL_REVIEW` 等 |
| 3 | リポジトリ固有設定 | `config.yaml` の `repositories[].claude_model` |
| 4 | 環境変数 `CLAUDE_MODEL` | `.env` の `CLAUDE_MODEL` |
| 5 | グローバル設定 | `config.yaml` の `global.claude.model` |
| 6 | ハードコードデフォルト | `claude-sonnet-4-6` |

---

## 11. プロンプト変数一覧

プロンプトテンプレート内で使用できるプレースホルダと、その展開タイミング:

| 変数 | 展開元 | 使用ステップ |
|------|--------|--------------|
| `{issue_number}` | ジョブ JSON の `issue_number` | implement |
| `{issue_title}` | ジョブ JSON の `issue_title` | implement |
| `{issue_body}` | ジョブ JSON の `issue_body` | implement |
| `{git_diff}` | `git diff HEAD~1` | （未使用だが利用可能） |
| `{git_diff_from_main}` | `git diff {base_branch}...HEAD` | review, test, docs |

> `{git_diff_from_main}` は各ステップ実行直前に再取得されるため、前ステップのコミット内容が反映されます。
