#!/usr/bin/env bash
# 把 vault (lb) 真实复制进 content/ 再同步到 GitHub。
# 不再用符号链接：content 一旦是真实目录，ln -snf 会在里面嵌套出 content/lb。
set -euo pipefail

cd "$(dirname "$0")"
VAULT="/Users/joker/Library/Mobile Documents/iCloud~md~obsidian/Documents/juwiki/lb"

[ -d "$VAULT" ] || { echo "vault not found: $VAULT" >&2; exit 1; }

# 清掉旧的符号链接（如果有）
[ -L content ] && rm content
mkdir -p content

# --delete: vault 里删掉的笔记，站点里也跟着删
# 排除：vault 自带的 git、Obsidian/插件配置（含明文 API Key）、本地 AI 配置、图片资源 Assert（与 .gitignore 一致）
rsync -a --delete \
  --exclude='.git' \
  --exclude='.obsidian' \
  --exclude='.makemd' \
  --exclude='.space' \
  --exclude='.trash' \
  --exclude='.claude' \
  --exclude='.gitignore' \
  --exclude='.DS_Store' \
  --exclude='CLAUDE.md' \
  --exclude='AGENTS.md' \
  --exclude='Assert' \
  "$VAULT/" content/

# 没有首页就别推，避免再出一次 404
[ -f content/index.md ] || { echo "content/index.md missing, abort" >&2; exit 1; }

npx quartz sync --no-pull
