#!/bin/bash
# cli.sh - claude-pipeline CLI エントリーポイント
# 使用法: claude-pipeline <command> [args...]
#
# コマンド:
#   repo add <owner/repo> [--pipeline <name>] [--branch-prefix <prefix>] [--base-branch <branch>]
#   repo list
#   repo pause <name>
#   repo resume <name>
#   repo remove <name>
#   skill pin <repo-name> <skill-package>
#   skill unpin <repo-name> <skill-package>
#   skill list [repo-name]
#   skill discover <repo-name>
#   run <owner/repo> <issue-number>
#   status
#   logs <repo-name> [issue-number]
#   poll          (手動でポーリング実行)
#   cleanup       (古いログとワークスペースの削除)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

CONFIG="$BASE_DIR/config.yaml"
DAEMON_DIR="$BASE_DIR/daemon"
QUEUE_DIR="$BASE_DIR/workspace/.queue"
JOBS_DIR="$BASE_DIR/workspace/.jobs"

# .env の読み込み
if [ -f "$BASE_DIR/.env" ]; then
  set -a
  source "$BASE_DIR/.env"
  set +a
fi

# ヘルプ表示
show_help() {
  cat <<'EOF'
claude-pipeline - Issue駆動の自動開発パイプライン

使用法:
  claude-pipeline <command> [args...]

リポジトリ管理:
  repo add <owner/repo>    リポジトリを登録
    --pipeline <name>        パイプライン名 (デフォルト: default)
    --branch-prefix <prefix> ブランチプレフィックス (デフォルト: feature/)
    --base-branch <branch>   ベースブランチ (デフォルト: develop)
    --context <text>         プロジェクトコンテキスト
  repo list                登録リポジトリ一覧
  repo pause <name>        リポジトリを一時停止
  repo resume <name>       リポジトリを再開
  repo remove <name>       リポジトリを削除

スキル管理:
  skill pin <repo> <pkg>   スキルを固定
  skill unpin <repo> <pkg> スキル固定を解除
  skill list [repo]        スキル一覧
  skill discover <repo>    スキルを手動で発見・更新

実行:
  run <owner/repo> <issue> 特定Issueを即時実行
  poll                     手動ポーリング
  status                   実行状況の表示
  logs <repo> [issue]      ログ表示

メンテナンス:
  cleanup                  古いログとワークスペースの削除
  version                  バージョン表示

EOF
}

# === repo コマンド群 ===

repo_add() {
  local REPO=""
  local PIPELINE="default"
  local BRANCH_PREFIX="feature/"
  local BASE_BRANCH="develop"
  local CONTEXT=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --pipeline)    PIPELINE="$2"; shift 2 ;;
      --branch-prefix) BRANCH_PREFIX="$2"; shift 2 ;;
      --base-branch) BASE_BRANCH="$2"; shift 2 ;;
      --context)     CONTEXT="$2"; shift 2 ;;
      *)             REPO="$1"; shift ;;
    esac
  done

  if [ -z "$REPO" ]; then
    echo "エラー: リポジトリ（owner/repo形式）を指定してください"
    exit 1
  fi

  # リポジトリ名を生成（owner/repo → repo部分）
  local NAME
  NAME=$(echo "$REPO" | sed 's|.*/||')

  # 既に登録済みか確認
  local EXISTING
  EXISTING=$(yq ".repositories[] | select(.repo == \"$REPO\") | .name" "$CONFIG" 2>/dev/null || echo "")
  if [ -n "$EXISTING" ]; then
    echo "エラー: $REPO は既に登録されています（名前: $EXISTING）"
    exit 1
  fi

  # リポジトリの存在確認
  if ! gh repo view "$REPO" --json name > /dev/null 2>&1; then
    echo "エラー: リポジトリ $REPO にアクセスできません"
    exit 1
  fi

  # config.yaml に追加
  if [ -n "$CONTEXT" ]; then
    yq -i ".repositories += [{
      \"name\": \"$NAME\",
      \"repo\": \"$REPO\",
      \"pipeline\": \"$PIPELINE\",
      \"branch_prefix\": \"$BRANCH_PREFIX\",
      \"base_branch\": \"$BASE_BRANCH\",
      \"status\": \"active\",
      \"pinned_skills\": [],
      \"context\": \"$CONTEXT\"
    }]" "$CONFIG"
  else
    yq -i ".repositories += [{
      \"name\": \"$NAME\",
      \"repo\": \"$REPO\",
      \"pipeline\": \"$PIPELINE\",
      \"branch_prefix\": \"$BRANCH_PREFIX\",
      \"base_branch\": \"$BASE_BRANCH\",
      \"status\": \"active\",
      \"pinned_skills\": []
    }]" "$CONFIG"
  fi

  echo "✅ リポジトリを登録しました:"
  echo "  名前: $NAME"
  echo "  リポジトリ: $REPO"
  echo "  パイプライン: $PIPELINE"
  echo "  ブランチプレフィックス: $BRANCH_PREFIX"
  echo "  ベースブランチ: $BASE_BRANCH"
}

repo_list() {
  local COUNT
  COUNT=$(yq '.repositories | length' "$CONFIG")

  if [ "$COUNT" -eq 0 ]; then
    echo "登録リポジトリはありません"
    echo ""
    echo "追加するには: claude-pipeline repo add <owner/repo>"
    return
  fi

  printf "%-20s %-35s %-12s %-8s\n" "NAME" "REPO" "PIPELINE" "STATUS"
  printf "%-20s %-35s %-12s %-8s\n" "----" "----" "--------" "------"

  for i in $(seq 0 $((COUNT - 1))); do
    local name repo pipeline status
    name=$(yq ".repositories[$i].name" "$CONFIG")
    repo=$(yq ".repositories[$i].repo" "$CONFIG")
    pipeline=$(yq ".repositories[$i].pipeline // \"default\"" "$CONFIG")
    status=$(yq ".repositories[$i].status // \"active\"" "$CONFIG")
    printf "%-20s %-35s %-12s %-8s\n" "$name" "$repo" "$pipeline" "$status"
  done
}

repo_pause() {
  local NAME="${1:?リポジトリ名を指定してください}"
  yq -i "(.repositories[] | select(.name == \"$NAME\")).status = \"paused\"" "$CONFIG"
  echo "⏸️  $NAME を一時停止しました"
}

repo_resume() {
  local NAME="${1:?リポジトリ名を指定してください}"
  yq -i "(.repositories[] | select(.name == \"$NAME\")).status = \"active\"" "$CONFIG"
  echo "▶️  $NAME を再開しました"
}

repo_remove() {
  local NAME="${1:?リポジトリ名を指定してください}"
  yq -i "del(.repositories[] | select(.name == \"$NAME\"))" "$CONFIG"
  echo "🗑️  $NAME を削除しました"
}

# === skill コマンド群 ===

skill_pin() {
  local REPO_NAME="${1:?リポジトリ名を指定してください}"
  local SKILL="${2:?スキルパッケージを指定してください}"

  yq -i "(.repositories[] | select(.name == \"$REPO_NAME\")).pinned_skills += [\"$SKILL\"]" "$CONFIG"
  echo "📌 $REPO_NAME にスキルを固定: $SKILL"
}

skill_unpin() {
  local REPO_NAME="${1:?リポジトリ名を指定してください}"
  local SKILL="${2:?スキルパッケージを指定してください}"

  yq -i "del((.repositories[] | select(.name == \"$REPO_NAME\")).pinned_skills[] | select(. == \"$SKILL\"))" "$CONFIG"
  echo "📌 $REPO_NAME からスキル固定を解除: $SKILL"
}

skill_list() {
  local REPO_NAME="${1:-}"

  if [ -n "$REPO_NAME" ]; then
    echo "=== $REPO_NAME のスキル ==="
    echo ""
    echo "📌 固定スキル:"
    yq "(.repositories[] | select(.name == \"$REPO_NAME\")).pinned_skills[]" "$CONFIG" 2>/dev/null || echo "  (なし)"

    echo ""
    echo "🔍 発見済みスキル:"
    local CACHE_FILE="$BASE_DIR/skills/cache/$(echo "$REPO_NAME" | sed 's/[^a-zA-Z0-9_-]/-/g').yaml"
    if [ -f "$CACHE_FILE" ]; then
      yq '.installed_skills[]' "$CACHE_FILE" 2>/dev/null || echo "  (なし)"
      echo ""
      echo "最終発見: $(yq '.last_discovered' "$CACHE_FILE")"
    else
      echo "  (未発見)"
    fi
  else
    echo "グローバルにインストール済みのスキル:"
    npx skills list 2>/dev/null || echo "  (npx skills コマンドが利用できません)"
  fi
}

skill_discover() {
  local REPO_NAME="${1:?リポジトリ名を指定してください}"
  local REPO
  REPO=$(yq ".repositories[] | select(.name == \"$REPO_NAME\") | .repo" "$CONFIG")

  if [ -z "$REPO" ] || [ "$REPO" = "null" ]; then
    echo "エラー: リポジトリ $REPO_NAME が見つかりません"
    exit 1
  fi

  # キャッシュを強制削除して再発見
  local CACHE_FILE="$BASE_DIR/skills/cache/$(echo "$REPO_NAME" | sed 's/[^a-zA-Z0-9_-]/-/g').yaml"
  rm -f "$CACHE_FILE"

  # 一時的にリポジトリをclone
  local TEMP_DIR
  TEMP_DIR=$(mktemp -d)
  git clone --depth 1 "https://github.com/${REPO}.git" "$TEMP_DIR" 2>/dev/null

  "$DAEMON_DIR/skill-discovery.sh" "$TEMP_DIR" "$REPO_NAME" ""

  rm -rf "$TEMP_DIR"
  echo ""
  echo "スキル発見が完了しました。確認: claude-pipeline skill list $REPO_NAME"
}

# === run コマンド ===

run_manual() {
  local REPO="${1:?リポジトリ（owner/repo）を指定してください}"
  local ISSUE_NUMBER="${2:?Issue番号を指定してください}"

  # リポジトリ名を取得
  local REPO_NAME
  REPO_NAME=$(yq ".repositories[] | select(.repo == \"$REPO\") | .name" "$CONFIG" 2>/dev/null || echo "")

  if [ -z "$REPO_NAME" ] || [ "$REPO_NAME" = "null" ]; then
    echo "エラー: $REPO は登録されていません。先に repo add してください"
    exit 1
  fi

  # Issue の取得
  local ISSUE_DATA
  ISSUE_DATA=$(gh issue view "$ISSUE_NUMBER" --repo "$REPO" --json number,title,body 2>/dev/null || echo "")

  if [ -z "$ISSUE_DATA" ]; then
    echo "エラー: Issue #$ISSUE_NUMBER が見つかりません"
    exit 1
  fi

  local ISSUE_TITLE ISSUE_BODY PIPELINE BRANCH_PREFIX BASE_BRANCH SPECIFIED_BRANCH
  ISSUE_TITLE=$(echo "$ISSUE_DATA" | jq -r '.title')
  ISSUE_BODY=$(echo "$ISSUE_DATA" | jq -r '.body // ""')
  PIPELINE=$(yq ".repositories[] | select(.name == \"$REPO_NAME\") | .pipeline // \"default\"" "$CONFIG")
  BRANCH_PREFIX=$(yq ".repositories[] | select(.name == \"$REPO_NAME\") | .branch_prefix // \"feature/\"" "$CONFIG")
  BASE_BRANCH=$(yq ".repositories[] | select(.name == \"$REPO_NAME\") | .base_branch // \"develop\"" "$CONFIG")

  # Issue body からブランチ指定を抽出
  SPECIFIED_BRANCH=$(echo "$ISSUE_BODY" | grep -iE '^\s*(branch|ブランチ)\s*[:：]\s*' | head -1 | sed -E 's/^\s*(branch|ブランチ)\s*[:：]\s*//' | tr -d '[:space:]' || echo "")

  local JOB_ID="${REPO_NAME}-${ISSUE_NUMBER}"

  # ジョブファイル作成
  mkdir -p "$JOBS_DIR"
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
    --arg status "running" \
    --arg created_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg started_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
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
      created_at: $created_at,
      started_at: $started_at
    }' > "$JOBS_DIR/${JOB_ID}.json"

  echo "🚀 手動実行を開始: $REPO #${ISSUE_NUMBER} - ${ISSUE_TITLE}"

  # ログファイル
  local JOB_LOG_DIR="$BASE_DIR/logs/$REPO_NAME"
  mkdir -p "$JOB_LOG_DIR"
  local JOB_LOG="$JOB_LOG_DIR/${ISSUE_NUMBER}-$(date +%Y%m%d-%H%M%S).log"

  # runner.sh を実行（フォアグラウンド）
  "$DAEMON_DIR/runner.sh" "$JOBS_DIR/${JOB_ID}.json" 2>&1 | tee "$JOB_LOG"
}

# === status コマンド ===

show_status() {
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  claude-pipeline ステータス"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""

  # 実行中ジョブ
  echo "🔄 実行中:"
  local HAS_RUNNING=false
  for job_file in "$JOBS_DIR"/*.json; do
    [ -f "$job_file" ] || continue
    local status
    status=$(jq -r '.status' "$job_file")
    if [ "$status" = "running" ]; then
      local repo_name issue_number step
      repo_name=$(jq -r '.repo_name' "$job_file")
      issue_number=$(jq -r '.issue_number' "$job_file")
      step=$(jq -r '.current_step // "unknown"' "$job_file")
      echo "  $repo_name #${issue_number}  [${step}]"
      HAS_RUNNING=true
    fi
  done
  $HAS_RUNNING || echo "  (なし)"

  # キュー
  echo ""
  echo "⏳ キュー:"
  local HAS_QUEUED=false
  for queue_file in "$QUEUE_DIR"/*.json; do
    [ -f "$queue_file" ] || continue
    local repo_name issue_number issue_title
    repo_name=$(jq -r '.repo_name' "$queue_file")
    issue_number=$(jq -r '.issue_number' "$queue_file")
    issue_title=$(jq -r '.issue_title' "$queue_file")
    echo "  $repo_name #${issue_number}  ${issue_title}"
    HAS_QUEUED=true
  done
  $HAS_QUEUED || echo "  (なし)"

  # 最近の完了
  echo ""
  echo "✅ 最近の完了:"
  local HAS_COMPLETED=false
  for job_file in "$JOBS_DIR"/*.json; do
    [ -f "$job_file" ] || continue
    local status
    status=$(jq -r '.status' "$job_file")
    if [ "$status" = "completed" ] || [ "$status" = "failed" ]; then
      local repo_name issue_number ended_at pr_url icon
      repo_name=$(jq -r '.repo_name' "$job_file")
      issue_number=$(jq -r '.issue_number' "$job_file")
      ended_at=$(jq -r '.ended_at // "?"' "$job_file")
      pr_url=$(jq -r '.pr_url // ""' "$job_file")
      [ "$status" = "completed" ] && icon="✅" || icon="❌"
      echo "  $icon $repo_name #${issue_number}  ${ended_at}  ${pr_url}"
      HAS_COMPLETED=true
    fi
  done
  $HAS_COMPLETED || echo "  (なし)"

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# === logs コマンド ===

show_logs() {
  local REPO_NAME="${1:?リポジトリ名を指定してください}"
  local ISSUE_NUMBER="${2:-}"
  local LOG_DIR="$BASE_DIR/logs/$REPO_NAME"

  if [ ! -d "$LOG_DIR" ]; then
    echo "ログが見つかりません: $REPO_NAME"
    return
  fi

  if [ -n "$ISSUE_NUMBER" ]; then
    # 特定 Issue のログ
    local LOG_FILE
    LOG_FILE=$(ls -t "$LOG_DIR"/${ISSUE_NUMBER}-*.log 2>/dev/null | head -1)
    if [ -n "$LOG_FILE" ]; then
      cat "$LOG_FILE"
    else
      echo "Issue #${ISSUE_NUMBER} のログが見つかりません"
    fi
  else
    # ログファイル一覧
    echo "ログファイル一覧: $REPO_NAME"
    ls -lt "$LOG_DIR"/*.log 2>/dev/null | head -20 || echo "  ログなし"
  fi
}

# === cleanup コマンド ===

do_cleanup() {
  local RETENTION_DAYS
  RETENTION_DAYS=$(yq '.global.log_retention_days // 30' "$CONFIG")

  echo "クリーンアップ開始（保持期間: ${RETENTION_DAYS}日）"

  # 古いログの削除
  find "$BASE_DIR/logs" -name "*.log" -mtime +"$RETENTION_DAYS" -delete 2>/dev/null || true
  echo "✅ 古いログを削除しました"

  # 完了/失敗ジョブの削除
  for job_file in "$JOBS_DIR"/*.json; do
    [ -f "$job_file" ] || continue
    local status
    status=$(jq -r '.status' "$job_file")
    if [ "$status" = "completed" ] || [ "$status" = "failed" ]; then
      rm -f "$job_file"
    fi
  done
  echo "✅ 完了済みジョブを削除しました"

  # 残存ワークスペースの削除
  for ws_dir in "$BASE_DIR/workspace"/*/; do
    [ -d "$ws_dir" ] || continue
    local dirname
    dirname=$(basename "$ws_dir")
    # .queue, .jobs, .locks は除外
    case "$dirname" in
      .queue|.jobs|.locks) continue ;;
      *) rm -rf "$ws_dir"; echo "  🗑️  workspace/$dirname を削除" ;;
    esac
  done
  echo "✅ クリーンアップ完了"
}

# === メインルーティング ===

COMMAND="${1:-help}"
shift || true

case "$COMMAND" in
  repo)
    SUBCMD="${1:-list}"
    shift || true
    case "$SUBCMD" in
      add)     repo_add "$@" ;;
      list)    repo_list ;;
      pause)   repo_pause "$@" ;;
      resume)  repo_resume "$@" ;;
      remove)  repo_remove "$@" ;;
      *)       echo "不明なサブコマンド: repo $SUBCMD"; show_help; exit 1 ;;
    esac
    ;;
  skill)
    SUBCMD="${1:-list}"
    shift || true
    case "$SUBCMD" in
      pin)      skill_pin "$@" ;;
      unpin)    skill_unpin "$@" ;;
      list)     skill_list "$@" ;;
      discover) skill_discover "$@" ;;
      *)        echo "不明なサブコマンド: skill $SUBCMD"; show_help; exit 1 ;;
    esac
    ;;
  run)     run_manual "$@" ;;
  poll)    "$DAEMON_DIR/poller.sh" ;;
  status)  show_status ;;
  logs)    show_logs "$@" ;;
  cleanup) do_cleanup ;;
  version) echo "claude-pipeline v0.1.0" ;;
  help|--help|-h) show_help ;;
  *)       echo "不明なコマンド: $COMMAND"; show_help; exit 1 ;;
esac
