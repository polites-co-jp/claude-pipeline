FROM node:20-slim

# 基本パッケージ
RUN apt-get update && apt-get install -y \
    git \
    curl \
    jq \
    cron \
    ca-certificates \
    dos2unix \
    && rm -rf /var/lib/apt/lists/*

# yq のインストール
RUN curl -sL "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64" -o /usr/local/bin/yq \
    && chmod +x /usr/local/bin/yq

# GitHub CLI のインストール
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    | tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
    && apt-get update \
    && apt-get install -y gh \
    && rm -rf /var/lib/apt/lists/*

# Claude Code CLI のインストール
RUN npm install -g @anthropic-ai/claude-code

# skills CLI のインストール
RUN npm install -g skills

# 作業ディレクトリ
WORKDIR /app

# スクリプトをコピー（context は claude-pipeline/ ルート）
COPY daemon/ ./daemon/
COPY pipelines/ ./pipelines/
COPY scripts/ ./scripts/
COPY config.yaml.example ./config.yaml.example
COPY .env.example ./.env.example

# CRLF → LF 変換（Windows環境でのビルド対応）& 実行権限
RUN dos2unix daemon/*.sh scripts/*.sh
RUN chmod +x daemon/*.sh scripts/*.sh

# ディレクトリ作成
RUN mkdir -p workspace/.queue workspace/.jobs workspace/.locks logs skills/cache

# エントリーポイント
COPY cp-containers/entrypoint.sh /docker-entrypoint.sh
RUN dos2unix /docker-entrypoint.sh && chmod +x /docker-entrypoint.sh

ENTRYPOINT ["/docker-entrypoint.sh"]
