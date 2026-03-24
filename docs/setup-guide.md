# claude-pipeline セットアップガイド

VPS（プライベートネットワーク）上に claude-pipeline をデプロイし、GitHub Issue ベースの自動開発パイプラインを稼働させるまでの手順です。

Docker コンテナで運用する構成を前提としています。`cp-pipeline` コンテナ内で Claude Code CLI が自動実行され、Issue の実装・テスト・レビュー・PR 作成までを一貫して行います。

## 目次

1. [前提条件](#1-前提条件)
2. [Ubuntu 24.04 初期環境構築](#2-ubuntu-2404-初期環境構築)
3. [API キー・トークンの準備](#3-api-キートークンの準備)
4. [リポジトリのクローンと設定](#4-リポジトリのクローンと設定)
5. [config.yaml の設定](#5-configyaml-の設定)
6. [コンテナのビルド・起動](#6-コンテナのビルド起動)
7. [リポジトリの登録](#7-リポジトリの登録)
8. [Discord 通知の設定](#8-discord-通知の設定)
9. [動作確認](#9-動作確認)
10. [トラブルシューティング](#10-トラブルシューティング)

---

## 1. 前提条件

### VPS の要件

| 項目 | 要件 |
|------|------|
| OS | Ubuntu 24.04 LTS 推奨 |
| メモリ | 2GB 以上推奨（Claude Code CLI の実行に必要） |
| ストレージ | 10GB 以上の空き容量 |
| ネットワーク | **外向き通信が可能**であること（GitHub API, Anthropic API, Discord への接続） |

> **注意**: VPS がプライベートネットワーク上にあり外部からアクセスできない環境を前提としています。GitHub Webhook は使用せず、ポーリング方式で Issue を検出します。

### 必要なソフトウェア

| ツール | 用途 |
|--------|------|
| Docker Engine 20.10+ | コンテナ実行基盤 |
| Docker Compose v2+ | マルチコンテナ管理 |
| Git | リポジトリのクローン |

> Docker コンテナ内に Claude Code CLI, GitHub CLI, Node.js, jq, yq 等がすべてインストールされるため、ホスト側にこれらは不要です。

### アーキテクチャ概要

```
┌─────────────────────────────────────────────┐
│  VPS (Ubuntu 24.04)                         │
│                                             │
│  ┌───────────────────────────────────────┐  │
│  │  cp-pipeline コンテナ                 │  │
│  │  ┌─────────────────────────────────┐  │  │
│  │  │  cron → poller.sh               │  │  │
│  │  │    ↓ Issue検出                   │  │  │
│  │  │  runner.sh                       │  │  │
│  │  │    ↓ Claude Code CLI 実行       │  │  │
│  │  │  実装 → テスト → レビュー → PR  │  │  │
│  │  └─────────────────────────────────┘  │  │
│  └───────────────────────────────────────┘  │
│                                             │
│  ┌───────────────────────────────────────┐  │
│  │  cp-web コンテナ                      │  │
│  │  Web管理UI (ポート 3000)              │  │
│  └───────────────────────────────────────┘  │
└─────────────────────────────────────────────┘
```

---

## 2. Ubuntu 24.04 初期環境構築

インストール直後の Ubuntu 24.04 に Docker と Git をセットアップする手順です。

### 2.1 システムの更新

```bash
sudo apt update && sudo apt upgrade -y
```

### 2.2 必要な基本パッケージのインストール

```bash
sudo apt install -y git curl ca-certificates gnupg
```

### 2.3 Docker のインストール

```bash
# Docker の公式 GPG キーを追加
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

# リポジトリを追加
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# Docker Engine, CLI, Compose プラグインのインストール
sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
```

### 2.4 現在のユーザーを docker グループに追加

```bash
sudo usermod -aG docker $USER

# グループ変更を反映（再ログインでも可）
newgrp docker
```

### 2.5 インストール確認

```bash
docker --version
# Docker version 27.x.x, build xxxxx

docker compose version
# Docker Compose version v2.x.x

git --version
# git version 2.x.x
```

---

## 3. API キー・トークンの準備

セットアップ前に、以下の3つのキー/トークンを取得しておいてください。

### 3.1 Anthropic API Key

1. [Anthropic Console](https://console.anthropic.com/) にアクセス
2. **API Keys** セクションで新しいキーを作成
3. `sk-ant-...` 形式のキーをコピーして控えておく

> **注意**: Claude Code CLI の実行にはクレジットが必要です。Usage の上限設定も確認してください。

### 3.2 GitHub Personal Access Token (PAT)

1. [GitHub Settings > Developer settings > Personal access tokens > Tokens (classic)](https://github.com/settings/tokens) にアクセス
2. **Generate new token (classic)** をクリック
3. 以下のスコープを選択:
   - `repo`（リポジトリへのフルアクセス）
   - `write:org`（ラベル操作に必要な場合）
4. `ghp_...` 形式のトークンをコピーして控えておく

> **Fine-grained tokens を使う場合**: 対象リポジトリに対して `Issues: Read and write`、`Pull requests: Read and write`、`Contents: Read and write` を許可してください。

### 3.3 Discord Webhook URL

1. Discord サーバーで通知を受け取りたいチャンネルの設定を開く
2. **連携サービス** → **ウェブフック** → **新しいウェブフック**
3. 名前を設定（例: `claude-pipeline`）
4. **ウェブフック URL をコピー** して控えておく

---

## 4. リポジトリのクローンと設定

### 4.1 リポジトリのクローン

```bash
cd /opt  # または任意のディレクトリ
sudo git clone https://github.com/polites-co-jp/self-company.git
sudo chown -R $USER:$USER self-company
cd self-company/claude-pipeline
```

### 4.2 設定ファイルの準備

```bash
# テンプレートからコピー
cp .env.example .env
cp config.yaml.example config.yaml
```

### 4.3 環境変数を設定

```bash
nano .env
```

以下を記入:

```ini
# Anthropic API Key（cp-pipeline コンテナ内の Claude Code CLI で使用）
ANTHROPIC_API_KEY=sk-ant-xxxxxxxxxxxxxxxxxxxxx

# GitHub Personal Access Token
# 必要なスコープ: repo, issues
GITHUB_TOKEN=ghp_xxxxxxxxxxxxxxxxxxxxx

# Discord Webhook URL
DISCORD_WEBHOOK_URL=https://discord.com/api/webhooks/xxxxx/xxxxx
```

> **セキュリティ**: `.env` ファイルは `.gitignore` に含まれており、Git にコミットされません。ファイルの権限も制限しておくと安全です:
> ```bash
> chmod 600 .env
> ```

### 4.4 Git のコミット用ユーザー設定

`cp-containers/docker-compose.yml` 内の pipeline サービスに Git ユーザー情報が設定されています。パイプラインが作成するコミットの author/committer を変更したい場合は編集してください:

```bash
nano cp-containers/docker-compose.yml
```

```yaml
environment:
  - GIT_AUTHOR_NAME=claude-pipeline
  - GIT_AUTHOR_EMAIL=claude-pipeline@example.com
  - GIT_COMMITTER_NAME=claude-pipeline
  - GIT_COMMITTER_EMAIL=claude-pipeline@example.com
```

---

## 5. config.yaml の設定

`config.yaml` で動作をカスタマイズできます。主要な設定項目:

```yaml
global:
  # ポーリング間隔（秒）。デフォルト300秒 = 5分
  poll_interval: 300

  # Issue のトリガーラベル
  # このラベルが付いたIssueを自動実装の対象とする
  trigger_label: "auto-implement"

  # 同時実行ジョブ数の上限
  # VPSのスペックに合わせて調整
  max_concurrent_jobs: 3

  # ログ保持日数
  log_retention_days: 30

  # Claude Code で使うモデル
  claude:
    model: "claude-sonnet-4-6"

  # スキル自動発見
  skill_discovery:
    enabled: true           # false にすると手動スキルのみ使用
    cache_ttl: 604800       # キャッシュ有効期間（7日）
    max_skills_per_repo: 5  # リポジトリあたりの最大スキル数
```

> 初回はデフォルト設定のままで問題ありません。運用しながら調整してください。

---

## 6. コンテナのビルド・起動

### 6.1 ビルドと起動

```bash
cd cp-containers
docker compose up -d --build
```

これにより以下の2つのコンテナが起動します:

| コンテナ名 | 説明 |
|-----------|------|
| `cp-pipeline` | ポーリング & パイプライン実行デーモン。**このコンテナ内で Claude Code CLI が実行され、コードの実装・テスト・レビューを自動で行います** |
| `cp-web` | Web 管理UI（ポート 3000） |

### 6.2 起動確認

```bash
# コンテナの状態を確認
docker compose ps

# ログを確認
docker compose logs -f

# 正常起動のメッセージ:
# cp-pipeline: [entrypoint] cron を設定しました: 5分ごとにポーリング
# cp-web: [web] claude-pipeline Web UI: http://0.0.0.0:3000
```

### 6.3 Web UI にアクセス

ブラウザで以下にアクセスしてください:

```
http://<VPS_IP>:3000
```

Web UI からリポジトリの登録・管理・ステータス確認・ログ閲覧が行えます。

### 6.4 コンテナの停止・再起動

> **注意**: `docker compose` コマンドは `cp-containers/` ディレクトリ内で実行するか、`-f` オプションでファイルを指定してください。

```bash
# cp-containers/ ディレクトリ内で実行する場合
cd cp-containers

# 停止
docker compose down

# 再起動（設定変更後など）
docker compose restart

# 再ビルドして起動（Dockerfile やスクリプトの変更後）
docker compose up -d --build
```

`claude-pipeline/` ディレクトリから実行する場合は `-f` オプションを使います:

```bash
docker compose -f cp-containers/docker-compose.yml up -d --build
```

---

## 7. リポジトリの登録

自動実装の対象にするリポジトリを登録します。CLI はすべて `cp-pipeline` コンテナ内で実行します。

### エイリアスの設定（推奨）

ホスト側から便利に操作できるよう、エイリアスを設定します:

```bash
echo 'alias claude-pipeline="docker exec cp-pipeline ./scripts/cli.sh"' >> ~/.bashrc
source ~/.bashrc
```

### 基本的な登録

```bash
claude-pipeline repo add yourname/my-project
```

### オプション付き登録

```bash
claude-pipeline repo add yourname/my-project \
  --pipeline default \
  --branch-prefix "feat/" \
  --base-branch "main" \
  --context "Next.js 15 App Router + Tailwind CSS のプロジェクト"
```

| オプション | デフォルト | 説明 |
|-----------|----------|------|
| `--pipeline` | `default` | 使用するパイプライン定義名 |
| `--branch-prefix` | `feat/` | feature ブランチのプレフィックス |
| `--base-branch` | `main` | PR のマージ先ブランチ |
| `--context` | (なし) | プロジェクト固有の説明。Claude がコードを書く際の参考情報 |

### 登録の確認

```bash
claude-pipeline repo list
```

出力例:

```
NAME              REPO                        PIPELINE   STATUS
----              ----                        --------   ------
my-project        yourname/my-project         default    active
another-app       yourname/another-app        default    active
```

### スキルの固定（オプション）

特定のスキルを常に適用したい場合:

```bash
claude-pipeline skill pin my-project vercel-labs/skills/vercel-react-best-practices
```

---

## 8. Discord 通知の設定

### config.yaml での通知タイミング設定

```yaml
global:
  discord:
    webhook_url_env: "DISCORD_WEBHOOK_URL"
    notify_on:
      - "success"    # パイプライン成功時
      - "failure"    # パイプライン失敗時
      # - "start"    # パイプライン開始時（必要に応じて有効化）
```

### 通知テスト

```bash
# cp-pipeline コンテナ内で通知テストを実行
docker exec cp-pipeline ./daemon/notifier.sh "info" "test/repo" "0" "通知テストです"
```

Discord チャンネルにメッセージが届けば成功です。

---

## 9. 動作確認

### 9.1 手動ポーリングテスト

リポジトリを登録した状態で:

```bash
claude-pipeline poll
```

出力例:

```
[poller] 2026-03-24 15:00:00 ポーリング開始（2リポジトリ）
[poller] 🔍 yourname/my-project のIssueをチェック中...
[poller]   → 対象Issueなし
[poller] 🔍 yourname/another-app のIssueをチェック中...
[poller]   → 対象Issueなし
[poller] ポーリング完了: 0件の新規ジョブ
```

### 9.2 テスト Issue での E2E 確認

1. 登録済みリポジトリに Issue を作成:
   - タイトル: `テスト: READMEにバッジを追加`
   - 本文: `README.md のタイトル下にCIステータスバッジを追加してください`
   - ラベル: `auto-implement`

2. 手動で即時実行:

```bash
claude-pipeline run yourname/my-project 1
```

3. 実行ログを確認:

```
================================================================
 claude-pipeline runner
 リポジトリ: yourname/my-project
 Issue: #1 - テスト: READMEにバッジを追加
 パイプライン: default
 開始: 2026-03-24 15:05:00
================================================================

[runner] === Step 0: リポジトリのクローン ===
[runner] ブランチ作成: feat/issue-1

[runner] === Step 0.5: スキル発見・CLAUDE.md合成 ===
...

[runner] === Step 1/4: implement ===
[runner] ✅ コミット: feat(#1): implement - テスト: READMEにバッジを追加

[runner] === Step 2/4: review ===
[runner] ℹ️  変更なし、スキップ

[runner] === Step 3/4: test ===
[runner] ℹ️  変更なし、スキップ

[runner] === Step 4/4: docs ===
[runner] ℹ️  変更なし、スキップ

[runner] === Push & PR 作成 ===
[runner] ✅ Push完了: feat/issue-1
[runner] ✅ PR作成: https://github.com/yourname/my-project/pull/2

================================================================
 パイプライン完了
 PR: https://github.com/yourname/my-project/pull/2
 終了: 2026-03-24 15:07:30
================================================================
```

4. Discord に通知が届くことを確認
5. GitHub に PR が作成されていることを確認

### 9.3 ステータス確認

```bash
claude-pipeline status
```

出力例:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  claude-pipeline ステータス
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

🔄 実行中:
  (なし)

⏳ キュー:
  (なし)

✅ 最近の完了:
  ✅ my-project #1  2026-03-24T15:07:30Z  https://github.com/yourname/my-project/pull/2

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

---

## 10. トラブルシューティング

### `docker compose` で `no configuration file provided` エラー

`docker-compose.yml` は `cp-containers/` ディレクトリにあります。以下のいずれかで対応してください:

```bash
# 方法1: cp-containers/ に移動して実行
cd cp-containers
docker compose up -d --build

# 方法2: -f オプションで指定（claude-pipeline/ から実行する場合）
docker compose -f cp-containers/docker-compose.yml up -d --build
```

### コンテナが起動しない

```bash
# cp-containers/ ディレクトリ内で実行
cd cp-containers

# ビルドログを確認
docker compose build --no-cache

# コンテナのログを確認
docker compose logs cp-pipeline

# コンテナに入って確認
docker exec -it cp-pipeline bash
```

### Issue が検出されない

| チェック項目 | 確認コマンド |
|-------------|------------|
| ラベルが正しいか | GitHub UI で `auto-implement` ラベルの存在を確認 |
| リポジトリが active か | `claude-pipeline repo list` |
| GitHub トークンが有効か | `docker exec cp-pipeline gh auth status` |
| Issue が open か | `docker exec cp-pipeline gh issue list --repo yourname/repo --label auto-implement` |

### パイプラインが失敗する

```bash
# ログを確認
claude-pipeline logs my-project 42

# 直近のログファイルを見る（コンテナからホストにマウントされている）
ls -lt logs/my-project/
cat logs/my-project/42-*.log
```

| よくある原因 | 対処 |
|------------|------|
| Anthropic API キーが無効 | `.env` の `ANTHROPIC_API_KEY` を確認 |
| API クレジット不足 | [Anthropic Console](https://console.anthropic.com/) でクレジットを確認 |
| Issue の本文が不十分 | Issue に具体的な要件を記載する |
| リポジトリへの push 権限がない | `GITHUB_TOKEN` のスコープを確認 |

### Discord 通知が届かない

```bash
# コンテナ内から Webhook URL の疎通テスト
docker exec cp-pipeline curl -H "Content-Type: application/json" \
  -d '{"content":"テスト通知"}' \
  "$DISCORD_WEBHOOK_URL"
```

- HTTP 204 が返れば Webhook は正常
- `config.yaml` の `notify_on` に `success` や `failure` が含まれているか確認

### ディスクスペースの管理

```bash
# 古いログとジョブを削除
claude-pipeline cleanup

# workspace に残っている作業ディレクトリを手動確認
ls -la workspace/
```

---

## 補足: 運用時の推奨事項

### Issue の書き方のコツ

Claude がより正確に実装できるよう、Issue には以下を含めると効果的です:

- **具体的な要件**: 「〇〇機能を追加」ではなく、入力・出力・振る舞いを明記
- **技術的な制約**: 使用するライブラリやアーキテクチャの指定
- **参考ファイル**: 既存の類似コードのファイルパスを記載
- **受け入れ条件**: 完了の判断基準をリスト化

### パイプラインのカスタマイズ

`pipelines/` に新しい YAML ファイルを作成し、リポジトリごとに割り当てられます:

```bash
# カスタムパイプラインを作成
cp pipelines/default.yaml pipelines/frontend.yaml
nano pipelines/frontend.yaml

# リポジトリに割り当て
claude-pipeline repo add yourname/frontend-app --pipeline frontend
```

### 定期メンテナンス

```bash
# 週に1回程度実行を推奨
claude-pipeline cleanup
```

### コンテナの更新

スクリプトや Dockerfile を更新した場合:

```bash
cd /opt/self-company
git pull
cd claude-pipeline/cp-containers
docker compose up -d --build
```
