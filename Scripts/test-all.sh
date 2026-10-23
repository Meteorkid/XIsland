#!/bin/bash
set -euo pipefail

###############################################################################
# X Island — 完整自动化测试入口
#
#   1. Swift 单元测试（swift test）
#   2. 集成测试（Scripts/test.sh，自行拉起隔离实例，不触碰生产 App 与用户数据）
#
# 说明：早期版本这里会先 pkill 掉正在运行的 X Island 再重启生产实例；
# 现在集成测试完全跑在隔离实例上（独立 runtime 目录 / defaults suite / socket），
# 因此不再需要、也不应该打扰用户正在使用的生产实例。
#
# 用法：
#   bash Scripts/test-all.sh
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_DIR"

echo "==> [1/2] Running Swift unit tests..."
swift test

echo ""
echo "==> [2/2] Running integration tests (isolated instance)..."
bash Scripts/test.sh

echo ""
echo "All automated tests passed."
