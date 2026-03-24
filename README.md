# claude-pipeline

GitHub Issue 駆動の自動開発パイプライン。Claude Code CLI を活用して、Issue の要件から実装・コードレビュー・テスト・ドキュメント化までを自動で行い、PR を作成します。

## 特徴

- **Issue 駆動**: `auto-implement` ラベル付き Issue を自動検出して実装
- **スキル自動発見**: `npx skills find` でプロジェクトに最適なスキルを動的に発見・適用
- **段階的コミット**: 実装→レビュー→テスト→ドキュメントを個別コミットで管理
- **複数リポジトリ対応**: 複数の GitHub リポジトリを一元管理
- **並行実行**: 異なるリポジトリの Issue を並行処理（同一リポジトリは直列）
- **Discord 通知**: パイプライン完了/失敗時に Discord に通知

## アーキテクチャ

```
GitHub Issue (auto-implement ラベル)
       │
       ▼ (ポーリング: 5分ごと)
  ┌─────────┐
  │ poller   │ → 全登録リポジトリの Issue をチェック
  └────┬────┘
       ▼
  ┌─────────┐
  │scheduler │ → 並行制御・キュー管理
  └────┬────┘
       ▼
  ┌─────────┐    ┌──────────────┐
  │ runner   │───▶│skill-discovery│ スキル自動発見
  └────┬────┘    └──────────────┘
       │
       ├─ 1. feature branch 作成
       ├─ 2. implement (claude -p) → commit
       ├─ 3. review (claude -p) → commit
       ├─ 4. test (claude -p) → commit
       ├─ 5. docs (claude -p) → commit
       ├─ 6. push → PR 作成
       └─ 7. Discord 通知
```

## 前提条件

- Git
- [GitHub CLI (gh)](https://cli.github.com/)
- [Claude Code CLI](https://docs.anthropic.com/claude-code/)
- [jq](https://jqlang.github.io/jq/)
- [yq](https://github.com/mikefarah/yq)
- Node.js / npx
- curl

## セットアップ

### 方法1: 直接インストール

```bash
cd claude-pipeline
./scripts/setup.sh
```

セットアップが完了したら:

1. `.env` を編集して API キーを設定
2. `config.yaml` を必要に応じてカスタマイズ

### 方法2: Docker

```bash
cd claude-pipeline
cp .env.example .env
cp config.yaml.example config.yaml

# .env と config.yaml を編集

docker compose up -d
```

## 使い方

### リポジトリの登録

```bash
# リポジトリを登録
claude-pipeline repo add yourname/my-project

# オプション付きで登録
claude-pipeline repo add yourname/my-project \
  --pipeline default \
  --branch-prefix feat/ \
  --base-branch main \
  --context "Next.js 15 + Tailwind CSS のプロジェクト"

# 一覧
claude-pipeline repo list

# 一時停止 / 再開
claude-pipeline repo pause my-project
claude-pipeline repo resume my-project

# 削除
claude-pipeline repo remove my-project
```

### スキル管理

```bash
# リポジトリにスキルを固定
claude-pipeline skill pin my-project vercel-labs/skills/vercel-react-best-practices

# スキル一覧
claude-pipeline skill list my-project

# スキルを手動で発見（キャッシュをリセットして再検索）
claude-pipeline skill discover my-project
```

### パイプラインの実行

```bash
# 手動でポーリング
claude-pipeline poll

# 特定 Issue を即時実行
claude-pipeline run yourname/my-project 42

# 実行状況
claude-pipeline status

# ログ確認
claude-pipeline logs my-project 42
```

### メンテナンス

```bash
# 古いログとジョブを削除
claude-pipeline cleanup
```

## ワークフロー

1. Claude Code で仕様をディスカッション
2. GitHub Issue を作成し `auto-implement` ラベルを付ける
3. ポーラーが Issue を検出（5分ごと、または手動 `claude-pipeline poll`）
4. パイプラインが自動実行:
   - **implement**: Issue の要件をコードに実装
   - **review**: セルフコードレビュー & 修正
   - **test**: テスト作成 & 実行
   - **docs**: ドキュメント更新
5. PR が作成され、Discord に通知

## 設定リファレンス

### config.yaml

```yaml
global:
  poll_interval: 300              # ポーリング間隔（秒）
  trigger_label: "auto-implement" # トリガーラベル
  done_label: "auto-implemented"  # 完了時ラベル
  max_concurrent_jobs: 3          # 同時実行数
  log_retention_days: 30          # ログ保持日数

  discord:
    webhook_url_env: "DISCORD_WEBHOOK_URL"
    notify_on: ["success", "failure"]

  claude:
    api_key_env: "ANTHROPIC_API_KEY"
    model: "claude-sonnet-4-6"

  skill_discovery:
    enabled: true
    cache_ttl: 604800             # 7日
    max_skills_per_repo: 5
    trusted_sources: ["vercel-labs", "anthropics"]

repositories:
  - name: "my-project"
    repo: "yourname/my-project"
    pipeline: "default"
    branch_prefix: "feat/"
    base_branch: "main"
    status: "active"
    pinned_skills: []
    context: "プロジェクト固有の情報"
```

### カスタムパイプライン

`pipelines/` にYAMLファイルを作成し、`config.yaml` で指定:

```yaml
name: "custom"
steps:
  - name: "implement"
    prompt_template: "カスタムプロンプト..."
    commit_prefix: "feat"
    max_turns: 50
    # ...
```

### .env

```
ANTHROPIC_API_KEY=sk-ant-...
GITHUB_TOKEN=ghp_...
DISCORD_WEBHOOK_URL=https://discord.com/api/webhooks/...
```

## ディレクトリ構成

```
claude-pipeline/
├── config.yaml.example    設定テンプレート
├── .env.example           環境変数テンプレート
├── daemon/
│   ├── poller.sh          Issue ポーリング
│   ├── scheduler.sh       ジョブスケジューリング
│   ├── runner.sh          パイプライン実行
│   ├── notifier.sh        Discord 通知
│   └── skill-discovery.sh スキル自動発見
├── pipelines/
│   └── default.yaml       デフォルトパイプライン
├── scripts/
│   ├── setup.sh           初期セットアップ
│   └── cli.sh             CLI
├── skills/cache/          スキルキャッシュ
├── workspace/             作業ディレクトリ
├── logs/                  実行ログ
├── Dockerfile
├── docker-compose.yml
└── docker-entrypoint.sh
```

## 並行実行ルール

| 条件 | 動作 |
|------|------|
| 同一リポジトリの Issue | 直列実行（キューで待機） |
| 異なるリポジトリの Issue | 並列実行 |
| 同時実行数が上限に達した場合 | キューで待機 |

## トラブルシューティング

### Issue が検出されない

- `auto-implement` ラベルが正しく付いているか確認
- `claude-pipeline repo list` でリポジトリが active か確認
- `GITHUB_TOKEN` に `repo` と `issues` 権限があるか確認

### パイプラインが失敗する

- `claude-pipeline logs <repo> <issue>` でログを確認
- `ANTHROPIC_API_KEY` が有効か確認
- Issue の本文が十分に詳細か確認（Claude が要件を理解できるように）

### Discord 通知が届かない

- `DISCORD_WEBHOOK_URL` が正しいか確認
- `config.yaml` の `notify_on` 設定を確認
