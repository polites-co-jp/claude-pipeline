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
SPECIFIED_BRANCH=$(jq -r '.specified_branch // ""' "$JOB_FILE")

JOB_ID="${REPO_NAME}-${ISSUE_NUMBER}"
WORKSPACE_DIR="$BASE_DIR/workspace/${JOB_ID}"
PIPELINE_FILE="$BASE_DIR/pipelines/${PIPELINE}.yaml"
HISTORY_DIR="$BASE_DIR/workspace/.history/${REPO_NAME}"
HISTORY_MAX=100
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
echo " ベースブランチ: $BASE_BRANCH"
if [ -n "$SPECIFIED_BRANCH" ]; then
echo " 指定ブランチ: $SPECIFIED_BRANCH"
fi
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

# ブランチ戦略の決定
# 1. Issue 内でブランチが指定されている場合 → そのブランチをそのまま使用
# 2. 指定がない場合 → base_branch から feature/{issue_title_slug} ブランチを作成
if [ -n "$SPECIFIED_BRANCH" ]; then
  # Issue で指定されたブランチを使用
  # リモートに存在するか確認
  if git ls-remote --heads origin "$SPECIFIED_BRANCH" | grep -q "$SPECIFIED_BRANCH"; then
    git checkout "$SPECIFIED_BRANCH"
    echo "[runner] 指定ブランチにチェックアウト: $SPECIFIED_BRANCH"
  else
    # リモートに存在しない場合、ベースブランチから作成
    git checkout "$BASE_BRANCH"
    git checkout -b "$SPECIFIED_BRANCH"
    echo "[runner] 指定ブランチを新規作成: $SPECIFIED_BRANCH (from $BASE_BRANCH)"
  fi
  BRANCH_NAME="$SPECIFIED_BRANCH"
else
  # デフォルト: ベースブランチから feature ブランチを作成
  git checkout "$BASE_BRANCH"

  # Issue タイトルからブランチ名を生成（英数字・ハイフンに正規化）
  TITLE_SLUG=$(echo "$ISSUE_TITLE" | \
    tr '[:upper:]' '[:lower:]' | \
    sed 's/[^a-z0-9]/-/g' | \
    sed 's/--*/-/g' | \
    sed 's/^-//' | \
    sed 's/-$//' | \
    cut -c1-50)

  # スラッグが空の場合（日本語タイトル等）はIssue番号をフォールバック
  if [ -z "$TITLE_SLUG" ]; then
    TITLE_SLUG="issue-${ISSUE_NUMBER}"
  fi

  BRANCH_NAME="${BRANCH_PREFIX}${TITLE_SLUG}"
  git checkout -b "$BRANCH_NAME"
  echo "[runner] ブランチ作成: $BRANCH_NAME (from $BASE_BRANCH)"
fi

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

# --- ヘルパー関数: モデル解決 ---
resolve_model() {
  local step_index="$1"
  local step_name="$2"
  local model
  model=$(yq ".steps[$step_index].model // \"\"" "$PIPELINE_FILE")
  if [ -n "$model" ]; then
    echo "$model"
    return
  fi
  local name_upper
  name_upper=$(echo "$step_name" | tr '[:lower:]' '[:upper:]' | tr '-' '_')
  local env_var="CLAUDE_MODEL_${name_upper}"
  local env_model="${!env_var:-}"
  if [ -n "$env_model" ]; then
    echo "$env_model"
    return
  fi
  echo "$DEFAULT_MODEL"
}

# --- ヘルパー関数: プロンプト変数展開 ---
expand_prompt() {
  local template="$1"
  local prompt="$template"
  local git_diff_main
  git_diff_main=$(git diff "${BASE_BRANCH}...HEAD" 2>/dev/null || echo "(差分なし)")
  local git_diff_head
  git_diff_head=$(git diff HEAD~1 2>/dev/null || echo "(初回コミットのため差分なし)")

  prompt="${prompt//\{issue_number\}/$ISSUE_NUMBER}"
  prompt="${prompt//\{issue_title\}/$ISSUE_TITLE}"
  prompt="${prompt//\{issue_body\}/$ISSUE_BODY}"
  prompt="${prompt//\{git_diff\}/$git_diff_head}"
  prompt="${prompt//\{git_diff_from_main\}/$git_diff_main}"
  echo "$prompt"
}

# --- ヘルパー関数: Claude Code 実行 ---
run_claude() {
  local prompt="$1"
  local model="$2"
  local tools="$3"
  local turns="$4"

  echo "[runner] Claude Code を実行中... (model: $model, max_turns: $turns)"
  set +e
  local output
  output=$(claude -p "$prompt" \
    --model "$model" \
    --allowedTools "$tools" \
    --max-turns "$turns" \
    2>&1)
  local exit_code=$?
  set -e

  # 履歴を保存（RUN_CLAUDE_OUTPUT に格納、呼び出し元で参照）
  RUN_CLAUDE_OUTPUT="$output"

  echo "$output"
  return $exit_code
}

# --- ヘルパー関数: プロンプト・レスポンス履歴の保存 ---
save_history() {
  local step_name="$1"
  local model="$2"
  local prompt="$3"
  local response="$4"
  local exit_code="${5:-0}"
  local label="${6:-}"

  mkdir -p "$HISTORY_DIR"

  local timestamp
  timestamp=$(date -u +%Y%m%d-%H%M%S)
  local filename="${timestamp}_issue-${ISSUE_NUMBER}_${step_name}"
  [ -n "$label" ] && filename="${filename}_${label}"
  filename="${filename}.json"

  jq -n \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg repo "$REPO" \
    --arg repo_name "$REPO_NAME" \
    --argjson issue_number "$ISSUE_NUMBER" \
    --arg issue_title "$ISSUE_TITLE" \
    --arg step "$step_name" \
    --arg model "$model" \
    --arg prompt "$prompt" \
    --arg response "$response" \
    --argjson exit_code "$exit_code" \
    --arg label "$label" \
    '{
      timestamp: $ts,
      repo: $repo,
      repo_name: $repo_name,
      issue_number: $issue_number,
      issue_title: $issue_title,
      step: $step,
      label: $label,
      model: $model,
      exit_code: $exit_code,
      prompt: $prompt,
      response: $response
    }' > "$HISTORY_DIR/$filename"

  echo "[runner] 📄 履歴保存: $filename"

  # 古い履歴を削除（最大 HISTORY_MAX 件）
  local count
  count=$(ls -1 "$HISTORY_DIR" | wc -l)
  if [ "$count" -gt "$HISTORY_MAX" ]; then
    local to_delete=$((count - HISTORY_MAX))
    ls -1t "$HISTORY_DIR" | tail -n "$to_delete" | while IFS= read -r old_file; do
      rm -f "$HISTORY_DIR/$old_file"
    done
    echo "[runner] 🗑️ 古い履歴を ${to_delete} 件削除"
  fi
}

# --- ヘルパー関数: 変更のコミット & プッシュ ---
commit_if_changed() {
  local prefix="$1"
  local step_name="$2"
  local label="${3:-}"
  if [ -n "$(git status --porcelain)" ]; then
    git add -A
    local msg="${prefix}(#${ISSUE_NUMBER}): ${step_name} - ${ISSUE_TITLE}"
    [ -n "$label" ] && msg="${prefix}(#${ISSUE_NUMBER}): ${step_name} (${label}) - ${ISSUE_TITLE}"
    git commit -m "$msg"
    echo "[runner] ✅ コミット: $msg"
    git push -u origin "$BRANCH_NAME"
    echo "[runner] ✅ プッシュ: $BRANCH_NAME"
    return 0
  fi
  return 1
}

for i in $(seq 0 $((STEP_COUNT - 1))); do
  STEP_NAME=$(yq ".steps[$i].name" "$PIPELINE_FILE")
  STEP_DESC=$(yq ".steps[$i].description // \"\"" "$PIPELINE_FILE")
  REVIEW_MODE=$(yq ".steps[$i].review_mode // \"\"" "$PIPELINE_FILE")

  CURRENT_STEP="$STEP_NAME"

  echo ""
  echo "[runner] === Step $((i + 1))/${STEP_COUNT}: ${STEP_NAME} (${STEP_DESC}) ==="

  # ジョブステータスを更新
  jq --arg step "$STEP_NAME" '.current_step = $step' "$JOB_FILE" > "${JOB_FILE}.tmp" && mv "${JOB_FILE}.tmp" "$JOB_FILE"

  # ============================================================
  # review_mode: feedback_only — [実装→テスト→レビュー] ループ
  # ============================================================
  if [ "$REVIEW_MODE" = "feedback_only" ]; then
    MAX_ITERATIONS=$(yq ".steps[$i].max_iterations // 3" "$PIPELINE_FILE")
    REVIEW_TARGET=$(yq ".steps[$i].review_target // \"implement\"" "$PIPELINE_FILE")
    REVIEW_TOOLS=$(yq ".steps[$i].allowed_tools // \"Glob,Grep,Read\"" "$PIPELINE_FILE")
    REVIEW_TURNS=$(yq ".steps[$i].max_turns // 30" "$PIPELINE_FILE")
    REVIEW_MODEL=$(resolve_model "$i" "$STEP_NAME")

    # レビュー対象ステップの情報を取得（再実装用）
    TARGET_INDEX=""
    for ti in $(seq 0 $((STEP_COUNT - 1))); do
      if [ "$(yq ".steps[$ti].name" "$PIPELINE_FILE")" = "$REVIEW_TARGET" ]; then
        TARGET_INDEX="$ti"
        break
      fi
    done

    if [ -z "$TARGET_INDEX" ]; then
      echo "[runner] ❌ review_target '$REVIEW_TARGET' が見つかりません"
      exit 1
    fi

    IMPL_MODEL=$(resolve_model "$TARGET_INDEX" "$REVIEW_TARGET")
    IMPL_TOOLS=$(yq ".steps[$TARGET_INDEX].allowed_tools // \"Edit,Write,Bash,Glob,Grep,Read\"" "$PIPELINE_FILE")
    IMPL_TURNS=$(yq ".steps[$TARGET_INDEX].max_turns // 50" "$PIPELINE_FILE")
    IMPL_PREFIX=$(yq ".steps[$TARGET_INDEX].commit_prefix // \"feat\"" "$PIPELINE_FILE")
    REIMPL_TEMPLATE=$(yq ".steps[$i].reimpl_prompt_template // \"\"" "$PIPELINE_FILE")

    # テスト設定の読み込み
    TEST_BEFORE_REVIEW=$(yq ".steps[$i].test_before_review // false" "$PIPELINE_FILE")
    if [ "$TEST_BEFORE_REVIEW" = "true" ]; then
      TEST_PROMPT_TEMPLATE=$(yq ".steps[$i].test_prompt_template" "$PIPELINE_FILE")
      TEST_TOOLS=$(yq ".steps[$i].test_allowed_tools // \"Edit,Write,Bash,Glob,Grep,Read\"" "$PIPELINE_FILE")
      TEST_TURNS=$(yq ".steps[$i].test_max_turns // 40" "$PIPELINE_FILE")
      TEST_PREFIX=$(yq ".steps[$i].test_commit_prefix // \"test\"" "$PIPELINE_FILE")
      TEST_MODEL=$(resolve_model "$i" "test")
      # 環境変数 CLAUDE_MODEL_TEST があればそちらを優先
      if [ -n "${CLAUDE_MODEL_TEST:-}" ]; then
        TEST_MODEL="$CLAUDE_MODEL_TEST"
      fi
      TEST_FIX_MAX_RETRIES=$(yq ".steps[$i].test_fix_max_retries // 5" "$PIPELINE_FILE")
      TEST_FIX_TEMPLATE=$(yq ".steps[$i].test_fix_prompt_template // \"\"" "$PIPELINE_FILE")
      TEST_FIX_TOOLS=$(yq ".steps[$i].test_fix_allowed_tools // \"Edit,Write,Bash,Glob,Grep,Read\"" "$PIPELINE_FILE")
      TEST_FIX_TURNS=$(yq ".steps[$i].test_fix_max_turns // 40" "$PIPELINE_FILE")
      TEST_FIX_PREFIX=$(yq ".steps[$i].test_fix_commit_prefix // \"fix\"" "$PIPELINE_FILE")
    fi

    for iteration in $(seq 1 "$MAX_ITERATIONS"); do
      echo ""
      echo "[runner] === イテレーション ${iteration}/${MAX_ITERATIONS} ==="

      # -------------------------------------------------------
      # Phase 1: テストコード実装 & テスト実施
      # -------------------------------------------------------
      if [ "$TEST_BEFORE_REVIEW" = "true" ]; then
        CURRENT_STEP="test (iteration ${iteration})"
        echo "[runner] 🧪 テストコード実装 & テスト実施..."

        TEST_PROMPT=$(expand_prompt "$TEST_PROMPT_TEMPLATE")

        set +e
        TEST_OUTPUT=$(run_claude "$TEST_PROMPT" "$TEST_MODEL" "$TEST_TOOLS" "$TEST_TURNS")
        TEST_EXIT=$?
        set -e

        echo "$TEST_OUTPUT"

        # テスト履歴を保存
        save_history "test" "$TEST_MODEL" "$TEST_PROMPT" "$TEST_OUTPUT" "$TEST_EXIT" "iteration-${iteration}"

        # テスト変更をコミット
        commit_if_changed "$TEST_PREFIX" "test" "iteration ${iteration}" || echo "[runner] ℹ️  テストで変更なし"

        # Phase 1.5: テスト失敗時の実装修正ループ（最大 test_fix_max_retries 回、超過で失敗終了）
        if [ "$TEST_EXIT" -ne 0 ]; then
          LAST_TEST_OUTPUT="$TEST_OUTPUT"

          for fix_attempt in $(seq 1 "$TEST_FIX_MAX_RETRIES"); do
            echo ""
            echo "[runner] 🔧 テスト失敗 → 実装修正 (リトライ ${fix_attempt}/${TEST_FIX_MAX_RETRIES})"
            CURRENT_STEP="test-fix (iteration ${iteration}, retry ${fix_attempt})"

            # 実装修正プロンプトを構築
            FIX_PROMPT=$(expand_prompt "$TEST_FIX_TEMPLATE")
            FIX_PROMPT="${FIX_PROMPT//\{test_output\}/$LAST_TEST_OUTPUT}"

            set +e
            FIX_OUTPUT=$(run_claude "$FIX_PROMPT" "$IMPL_MODEL" "$TEST_FIX_TOOLS" "$TEST_FIX_TURNS")
            FIX_EXIT=$?
            set -e

            echo "$FIX_OUTPUT"

            # 実装修正履歴を保存
            save_history "test-fix" "$IMPL_MODEL" "$FIX_PROMPT" "$FIX_OUTPUT" "$FIX_EXIT" "iteration-${iteration}-retry-${fix_attempt}"

            # 実装修正の変更をコミット
            commit_if_changed "$TEST_FIX_PREFIX" "test-fix" "iteration ${iteration} retry ${fix_attempt}" || echo "[runner] ℹ️  実装修正で変更なし"

            # 修正が成功した場合（Claude が正常終了）はテスト通過とみなす
            if [ "$FIX_EXIT" -eq 0 ]; then
              echo "[runner] ✅ 実装修正 & テスト通過 (リトライ ${fix_attempt})"
              TEST_EXIT=0
              break
            fi

            LAST_TEST_OUTPUT="$FIX_OUTPUT"
            echo "[runner] ⚠️ 実装修正後もテスト失敗 (exit: $FIX_EXIT)"
          done

          # リトライ上限に達してもテスト未通過 → パイプライン失敗
          if [ "$TEST_EXIT" -ne 0 ]; then
            CURRENT_STEP="test-fix (iteration ${iteration})"
            echo "[runner] ❌ テスト修正が ${TEST_FIX_MAX_RETRIES} 回失敗しました。パイプラインを失敗終了します"
            exit 1
          fi
        fi
      fi

      # -------------------------------------------------------
      # Phase 2: レビュー（読み取り専用）
      # -------------------------------------------------------
      CURRENT_STEP="review (iteration ${iteration})"

      REVIEW_PROMPT_TEMPLATE=$(yq ".steps[$i].prompt_template" "$PIPELINE_FILE")
      REVIEW_PROMPT=$(expand_prompt "$REVIEW_PROMPT_TEMPLATE")

      echo "[runner] 📝 レビュー実行中..."
      set +e
      REVIEW_OUTPUT=$(run_claude "$REVIEW_PROMPT" "$REVIEW_MODEL" "$REVIEW_TOOLS" "$REVIEW_TURNS")
      REVIEW_EXIT=$?
      set -e

      echo "$REVIEW_OUTPUT"

      # レビュー履歴を保存
      save_history "review" "$REVIEW_MODEL" "$REVIEW_PROMPT" "$REVIEW_OUTPUT" "$REVIEW_EXIT" "iteration-${iteration}"

      if [ $REVIEW_EXIT -ne 0 ]; then
        echo "[runner] ⚠️ レビューがエラーで終了 (exit: $REVIEW_EXIT) だが続行します"
      fi

      # レビュー結果の判定: LGTM なら問題なし
      FIRST_LINE=$(echo "$REVIEW_OUTPUT" | grep -E '^\s*(LGTM|NEEDS_FIX)' | head -1 | tr -d '[:space:]')

      if [ "$FIRST_LINE" = "LGTM" ]; then
        echo "[runner] ✅ レビュー通過 (LGTM) — イテレーション ${iteration} で完了"
        break
      fi

      echo "[runner] 🔄 レビューで問題を検出"

      # 最終イテレーションの場合は再実装せず警告のみ
      if [ "$iteration" -eq "$MAX_ITERATIONS" ]; then
        echo "[runner] ⚠️ 最大イテレーション (${MAX_ITERATIONS}) に達しました。レビュー指摘が残っている可能性があります"
        break
      fi

      # -------------------------------------------------------
      # Phase 3: レビュー指摘に基づく再実装
      # -------------------------------------------------------
      CURRENT_STEP="reimpl (iteration ${iteration})"
      REIMPL_PROMPT=$(expand_prompt "$REIMPL_TEMPLATE")
      REIMPL_PROMPT="${REIMPL_PROMPT//\{review_feedback\}/$REVIEW_OUTPUT}"

      echo "[runner] 🔧 再実装実行中..."
      set +e
      run_claude "$REIMPL_PROMPT" "$IMPL_MODEL" "$IMPL_TOOLS" "$IMPL_TURNS"
      REIMPL_EXIT=$?
      set -e

      # 再実装履歴を保存
      save_history "reimpl" "$IMPL_MODEL" "$REIMPL_PROMPT" "$RUN_CLAUDE_OUTPUT" "$REIMPL_EXIT" "iteration-${iteration}"

      if [ $REIMPL_EXIT -ne 0 ]; then
        echo "[runner] ⚠️ 再実装がエラーで終了 (exit: $REIMPL_EXIT) だが続行します"
      fi

      # 再実装の変更をコミット
      commit_if_changed "$IMPL_PREFIX" "$REVIEW_TARGET" "review fix ${iteration}" || echo "[runner] ℹ️  再実装で変更なし"

      # 次のイテレーションで再度テスト→レビューが実行される
    done

    continue
  fi

  # ============================================================
  # 通常ステップの実行
  # ============================================================
  COMMIT_PREFIX=$(yq ".steps[$i].commit_prefix // \"chore\"" "$PIPELINE_FILE")
  ALLOWED_TOOLS=$(yq ".steps[$i].allowed_tools // \"Edit,Write,Bash,Glob,Grep,Read\"" "$PIPELINE_FILE")
  MAX_TURNS=$(yq ".steps[$i].max_turns // 30" "$PIPELINE_FILE")
  SKIP_IF_NO_CHANGES=$(yq ".steps[$i].skip_if_no_changes // false" "$PIPELINE_FILE")
  RETRY_ON_TEST_FAILURE=$(yq ".steps[$i].retry_on_test_failure // 0" "$PIPELINE_FILE")
  CURRENT_MODEL=$(resolve_model "$i" "$STEP_NAME")

  # プロンプトテンプレートの取得と変数展開
  PROMPT_TEMPLATE=$(yq ".steps[$i].prompt_template" "$PIPELINE_FILE")
  PROMPT=$(expand_prompt "$PROMPT_TEMPLATE")

  # Claude Code で実行
  ATTEMPT=0
  MAX_ATTEMPTS=$((RETRY_ON_TEST_FAILURE + 1))

  while [ "$ATTEMPT" -lt "$MAX_ATTEMPTS" ]; do
    ATTEMPT=$((ATTEMPT + 1))

    if [ "$ATTEMPT" -gt 1 ]; then
      echo "[runner] リトライ ${ATTEMPT}/${MAX_ATTEMPTS}"
      PROMPT="$PROMPT

前回の実行でテストが失敗しました。テストの失敗を修正してください。"
    fi

    echo "[runner] Claude Code を実行中... (model: $CURRENT_MODEL, max_turns: $MAX_TURNS)"

    set +e
    STEP_OUTPUT=$(run_claude "$PROMPT" "$CURRENT_MODEL" "$ALLOWED_TOOLS" "$MAX_TURNS")
    CLAUDE_EXIT=$?
    set -e

    echo "$STEP_OUTPUT"

    # 履歴を保存
    retry_label=""
    [ "$ATTEMPT" -gt 1 ] && retry_label="retry-${ATTEMPT}"
    save_history "$STEP_NAME" "$CURRENT_MODEL" "$PROMPT" "$STEP_OUTPUT" "$CLAUDE_EXIT" "$retry_label"

    if [ "$CLAUDE_EXIT" -ne 0 ] && [ "$RETRY_ON_TEST_FAILURE" -gt 0 ] && [ "$ATTEMPT" -lt "$MAX_ATTEMPTS" ]; then
      echo "[runner] ⚠️ Claude Code がエラーで終了 (exit: $CLAUDE_EXIT)。リトライします"
      continue
    elif [ "$CLAUDE_EXIT" -ne 0 ] && [ "$RETRY_ON_TEST_FAILURE" -eq 0 ]; then
      echo "[runner] ⚠️ Claude Code がエラーで終了 (exit: $CLAUDE_EXIT) だが続行します"
    fi

    break
  done

  # 変更があればコミット & プッシュ
  if [ -n "$(git status --porcelain)" ]; then
    git add -A
    COMMIT_MSG="${COMMIT_PREFIX}(#${ISSUE_NUMBER}): ${STEP_NAME} - ${ISSUE_TITLE}"
    git commit -m "$COMMIT_MSG"
    echo "[runner] ✅ コミット: $COMMIT_MSG"
    git push -u origin "$BRANCH_NAME"
    echo "[runner] ✅ プッシュ: $BRANCH_NAME"
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
echo "[runner] === PR 作成 ==="
CURRENT_STEP="push-and-pr"

# 各ステップで都度プッシュ済みだが、未プッシュのコミットがあれば最終プッシュ
if [ -n "$(git log origin/$BRANCH_NAME..HEAD 2>/dev/null)" ]; then
  git push -u origin "$BRANCH_NAME"
  echo "[runner] ✅ 最終Push完了: $BRANCH_NAME"
else
  echo "[runner] ℹ️  全コミットはプッシュ済み"
fi

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
