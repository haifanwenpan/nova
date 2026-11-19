#!/usr/bin/env python3
"""
bin2hex.py - 把 H.264 裸码流 (.264) 转成 nova testbench 使用的 hex 文本

原版 test/bin2hex.pl 有两个不便：
  1. 输出文件名硬编码为 akiyo300_1ref.txt（脚本第 8 行），只能生成一个文件；
  2. 每行写 2 字节，但没做奇数长度补齐，末行可能是 2 个 hex 字符而不是 4 个，
     导致 $readmemh 读到的最后一个 word 位宽不对。

本脚本保持相同的"每行一个 16bit word、大端序、高位在前"格式，但：
  - 输出路径可指定；
  - 若码流长度为奇数，末尾补 0x00 凑整（补的是填充字节，解码器读到 trailing 就停）；
  - 打印统计信息，便于核对。

用法:
    bin2hex.py <in.264> <out.txt>
    bin2hex.py <in.264>              # 默认输出 <in>.txt
"""
import sys
from pathlib import Path


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 1

    src = Path(sys.argv[1])
    dst = Path(sys.argv[2]) if len(sys.argv) > 2 else src.with_suffix(".txt")

    data = src.read_bytes()
    orig_len = len(data)
    if orig_len % 2:
        data += b"\x00"
        print(f"[bin2hex] 码流长度 {orig_len} 为奇数，末尾补 1 字节 0x00")

    with dst.open("w", encoding="ascii") as f:
        for i in range(0, len(data), 2):
            f.write(f"{data[i]:02X}{data[i + 1]:02X}\n")

    n_words = len(data) // 2
    print(f"[bin2hex] {src} -> {dst}")
    print(f"[bin2hex]   {orig_len} 字节 = {n_words} 个 16bit word = {n_words} 行")
    if n_words > 131072:
        print(f"[bin2hex]   警告: 超过 Beha_Bitstream_ram_size+1 = 131072 word，尾部会被截断")
    return 0


if __name__ == "__main__":
    sys.exit(main())
