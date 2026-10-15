#!/bin/sh
# 仅为当前构建进程设置工具路径；工具放在仓库忽略的构建目录内。
set -eu
project_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
tool_root=${XISLAND_TOOLCHAIN_ROOT:-"$project_root/.build/windows-toolchain"}
export CARGO_HOME="$tool_root/cargo"
export RUSTUP_HOME="$tool_root/rustup"
export CARGO_HTTP_MULTIPLEXING=false
export XWIN_CACHE_DIR="$tool_root/windows-sdk"
local_bin="$tool_root/tools/bin:$tool_root/cargo/bin"
local_lib=""
for package in llvm lld z3; do
  for version in "$tool_root/bottles/$package/"*; do
    if [ -d "$version/bin" ]; then local_bin="$local_bin:$version/bin"; fi
    if [ -d "$version/lib" ]; then local_lib="$local_lib:$version/lib"; fi
  done
done
for version in "$tool_root/bottles/makensis/"*; do
  if [ -d "$version/bin" ]; then
    local_bin="$local_bin:$version/bin"
    export NSISDIR="$version/share/nsis"
  fi
done
export PATH="$local_bin:$PATH"
# LLVM 的动态库只由各工具包装器加载，不能覆盖 Rust 自带的同名 LLVM 库。
export XISLAND_LLVM_LIBRARY_PATH="${local_lib#:}:/opt/homebrew/opt/zstd/lib"
exec "$@"
