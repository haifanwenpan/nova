#!/bin/bash
#---------------------------------------------------------------------------------------------------
# setup_rtl.sh - 从原始 src/ 复制 RTL 到 sim/rtl 并打上必需的位宽修复补丁
#
# 为什么需要这一步：
#   nova 源码写于 2005-2008 年，使用较老的 Verilog-2001 风格。其中两处用了
#     {expr + 1}
#   这种"未定宽表达式放进拼接"的写法，在 iverilog 12 下会报
#     error: Concatenation operand "(...) + ('sd1)" has indefinite width.
#   语义上原作者期望的是 32bit 自增后截断，改成显式位宽常量即可，功能不变。
#   为保持 src/ 原样（便于对照阅读），补丁只作用于 sim/rtl 副本。
#---------------------------------------------------------------------------------------------------
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SIM_DIR="$(dirname "$HERE")"
NOVA_DIR="$(dirname "$SIM_DIR")"
SRC_DIR="$NOVA_DIR/src"
RTL_DIR="$SIM_DIR/rtl"

echo "[setup] src = $SRC_DIR"
echo "[setup] rtl = $RTL_DIR"

rm -rf "$RTL_DIR"
mkdir -p "$RTL_DIR"
cp "$SRC_DIR"/*.v "$RTL_DIR"/

# ---- 补丁 1/2: pc_decoding.v 的 trailing_bits / pcm_alignment 指针进位 ----
python3 - "$RTL_DIR" <<'PY'
import sys, re, pathlib
rtl = pathlib.Path(sys.argv[1])

# 1) pc_decoding.v : {{pc_reg[6:3] + 1},3'b0}  ->  {{pc_reg[6:3] + 4'd1},3'b0}
p = rtl / "pc_decoding.v"
s = p.read_text()
n = s.count("{{pc_reg[6:3] + 1},3'b0}")
s = s.replace("{{pc_reg[6:3] + 1},3'b0}", "{{pc_reg[6:3] + 4'd1},3'b0}")
p.write_text(s)
print(f"[patch] pc_decoding.v           : {n} 处拼接位宽修复")

# 2) Intra_pred_pipeline.v : {(mb_num_h + 1),2'b0} -> {(mb_num_h + 4'd1),2'b0}
p = rtl / "Intra_pred_pipeline.v"
s = p.read_text()
n = s.count("{(mb_num_h + 1),2'b0}")
s = s.replace("{(mb_num_h + 1),2'b0}", "{(mb_num_h + 4'd1),2'b0}")
p.write_text(s)
print(f"[patch] Intra_pred_pipeline.v   : {n} 处拼接位宽修复")

# 3) Beha_BitStream_ram.v 里硬编码的 Windows 绝对路径改成可由 plusarg 覆盖
#    真正运行用的是 tb_nova.v 自带的 ROM 模型，这个文件只是保留供参考，
#    但仍改掉以免误用时读不到文件。
p = rtl / "Beha_BitStream_ram.v"
if p.exists():
    s = p.read_text()
    s2 = re.sub(r'\$readmemh\("[^"]*"', '$readmemh("nova_bitstream.txt"', s)
    if s2 != s:
        p.write_text(s2)
        print("[patch] Beha_BitStream_ram.v    : 硬编码路径 -> 相对路径")
PY

echo "[setup] RTL 副本就绪: $(ls "$RTL_DIR"/*.v | wc -l) 个文件"
