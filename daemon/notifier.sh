#!/bin/bash
# notifier.sh - Discord Webhook通知
# 使用法: ./notifier.sh <type> <repo> <issue_number> <message> [pr_url]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# .env の読み込み
if [ -f "$BASE_DIR/.env" ]; then
  set -a
  source "$BASE_DIR/.env"
  set +a
fi

# 設定読み込み
CONFIG="$BASE_DIR/config.yaml"
WEBHOOK_URL_ENV=$(yq '.global.discord.webhook_url_env' "$CONFIG")
WEBHOOK_URL="${!WEBHOOK_URL_ENV:-}"

if [ -z "$WEBHOOK_URL" ]; then
  echo "[notifier] Discord Webhook URLが設定されていません" >&2
  exit 1
fi

TYPE="${1:-info}"       # success | failure | start | info
REPO="${2:-unknown}"
ISSUE_NUMBER="${3:-0}"
MESSAGE="${4:-}"
PR_URL="${5:-}"

# 色の設定
case "$TYPE" in
  success)  COLOR=3066993  ;; # 緑
  failure)  COLOR=15158332 ;; # 赤
  start)    COLOR=3447003  ;; # 青
  *)        COLOR=9807270  ;; # グレー
esac

# タイトル
case "$TYPE" in
  success)  TITLE="✅ 自動実装完了" ;;
  failure)  TITLE="❌ 自動実装失敗" ;;
  start)    TITLE="🔄 自動実装開始" ;;
  *)        TITLE="ℹ️ 通知" ;;
esac

# Embed フィールド構築
FIELDS="["
FIELDS+="{\"name\": \"リポジトリ\", \"value\": \"\`$REPO\`\", \"inline\": true},"
FIELDS+="{\"name\": \"Issue\", \"value\": \"#$ISSUE_NUMBER\", \"inline\": true}"

if [ -n "$PR_URL" ]; then
  FIELDS+=",{\"name\": \"PR\", \"value\": \"$PR_URL\", \"inline\": false}"
fi

FIELDS+="]"

# メッセージが長すぎる場合は切り詰め
if [ ${#MESSAGE} -gt 1000 ]; then
  MESSAGE="${MESSAGE:0:997}..."
fi

# JSON ペイロード構築
PAYLOAD=$(jq -n \
  --arg title "$TITLE" \
  --arg desc "$MESSAGE" \
  --argjson color "$COLOR" \
  --argjson fields "$FIELDS" \
  --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{
    embeds: [{
      title: $title,
      description: $desc,
      color: $color,
      fields: $fields,
      timestamp: $timestamp
    }]
  }')

# 送信
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD" \
  "$WEBHOOK_URL")

if [ "$HTTP_CODE" -ge 200 ] && [ "$HTTP_CODE" -lt 300 ]; then
  echo "[notifier] Discord通知送信成功 (HTTP $HTTP_CODE)"
else
  echo "[notifier] Discord通知送信失敗 (HTTP $HTTP_CODE)" >&2
  exit 1
fi
