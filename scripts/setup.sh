#!/bin/bash
# setup.sh - claude-pipeline 初期セットアップ
# 使用法: ./setup.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  claude-pipeline セットアップ"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# === 1. 依存ツールのチェック ===
echo "📋 依存ツールのチェック..."

MISSING=()

check_tool() {
  local tool="$1"
  local install_hint="${2:-}"
  if command -v "$tool" > /dev/null 2>&1; then
    local version
    version=$("$tool" --version 2>&1 | head -1 || echo "unknown")
    echo "  ✅ $tool ($version)"
  else
    echo "  ❌ $tool が見つかりません"
    [ -n "$install_hint" ] && echo "     → $install_hint"
    MISSING+=("$tool")
  fi
}

check_tool "gh" "https://cli.github.com/"
check_tool "claude" "npm install -g @anthropic-ai/claude-code"
check_tool "jq" "apt install jq / brew install jq"
check_tool "yq" "https://github.com/mikefarah/yq"
check_tool "npx" "https://nodejs.org/"
check_tool "git" "apt install git / brew install git"
check_tool "curl" "apt install curl"

echo ""

if [ ${#MISSING[@]} -gt 0 ]; then
  echo "⚠️  以下のツールがインストールされていません:"
  for tool in "${MISSING[@]}"; do
    echo "  - $tool"
  done
  echo ""
  echo "インストール後に再度 setup.sh を実行してください"
  exit 1
fi

echo "✅ 全ての依存ツールが利用可能です"
echo ""

# === 2. 設定ファイルの生成 ===
echo "📋 設定ファイルの生成..."

if [ ! -f "$BASE_DIR/config.yaml" ]; then
  cp "$BASE_DIR/config.yaml.example" "$BASE_DIR/config.yaml"
  echo "  ✅ config.yaml を生成しました"
else
  echo "  ℹ️  config.yaml は既に存在します"
fi

if [ ! -f "$BASE_DIR/.env" ]; then
  cp "$BASE_DIR/.env.example" "$BASE_DIR/.env"
  echo "  ✅ .env を生成しました"
  echo ""
  echo "  ⚠️  .env を編集して以下を設定してください:"
  echo "     - ANTHROPIC_API_KEY"
  echo "     - GITHUB_TOKEN"
  echo "     - DISCORD_WEBHOOK_URL"
else
  echo "  ℹ️  .env は既に存在します"
fi

echo ""

# === 3. ディレクトリ作成 ===
echo "📋 ディレクトリの作成..."

mkdir -p "$BASE_DIR/workspace/.queue"
mkdir -p "$BASE_DIR/workspace/.jobs"
mkdir -p "$BASE_DIR/workspace/.locks"
mkdir -p "$BASE_DIR/logs"
mkdir -p "$BASE_DIR/skills/cache"

echo "  ✅ workspace/, logs/, skills/ を作成しました"
echo ""

# === 4. スクリプトに実行権限を付与 ===
echo "📋 実行権限の付与..."

chmod +x "$BASE_DIR/daemon/"*.sh
chmod +x "$BASE_DIR/scripts/"*.sh

echo "  ✅ 全スクリプトに実行権限を付与しました"
echo ""

# === 5. CLI のシンボリックリンク（オプション） ===
echo "📋 CLI セットアップ..."

CLI_PATH="$BASE_DIR/scripts/cli.sh"

if [ -w "/usr/local/bin" ]; then
  ln -sf "$CLI_PATH" /usr/local/bin/claude-pipeline
  echo "  ✅ claude-pipeline コマンドをインストールしました"
else
  echo "  ℹ️  /usr/local/bin に書き込み権限がありません"
  echo "     手動で設定してください:"
  echo "     sudo ln -sf $CLI_PATH /usr/local/bin/claude-pipeline"
  echo "     または PATH に追加:"
  echo "     export PATH=\"$BASE_DIR/scripts:\$PATH\""
fi

echo ""

# === 6. GitHub CLI 認証チェック ===
echo "📋 GitHub CLI 認証チェック..."

if gh auth status > /dev/null 2>&1; then
  echo "  ✅ GitHub CLI は認証済みです"
else
  echo "  ⚠️  GitHub CLI が未認証です"
  echo "     gh auth login を実行するか、.env に GITHUB_TOKEN を設定してください"
fi

echo ""

# === 7. cron 登録（オプション） ===
echo "📋 cron 設定..."
echo "  ポーリングを自動実行するには、以下を crontab に追加してください:"
echo ""
echo "  # claude-pipeline: 5分ごとにIssueをポーリング"
echo "  */5 * * * * cd $BASE_DIR && ./daemon/poller.sh >> $BASE_DIR/logs/poller.log 2>&1"
echo ""
echo "  登録コマンド:"
echo "  (crontab -l 2>/dev/null; echo \"*/5 * * * * cd $BASE_DIR && ./daemon/poller.sh >> $BASE_DIR/logs/poller.log 2>&1\") | crontab -"
echo ""

# === 8. .gitignore ===
if [ ! -f "$BASE_DIR/.gitignore" ]; then
  cat > "$BASE_DIR/.gitignore" <<'EOF'
# 環境変数（秘密情報）
.env

# 実行時生成物
workspace/
logs/
skills/cache/

# 設定ファイル（各環境固有）
config.yaml
EOF
  echo "  ✅ .gitignore を生成しました"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  セットアップ完了！"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "次のステップ:"
echo "  1. .env を編集してAPIキーを設定"
echo "  2. claude-pipeline repo add <owner/repo> でリポジトリを登録"
echo "  3. GitHub Issue に「auto-implement」ラベルを付けて試す"
echo "  4. claude-pipeline poll で手動ポーリング、または cron を設定"
echo ""
