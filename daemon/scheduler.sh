#!/bin/bash
# scheduler.sh - ジョブスケジューリング
# キューからジョブを取り出し、並行制御しながら runner.sh を起動する
# 使用法: ./scheduler.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# .env の読み込み
if [ -f "$BASE_DIR/.env" ]; then
  set -a
  source "$BASE_DIR/.env"
  set +a
fi

CONFIG="$BASE_DIR/config.yaml"
QUEUE_DIR="$BASE_DIR/workspace/.queue"
JOBS_DIR="$BASE_DIR/workspace/.jobs"
LOCKS_DIR="$BASE_DIR/workspace/.locks"
LOG_DIR="$BASE_DIR/logs"

mkdir -p "$QUEUE_DIR" "$JOBS_DIR" "$LOCKS_DIR" "$LOG_DIR"

MAX_CONCURRENT=$(yq '.global.max_concurrent_jobs // 3' "$CONFIG")

echo "[scheduler] $(date '+%Y-%m-%d %H:%M:%S') スケジューリング開始"

# 現在の実行中ジョブ数を確認
count_running_jobs() {
  local count=0
  for job_file in "$JOBS_DIR"/*.json; do
    [ -f "$job_file" ] || continue
    local status
    status=$(jq -r '.status' "$job_file")
    if [ "$status" = "running" ]; then
      # プロセスがまだ生きているか確認
      local pid
      pid=$(jq -r '.pid // 0' "$job_file")
      if [ "$pid" -gt 0 ] && kill -0 "$pid" 2>/dev/null; then
        count=$((count + 1))
      else
        # プロセスが死んでいる場合は失敗扱い
        echo "[scheduler] ⚠️ ジョブ $(basename "$job_file" .json) のプロセス($pid)が見つかりません。失敗扱いにします" >&2
        jq '.status = "failed" | .error = "プロセスが予期せず終了しました"' "$job_file" > "${job_file}.tmp" && mv "${job_file}.tmp" "$job_file"
      fi
    fi
  done
  echo "$count"
}

# リポジトリがロック中か確認
is_repo_locked() {
  local repo_name="$1"
  local lock_file="$LOCKS_DIR/${repo_name}.lock"

  if [ -f "$lock_file" ]; then
    local pid
    pid=$(cat "$lock_file")
    if kill -0 "$pid" 2>/dev/null; then
      return 0  # ロック中
    else
      # ロックが古い（プロセスが死んでいる）場合は削除
      rm -f "$lock_file"
    fi
  fi
  return 1  # ロックなし
}

# リポジトリをロック
lock_repo() {
  local repo_name="$1"
  local pid="$2"
  echo "$pid" > "$LOCKS_DIR/${repo_name}.lock"
}

# キュー内のジョブを処理
QUEUED_FILES=$(ls "$QUEUE_DIR"/*.json 2>/dev/null | sort || true)

if [ -z "$QUEUED_FILES" ]; then
  echo "[scheduler] キューにジョブがありません"
  exit 0
fi

for queue_file in $QUEUED_FILES; do
  [ -f "$queue_file" ] || continue

  JOB_ID=$(basename "$queue_file" .json)
  REPO_NAME=$(jq -r '.repo_name' "$queue_file")
  REPO=$(jq -r '.repo' "$queue_file")
  ISSUE_NUMBER=$(jq -r '.issue_number' "$queue_file")

  # 同時実行数チェック
  RUNNING=$(count_running_jobs)
  if [ "$RUNNING" -ge "$MAX_CONCURRENT" ]; then
    echo "[scheduler] 同時実行上限 (${MAX_CONCURRENT}) に達しています。残りのジョブは次回実行します"
    break
  fi

  # 同一リポジトリのロックチェック（直列実行保証）
  if is_repo_locked "$REPO_NAME"; then
    echo "[scheduler] ⏳ $REPO_NAME はロック中（他のジョブが実行中）。#${ISSUE_NUMBER} は待機"
    continue
  fi

  echo "[scheduler] 🚀 ジョブを開始: $REPO_NAME #${ISSUE_NUMBER}"

  # キューからジョブディレクトリに移動
  mv "$queue_file" "$JOBS_DIR/${JOB_ID}.json"

  # ジョブのステータスを更新
  jq --arg started_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '.status = "running" | .started_at = $started_at' \
    "$JOBS_DIR/${JOB_ID}.json" > "$JOBS_DIR/${JOB_ID}.json.tmp" \
    && mv "$JOBS_DIR/${JOB_ID}.json.tmp" "$JOBS_DIR/${JOB_ID}.json"

  # ログファイル
  JOB_LOG_DIR="$LOG_DIR/$REPO_NAME"
  mkdir -p "$JOB_LOG_DIR"
  JOB_LOG="$JOB_LOG_DIR/${ISSUE_NUMBER}-$(date +%Y%m%d-%H%M%S).log"

  # runner.sh をバックグラウンドで起動
  "$SCRIPT_DIR/runner.sh" "$JOBS_DIR/${JOB_ID}.json" > "$JOB_LOG" 2>&1 &
  RUNNER_PID=$!

  # PID を記録
  jq --arg pid "$RUNNER_PID" '.pid = ($pid | tonumber)' \
    "$JOBS_DIR/${JOB_ID}.json" > "$JOBS_DIR/${JOB_ID}.json.tmp" \
    && mv "$JOBS_DIR/${JOB_ID}.json.tmp" "$JOBS_DIR/${JOB_ID}.json"

  # リポジトリをロック
  lock_repo "$REPO_NAME" "$RUNNER_PID"

  echo "[scheduler] ✅ runner.sh 起動 (PID: $RUNNER_PID, ログ: $JOB_LOG)"
done

echo "[scheduler] スケジューリング完了"
