#!/usr/bin/env python3
"""
检查代码行长度
"""

from docx import Document
import os

OUTPUT_FILE = "/Users/meteor/github/xisland/软著申请材料/XIsland_源代码文档.docx"


def check_line_length():
    """检查代码行长度"""
    print("检查代码行长度...")

    doc = Document(OUTPUT_FILE)

    # 统计信息
    total_lines = 0
    long_lines = []
    max_length = 0

    # 遍历所有段落
    for i, para in enumerate(doc.paragraphs):
        text = para.text.strip()
        if text and text[0].isdigit() and '  ' in text:
            total_lines += 1
            line_length = len(text)

            if line_length > max_length:
                max_length = line_length

            # 检查是否超过80个字符（可能导致换行）
            if line_length > 80:
                long_lines.append((i, line_length, text[:80]))

    print(f"\n=== 代码行统计 ===")
    print(f"总行数: {total_lines}")
    print(f"最大行长度: {max_length} 字符")
    print(f"超过80字符的行数: {len(long_lines)}")

    # 显示最长的10行
    if long_lines:
        print(f"\n=== 最长的10行 ===")
        # 按长度排序
        long_lines.sort(key=lambda x: x[1], reverse=True)
        for i, (pos, length, text) in enumerate(long_lines[:10]):
            print(f"{i+1}. 段落 {pos}: {length} 字符")
            print(f"   {text}...")
            print()


if __name__ == "__main__":
    check_line_length()
