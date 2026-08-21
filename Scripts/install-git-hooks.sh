#!/bin/bash
# 安装 git pre-commit hook，指向仓库内自带的测试脚本。
# 通过设置 core.hooksPath 指向 .githooks 目录，避免在 .git/hooks 里维护软链。
set -euo pipefail

# 脚本所在目录（Scripts/），向上即仓库根。
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_DIR"

# 确保 hooks 目录存在，并让 pre-commit 具备可执行权限。
mkdir -p .githooks
chmod +x .githooks/pre-commit

# 用相对路径注册，便于整个仓库随位置迁移。
git config core.hooksPath .githooks

echo "Git hooks installed."
echo "Pre-commit now runs: bash Scripts/test-all.sh"
