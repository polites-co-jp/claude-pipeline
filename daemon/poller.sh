#!/bin/bash
# poller.sh - GitHub Issue ポーリング
# cron で定期実行し、auto-implement ラベル付きの新規 Issue を検出する
# 使用法: ./poller.sh

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
LOG_DIR="$BASE_DIR/logs"

mkdir -p "$QUEUE_DIR" "$JOBS_DIR" "$LOG_DIR"

# GitHub トークン設定
GITHUB_TOKEN_ENV=$(yq '.global.github.token_env // "GITHUB_TOKEN"' "$CONFIG")
export GH_TOKEN="${!GITHUB_TOKEN_ENV:-}"

if [ -z "$GH_TOKEN" ]; then
  echo "[poller] GitHub トークンが設定されていません" >&2
  exit 1
fi

TRIGGER_LABEL=$(yq '.global.trigger_label // "auto-implement"' "$CONFIG")
REPO_COUNT=$(yq '.repositories | length' "$CONFIG")

if [ "$REPO_COUNT" -eq 0 ]; then
  echo "[poller] 登録リポジトリがありません"
  exit 0
fi

echo "[poller] $(date '+%Y-%m-%d %H:%M:%S') ポーリング開始（${REPO_COUNT}リポジトリ）"

NEW_JOBS=0

for i in $(seq 0 $((REPO_COUNT - 1))); do
  REPO_NAME=$(yq ".repositories[$i].name" "$CONFIG")
  REPO=$(yq ".repositories[$i].repo" "$CONFIG")
  REPO_STATUS=$(yq ".repositories[$i].status // \"active\"" "$CONFIG")
  PIPELINE=$(yq ".repositories[$i].pipeline // \"default\"" "$CONFIG")
  BRANCH_PREFIX=$(yq ".repositories[$i].branch_prefix // \"feature/\"" "$CONFIG")
  BASE_BRANCH=$(yq ".repositories[$i].base_branch // \"develop\"" "$CONFIG")

  # 一時停止中のリポジトリはスキップ
  if [ "$REPO_STATUS" = "paused" ]; then
    echo "[poller] ⏸️  $REPO_NAME はpause中、スキップ"
    continue
  fi

  echo "[poller] 🔍 $REPO のIssueをチェック中..."

  # auto-implement ラベル付きのオープンIssueを取得
  ISSUES=$(gh issue list \
    --repo "$REPO" \
    --label "$TRIGGER_LABEL" \
    --state open \
    --json number,title,body,labels \
    --limit 50 2>/dev/null || echo "[]")

  ISSUE_COUNT=$(echo "$ISSUES" | jq 'length')

  if [ "$ISSUE_COUNT" -eq 0 ]; then
    echo "[poller]   → 対象Issueなし"
    continue
  fi

  echo "[poller]   → ${ISSUE_COUNT}件のIssueを検出"

  # 各 Issue をキューに追加
  for j in $(seq 0 $((ISSUE_COUNT - 1))); do
    ISSUE_NUMBER=$(echo "$ISSUES" | jq -r ".[$j].number")
    ISSUE_TITLE=$(echo "$ISSUES" | jq -r ".[$j].title")
    ISSUE_BODY=$(echo "$ISSUES" | jq -r ".[$j].body // \"\"")

    # 既にキューまたは実行中でないか確認
    JOB_ID="${REPO_NAME}-${ISSUE_NUMBER}"
    if [ -f "$QUEUE_DIR/${JOB_ID}.json" ] || [ -f "$JOBS_DIR/${JOB_ID}.json" ]; then
      echo "[poller]   → #${ISSUE_NUMBER} は既にキュー/実行中、スキップ"
      continue
    fi

    # Issue body からブランチ指定を抽出
    # 対応フォーマット: "branch: xxx" または "ブランチ: xxx"（行頭）
    SPECIFIED_BRANCH=$(echo "$ISSUE_BODY" | grep -iE '^\s*(branch|ブランチ)\s*[:：]\s*' | head -1 | sed -E 's/^\s*(branch|ブランチ)\s*[:：]\s*//' | tr -d '[:space:]' || echo "")

    # ジョブをキューに追加
    jq -n \
      --arg repo "$REPO" \
      --arg repo_name "$REPO_NAME" \
      --arg issue_number "$ISSUE_NUMBER" \
      --arg issue_title "$ISSUE_TITLE" \
      --arg issue_body "$ISSUE_BODY" \
      --arg pipeline "$PIPELINE" \
      --arg branch_prefix "$BRANCH_PREFIX" \
      --arg base_branch "$BASE_BRANCH" \
      --arg specified_branch "$SPECIFIED_BRANCH" \
      --arg status "queued" \
      --arg created_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{
        repo: $repo,
        repo_name: $repo_name,
        issue_number: ($issue_number | tonumber),
        issue_title: $issue_title,
        issue_body: $issue_body,
        pipeline: $pipeline,
        branch_prefix: $branch_prefix,
        base_branch: $base_branch,
        specified_branch: $specified_branch,
        status: $status,
        created_at: $created_at
      }' > "$QUEUE_DIR/${JOB_ID}.json"

    echo "[poller]   → ✅ #${ISSUE_NUMBER} をキューに追加: ${ISSUE_TITLE}"
    NEW_JOBS=$((NEW_JOBS + 1))
  done
done

echo "[poller] ポーリング完了: ${NEW_JOBS}件の新規ジョブ"

# 新規ジョブがあればスケジューラーを起動
if [ "$NEW_JOBS" -gt 0 ]; then
  echo "[poller] スケジューラーを起動します"
  "$SCRIPT_DIR/scheduler.sh" &
fi
