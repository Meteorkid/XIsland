#!/usr/bin/env python3
"""
检查实际代码内容长度（不包括行号）
"""

from docx import Document
import os

OUTPUT_FILE = "/Users/meteor/github/xisland/软著申请材料/XIsland_源代码文档.docx"


def check_actual_code_length():
    """检查实际代码内容长度"""
    print("检查实际代码内容长度...")

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

            # 移除行号（前4位数字和2个空格）
            if len(text) > 6:
                code_content = text[6:]  # 移除行号 "1234  "
                code_length = len(code_content)

                if code_length > max_length:
                    max_length = code_length

                # 检查是否超过74个字符（80 - 6行号 = 74）
                if code_length > 74:
                    long_lines.append((i, code_length, code_content[:80]))

    print(f"\n=== 代码内容统计 ===")
    print(f"总行数: {total_lines}")
    print(f"最大代码长度: {max_length} 字符")
    print(f"超过74字符的行数: {len(long_lines)}")

    # 显示最长的10行
    if long_lines:
        print(f"\n=== 最长的10行（不含行号）===")
        # 按长度排序
        long_lines.sort(key=lambda x: x[1], reverse=True)
        for i, (pos, length, text) in enumerate(long_lines[:10]):
            print(f"{i+1}. 段落 {pos}: {length} 字符")
            print(f"   {text}...")
            print()


if __name__ == "__main__":
    check_actual_code_length()
