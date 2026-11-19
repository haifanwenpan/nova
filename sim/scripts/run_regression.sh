#!/bin/bash
#---------------------------------------------------------------------------------------------------
# run_regression.sh - nova 解码器一键回归：编码/参考/仿真/比对
#
# 完整流程
#   1. 准备码流: 若有 .264 就用它；否则用 ffmpeg 从原始 YUV 现编一个 baseline 码流
#   2. 生成 hex: 用 bin2hex.py 把 .264 转成 $readmemh 能读的文本
#   3. 生成参考: ffmpeg 解码同一码流得到 YUV420p（这是"金标准"）
#   4. 编译 RTL: iverilog 编译 tb_nova + sim/rtl/*.v
#   5. 跑仿真:   vvp 输出 nova 的 YUV420p
#   6. 比对:     compare_yuv.py 逐像素比对，maxdiff 必须为 0
#
# 用法
#   ./run_regression.sh                       # 默认用仓库自带 akiyo 码流，跑 10 帧
#   ./run_regression.sh -n 300                # 跑 300 帧
#   ./run_regression.sh -b my.264 -n 50       # 指定码流
#   ./run_regression.sh --nodb                # 关闭去块滤波（看 DF 的效果）
#   ./run_regression.sh --encode              # 先用 ffmpeg 现编一个 baseline 码流再跑
#---------------------------------------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SIM_DIR="$(dirname "$HERE")"
NOVA_DIR="$(dirname "$SIM_DIR")"
cd "$SIM_DIR"

BITSTREAM="$NOVA_DIR/test/bitstream/akiyo300_1ref.txt"
FRAMES=10
FREQ=1
NODB=0
DO_ENCODE=0
ENCODE_SRC=""
TAG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -b|--bitstream) BITSTREAM="$2"; shift 2 ;;
    -n|--frames)    FRAMES="$2";    shift 2 ;;
    -f|--freq)      FREQ="$2";      shift 2 ;;
    -t|--tag)       TAG="$2";       shift 2 ;;
    --nodb)         NODB=1;         shift ;;
    --encode)       DO_ENCODE=1;    shift ;;
    --encode-from)  DO_ENCODE=1; ENCODE_SRC="$2"; shift 2 ;;
    -h|--help)      sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "未知参数: $1"; exit 1 ;;
  esac
done

[[ -n "$TAG" ]] || TAG="run$( [[ $NODB -eq 1 ]] && echo _nodb || echo '' )"

mkdir -p out vectors
LOG="out/${TAG}.log"
: > "$LOG"
say() { echo "$@" | tee -a "$LOG"; }

say "=============================================================="
say " nova 回归测试    $(date '+%Y-%m-%d %H:%M:%S')"
say "   帧数=$FRAMES  freq=$FREQ  DF=$([[ $NODB -eq 1 ]] && echo off || echo on)"
say "=============================================================="

#-------------------------------------------------------------------------------------------
# 1. 准备码流
#-------------------------------------------------------------------------------------------
if [[ $DO_ENCODE -eq 1 ]]; then
  if [[ -z "$ENCODE_SRC" ]]; then
    # 没有源 YUV 就用 ffmpeg 的 testsrc 生成 30 帧 QCIF
    ENCODE_SRC="vectors/testsrc_qcif.yuv"
    if [[ ! -f "$ENCODE_SRC" ]]; then
      say "[1/6] 生成测试序列 testsrc QCIF 300 帧 ..."
      ffmpeg -hide_banner -loglevel error -f lavfi -i "testsrc=size=176x144:rate=30:duration=10" \
             -pix_fmt yuv420p -f rawvideo "$ENCODE_SRC" 2>&1 | tee -a "$LOG"
    fi
  fi
  say "[1/6] ffmpeg 编码 baseline 码流 (QP=28, 单参考帧, 无 B 帧) ..."
  RAW264="vectors/$(basename "${ENCODE_SRC%.*}").264"
  ffmpeg -hide_banner -loglevel error -y -f rawvideo -pix_fmt yuv420p -s 176x144 -r 30 \
         -i "$ENCODE_SRC" -c:v libx264 -profile:v baseline -level 1.0 \
         -x264-params "keyint=30:min-keyint=30:ref=1:slices=1" -qp 28 \
         -f h264 "$RAW264" 2>&1 | tee -a "$LOG"
  HEX="${RAW264%.264}.txt"
  python3 scripts/bin2hex.py "$RAW264" "$HEX" 2>&1 | tee -a "$LOG"
  BITSTREAM="$HEX"
  REF_YUV="vectors/$(basename "${ENCODE_SRC%.*}")_ref.yuv"
  say "[2/6] ffmpeg 解码同一码流，生成参考 YUV ..."
  ffmpeg -hide_banner -loglevel error -y -i "$RAW264" -f rawvideo -pix_fmt yuv420p "$REF_YUV" \
         2>&1 | tee -a "$LOG"
else
  if [[ ! -f "$BITSTREAM" ]]; then
    say "错误: 找不到码流 $BITSTREAM"
    exit 1
  fi

  # 支持两种输入：直接的 .264 裸码流，或已转好的 $readmemh hex 文本
  if [[ "$BITSTREAM" == *.264 || "$BITSTREAM" == *.h264 ]]; then
    RAW264="$BITSTREAM"
    HEX="out/${TAG}_from264.txt"
    say "[1/6] 输入为 .264 裸码流，先转成 hex 文本 ..."
    python3 scripts/bin2hex.py "$RAW264" "$HEX" 2>&1 | tee -a "$LOG"
    BITSTREAM="$HEX"
  else
    say "[1/6] 使用已有 hex 码流: $BITSTREAM"
    # 从 hex 文本还原出 .264，供 ffmpeg 做参考解码
    RAW264="out/${TAG}_from_hex.264"
  python3 - "$BITSTREAM" "$RAW264" <<'PY' 2>&1 | tee -a "$LOG"
import sys, pathlib
src, dst = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
words = [ln.strip() for ln in src.read_text().splitlines() if ln.strip()]
data = bytearray()
for w in words:
    w = w.zfill(4)
    data += bytes((int(w[0:2], 16), int(w[2:4], 16)))
dst.write_bytes(bytes(data))
print(f"[hex2bin] {src.name} -> {dst.name}  ({len(words)} word, {len(data)} 字节)")
PY
  fi

  REF_YUV="out/${TAG}_ref.yuv"
  say "[2/6] ffmpeg 解码生成参考 YUV ..."
  ffmpeg -hide_banner -loglevel error -y -i "$RAW264" -f rawvideo -pix_fmt yuv420p "$REF_YUV" \
         2>&1 | tee -a "$LOG"
fi

#-------------------------------------------------------------------------------------------
# 2. 编译
#-------------------------------------------------------------------------------------------
say "[3/6] 编译 RTL (iverilog) ..."
BUILD_LOG="out/${TAG}_build.log"
iverilog -g2005 -o "out/nova_tb.vvp" -s tb_nova -I rtl tb/tb_nova.v rtl/*.v \
    > "$BUILD_LOG" 2>&1
rc=$?
# timescale 继承告警是 iverilog 的固有噪音，过滤掉看真实问题
grep -v -i "inherited from another\|The inherited timescale\|sorry: implicit\|implicit definition" \
     "$BUILD_LOG" > "${BUILD_LOG}.filtered" || true
if [[ $rc -ne 0 ]]; then
  say "      编译失败，错误如下:"
  cat "${BUILD_LOG}.filtered" | tee -a "$LOG"
  exit 1
fi
nwarn=$(wc -l < "${BUILD_LOG}.filtered")
say "      编译成功（$nwarn 条非 timescale 提示，详见 $BUILD_LOG.filtered）"

#-------------------------------------------------------------------------------------------
# 3. 仿真
#-------------------------------------------------------------------------------------------
NOVA_YUV="out/${TAG}_nova.yuv"
say "[4/6] 运行仿真 ($FRAMES 帧) ..."
EXTRA=""
[[ $NODB -eq 1 ]] && EXTRA="+nodb"
START=$(date +%s)
vvp out/nova_tb.vvp \
    +bitstream="$BITSTREAM" \
    +out="$NOVA_YUV" \
    +frames="$FRAMES" \
    +freq="$FREQ" \
    +maxcyc=$(( FRAMES * 120000 + 200000 )) \
    $EXTRA 2>&1 | grep -v "screen size is bogus" | tee -a "$LOG" | tail -6
END=$(date +%s)
say "      仿真耗时 $((END-START)) 秒"

if [[ ! -s "$NOVA_YUV" ]]; then
  say "错误: 没有产生输出 $NOVA_YUV"
  exit 1
fi

#-------------------------------------------------------------------------------------------
# 4. 比对
#-------------------------------------------------------------------------------------------
say "[5/6] 逐像素比对 ..."
python3 scripts/compare_yuv.py "$NOVA_YUV" "$REF_YUV" --frames "$FRAMES" \
    --quiet $([[ $NODB -eq 1 ]] && echo "" ) 2>&1 | tee -a "$LOG"
CMP_RC=${PIPESTATUS[0]}

#-------------------------------------------------------------------------------------------
# 5. 掉帧检查
#-------------------------------------------------------------------------------------------
say "[6/6] 完整性检查 ..."
python3 - "$NOVA_YUV" "$REF_YUV" "$FRAMES" <<'PY' 2>&1 | tee -a "$LOG"
import sys, pathlib
frame = 176*144*3//2
nova = pathlib.Path(sys.argv[1]).stat().st_size // frame
ref  = pathlib.Path(sys.argv[2]).stat().st_size // frame
want = int(sys.argv[3])
print(f"[check] nova 输出 {nova} 帧 / 参考序列共 {ref} 帧 / 请求 {want} 帧")
if nova < min(want, ref):
    print(f"[check] 失败: 少解了 {min(want, ref) - nova} 帧")
    sys.exit(2)
print("[check] 帧数完整")
PY
CHK_RC=$?

say "=============================================================="
if [[ $CMP_RC -eq 0 && $CHK_RC -eq 0 ]]; then
  say " 结果: PASS"
  say "=============================================================="
  exit 0
else
  say " 结果: FAIL (compare=$CMP_RC check=$CHK_RC)"
  say "=============================================================="
  exit 1
fi
