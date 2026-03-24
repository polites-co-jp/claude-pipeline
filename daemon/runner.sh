#!/bin/bash
# runner.sh - パイプライン実行エンジン
# 1つのIssueに対してパイプラインの全ステップを実行する
# 使用法: ./runner.sh <job_file.json>

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
JOB_FILE="${1:?ジョブファイルを指定してください}"

# ジョブ情報の読み込み
REPO=$(jq -r '.repo' "$JOB_FILE")
REPO_NAME=$(jq -r '.repo_name' "$JOB_FILE")
ISSUE_NUMBER=$(jq -r '.issue_number' "$JOB_FILE")
ISSUE_TITLE=$(jq -r '.issue_title' "$JOB_FILE")
ISSUE_BODY=$(jq -r '.issue_body' "$JOB_FILE")
PIPELINE=$(jq -r '.pipeline' "$JOB_FILE")
BRANCH_PREFIX=$(jq -r '.branch_prefix' "$JOB_FILE")
BASE_BRANCH=$(jq -r '.base_branch' "$JOB_FILE")

JOB_ID="${REPO_NAME}-${ISSUE_NUMBER}"
WORKSPACE_DIR="$BASE_DIR/workspace/${JOB_ID}"
PIPELINE_FILE="$BASE_DIR/pipelines/${PIPELINE}.yaml"
LOCKS_DIR="$BASE_DIR/workspace/.locks"

# GitHub トークン設定
GITHUB_TOKEN_ENV=$(yq '.global.github.token_env // "GITHUB_TOKEN"' "$CONFIG")
export GH_TOKEN="${!GITHUB_TOKEN_ENV:-}"

# Claude 設定
CLAUDE_API_KEY_ENV=$(yq '.global.claude.api_key_env // "ANTHROPIC_API_KEY"' "$CONFIG")
export ANTHROPIC_API_KEY="${!CLAUDE_API_KEY_ENV:-}"

# .env から読み込まれた環境変数を退避（CLAUDE_MODEL は後で上書きするため）
ENV_CLAUDE_MODEL="${CLAUDE_MODEL:-}"

# デフォルトモデルの解決
#   優先順位: リポジトリ固有(yaml) > 環境変数 CLAUDE_MODEL(.env) > yaml グローバル > ハードコード
REPO_INDEX=$(yq ".repositories | to_entries[] | select(.value.name == \"$REPO_NAME\") | .key" "$CONFIG" 2>/dev/null || echo "")
DEFAULT_MODEL=""
if [ -n "$REPO_INDEX" ]; then
  DEFAULT_MODEL=$(yq ".repositories[$REPO_INDEX].claude_model // \"\"" "$CONFIG")
fi
if [ -z "$DEFAULT_MODEL" ] && [ -n "$ENV_CLAUDE_MODEL" ]; then
  DEFAULT_MODEL="$ENV_CLAUDE_MODEL"
fi
if [ -z "$DEFAULT_MODEL" ]; then
  DEFAULT_MODEL=$(yq '.global.claude.model // "claude-sonnet-4-6"' "$CONFIG")
fi

# 通知設定
NOTIFY_ON=$(yq '.global.discord.notify_on[]' "$CONFIG" 2>/dev/null || echo "success failure")

echo "================================================================"
echo " claude-pipeline runner"
echo " リポジトリ: $REPO"
echo " Issue: #${ISSUE_NUMBER} - ${ISSUE_TITLE}"
echo " パイプライン: $PIPELINE"
echo " デフォルトモデル: $DEFAULT_MODEL"
echo " 開始: $(date '+%Y-%m-%d %H:%M:%S')"
echo "================================================================"

# クリーンアップ関数
cleanup() {
  local exit_code=$?

  # リポジトリロックの解除
  rm -f "$LOCKS_DIR/${REPO_NAME}.lock"

  if [ $exit_code -ne 0 ]; then
    echo "[runner] ❌ パイプラインが失敗しました (exit code: $exit_code)"

    # ジョブステータスを更新
    if [ -f "$JOB_FILE" ]; then
      jq --arg ended_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '.status = "failed" | .ended_at = $ended_at' \
        "$JOB_FILE" > "${JOB_FILE}.tmp" && mv "${JOB_FILE}.tmp" "$JOB_FILE"
    fi

    # 失敗ラベルを付与
    FAILED_LABEL=$(yq '.global.failed_label // "auto-implement-failed"' "$CONFIG")
    gh issue edit "$ISSUE_NUMBER" --repo "$REPO" \
      --add-label "$FAILED_LABEL" 2>/dev/null || true

    # Issue にコメント
    FAILED_STEP="${CURRENT_STEP:-unknown}"
    gh issue comment "$ISSUE_NUMBER" --repo "$REPO" \
      --body "## ⚠️ 自動実装パイプラインが失敗しました

**失敗ステップ**: ${FAILED_STEP}
**パイプライン**: ${PIPELINE}
**時刻**: $(date '+%Y-%m-%d %H:%M:%S')

ログを確認して再試行してください。" 2>/dev/null || true

    # Discord 通知（失敗）
    if echo "$NOTIFY_ON" | grep -q "failure"; then
      "$SCRIPT_DIR/notifier.sh" "failure" "$REPO" "$ISSUE_NUMBER" \
        "Issue #${ISSUE_NUMBER}: ${ISSUE_TITLE}\nステップ「${FAILED_STEP}」で失敗しました" 2>/dev/null || true
    fi
  fi

  echo "[runner] ロック解除: $REPO_NAME"
}
trap cleanup EXIT

# パイプラインファイルの存在確認
if [ ! -f "$PIPELINE_FILE" ]; then
  echo "[runner] ❌ パイプライン定義が見つかりません: $PIPELINE_FILE"
  exit 1
fi

# ステップ数を取得
STEP_COUNT=$(yq '.steps | length' "$PIPELINE_FILE")
echo "[runner] パイプライン: ${STEP_COUNT}ステップ"

# 開始通知
if echo "$NOTIFY_ON" | grep -q "start"; then
  "$SCRIPT_DIR/notifier.sh" "start" "$REPO" "$ISSUE_NUMBER" \
    "Issue #${ISSUE_NUMBER}: ${ISSUE_TITLE}\nパイプライン「${PIPELINE}」を開始します（${STEP_COUNT}ステップ）" 2>/dev/null || true
fi

# === 1. リポジトリのクローン ===
echo ""
echo "[runner] === Step 0: リポジトリのクローン ==="
rm -rf "$WORKSPACE_DIR"
git clone "https://github.com/${REPO}.git" "$WORKSPACE_DIR"
cd "$WORKSPACE_DIR"

# ベースブランチに切り替え
git checkout "$BASE_BRANCH"

# feature ブランチ作成
BRANCH_NAME="${BRANCH_PREFIX}issue-${ISSUE_NUMBER}"
git checkout -b "$BRANCH_NAME"
echo "[runner] ブランチ作成: $BRANCH_NAME"

# === 2. スキル発見・CLAUDE.md 合成 ===
echo ""
echo "[runner] === Step 0.5: スキル発見・CLAUDE.md合成 ==="
CURRENT_STEP="skill-discovery"

# pinned_skills の取得
PINNED_SKILLS=""
if [ -n "$REPO_INDEX" ]; then
  PINNED_SKILLS=$(yq ".repositories[$REPO_INDEX].pinned_skills[]" "$CONFIG" 2>/dev/null || echo "")
fi

# プロジェクト固有のコンテキスト
PROJECT_CONTEXT=""
if [ -n "$REPO_INDEX" ]; then
  PROJECT_CONTEXT=$(yq ".repositories[$REPO_INDEX].context // \"\"" "$CONFIG")
fi

# 動的スキル発見
DISCOVERED_SKILLS=$("$SCRIPT_DIR/skill-discovery.sh" "$WORKSPACE_DIR" "$REPO_NAME" "$ISSUE_BODY" 2>/dev/null || echo "")

# CLAUDE.md の合成（既存の CLAUDE.md を保持しつつ追記）
SYNTHESIZED_CLAUDE_MD=""

# 既存の CLAUDE.md があれば読み込み
if [ -f "$WORKSPACE_DIR/CLAUDE.md" ]; then
  SYNTHESIZED_CLAUDE_MD+=$(cat "$WORKSPACE_DIR/CLAUDE.md")
  SYNTHESIZED_CLAUDE_MD+=$'\n\n'
fi

# プロジェクトコンテキストを追加
if [ -n "$PROJECT_CONTEXT" ] && [ "$PROJECT_CONTEXT" != "null" ]; then
  SYNTHESIZED_CLAUDE_MD+="# プロジェクトコンテキスト"$'\n'
  SYNTHESIZED_CLAUDE_MD+="$PROJECT_CONTEXT"$'\n\n'
fi

# スキルのガイドラインを合成
ALL_SKILLS=""
[ -n "$PINNED_SKILLS" ] && ALL_SKILLS+="$PINNED_SKILLS"$'\n'
[ -n "$DISCOVERED_SKILLS" ] && ALL_SKILLS+="$DISCOVERED_SKILLS"$'\n'

if [ -n "$ALL_SKILLS" ]; then
  SYNTHESIZED_CLAUDE_MD+="# 適用スキル・ガイドライン"$'\n\n'

  while IFS= read -r skill; do
    [ -z "$skill" ] && continue
    echo "[runner] スキル適用: $skill"

    # スキルの SKILL.md を探す（グローバルインストール先）
    # npx skills でインストールされたスキルは ~/.claude/skills/ にある想定
    SKILL_MD=""
    for search_path in \
      "$HOME/.claude/skills/$skill/SKILL.md" \
      "$HOME/.config/claude-code/skills/$skill/SKILL.md"; do
      if [ -f "$search_path" ]; then
        SKILL_MD="$search_path"
        break
      fi
    done

    if [ -n "$SKILL_MD" ]; then
      SYNTHESIZED_CLAUDE_MD+="## $(basename "$(dirname "$SKILL_MD")")"$'\n'
      SYNTHESIZED_CLAUDE_MD+=$(cat "$SKILL_MD")
      SYNTHESIZED_CLAUDE_MD+=$'\n\n'
    fi
  done <<< "$ALL_SKILLS"
fi

# 合成した CLAUDE.md を配置（.claude/ ディレクトリに）
if [ -n "$SYNTHESIZED_CLAUDE_MD" ]; then
  mkdir -p "$WORKSPACE_DIR/.claude"
  echo "$SYNTHESIZED_CLAUDE_MD" > "$WORKSPACE_DIR/.claude/CLAUDE.md"
  echo "[runner] CLAUDE.md を合成しました"
fi

# === 3. パイプラインステップの実行 ===
for i in $(seq 0 $((STEP_COUNT - 1))); do
  STEP_NAME=$(yq ".steps[$i].name" "$PIPELINE_FILE")
  STEP_DESC=$(yq ".steps[$i].description // \"\"" "$PIPELINE_FILE")
  COMMIT_PREFIX=$(yq ".steps[$i].commit_prefix // \"chore\"" "$PIPELINE_FILE")
  ALLOWED_TOOLS=$(yq ".steps[$i].allowed_tools // \"Edit,Write,Bash,Glob,Grep,Read\"" "$PIPELINE_FILE")
  MAX_TURNS=$(yq ".steps[$i].max_turns // 30" "$PIPELINE_FILE")
  SKIP_IF_NO_CHANGES=$(yq ".steps[$i].skip_if_no_changes // false" "$PIPELINE_FILE")
  RETRY_ON_TEST_FAILURE=$(yq ".steps[$i].retry_on_test_failure // 0" "$PIPELINE_FILE")

  # モデル解決（優先順位: ステップyaml > 環境変数 CLAUDE_MODEL_<STEP> > デフォルト）
  STEP_MODEL=$(yq ".steps[$i].model // \"\"" "$PIPELINE_FILE")
  STEP_NAME_UPPER=$(echo "$STEP_NAME" | tr '[:lower:]' '[:upper:]' | tr '-' '_')
  ENV_VAR_NAME="CLAUDE_MODEL_${STEP_NAME_UPPER}"
  ENV_STEP_MODEL="${!ENV_VAR_NAME:-}"
  if [ -n "$STEP_MODEL" ]; then
    CURRENT_MODEL="$STEP_MODEL"
  elif [ -n "$ENV_STEP_MODEL" ]; then
    CURRENT_MODEL="$ENV_STEP_MODEL"
  else
    CURRENT_MODEL="$DEFAULT_MODEL"
  fi

  CURRENT_STEP="$STEP_NAME"

  echo ""
  echo "[runner] === Step $((i + 1))/${STEP_COUNT}: ${STEP_NAME} (${STEP_DESC}) ==="

  # ジョブステータスを更新
  jq --arg step "$STEP_NAME" '.current_step = $step' "$JOB_FILE" > "${JOB_FILE}.tmp" && mv "${JOB_FILE}.tmp" "$JOB_FILE"

  # プロンプトテンプレートの取得と変数展開
  PROMPT_TEMPLATE=$(yq ".steps[$i].prompt_template" "$PIPELINE_FILE")

  # git diff の取得
  GIT_DIFF=$(git diff HEAD~1 2>/dev/null || echo "(初回コミットのため差分なし)")
  GIT_DIFF_FROM_MAIN=$(git diff "${BASE_BRANCH}...HEAD" 2>/dev/null || echo "(差分なし)")

  # 変数を展開
  PROMPT="$PROMPT_TEMPLATE"
  PROMPT="${PROMPT//\{issue_number\}/$ISSUE_NUMBER}"
  PROMPT="${PROMPT//\{issue_title\}/$ISSUE_TITLE}"
  PROMPT="${PROMPT//\{issue_body\}/$ISSUE_BODY}"
  PROMPT="${PROMPT//\{git_diff\}/$GIT_DIFF}"
  PROMPT="${PROMPT//\{git_diff_from_main\}/$GIT_DIFF_FROM_MAIN}"

  # Claude Code で実行
  ATTEMPT=0
  MAX_ATTEMPTS=$((RETRY_ON_TEST_FAILURE + 1))

  while [ "$ATTEMPT" -lt "$MAX_ATTEMPTS" ]; do
    ATTEMPT=$((ATTEMPT + 1))

    if [ "$ATTEMPT" -gt 1 ]; then
      echo "[runner] リトライ ${ATTEMPT}/${MAX_ATTEMPTS}"
      # リトライ時は失敗理由を追加
      PROMPT="$PROMPT

前回の実行でテストが失敗しました。テストの失敗を修正してください。"
    fi

    echo "[runner] Claude Code を実行中... (model: $CURRENT_MODEL, max_turns: $MAX_TURNS)"

    # claude -p で非対話実行
    set +e
    claude -p "$PROMPT" \
      --model "$CURRENT_MODEL" \
      --allowedTools "$ALLOWED_TOOLS" \
      --max-turns "$MAX_TURNS" \
      2>&1
    CLAUDE_EXIT=$?
    set -e

    if [ "$CLAUDE_EXIT" -ne 0 ] && [ "$RETRY_ON_TEST_FAILURE" -gt 0 ] && [ "$ATTEMPT" -lt "$MAX_ATTEMPTS" ]; then
      echo "[runner] ⚠️ Claude Code がエラーで終了 (exit: $CLAUDE_EXIT)。リトライします"
      continue
    elif [ "$CLAUDE_EXIT" -ne 0 ] && [ "$RETRY_ON_TEST_FAILURE" -eq 0 ]; then
      echo "[runner] ⚠️ Claude Code がエラーで終了 (exit: $CLAUDE_EXIT) だが続行します"
    fi

    break
  done

  # 変更があればコミット
  if [ -n "$(git status --porcelain)" ]; then
    git add -A
    COMMIT_MSG="${COMMIT_PREFIX}(#${ISSUE_NUMBER}): ${STEP_NAME} - ${ISSUE_TITLE}"
    git commit -m "$COMMIT_MSG"
    echo "[runner] ✅ コミット: $COMMIT_MSG"
  else
    if [ "$SKIP_IF_NO_CHANGES" = "true" ]; then
      echo "[runner] ℹ️  変更なし、スキップ"
    else
      echo "[runner] ℹ️  変更なし"
    fi
  fi
done

# === 4. Push & PR 作成 ===
echo ""
echo "[runner] === Push & PR 作成 ==="
CURRENT_STEP="push-and-pr"

git push origin "$BRANCH_NAME"
echo "[runner] ✅ Push完了: $BRANCH_NAME"

# PR 作成
PR_BODY="## 概要
Issue #${ISSUE_NUMBER} の自動実装

## 変更内容
$(git log "${BASE_BRANCH}..HEAD" --pretty=format:'- %s' | head -20)

## パイプライン
- **パイプライン**: ${PIPELINE}
- **デフォルトモデル**: ${DEFAULT_MODEL}
- **実行日時**: $(date '+%Y-%m-%d %H:%M:%S')

---
🤖 [claude-pipeline](https://github.com/) で自動生成

Closes #${ISSUE_NUMBER}"

PR_URL=$(gh pr create \
  --repo "$REPO" \
  --title "Issue #${ISSUE_NUMBER}: ${ISSUE_TITLE}" \
  --body "$PR_BODY" \
  --base "$BASE_BRANCH" \
  --head "$BRANCH_NAME" 2>&1)

echo "[runner] ✅ PR作成: $PR_URL"

# === 5. Issue ラベル更新 ===
TRIGGER_LABEL=$(yq '.global.trigger_label // "auto-implement"' "$CONFIG")
DONE_LABEL=$(yq '.global.done_label // "auto-implemented"' "$CONFIG")

gh issue edit "$ISSUE_NUMBER" --repo "$REPO" \
  --remove-label "$TRIGGER_LABEL" \
  --add-label "$DONE_LABEL" 2>/dev/null || true

echo "[runner] ✅ ラベル更新: $TRIGGER_LABEL → $DONE_LABEL"

# === 6. ジョブ完了 ===
jq --arg ended_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg pr_url "$PR_URL" \
  '.status = "completed" | .ended_at = $ended_at | .pr_url = $pr_url' \
  "$JOB_FILE" > "${JOB_FILE}.tmp" && mv "${JOB_FILE}.tmp" "$JOB_FILE"

# === 7. Discord 通知 ===
if echo "$NOTIFY_ON" | grep -q "success"; then
  COMMITS=$(git log "${BASE_BRANCH}..HEAD" --pretty=format:'• %s' | head -10)
  "$SCRIPT_DIR/notifier.sh" "success" "$REPO" "$ISSUE_NUMBER" \
    "Issue #${ISSUE_NUMBER}: ${ISSUE_TITLE}\n\n**コミット:**\n${COMMITS}" \
    "$PR_URL" 2>/dev/null || true
fi

# === 8. ワークスペースのクリーンアップ ===
cd "$BASE_DIR"
rm -rf "$WORKSPACE_DIR"
echo "[runner] ✅ ワークスペースをクリーンアップ"

echo ""
echo "================================================================"
echo " パイプライン完了"
echo " PR: $PR_URL"
echo " 終了: $(date '+%Y-%m-%d %H:%M:%S')"
echo "================================================================"
