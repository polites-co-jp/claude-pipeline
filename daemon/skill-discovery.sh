#!/bin/bash
# skill-discovery.sh - 動的スキル発見・インストール
# 使用法: ./skill-discovery.sh <repo_dir> <repo_name> <issue_body>
# 出力: インストールされたスキル名（改行区切り）

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
SKILLS_CACHE_DIR="$BASE_DIR/skills/cache"
mkdir -p "$SKILLS_CACHE_DIR"

REPO_DIR="${1:?リポジトリディレクトリを指定してください}"
REPO_NAME="${2:?リポジトリ名を指定してください}"
ISSUE_BODY="${3:-}"

# スキル発見が有効か確認
DISCOVERY_ENABLED=$(yq '.global.skill_discovery.enabled // true' "$CONFIG")
if [ "$DISCOVERY_ENABLED" != "true" ]; then
  echo "[skill-discovery] スキル発見は無効です" >&2
  exit 0
fi

CACHE_TTL=$(yq '.global.skill_discovery.cache_ttl // 604800' "$CONFIG")
MAX_SKILLS=$(yq '.global.skill_discovery.max_skills_per_repo // 5' "$CONFIG")

# キャッシュファイル
SAFE_NAME=$(echo "$REPO_NAME" | sed 's/[^a-zA-Z0-9_-]/-/g')
CACHE_FILE="$SKILLS_CACHE_DIR/${SAFE_NAME}.yaml"

# キャッシュチェック
if [ -f "$CACHE_FILE" ]; then
  LAST_DISCOVERED=$(yq '.last_discovered // ""' "$CACHE_FILE")
  if [ -n "$LAST_DISCOVERED" ]; then
    CACHE_AGE=$(( $(date +%s) - $(date -d "$LAST_DISCOVERED" +%s 2>/dev/null || echo 0) ))
    if [ "$CACHE_AGE" -lt "$CACHE_TTL" ]; then
      echo "[skill-discovery] キャッシュ有効（${CACHE_AGE}秒前に発見済み）" >&2
      yq '.installed_skills[]' "$CACHE_FILE" 2>/dev/null || true
      exit 0
    fi
  fi
fi

echo "[skill-discovery] スキル発見を開始します: $REPO_NAME" >&2

# 1. 技術スタックの自動検出
TECH_STACK=""

if [ -f "$REPO_DIR/package.json" ]; then
  # Node.js プロジェクト
  DEPS=$(jq -r '(.dependencies // {}) + (.devDependencies // {}) | keys[]' "$REPO_DIR/package.json" 2>/dev/null | head -30 | tr '\n' ' ')
  TECH_STACK+=" nodejs $DEPS"
fi

if [ -f "$REPO_DIR/go.mod" ]; then
  TECH_STACK+=" go golang"
fi

if [ -f "$REPO_DIR/requirements.txt" ] || [ -f "$REPO_DIR/pyproject.toml" ]; then
  TECH_STACK+=" python"
  [ -f "$REPO_DIR/requirements.txt" ] && TECH_STACK+=" $(head -20 "$REPO_DIR/requirements.txt" | tr '\n' ' ')"
fi

if [ -f "$REPO_DIR/Cargo.toml" ]; then
  TECH_STACK+=" rust"
fi

if [ -f "$REPO_DIR/Gemfile" ]; then
  TECH_STACK+=" ruby"
fi

if [ -f "$REPO_DIR/pom.xml" ] || [ -f "$REPO_DIR/build.gradle" ]; then
  TECH_STACK+=" java"
fi

# フレームワーク特定
if echo "$TECH_STACK" | grep -qi "next"; then
  TECH_STACK+=" nextjs react"
fi
if echo "$TECH_STACK" | grep -qi "fastapi\|flask\|django"; then
  TECH_STACK+=" web-framework"
fi

echo "[skill-discovery] 検出された技術スタック: $TECH_STACK" >&2

if [ -z "$TECH_STACK" ]; then
  echo "[skill-discovery] 技術スタックを検出できませんでした" >&2
  exit 0
fi

# 2. Claude に検索クエリを生成させる
SEARCH_QUERIES=$(claude -p "
以下の技術スタック情報から、Claude Codeのスキル検索に使う検索クエリを最大3つ提案してください。
1行1クエリで出力してください。余計な説明は不要です。

技術スタック: ${TECH_STACK}
Issue内容: ${ISSUE_BODY:0:500}

例:
react performance
nextjs testing
api security
" --output-format text 2>/dev/null || echo "")

if [ -z "$SEARCH_QUERIES" ]; then
  echo "[skill-discovery] 検索クエリの生成に失敗しました" >&2
  exit 0
fi

echo "[skill-discovery] 検索クエリ:" >&2
echo "$SEARCH_QUERIES" >&2

# 3. スキル検索
SEARCH_RESULTS=""
while IFS= read -r query; do
  [ -z "$query" ] && continue
  RESULT=$(npx skills find "$query" 2>/dev/null || echo "")
  if [ -n "$RESULT" ]; then
    SEARCH_RESULTS+="### Query: $query"$'\n'
    SEARCH_RESULTS+="$RESULT"$'\n\n'
  fi
done <<< "$SEARCH_QUERIES"

if [ -z "$SEARCH_RESULTS" ]; then
  echo "[skill-discovery] スキルが見つかりませんでした" >&2
  exit 0
fi

# 4. Claude に最適なスキルを選定させる
TRUSTED_SOURCES=$(yq '.global.skill_discovery.trusted_sources[]' "$CONFIG" 2>/dev/null | tr '\n' ', ')

SKILLS_TO_INSTALL=$(claude -p "
以下のスキル検索結果から、このプロジェクトに最適なスキルを最大${MAX_SKILLS}つ選んでください。

## 選定基準
- インストール数が多いものを優先
- 以下のソースを信頼: ${TRUSTED_SOURCES}
- プロジェクトの技術スタックに合致するもの
- 重複する機能のスキルは1つだけ選ぶ

## 検索結果
${SEARCH_RESULTS}

## 技術スタック
${TECH_STACK}

## 出力形式
インストールコマンドで使うパッケージ名を1行1つで出力してください。
例: vercel-labs/skills/vercel-react-best-practices
何も適切なものがなければ none と出力してください。
" --output-format text 2>/dev/null || echo "none")

if [ "$SKILLS_TO_INSTALL" = "none" ] || [ -z "$SKILLS_TO_INSTALL" ]; then
  echo "[skill-discovery] 適切なスキルが見つかりませんでした" >&2
  # 空のキャッシュを作成
  cat > "$CACHE_FILE" <<EOF
last_discovered: "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
tech_stack: "$(echo "$TECH_STACK" | xargs)"
installed_skills: []
EOF
  exit 0
fi

# 5. スキルをインストール
INSTALLED=()
while IFS= read -r skill; do
  skill=$(echo "$skill" | xargs) # trim
  [ -z "$skill" ] && continue
  [ "$skill" = "none" ] && continue

  echo "[skill-discovery] スキルをインストール: $skill" >&2
  if npx skills add "$skill" -g -y 2>/dev/null; then
    INSTALLED+=("$skill")
    echo "[skill-discovery] ✅ インストール成功: $skill" >&2
  else
    echo "[skill-discovery] ⚠️ インストール失敗: $skill" >&2
  fi
done <<< "$SKILLS_TO_INSTALL"

# 6. キャッシュに記録
{
  echo "last_discovered: \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\""
  echo "tech_stack: \"$(echo "$TECH_STACK" | xargs)\""
  echo "installed_skills:"
  for s in "${INSTALLED[@]}"; do
    echo "  - \"$s\""
  done
} > "$CACHE_FILE"

# インストールされたスキル名を出力
for s in "${INSTALLED[@]}"; do
  echo "$s"
done

echo "[skill-discovery] スキル発見完了: ${#INSTALLED[@]}個インストール" >&2
