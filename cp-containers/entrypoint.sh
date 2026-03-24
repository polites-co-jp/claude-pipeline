#!/bin/bash
# Docker コンテナのエントリーポイント
set -euo pipefail

BASE_DIR="/app"

# config.yaml が無ければ example からコピー
if [ ! -f "$BASE_DIR/config.yaml" ]; then
  cp "$BASE_DIR/config.yaml.example" "$BASE_DIR/config.yaml"
  echo "[entrypoint] config.yaml を生成しました"
fi

# Windows環境からマウントされたファイルのCRLF→LF変換
# Dockerバインドマウントではsed -iのrenameが失敗するため、tmpファイル経由で変換
if grep -qP '\r' "$BASE_DIR/config.yaml" 2>/dev/null; then
  tr -d '\r' < "$BASE_DIR/config.yaml" > /tmp/config.yaml.tmp && cp /tmp/config.yaml.tmp "$BASE_DIR/config.yaml" && rm /tmp/config.yaml.tmp
  echo "[entrypoint] config.yaml のCRLF→LF変換を実行しました"
fi

# .env の読み込み
if [ -f "$BASE_DIR/.env" ]; then
  # Windows環境からマウントされた場合のCRLF→LF変換
  if grep -qP '\r' "$BASE_DIR/.env" 2>/dev/null; then
    tr -d '\r' < "$BASE_DIR/.env" > /tmp/env.tmp && cp /tmp/env.tmp "$BASE_DIR/.env" && rm /tmp/env.tmp
    echo "[entrypoint] .env のCRLF→LF変換を実行しました"
  fi
  set -a
  source "$BASE_DIR/.env"
  set +a
fi

# cron ジョブの設定
POLL_INTERVAL=$(yq '.global.poll_interval // 300' "$BASE_DIR/config.yaml")
CRON_MINUTES=$((POLL_INTERVAL / 60))
[ "$CRON_MINUTES" -lt 1 ] && CRON_MINUTES=1

# 環境変数を cron に引き継ぐ
printenv | grep -E '^(ANTHROPIC_|GITHUB_|DISCORD_|GH_|CLAUDE_MODEL|PATH=)' > /etc/environment 2>/dev/null || true

# cron タブ作成
echo "*/${CRON_MINUTES} * * * * cd $BASE_DIR && ./daemon/poller.sh >> $BASE_DIR/logs/poller.log 2>&1" | crontab -

echo "[entrypoint] cron を設定しました: ${CRON_MINUTES}分ごとにポーリング"

# cron をバックグラウンドで起動
cron

echo "[entrypoint] claude-pipeline が起動しました"
echo "[entrypoint] ログ: tail -f $BASE_DIR/logs/poller.log"

# ログを監視しつつ待機
touch "$BASE_DIR/logs/poller.log"
tail -f "$BASE_DIR/logs/poller.log"
