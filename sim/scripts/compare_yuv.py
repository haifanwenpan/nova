#!/usr/bin/env python3
"""
compare_yuv.py - 逐帧比对 nova 仿真输出与 ffmpeg 参考解码输出

为什么需要严格比对：
  H.264 解码器是"比特精确"的规范 —— 给定同一码流，任何符合标准的解码器
  在 IDCT、帧内/帧间预测、去块滤波上都必须产生完全相同的像素值
  （标准只允许在 IDCT 的中间运算精度上有极小的自由度，JM/x264/ffmpeg 都
   采用规范附件的简化 IDCT，实际输出一致）。
  因此 maxdiff 是否等于 0 是判断 RTL 功能正确性的最强判据，比 PSNR 更有意义。

输出：
  - 每帧 Y/U/V 三个平面的 maxdiff / mean abs diff / 不同像素数 / PSNR
  - 末尾汇总，若全部 maxdiff==0 则打印 PASS 并以 0 退出，否则打印 FAIL 并以 1 退出

用法:
    compare_yuv.py <nova.yuv> <ref.yuv> [--frames N] [--w 176] [--h 144]
"""
from __future__ import annotations

import argparse
import math
import sys
from pathlib import Path

# 各平面在 4:2:0 下相对亮度像素数的比例
PLANES = (("Y", 1, 1), ("U", 2, 2), ("V", 2, 2))


def psnr(mse: float, peak: int = 255) -> float:
    if mse == 0:
        return math.inf
    return 10.0 * math.log10((peak * peak) / mse)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("nova", type=Path, help="nova 仿真输出的 YUV420p")
    ap.add_argument("ref", type=Path, help="ffmpeg 参考 YUV420p")
    ap.add_argument("--frames", type=int, default=0, help="只比前 N 帧（0=全部）")
    ap.add_argument("--w", type=int, default=176)
    ap.add_argument("--h", type=int, default=144)
    ap.add_argument("--quiet", action="store_true", help="只打印汇总")
    args = ap.parse_args()

    w, h = args.w, args.h
    y_size = w * h
    c_size = (w // 2) * (h // 2)
    frame_size = y_size + 2 * c_size

    a = args.nova.read_bytes()
    b = args.ref.read_bytes()

    n_a = len(a) // frame_size
    n_b = len(b) // frame_size
    n = min(n_a, n_b)
    if args.frames:
        n = min(n, args.frames)

    print(f"[compare] nova : {args.nova}  ({len(a)} B, {n_a} 帧)")
    print(f"[compare] ref  : {args.ref}  ({len(b)} B, {n_b} 帧)")
    print(f"[compare] 比对 {n} 帧, {w}x{h} YUV420p, 单帧 {frame_size} B")
    print()

    if n == 0:
        print("[compare] 没有可比对的帧")
        return 1

    header = f"{'帧':>4}  {'平面':>4}  {'maxdiff':>7}  {'mean':>8}  {'不同像素':>9}  {'PSNR(dB)':>10}"
    if not args.quiet:
        print(header)
        print("-" * len(header))

    total_diff = 0
    worst = (0, "", 0)   # (帧号, 平面, maxdiff)
    global_sse = 0
    global_px = 0
    bad_frames = []

    for f in range(n):
        fa = a[f * frame_size:(f + 1) * frame_size]
        fb = b[f * frame_size:(f + 1) * frame_size]
        if len(fa) < frame_size or len(fb) < frame_size:
            break

        frame_bad = False
        off = 0
        for name, sx, sy in PLANES:
            size = (w // sx) * (h // sy)
            pa = fa[off:off + size]
            pb = fb[off:off + size]
            off += size

            diffs = [abs(x - y) for x, y in zip(pa, pb)]
            mx = max(diffs)
            ndiff = sum(1 for d in diffs if d)
            mean = sum(diffs) / size
            sse = sum(d * d for d in diffs)
            global_sse += sse
            global_px += size
            total_diff += ndiff
            if mx > worst[2]:
                worst = (f, name, mx)
            if mx != 0:
                frame_bad = True
            if not args.quiet:
                p = psnr(sse / size)
                ps = "inf" if p == math.inf else f"{p:10.2f}"
                print(f"{f:>4}  {name:>4}  {mx:>7}  {mean:>8.3f}  {ndiff:>9}  {ps:>10}")
        if frame_bad:
            bad_frames.append(f)

    print()
    print("=" * 60)
    overall = psnr(global_sse / global_px)
    overall_s = "inf (比特精确)" if overall == math.inf else f"{overall:.2f} dB"
    print(f"[compare] 总像素数    : {global_px}")
    print(f"[compare] 不同像素总数: {total_diff}")
    print(f"[compare] 最差单点    : 帧 {worst[0]} / {worst[1]} / maxdiff={worst[2]}")
    print(f"[compare] 整序列 PSNR : {overall_s}")

    if total_diff == 0:
        print(f"[compare] 结果: PASS —— {n} 帧全部比特精确，与 ffmpeg 完全一致")
        return 0
    print(f"[compare] 结果: FAIL —— {len(bad_frames)} 帧存在差异 "
          f"(首帧 {bad_frames[0]}, 末帧 {bad_frames[-1]})")
    return 1


if __name__ == "__main__":
    sys.exit(main())
