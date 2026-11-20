# 12 · 波形调试与 wave-mcp

> 前十一章都是"读代码 + 看打印"。这一章换一种证据：**把仿真跑出来的波形直接问出来**。
>
> 工具是 [wave-mcp](https://github.com/Tencent/wave-mcp/)（腾讯开源，Apache-2.0）——
> 一个 MCP server，把 FST/VCD 波形和 RTL 网表变成一组可以"提问"的接口：
> 谁在翻转、什么时候高、状态机走了哪条边、这条信号是谁驱动的、两次运行第一处不同在哪。
> **它不跑仿真**，只读你已经 dump 出来的波形。
>
> 本章所有数字都是在本仓库 `sim/` 环境下**实测**得到的，不是抄规格书。

---

## 12.0 为什么还要波形

`sim/tb/tb_nova.v` 现在能告诉你：解了几帧、每帧多少周期、像素对不对。
但它回答不了这类问题：

- "去块滤波到底占了整帧多少时间？" —— 打印只有帧总周期
- "`end_of_MB_DEC` 两次上升沿之间为什么有时 234 拍、有时 842 拍？"
- "`pic_num` 在 0 ns 是 `xxxxxx`，这个 X 是从哪来的？"
- "加了 `+nodb` 之后，第一处行为差异出现在哪个信号、哪个时刻？"

这些问题以前要么加探针（`$display` + 改 TB，每次重编），要么上 GTKWave 手工拖。
波形的信息一直都在，缺的是**查询接口**。

---

## 12.1 三分钟装好

```bash
cd /home/chenye/learning/nova
.venv/bin/python -m pip install --no-build-isolation wave-mcp
```

本机（Ubuntu 26.04 / Python 3.14）装的时候有三道坎，一次说清：

| 症状 | 原因 | 处理 |
|---|---|---|
| `CMake is required to build this package` | `pylibfst` 没有 cp314 wheel，要现场编译 | 先 `pip install cmake ninja setuptools wheel cffi` |
| `BackendUnavailable: Cannot import 'setuptools.build_meta'` | 隔离构建环境里拿不到刚装的 setuptools | 加 `--no-build-isolation` |
| 装完 `import _libfstapi` 失败 | PyPI 上 `py3-none-any` 的 `pylibfst` 轮子漏了扩展模块 | `pip install --no-build-isolation --no-cache-dir --force-reinstall --no-deps pylibfst` 重编 |

装完是这些版本：`wave-mcp 1.1.1`、`pyslang 12.1.0`、`pylibfst 0.2.1`、`mcp 2.3.0`。

### 接进 DSH（Windows 宿主 + WSL 里的 venv）

DSH 宿主进程跑在 Windows 上，Python 在 WSL 里，所以 stdio 要走 `wsl.exe` 中转。
bundle 已经放在 `C:\Users\chen.ye\dsh-bundles\wave-mcp`，关键配置是：

```yaml
command: C:\Windows\System32\wsl.exe
args:
  - -d
  - Ubuntu
  - --cd
  - /home/chenye/learning/nova
  - --exec
  - /home/chenye/learning/nova/.venv/bin/python
  - -m
  - wave_mcp.server
```

接上之后会多出 37 个 `mcp__wave__*` 工具。

### 浏览器查看器（可选，但值得装）

`open_wave_view` 需要一个外部的 `surver` 后端 + Surfer 的 WASM 前端。
wave-mcp 1.1 起不再随包发布这些资源，官方路子是 docker 自建；
**更省事的办法**是用它下架前的 PyPI 包（仍是 0.25.6，和 `surver` 版本号必须对上）：

```bash
curl -sSL --retry 3 -o /tmp/v.whl \
  https://files.pythonhosted.org/packages/a7/b8/b86f09bb5b039d443cdc77a1f9bb82e27dc0a744ca942b01a96f3336f571/wave_mcp_viewer_assets-0.25.6.post1-py3-none-manylinux_2_17_x86_64.whl
cd /tmp && rm -rf vx && mkdir vx && cd vx && unzip -q ../v.whl
mkdir -p ~/.wave-mcp/cache/viewer
cp wave_mcp_viewer_assets/data/surver ~/.wave-mcp/cache/viewer/
cp -r wave_mcp_viewer_assets/data/wasm ~/.wave-mcp/cache/viewer/
chmod +x ~/.wave-mcp/cache/viewer/surver
rm -f ~/.wave-mcp/cache/viewer/wasm/sw.js ~/.wave-mcp/cache/viewer/wasm/sw_new.js
```

> **必须打的一个补丁**：`wave_mcp/viewer/surver.py` 里的 `_die_with_parent()` 用
> `prctl(PR_SET_PDEATHSIG)` 让 surver 随父进程死。但 **PDEATHSIG 是 per-thread 的**——
> MCP server 用工作线程处理工具调用，`open_wave_view` 一返回、那个线程结束，
> 内核就把 surver 杀了。现象是**视图 URL 打开就 502**。
> 补丁把 `Popen` 挪到一个常驻 daemon 线程里执行。
> 仓库外留了一份：`C:\Users\chen.ye\dsh-bundles\wave-mcp\patch\apply.sh`（幂等，重装后跑一次）。

---

## 12.2 让 testbench 吐波形

`sim/tb/tb_nova.v` 里已经加了一个**可选开关**（第 170–190 行）：
不加 `+wave` 时行为和回归完全一致，加了才 dump。

```verilog
reg [1023:0] wave_file;
initial begin
  if ($value$plusargs("wave=%s", wave_file)) begin
    $dumpfile(wave_file);
    $dumpvars(1, tb_nova);                              // 顶层端口 + TB 变量
    $dumpvars(1, tb_nova.u_nova);                       // DUT 端口
    $dumpvars(2, tb_nova.u_nova.BitStream_controller);  // 解析器内部两层
    $dumpvars(1, tb_nova.u_nova.reconstruction);        // 重建数据通路
  end
end
```

```bash
cd /home/chenye/learning/nova/sim
iverilog -g2005 -o out/nova_tb.vvp -s tb_nova -I rtl tb/tb_nova.v rtl/*.v

# 解 1 帧，同时 dump
vvp out/nova_tb.vvp +bitstream=../test/bitstream/akiyo300_1ref.txt \
    +out=/tmp/w.yuv +frames=1 +wave=/tmp/nova_wave.vcd

# VCD → FST（体积约 1/13，随机访问快一个数量级）
vcd2fst -F -v /tmp/nova_wave.vcd -f out/nova_wave.fst
```

**实测**：1 帧 → VCD 约 15 MB → FST **1 175 477 B**，转换 **0.16 s**。

> **为什么不 `$dumpvars(0, tb_nova)`？** 全层次 dump 单帧约 **90 MB**，转 FST 要几十秒，
> 而且大部分是 4×4 块内部的中间量，平时用不到。上面这四行只取"协议层 + 两条数据通路"，
> 单帧降到 15 MB，本章所有例子都跑在它上面。
>
> 一旦要查更深的模块（比如 `DF_top.DF_mem_ctrl`），把那一路加一行 `$dumpvars(2, ...)` 重跑即可。

---

## 12.3 开一个会话

拿到 `.fst` 之后，先 `prepare_session`：它把波形和一个 RTL 网表（pyslang 展开）绑在一起，
后面的"这条信号谁驱动"才有得答。

```
prepare_session(
  wave_path     = "/home/chenye/learning/nova/sim/out/nova_wave.fst",
  filelist_path = "/tmp/nova_sim.f",      # 52 个 sim/rtl/*.v + +incdir+
  top           = "nova")
```

```text
status: ready
session_id: 504b491c59454624
netlist_health: ok / trust: full / 66 modules / 129 instances
                597 warnings, 0 errors
num_scopes: 23   num_signals: 1229
start_time: 0    end_time: 34046921 ns   (34.05 ms, 50069 拍 @680 ns)
definition_coverage: 95.7%
```

两件值得注意的事：

- **网表会被复用**。同一个 filelist 第二次开会直接命中缓存（`reused: true`），
  不会再花 20 多秒展开。所以**每次都传同一个 `/tmp/nova_sim.f`**。
- 597 条 warning 全是 `CaseDefault` / `ArithOpMismatch` / `NewlineEOF` 这类风格告警，
  `diagnostic_errors: 0`，不影响查询。

`/tmp/nova_sim.f` 这样生成（`setup_rtl.sh` 跑完之后）：

```bash
{ ls /home/chenye/learning/nova/sim/rtl/*.v; \
  echo "+incdir+/home/chenye/learning/nova/sim/rtl"; } > /tmp/nova_sim.f
```

**同一个进程里最好只开一个会**。多开会话之后数值类查询会报
`ambiguous_session`——这是 wave-mcp 的设计，不是 bug。

---

## 12.4 八个例子

下面每个例子的"输出"都是本机实跑截取的。

### 例 1：先问"谁在动"——`signal_activity`

**目的**：一帧里有一千多条信号，先筛掉不动的，省得瞎看。

```
signal_activity(
  paths = ["tb_nova.u_nova.reconstruction.DF_duration",
           "tb_nova.u_nova.reconstruction.gclk_DF",
           "tb_nova.u_nova.BitStream_controller.slice_data_state",
           "tb_nova.u_nova.BitStream_controller.pic_num",
           "tb_nova.u_nova.reconstruction.end_of_MB_DF",
           "tb_nova.u_nova.reconstruction.end_of_MB_DEC"],
  start = "min", end = "max")
```

```text
window: 0ns – 34.05ms   count: 6
DF_duration                       toggles   199  first 1.1us   last 28.67ms
gclk_DF                           toggles 41583  first 340ns    last 28.67ms
slice_data_state                  toggles   675  first 1.1us   last 28.52ms
pic_num                           toggles     2  first 1.1us   last 28.52ms
end_of_MB_DF                      toggles   196  first 470.6us last 28.48ms
end_of_MB_DEC                     toggles   199  first 1.36us  last 28.52ms
```

**你该看出什么**

- `pic_num` **一帧只变 2 次**——它是帧计数，本来就该这样。所以后面任何"逐 MB"的统计
  都不该拿它当基准。
- `gclk_DF` 是**门控时钟**：每个被放行的拍产生一个半周期宽（0.5 拍）的高脉冲。
  41583 条变化记录里**上升沿恰好 20790 个**（其余是复位前的 `x` 跳变和下降沿）。
  而下面用 `DF_duration` 量出 DF 活跃 **20691 拍**。20790 ÷ 99 = **210**，
  20691 ÷ 99 = **209**——两者每个 MB 只差 1 个脉冲（门控比 `DF_duration` 早一拍开），
  **互相印证**。
- `end_of_MB_DEC` 199 次翻转 = 99 个上升沿 + 100 个下降沿 → **99 个宏块**
  （多出的下降是 `x→0` 初值）。**99 = QCIF 的 11×9**，和
  `02-系统架构与顶层接口.md` 里的宏块扫描一致。
- **`end_of_MB_DF` 只有 196 次翻转 = 98 个脉冲，比 `end_of_MB_DEC` 的 99 少一个。**
  但这不是丢脉冲：`DF_duration` 的 99 个脉冲**全部完整**（最后一个 28.523→28.665 ms，
  正好 209 拍），说明 99 个宏块都真的滤完了。少的那一个是**设计上被分流**了——
  最后一个宏块的完成脉冲走的是另一根线（`end_of_lastMB_DF`），
  源码在例 5 会追到 `DF_mem_ctrl.v:106-108`。**这条路在打印里永远看不出来。**
- 所有信号 `first_change` 都在 1.1 us 附近——那是复位释放的时刻，不是设计问题。

### 例 2：量"去块滤波占多少"——`find_time_windows`

**目的**：`07-去块滤波.md` 说 204 cycles/MB，第 9 章实测 209。用波形再确认一次，
并且顺便得到**占空比**。

```
find_time_windows(
  predicate = DF_duration == 1'b1,
  start = "min", end = "max", min_duration = "1us")
```

```text
total_hits: 99      truncated: false
第一个窗口 329.1us → 471.2us   duration 142.1us
第二个窗口 610.6us → 752.8us   duration 142.1us
第三个窗口 841.2us → 983.3us   duration 142.1us
...
undecidable_time: 1.1us   (复位前 X 区，不算命中)
```

**你该看出什么**

- **99 个窗口，一个不多一个不少**，每个宽度都是 **142.1 us**。
  142.1 us ÷ 680 ns = **209.0 拍**——不是平均 209，是**每一个都精确 209**。
  用脚本直接核对：

  ```python
  # 99 个脉宽，集合只有 {209.0}
  DF_duration pulses: 99   distinct widths: [209.0]
  sum DF: 20691.0
  占整帧 20691 / 50069 = 41.3%
  占真实解码时间 20691 / 41942 = 49.3%
  ```

  注意分母有两个。**50069 是"仿真跑了多少拍"**，末尾有 8127 拍的等边界空转
  （见例 3）；**41942 才是"解码器真正在干活"的拍数**（最后一个 MB 完成的时刻）。
  两个都报，免得你拿 41.3% 去和别的分母比。

- **199 次翻转 = 99 个上升沿 + 100 个下降沿**（多出来的那一个下降是 1.1 us 的 `x→0` 初值），
  也就是 **99 个完整脉冲**，最后一个在 28.67 ms 落下。99 个 MB 的去块**全部跑完**。
- **41.3%（按整帧）/ 49.3%（按解码时间）**。这就是"为什么作者单独为去块滤波
  写一篇论文"的量化答案：解码器每干 2 拍活，就有 1 拍在滤波。换个算法更直观——
  MB 级节拍中位数 396.5 拍，其中 209 拍是 DF，**占 52.7%**。

### 例 3：把 MB 节拍折成事务——`fold_transactions`

**目的**：`end_of_MB_DEC` 是"一个宏块解码完"的脉冲。把相邻两个上升沿之间折成一条记录，
就得到**逐 MB 的周期数**——不需要改 TB 加探针。

```
fold_transactions(
  start_cond = end_of_MB_DEC == 1'b1,
  end_cond   = end_of_MB_DEC == 1'b1,
  start = "300us", end = "2ms", limit = 6)
```

```text
start 607.9us  end 838.4us    duration 230.5us
start 838.4us  end 1.036ms    duration 197.2us
start 1.197ms  end 1.387ms    duration 189.7us
start 1.387ms  end 1.679ms    duration 292.4us
start 1.896ms  incomplete: true
complete: 7   incomplete: 1   unmatched_ends: 1
note: 9 changes matched; evenly downsampled to 6. 窄化窗口可看全分辨率。
```

**你该看出什么**

- **`incomplete: true` 是诚实**。"窗口结束时这个事务还没结束"和"它到这里结束了"是两件事，
  工具不会替你猜一个结束时间。
- `unmatched_end: 1` 出现在窗口起点（300 us 之前就有一个脉冲在进行中），
  **不是错误**——它只是说"这条结束边找不到配对的开始边"。
- `sampled: true / sample_rate 0.667`：窗口里有 9 个变化，`limit=6` 装不下，
  工具**均匀抽样**而不是截断——首尾都保留。要看全分辨率就窄化窗口。
- **最后一段有个大坑**：99 个 MB 在第 **41942 拍**（28.52 ms）就全部解完了，
  之后到仿真结束（50069 拍）还有 **8127 拍的纯空转**——在等 `end_of_one_frame`。
  所以**别拿 `end_time` 当解码时间**。
- 缩小窗口就能拿到全分辨率。整帧统计（脚本 `FstSource.timelines` 直算）：

  ```
  MB 间隔（99 个上升沿 → 98 个间隔）
  中位数 396.5 拍   均值 423.1   最小 234   最大 842
  前 12 个：414 339 290 237 279 430 319 273 276 340 414 435
  ```

- **中位数 396.5 与文档里的 330 不一致，这点必须说清楚。** 第 9 章那个 330 来自一个
  当时的 `[RATE]` 探针（统计 980 个 MB、跳过帧边界），探针代码已经不在仓库里；
  现在能复现的是本节的 396.5 / 均值 423.1。
  **两者口径不同**：前者是"稳态 P 帧 + 探针口径"，后者是"首帧（含 I 帧）+ 波形口径"。
  引用时以本节的实测为准，330 请注明"旧探针口径，代码已不在"。
- 为什么**最大 842、最小 234**？这就是"每 MB 内容相关"——P_8x8 要跑 4 次 MV 预加载，
  skip MB 直接复制参考块。第 9 章按 `mb_type` 分解的表（skip 326 / 16×16 422 / P_8x8 515）
  是同一现象的另一侧证据。

### 例 4：状态机走了哪条边——`fsm_transitions`

**目的**：`BitStream_controller.v:307` 那个 `slice_data_state` 有 16 种编码
（`nova_defines.v:145-157`），想知道**这一帧实际走了哪几条**。

```
fsm_transitions(
  path = "tb_nova.u_nova.BitStream_controller.slice_data_state",
  start = "min", end = "max")
```

```text
states_seen: 0000 0010 0100 1100 1101 1110 1111 xxxx   (8 个)
changes: 675

xxxx → 0000   ×1     first 1.1us      ← 复位
0000 → 0010   ×99    first 47.6us     ← mb_skip_run → mb_type_s
0010 → 0100   ×99    first 48.28us    ← mb_type_s → mb_pred
0100 → 1100   ×81    first 63.92us    ← mb_pred → coded_block_pattern
1100 → 1101   ×80    first 64.6us     ← cbp → mb_qp_delta
1101 → 1111   ×98    first 65.28us    ← qp_delta → residual
1111 → 1110   ×99    first 327.1us    ← residual → mb_num_update
1110 → 0000   ×99    first 327.8us    ← 回到起点，下一个 MB

0100 → 1101   ×18    first 1.04ms     ← 旁路：没有 cbp 直接进 qp_delta
1100 → 1111   ×1     first 26.21ms    ← 旁路：有 cbp 但没有 qp_delta

branches: BitStream_controller.v:307  taken ×675
note: 这是"本次运行实际走到的"，不是覆盖率。
```

**你该看出什么**

- **主干是 7 条边、99 次一圈**，99 = QCIF 的宏块数。`1100→1101` 和 `1101→1111` 比 99 少，
  差值正好被两条旁路补上（81+18 = 99，80+1 = 81）。
- **`1100 → 1111` 只出现 1 次**（26.21 ms）——这是"cbp 非零但 qp_delta 为 0"的宏块，
  全帧只有 1 个。这种"只在特定语法组合下才走一次"的边，靠 grep 代码是看不出来的。
- 工具**明确拒绝把它当覆盖率**：没出现的边可能是设计上不可达、可能是这份码流没触发、
  也可能是真漏洞，一个波形分不出这三种情况。这条注解是刻意写进输出的。

### 例 5：追一条信号"是怎么来的"——`trace_value` / `trace_x`

**目的**：`end_of_MB_DF` 在 471.2 us 变 0。它到底是谁给的？

```
trace_value(path = "tb_nova.u_nova.reconstruction.end_of_MB_DF",
            time = "471240ns", max_depth = 6)
```

```text
reconstruction.end_of_MB_DF            value 0
  ← instance_port  reconstruction.v:516   DF_top DF_top (
    crosses_into: DF_top, port end_of_MB_DF (output)
    ← DF_top.v:138   DF_mem_ctrl DF_mem_ctrl (
      crosses_into: DF_mem_ctrl, port end_of_MB_DF (output)
      ← nonblocking  DF_mem_ctrl.v:108
          end_of_MB_DF <= (!(mb_num_h_DF == 10 && mb_num_v_DF == 8)) ? 1'b1 : 1'b0;
          note: sequential (registered) — value latched from a previous cycle
        ← DF_mem_ctrl.v:84  begin mb_num_h_DF <= mb_num_h; mb_num_v_DF <= mb_num_v; end
        ← DF_mem_ctrl.v:94  DF_12_cycles <= DF_12_cycles + 1;
```

**你该看出什么**

- 三层跳转（`reconstruction → DF_top → DF_mem_ctrl`）一次走完，
  每层都带**文件和行号**，中间还标了 `crosses_into`（跨模块的端口边界）。
- 关键那一行是 **`DF_mem_ctrl.v:108`**：
  `end_of_MB_DF <= (!(mb_num_h_DF == 10 && mb_num_v_DF == 8)) ? 1'b1 : 1'b0;`
  **`10` 和 `8` 是硬编码的 QCIF 尺寸**（11 列 × 9 行，最后一个是 10/8）。
  这正是 `10-兼容性陷阱与移植指南.md` 里"67 处硬编码"的其中一处——
  现在你知道它在波形上长什么样。
- `note: sequential (registered)` 是重要提示：这个值锁存自**上一拍**，
  所以"471.2 us 时它变 0"要理解成"上一拍的条件满足了"，追 fan-in 时不能同拍对齐。
- 看清楚这行前后的**分工**：`DF_12_cycles == 11` 那个时刻，代码同时写两根线——
  `end_of_MB_DF <= !(是最后一个 MB) ? 1 : 0`，而
  `end_of_lastMB_DF <= (是最后一个 MB) ? 1 : 0`（`DF_mem_ctrl.v:108-109`）。
  所以例 1 里"98 而不是 99"**不是丢了脉冲**，是最后一个宏块改走
  `end_of_lastMB_DF`——源码里的注释写得很明白：那个 MB 之后没有重建，
  不需要再对齐 `MB_rec_DF_align`。
  （`end_of_lastMB_DF` 在本 dump 的采集范围外，波形里看不到，只能从源码确认。）
  一条 trace 同时解释了一个计数异常和一处硬编码。

再追 X：

```
trace_x(path = "tb_nova.u_nova.BitStream_controller.pic_num", time = "0ns")
```

```text
pic_num = xxxxxx
  ← instance_port  BitStream_controller.v:307  BitStream_parser_FSM (
    ← nonblocking  BitStream_parser_FSM_gating.v:507  pic_num <= pic_num + 1;
      ← gclk_slice_data = x
         note: X root cause candidate: no driver in this module
               — undriven primary input / port (driven above this scope or not at all)
      ← mb_num = xxxxxxx
        ← ... slice_type = xxx   (同样的 undriven 提示)
        ← BitStream_parser_FSM_gating.v:333
```

**你该看出什么**

- 根因是 **`gclk_slice_data` 在 0 ns 还没有驱动**（门控时钟要等 `gclk_gen` 起来）。
  这是**复位前的正常 X**，不是设计缺陷——第 1 拍之后自己就清了。
- 这类"X 到底要不要修"的判断，用 `sample_at_clock` 看复位前后最直接：

  ```
  sample_at_clock(clock="tb_nova.clk", paths=[reset_n, slice_data_state],
                  start="min", end="8us")
    680ns   reset_n=1  state=xxxx     ← 复位还没拉低
    1.36us  reset_n=0  state=0000     ← 第一个复位沿，X 立刻消失
    2.72us  reset_n=1  state=0000
  ```

  **X 只活了一拍**，所以不用管。

### 例 6：两次运行差在哪——`diff_waveforms`

**目的**：`+nodb` 关掉去块滤波之后，**第一处**行为差异在哪？
这是回答"我改的这一行到底影响了什么"的标准姿势。

```bash
# 同一帧，一次带去块、一次 +nodb
vvp out/nova_tb.vvp +bitstream=../test/bitstream/akiyo300_1ref.txt \
    +out=/tmp/a.yuv +frames=1 +wave=/tmp/w_db.vcd
vvp out/nova_tb.vvp +bitstream=../test/bitstream/akiyo300_1ref.txt \
    +out=/tmp/b.yuv +frames=1 +nodb +wave=/tmp/w_nodb.vcd
vcd2fst -F -v /tmp/w_db.vcd   -f out/nova_wave.fst
vcd2fst -F -v /tmp/w_nodb.vcd -f out/nova_wave_nodb.fst
```

```
diff_waveforms(
  fst_paths = [".../nova_wave.fst", ".../nova_wave_nodb.fst"],
  signals   = [reconstruction.disable_DF,
               reconstruction.rec_DF_RAM0_wr,
               reconstruction.rec_DF_RAM0_addr,
               reconstruction.DF_duration,
               reconstruction.end_of_MB_DF])
```

```text
compared: 5    identical: 0    diverging: 5    coverage: complete

first_divergence: 0ns  reconstruction.disable_DF
      run0 = 0    run1 = 1                       ← 输入本来就不一样，符合预期
rec_DF_RAM0_wr     80.24us   1 vs 0
rec_DF_RAM0_addr   80.92us   0000001 vs 0000000
DF_duration       329.1us    1 vs 0
end_of_MB_DF      470.6us    1 vs 0
```

**你该看出什么**

- **`0 ns` 就分叉**，因为两次运行的**输入**不同（`disable_DF` 是 TB 的 `+nodb` 直接给的）。
  工具把它排在第一位，正好提醒你：先排除输入差异，再看下游。
- 真正的"因果链"从 **80.24 us** 开始：`disable_DF=1` 让
  `rec_DF_RAM_ctrl.v:65` 的 `rec_DF_RAM_wr = !disable_DF && (...)` 恒为 0，
  于是 `rec_DF_RAM0_wr` 不再写、地址停住、`DF_duration` 永不拉高。
  **`80.24 us` 之前两者一模一样**，说明关掉 DF 不影响解析和重建的前段——这正是我们想证明的。
- **只比 5 条信号是刻意的**。见 12.6 的坑：大 scope 会触发 `pylibfst` 段错误。

第二个用法：**同一配置、不同速率档**，找"什么时候开始不一样"。

```
diff_waveforms(fst_paths = ["/tmp/nova_f0.fst", "/tmp/nova_f3.fst"],
               signals = [parser_state, slice_data_state, BitStream_ram_addr,
                          end_of_one_frame],
               after = "20ms")
```

```text
compared: 4   identical: 3   diverging: 1
first_divergence: 30.64ms  BitStream_controller.parser_state
      run0 (cf=45000) = 01     run1 (cf=70000) = 00
```

**你该看出什么**

- 前 30 ms **完全一致**——`freq_ctrl` 只放行、不改变任何数据通路。
- 分叉点 **30.64 ms = 45058 拍**。这条链路是这样的：`end_of_one_frame` 在
  **45057 拍**拉高（`frame_cycle_counter` 从第 54 拍开始计，45000 拍后正好到 45054，
  再加几拍握手 = 45057，见 `bitstream_gclk_gen.v:100-122`），
  它让 `parser_state` 在下一拍（45058）从 `00` 回到 `01`，重新开始找 start code。
  而 cf3 的 70000 拍远远没到，`end_of_one_frame` **整帧一次都没拉高**，
  `parser_state` 就停在 `00`。**一条波形差分就把"速率控制在哪一拍介入"钉死了。**
- **别把单帧周期当成速率控制的精度**。`cf0` 单帧 **45069** 拍 = 45057（等边界）
  + 12（收尾）；`cf3` 单帧 **62156** 拍，但这个数字和 `cf3 = 70000` **无关**——
  码流只有 1 帧、15518 个 ROM word，解码在 **41942** 拍就完了，
  之后是 TB 靠"码流耗尽"判据（`tb_nova.v` 的 `SAT_FLUSH`）兜底 flush 出来的。
  README 表里的 45009 / 68839 是 14 帧稳态口径，那里 `cf3` 才会顶到 70000 附近。

### 例 7：在浏览器里看——`open_wave_view`

**目的**：数值查完了，剩下的"形状"还是要眼睛看。

```
open_wave_view(
  fst_paths = [".../nova_wave.fst"],
  signals   = [tb_nova.clk, reconstruction.DF_duration,
               reconstruction.gclk_DF, reconstruction.end_of_MB_DF,
               BitStream_controller.slice_data_state],
  viewport  = {"from": "300us", "to": "500us"},
  cursor    = {"time": "329120", "unit": "ns"},
  markers   = [{"time": "329100ns", "label": "DF start MB0", "color": "orange"},
               {"time": "471200ns", "label": "DF end MB0",   "color": "red"}],
  annotation = {"markdown": "DF_duration 高电平精确 209 拍/MB，99 个 MB 共 20691 拍 = 整帧 41.3% / 解码时间 49.3%",
                "confidence": "high",
                "evidence": ["find_time_windows 给出 99 个 142.1us 窗口"]})
```

```text
available: true
view_id: 0d7605f7
url: http://127.0.0.1:41299/view.html?token=mN7EESx9uS4tEdX-
native_hint: surfer http://127.0.0.1:37097/mN7EESx9uS4tEdX-
ssh_hint: ssh -L 41299:localhost:41299 <this-host>
```

把 `url` 丢进浏览器就能看。参数格式很严，全是实测踩出来的：

| 参数 | 必须 | 会被拒的写法 |
|---|---|---|
| `markers[].time` | 带单位的**字符串** `"329100ns"` | `"329.1us"`（小数）、`{"time":329100,"unit":"ns"}`（对象） |
| `markers[].color` | `blue/green/orange/purple/red/yellow` 之一 | 其他任何颜色名 |
| `viewport.from/to` | 同单位的字符串 `{"from":"300us","to":"500us"}` | 混用 `0ns` 和 `600us` |
| `cursor` | `{"time":"329120","unit":"ns"}` | 字符串 |
| `annotation.evidence` | 字符串**列表** | 单个字符串 |
| `diff.first_divergence` | 对象 `{"time":"680","unit":"ns"}` | 裸字符串 |

> 校验一下视图是否真的活着：`curl -s -o /dev/null -w "%{http_code}" <url>` 应该是 200。
> 如果几秒后变 502，就是 12.1 里那个 PDEATHSIG 补丁没打。

### 例 8：没有波形也能查连接——`open_static_session`

**目的**：只想看"谁驱动谁"，还没跑仿真。这时候不需要 `.fst`。

```
open_static_session(filelist_path = "/tmp/nova_sim.f", top = "nova")
```

```text
mode: static
netlist_available: true / 66 modules / 129 instances / 0 errors
available_tools: signal_connectivity, signal_drivers, signal_loads,
                 signal_fanin, driver_contributors, list_modules,
                 find_instances, files, scope_info, signal_info
```

然后就能纯静态地问：

```
signal_drivers(path = "nova.reconstruction.DF_duration")
  → instance_port  reconstruction.v:516   DF_top DF_top ( , port DF_duration (output)

signal_fanin(path = "tb_nova.u_nova.reconstruction.DF_duration")
  → tb_nova.u_nova.reconstruction.DF_top.DF_duration

signal_loads(path = "...reconstruction.disable_DF")
  → DF_top.disable_DF, hybrid_pipeline_ctrl.disable_DF, rec_DF_RAM_ctrl.disable_DF

signal_connectivity(path = "...reconstruction.rec_DF_RAM0_wr")
  → rec_DF_RAM0.wr_n, rec_DF_RAM_ctrl.rec_DF_RAM0_wr
```

**你该看出什么**

- `disable_DF` 的三个扇出**一次列全**：DF 本身、流水线控制、RAM 写控制。
  例 6 里 `rec_DF_RAM0_wr` 在 80.24 us 停住，根因就在第三条上。
- `signal_downstream` 是正向追踪，还能接时间点回答"这之后谁真的动了"：

  ```
  signal_downstream(path="...reconstruction.disable_DF", time="680ns")
    → DF_top.disable_DF, hybrid_pipeline_ctrl.disable_DF, rec_DF_RAM_ctrl.disable_DF
      in_waveform: false    ← 这三个跨模块端口没被 dump（12.2 的窄 scope 的代价）
  ```

  **`in_waveform: false` 不是错误**，是在提醒你：可达性来自网表，但这几条信号
  不在波形里，所以"它之后有没有变"答不了。想回答就把那一层加进 `$dumpvars`。

---

## 12.5 一张实测数字表

| 指标 | 怎么量的 | 数值 |
|---|---|---|
| 单帧总周期 | FST `end_time / 680` | **50 069** 拍（34.046 921 ms）|
| 宏块数 | `end_of_MB_DEC` 上升沿 | **99**（11×9）|
| DF 每 MB 周期 | `DF_duration` 高电平宽度 | **209.0 拍**，99 个**全部相同** |
| DF 占整帧 | 20691 / 50069 | **41.3%** |
| DF 占解码时间 | 20691 / 41942 | **49.3%** |
| MB 节拍（本波形口径）| `end_of_MB_DEC` 相邻上升沿 | 中位 **396.5**、均值 **423.1**、234–842 |
| MB 节拍（旧探针口径）| 已删除的 `[RATE]` 探针 | 330（**代码已不在，勿直接引用**）|
| 解析器主循环 | `slice_data_state` 边计数 | 7 条主干边 × 99 圈 + 2 条旁路 |
| 真实解码结束 | 最后一个 `end_of_MB_DEC` 上升沿 | **41 942** 拍（三种速率**完全相同**）|
| `cf0` 单帧 | `/tmp/nova_f0.fst` | **45 069** 拍（45057 等边界 + 12 拍收尾）|
| `cf3` 单帧 | `/tmp/nova_f3.fst` | **62 156** 拍（码流耗尽后 TB 兜底 flush）|
| 速率控制介入点 | `diff_waveforms(f0, f3)` | **30.64 ms**，`parser_state` 01 vs 00 |
| `+nodb` 首处分叉 | `diff_waveforms(db, nodb)` | **80.24 us**，`rec_DF_RAM0_wr` |
| FST 体积 | 1 帧窄 scope | **1 175 477 B**（VCD 15 MB，转换 0.16 s）|

---

## 12.6 踩坑清单

1. **时间参数不带单位 = 秒**。`signal_values(..., time=50067)` 会被当成 50067 **秒**，
   返回空。永远写 `"34046240ns"`。
2. **`diff_waveforms` 大 scope 会段错误**。`pylibfst` 在 C 层
   （`fstReaderIterBlocks2`，`fst_source.py:743`）崩，exit code −11。
   实测：比 128 条还多的信号、或一个 1229 信号的 scope，会随机崩。
   **对策：显式给 `signals=[...]` 列表（几条到几十条），或窄 scope + `clock=`**。
   窄到 `reconstruction`（193 条）时 5/5 稳定。崩了就重跑，同样的输入有时能过。
3. **多开会话时，每次查询都要带 `session_id`**。不带就报 `ambiguous_session`
   ——它是在说"你有好几个会话，我不知道问哪个"，不是坏了。
   列会话用 `session_info(list_sessions=true)`，用完 `close_session` 释放。
4. **`signal_drivers` 对 instance 路径不适用**（返回 `is_an_instance`），
   对输入端口返回 `primary_input`——那不是"没找到驱动"，是"驱动在外面"。
5. **`view_id` 最多 8 个**，用完 `close_wave_view` 释放。
6. **headless 截图别试**。`msedge.exe --headless=new --screenshot` 在
   WSL/Windows 桥下永不退出，会留下锁住 profile 的孤儿进程。要看就人工打开 URL。
7. **`pylibfst` 重装后必须重打 surver 补丁**，否则视图又是"打开就 502"。
8. **`end_time` 不是解码时间**。一帧解完（最后一个 `end_of_MB_DEC`）后还要等
   `end_of_one_frame`，本 dump 里这段空转 **8127 拍**。算占比、算 IPC、算吞吐时
   先确认分母是哪一个。
9. **`first_change` 早不代表有问题**。复位释放前所有触发器都是 X，`0 ns` 的 X 和
   `1.1 us` 的 `x→0` 都是正常初值，用 `trace_x` 确认根因是"门控时钟未起"就可以放下。

---

## 12.7 这套工具给这个项目补上了什么

前面十一章的证据链是三类：**规格书**、**源码**、**TB 打印**。
波形是第四类，也是唯一能回答"**这一拍发生了什么**"的那一类。回头看它具体补上了什么：

- **确认了 209**，而且比第 9 章的探针更强——探针给你一个平均，波形告诉你
  "99 个里每一个都是 209，方差为零"。这是"流水线填充/排空固定 5 拍"的直接证据。
- **量出了占比，而且量清了分母**。第 9 章只能说"DF 占比约 63%"（209/330），
  连分母是什么口径都说不清。现在能给出三个分母：整帧 41.3%、解码时间 49.3%、
  单 MB 内 52.7%——**并明确哪个该用在哪**。这比多一个小数点重要。
- **把"硬编码 QCIF"从代码里搬到了波形上**。`DF_mem_ctrl.v:108` 的
  `mb_num_h_DF == 10 && mb_num_v_DF == 8` 是第 10 章 67 处硬编码之一，
  现在有一条命令能把它指出来，而且能顺手解释"为什么 DF 的完成脉冲只有 98 个"。
- **给出了"改一行影响什么"的标准流程**：例 6 的两次 dump + 显式信号列表差分，
  比"改完重跑回归看 PSNR"细得多——PSNR 只告诉你结果变了，差分告诉你**从哪一拍开始变**。
- **顺手暴露了文档自身的口径问题**（330 vs 396.5，以及"50069 是不是解码时间"）。
  这大概是这套工具最有价值的地方：它让"文档里的数字"也必须接受复核，
  而且复核的成本从"写一个探针重编"降到"一条查询"。

---

**上一章** ← [11-动手实验.md](11-动手实验.md) ｜
**回到目录** → [README.md](README.md)
