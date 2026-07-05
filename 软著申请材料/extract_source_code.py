#!/usr/bin/env python3
"""
从XIsland项目提取源代码
提取前1500行和后1500行，共3000行
"""

import os
import subprocess

# 配置
PROJECT_DIR = "/Users/meteor/github/xisland"
OUTPUT_FILE = "/Users/meteor/github/xisland/软著申请材料/source_code_full.txt"
SOFTWARE_NAME = "X Island"
VERSION = "V1.0.0"

# 目标行数
LINES_PER_PAGE = 50
PAGES_FRONT = 30
PAGES_BACK = 30
TOTAL_LINES = LINES_PER_PAGE * (PAGES_FRONT + PAGES_BACK)  # 3000行


def get_swift_files():
    """获取所有Swift文件"""
    result = subprocess.run(
        ["find", PROJECT_DIR, "-type", "f", "-name", "*.swift"],
        capture_output=True,
        text=True
    )
    files = result.stdout.strip().split('\n')

    # 过滤掉不需要的文件
    exclude_patterns = [
        'Tests/',
        'UITests/',
        'Pods/',
        '.build/',
        'DerivedData/',
        'xcuserdata/'
    ]

    filtered_files = []
    for f in files:
        if f and not any(pattern in f for pattern in exclude_patterns):
            filtered_files.append(f)

    return filtered_files


def read_file_content(filepath):
    """读取文件内容"""
    try:
        with open(filepath, 'r', encoding='utf-8') as f:
            return f.readlines()
    except Exception as e:
        print(f"  警告：无法读取 {filepath}: {e}")
        return []


def extract_code():
    """提取源代码"""
    print("开始提取源代码...")

    # 获取所有Swift文件
    swift_files = get_swift_files()
    print(f"找到 {len(swift_files)} 个Swift文件")

    # 读取所有代码
    all_lines = []
    for filepath in swift_files:
        # 计算相对路径
        rel_path = os.path.relpath(filepath, PROJECT_DIR)

        # 添加文件头注释（不增加空行）
        all_lines.append(f"// File: {rel_path}")

        # 读取文件内容
        lines = read_file_content(filepath)
        for line in lines:
            stripped = line.rstrip('\n')
            # 只添加非空行
            if stripped.strip():
                all_lines.append(stripped)

    print(f"总共读取到 {len(all_lines)} 行代码（已过滤空行）")

    # 提取前1500行和后1500行
    if len(all_lines) >= TOTAL_LINES:
        front_lines = all_lines[:LINES_PER_PAGE * PAGES_FRONT]
        back_lines = all_lines[-(LINES_PER_PAGE * PAGES_BACK):]
    else:
        # 如果代码不足3000行，全部使用
        front_lines = all_lines
        back_lines = []

    print(f"前30页：{len(front_lines)} 行")
    print(f"后30页：{len(back_lines)} 行")

    return front_lines, back_lines


def write_source_code(front_lines, back_lines):
    """写入源代码文件"""
    print(f"\n写入文件: {OUTPUT_FILE}")

    with open(OUTPUT_FILE, 'w', encoding='utf-8') as f:
        # 写入文件头
        f.write("=" * 80 + "\n")
        f.write("                        软件著作权登记申请 - 源代码文档\n")
        f.write("=" * 80 + "\n")
        f.write("\n")
        f.write(f"软件名称：{SOFTWARE_NAME}（{SOFTWARE_NAME}）\n")
        f.write(f"版本号：{VERSION}\n")
        f.write("开发完成日期：2026年6月\n")
        f.write("\n")

        # 写入前30页
        f.write("-" * 80 + "\n")
        f.write("                              前 30 页（第 1-1500 行）\n")
        f.write("-" * 80 + "\n")
        f.write("\n")

        for line in front_lines:
            f.write(line + "\n")

        # 写入后30页（如果有）
        if back_lines:
            f.write("\n")
            f.write("-" * 80 + "\n")
            f.write("                              后 30 页（最后 1500 行）\n")
            f.write("-" * 80 + "\n")
            f.write("\n")

            for line in back_lines:
                f.write(line + "\n")

    file_size = os.path.getsize(OUTPUT_FILE) / 1024
    print(f"文件大小: {file_size:.1f} KB")


def main():
    """主函数"""
    try:
        front_lines, back_lines = extract_code()
        write_source_code(front_lines, back_lines)

        print("\n✅ 源代码提取完成！")
        print(f"\n文件保存到: {OUTPUT_FILE}")
        print(f"总行数: {len(front_lines) + len(back_lines)} 行")

        return 0
    except Exception as e:
        print(f"\n❌ 提取失败: {e}")
        import traceback
        traceback.print_exc()
        return 1


if __name__ == "__main__":
    exit(main())
