# 第 9 章 仿真环境与 ffmpeg 对比

前 8 章都是"读代码"。这一章讲**怎么让代码跑起来**，以及
**怎么证明它跑对了**。

**核心方法**：拿同一个码流，让 nova 和 ffmpeg 各解一遍，
**逐像素比对**。如果 300 帧全部零差异，那功能就是对的。

**为什么这个判据这么强**：

> H.264 是**比特精确（bit-exact）**的规范。给定同一码流，任何符合标准的
> 解码器在 IDCT、帧内/帧间预测、去块滤波上都必须产生**完全相同**的像素值
> （标准只允许在 IDCT 的中间运算精度上有极小自由度，而 JM/x264/ffmpeg
> 都采用规范附件的简化 IDCT，实际输出一致）。
>
> **所以 `maxdiff == 0` 比"PSNR 45 dB"有意义得多。**

## 9.1 为什么需要自己搭仿真环境

原始代码里**没有能直接跑的 testbench**：

```
src/
├── nova.v                    ← 顶层
├── nova_tb.v                 ← 有 tb，但……
├── Beha_BitStream_ram.v      ← $readmemh("D:/nova_opencores/bin2hex/akiyo300_1ref.txt", ...)
└── ext_frame_RAM0_wrapper.v  ← 只写文本日志，不写 YUV
    ext_frame_RAM1_wrapper.v
```

**三个问题**：

### 问题 1：硬编码的 Windows 绝对路径

```verilog
// Beha_BitStream_ram.v
initial
    $readmemh("D:/nova_opencores/bin2hex/akiyo300_1ref.txt", BitStream_ram);
```

**`D:/` 盘** ——作者的开发机。在任何其他机器上都是空 ROM → 全 X → 卡死。

### 问题 2：输出是文本日志，不是 YUV

```verilog
// ext_frame_RAM0_wrapper.v（原文）
$fdisplay(displayfile, "%h", mem[...]);
```

**输出 `nova_display.log`（hex 文本）**，然后要用一个 C 程序 `hex2bin`
转回二进制才是 YUV。

**为什么这样设计？** 因为 2008 年的仿真器写大二进制文件很慢，
写文本反而快（可读可 diff）。**但对现代工作流是负担**。

### 问题 3：帧边界靠 `pic_num` 奇偶判断

```verilog
// ext_frame_RAM0_wrapper.v
if (slice_header_s6 == 1'b1 && pic_num[0] == 1'b1) ...
// ext_frame_RAM1_wrapper.v
if (pic_num[0] == 1'b0 && pic_num_ext != 0) ...
```

**这在"IDR 帧 + P 帧交替"的码流里能工作，但很脆弱**：

- 如果码流开头有多个 IDR 帧 → `pic_num[0]` 的奇偶和"哪块是 display"就错位
- 如果 `pic_num` 回绕（6 bit，64 帧）→ 逻辑又变

## 9.2 我们搭的环境

```
sim/
├── rtl/               ← src/ 的副本 + 2 处位宽修复
├── tb/tb_nova.v       ← 全新 testbench（直接写 YUV420p）
├── scripts/
│   ├── setup_rtl.sh       ← 复制 + 打补丁
│   ├── bin2hex.py         ← .264 → hex 文本（改进版）
│   ├── compare_yuv.py     ← 逐像素比对
│   └── run_regression.sh  ← 一键 6 步回归
├── vectors/           ← 测试码流
└── out/               ← 输出与日志
```

### 9.2.1 `setup_rtl.sh`：复制 + 两处补丁

**为什么不在 `src/` 上直接改？** 因为要保持原仓库完整（可随时 diff、
可给别人看"原版长什么样"）。

```bash
#!/bin/bash
# setup_rtl.sh —— 把 src/ 复制到 sim/rtl/ 并打上 iverilog 需要的补丁
SRC=../src
DST=rtl
rm -rf "$DST"; mkdir -p "$DST"
cp "$SRC"/*.v "$DST"/

# 补丁 1：pc_decoding.v 的位宽不定
sed -i 's/{{pc_reg\[6:3\] + 1},3'"'"'b0}/{{pc_reg[6:3] + 4'"'"'d1},3'"'"'b0}/g' "$DST/pc_decoding.v"
# 补丁 2：Intra_pred_pipeline.v 的位宽不定
sed -i 's/{(mb_num_h + 1),2'"'"'b0}/{(mb_num_h + 4'"'"'d1),2'"'"'b0}/g' "$DST/Intra_pred_pipeline.v"
# 补丁 3：Beha_BitStream_ram.v 的硬编码路径
sed -i 's|"D:/nova_opencores/bin2hex/akiyo300_1ref.txt"|"akiyo300_1ref.txt"|' "$DST/Beha_BitStream_ram.v"
```

### 三个补丁的详细解释

**补丁 1 和 2：`iverilog` 的位宽推断问题**

原始代码：

```verilog
// pc_decoding.v:195-196
pc <= (pc_reg[2:0] == 3'b000) ? pc_reg : {{pc_reg[6:3] + 1}, 3'b0};
```

**`pc_reg[6:3]` 是 4 bit，`+ 1` 里的 `1` 是 32 bit 整数**。
在**拼接上下文**里，Verilog 要求每个操作数有**确定的位宽**，
但 `4bit + 32bit` 的结果位宽由工具推断 —— **iverilog 拒绝推断，报错**：

```
error: Concatenation operand "(pc_reg[6:3])+('sd1)" has indefinite width.
```

**修复**：显式写 `4'd1`（4 bit 的常量），结果就是 4 bit。

```verilog
pc <= (pc_reg[2:0] == 3'b000) ? pc_reg : {{pc_reg[6:3] + 4'd1}, 3'b0};
```

**同样的错误在 `Intra_pred_pipeline.v:325`**：

```verilog
// 原：{(mb_num_h + 1), 2'b0}
// 改：{(mb_num_h + 4'd1), 2'b0}
```

**为什么这是"补丁"而不是"bug"？** 因为**商业工具（DC/Precision）接受这种写法**
（按 IEEE 1364-2001 的规则推断成 4 bit），只有 iverilog 严格。所以
**这是工具兼容性问题，不是设计错误**。

**补丁 3：`$readmemh` 的路径**

改成相对路径后，需要在 `sim/` 目录下运行，或者用 `+bitstream=` 覆盖。

### 9.2.2 `tb_nova.v`：全新 testbench

**设计目标**：

1. **直接写标准 YUV420p** —— 能被 ffmpeg/任何播放器读
2. **不依赖 `pic_num` 奇偶** —— 用"脏缓冲"标志
3. **支持 plusargs** —— 换码流/换帧数/换频率不用改代码
4. **能处理末帧** —— 原 tb 会漏掉最后一帧

#### 接口：plusargs

| Plusarg | 含义 | 默认 |
|---|---|---|
| `+bitstream=<file.hex>` | 输入码流（`bin2hex.py` 产出的 hex 文本）| **必填** |
| `+out=<file.yuv>` | 输出 YUV420p | `nova_out.yuv` |
| `+frames=<n>` | 解多少帧后停 | 1 |
| `+freq=<0..3>` | `freq_ctrl` 速率档位 | 1 |
| `+nodb` | 关闭去块滤波（`pin_disable_DF=1`）| 关 |
| `+maxcyc=<n>` | 绝对周期上限（防死循环）| 60e6 |

**用法**：

```bash
vvp out/nova_tb.vvp +bitstream=../test/bitstream/akiyo300_1ref.txt \
                     +out=out/nova.yuv +frames=10 +freq=1
```

#### 时钟与复位

```verilog
localparam CLK_HALF = 340;     // 680 ns 周期 ≈ 1.47 MHz

initial clk = 1'b1;
always #CLK_HALF clk = ~clk;

initial begin
    reset_n = 1'b1;
    #1100 reset_n = 1'b0;      // 先等一会儿再复位（让 X 稳定）
    #1000 reset_n = 1'b1;
end
```

**680 ns ≈ 1.47 MHz** ——对应规格书的"QCIF 30 fps 需 1.5 MHz"。
用真实频率跑，才能验证速率控制的正确性。

#### 帧存模型

```verilog
localparam integer RAM_DEPTH    = 9504;   // 32-bit words per QCIF frame buffer
localparam integer LUMA_WORDS   = 6336;
localparam integer CHROMA_WORDS = 1584;

reg [31:0] mem0 [0:RAM_DEPTH-1];   // ext_frame_RAM0
reg [31:0] mem1 [0:RAM_DEPTH-1];   // ext_frame_RAM1
```

**nova 外挂两块帧存，ping-pong 使用**：

- 正在被写的 = display buffer
- 另一块 = reference buffer（供 inter 预测读）

**两个 wrapper 被合并进 tb**：`always @(posedge clk)` 里根据
`cs_n`/`wr`/`addr` 读写 `mem0`/`mem1`。

#### 关键创新：脏缓冲标志

```verilog
reg buf0_written = 1'b0;   // mem0 自上次吐帧后被写过
reg buf1_written = 1'b0;

always @ (posedge clk) begin
    if (ext_frame_RAM0_cs_n == 1'b0 && ext_frame_RAM0_wr == 1'b1) begin
        mem0[ext_frame_RAM0_addr] <= ext_frame_RAM0_data;
        buf0_written <= 1'b1;
    end
    if (ext_frame_RAM1_cs_n == 1'b0 && ext_frame_RAM1_wr == 1'b1) begin
        mem1[ext_frame_RAM1_addr] <= ext_frame_RAM1_data;
        buf1_written <= 1'b1;
    end
end
```

**吐帧时机**：

```verilog
// slice_header_s6 拉高 = nova 开始解析下一帧的 slice header
// = 上一帧已经完整写进帧存了
always @ (posedge clk) begin
    if (slice_header_s6 == 1'b1 || <flush 条件>) begin
        if (buf1_written)      begin emit_picture(mem1); buf1_written <= 0; end
        else if (buf0_written) begin emit_picture(mem0); buf0_written <= 0; end
    end
end
```

**为什么这样比 `pic_num[0]` 好？**

`slice_header_s6` 的定义（`BitStream_parser_FSM_gating.v:304`）：

```verilog
assign slice_header_s6 = (slice_header_state == `frame_num_s) ? 1'b1 : 1'b0;
```

**即"解析到 slice_header 的 frame_num 字段"** —— 这个时刻**必然**是
"上一帧刚刚全部写完、下一帧还没开始动帧存"的窗口。

**加上 `bufN_written` 标志，就完全不需要知道 `pic_num` 是奇是偶。**

#### 反包 YUV：`emit_picture`

```verilog
task emit_picture(input integer which);
    integer x, y, w, px;
    reg [31:0] word;
    begin
        // ---- Y ----
        for (y = 0; y < 144; y = y + 1)
            for (x = 0; x < 176; x = x + 4) begin
                word = (which == 0) ? mem0[y*44 + x/4] : mem1[y*44 + x/4];
                $fwrite(out_fd, "%c%c%c%c", word[7:0], word[15:8], word[23:16], word[31:24]);
            end
        // ---- Cb ----
        for (y = 0; y < 72; y = y + 1)
            for (x = 0; x < 88; x = x + 4) begin
                word = (which == 0) ? mem0[LUMA_WORDS + y*22 + x/4]
                                    : mem1[LUMA_WORDS + y*22 + x/4];
                $fwrite(out_fd, "%c%c%c%c", word[7:0], word[15:8], word[23:16], word[31:24]);
            end
        // ---- Cr ----（同上，基址 LUMA_WORDS + CHROMA_WORDS）
        ...
    end
endtask
```

**两个关键常量**：

- **行跨距 44 word**（luma）= 176 像素 / 4 像素每 word ✓
- **行跨距 22 word**（chroma）= 88 像素 / 4 ✓
- **最左像素在 `word[7:0]`** ← 这是 nova 的约定（`DF_mem_ctrl` 写帧存时
  第一个像素进最低字节）

**`$fwrite` 用 `%c` 而不是 `%0d`** —— 直接写二进制字节，不经过十进制转换。

#### 两个必须处理的坑

**坑 1：ROM 必须先清零，再 `$readmemh`，且在同一个 initial 块里**

```verilog
initial begin
    // ① 先全清 0
    for (bs_init_i = 0; bs_init_i <= `Beha_Bitstream_ram_size; bs_init_i = bs_init_i + 1)
        bs_ram[bs_init_i] = 16'h0000;
    // ② 再读码流（同一个块内，顺序有保证）
    if (bs_file != "") $readmemh(bs_file, bs_ram);
    ...
end
```

**为什么不能拆成两个 `initial` 块？** Verilog 标准**不规定**多个 `initial`
块的执行顺序。如果仿真器先执行 `$readmemh` 块、再执行清零块，**码流就被擦掉了**。

**为什么必须清零？** `$readmemh` 只填文件里有的行，**其余保持 X**。
小码流（比如单帧 2401 字节 = 1201 word）时 ROM 后面 13 万个 word 全是 X，
**nova 读到 X 后状态机卡在 X 上，永远不前进**（表现：跑几十万周期解不出帧）。

**坑 2：末帧 flush**

**问题**：nova 的帧边界信号 `slice_header_s6` 来自"**下一帧**的 slice header"。
**最后一帧后面没有下一帧** → 永远不吐帧。

**第一版修复（失败）**：空闲检测

```verilog
localparam IDLE_FLUSH = 5000;
// 连续 5000 周期无 slice_header_s6 也无写帧存 → flush
```

**为什么失败？** 因为在**完整 300 帧码流**里，nova 解完最后一帧后
**继续把 ROM 里补的 0 当作 MB 数据解**（全 0 的位流被解释成 skip MB），
`end_of_MB_DEC` **持续翻转** → 写帧存持续发生 → `idle_count` 永远被清零。

**第二版修复（成功）：码流耗尽检测**

```verilog
integer bs_end_addr;   // 真实码流占用的最后一个 word + 1

// 打开码流后扫描一遍，找出真实的末尾
bs_end_addr = 1;
for (bs_init_i = `Beha_Bitstream_ram_size; bs_init_i >= 0; bs_init_i = bs_init_i - 1)
    if (bs_ram[bs_init_i] !== 16'h0000) begin
        bs_end_addr = bs_init_i + 1;
        bs_init_i = -1;              // break
    end
$display("[TB] bitstream occupies ROM words 0..%0d", bs_end_addr - 1);

// flush 判据：ROM 地址已经追平码流末尾，且没有新的 MB 结束事件
localparam SAT_FLUSH = 2000;
always @ (posedge clk) begin
    if (reset_n !== 1'b1)
        sat_count <= 0;
    else if ((BitStream_ram_addr < bs_end_addr) || u_nova.end_of_MB_DEC === 1'b1)
        sat_count <= 0;
    else if (sat_count < SAT_FLUSH)
        sat_count <= sat_count + 1;
    else if (frames_done < frames_target) begin
        // 吐出最后一块脏缓冲
        ...
        $display("[TB] end-of-stream flush (bitstream exhausted): emitting last picture from buffer %0d", ...);
    end
end
```

**关键点**：

1. **`BitStream_ram_addr` 到 131071 会饱和不回绕**（`BitStream_buffer.v:116`），
   所以"地址追平 `bs_end_addr`"是可靠的"码流读完"信号
2. **`u_nova.end_of_MB_DEC` 必须层次化引用** —— 它在 nova 内部，不是 tb 端口。
   写成裸名 `end_of_MB_DEC` 会编译成一根悬空 wire（永远 0）→ flush 立刻误触发
3. **`SAT_FLUSH = 2000`** 是个经验值 —— 实测"第 99 个 MB 到末次写帧存只差 211 cycle"
   （`[GAP] mb=99 cyc99=41943 lastwr=42154 gap=211`），2000 足够宽松

**验证**（此时 `IDLE_FLUSH` 还是 5000，所以每帧都被兜底路径抢先吐出）：

```
[TB] bitstream occupies ROM words 0..15517
[TB] end-of-stream flush (bitstream exhausted): emitting last picture from buffer 1
[TB] DONE: 8 pictures, 387924 cycles, 48490 cycles/picture
```

**8 帧 PASS（比特精确）** —— 但如上一节所述，"成功"里藏着主路径失效的隐患，
下一节把它修掉。

**第三版修复时发现的隐藏坑：`IDLE_FLUSH` 不能太小**

修好末帧之后我们回头查了一遍：**`IDLE_FLUSH = 5000` 其实让每一帧都走了
兜底路径，主路径形同虚设**。

实测真实帧边界的间隙（用探针打 `slice_header_s6`）：

```
[PROBE] slice_header_s6 pulse #1 at tb cycle 63
[PROBE] slice_header_s6 pulse #2 at tb cycle 50067
[PROBE] slice_header_s6 pulse #3 at tb cycle 100071
```

而帧内**末次写帧存**发生在约 cycle 42154（见 `[GAP] mb=99 cyc99=41943 lastwr=42154 gap=211`）。
**间隙 = 50067 − 42154 ≈ 7900 周期 > 5000** → `idle_count` 先数满，
兜底路径抢先吐帧，`slice_header_s6` 那条主路径**一次都没轮到**。

**巧合的是**：兜底路径吐出的也是"已经写完的那块缓冲"，所以**像素仍然正确**
（300 帧依然比特精确）。**但这是运气** —— 它掩盖了主路径失效，
一旦有人改动 tb 的时序就会暴露成"帧错位"。

**修正**：把 `IDLE_FLUSH` 提到 **20000**（远大于 7900 的间隙，
又远小于一帧的 50000 周期，不会跨帧误判）。改完后日志变成：

```
[TB] emitted picture 1 at cycle 50067 (t=34046240)     ← 正好是 slice_header_s6 的拍
[TB] emitted picture 2 at cycle 100071
[TB] emitted picture 8 at cycle 400095
[TB] DONE: 8 pictures, 400097 cycles, 50012 cycles/picture
```

**没有一条 "end-of-stream flush" 打印** —— 主路径正常了，
8 帧依然 **PASS（比特精确）**。

**教训**：**兜底逻辑的阈值必须和真实时序对齐后再定，否则它会把主路径悄悄顶掉，
而"结果对"让它更难被发现。**

## 9.3 `bin2hex.py`：.264 → hex 文本

**为什么需要这一步？** 因为 `Beha_BitStream_ram` 是个 `reg [15:0]` 数组，
用 `$readmemh` 读 **hex 文本**。原版 `test/bin2hex.pl` 有两个不便：

1. **输出文件名硬编码**（脚本第 8 行 `$outfile = "akiyo300_1ref.txt";`），
   改输入就得改脚本
2. **奇数长度不补齐** —— 每行写 2 字节，末行可能只有 1 个字节，
   `$readmemh` 读到的最后一个 word 位宽不对

**我们的版本**：

```python
def main():
    src = Path(sys.argv[1])
    dst = Path(sys.argv[2]) if len(sys.argv) > 2 else src.with_suffix(".txt")

    data = src.read_bytes()
    orig_len = len(data)
    if orig_len % 2:
        data += b"\x00"                    # 奇数长度补 1 字节

    with dst.open("w") as f:
        for i in range(0, len(data), 2):
            f.write(f"{data[i]:02X}{data[i+1]:02X}\n")

    n_words = len(data) // 2
    print(f"[bin2hex] {src} -> {dst}")
    print(f"          {orig_len} 字节 = {n_words} 个 16bit word = {n_words} 行")
    if n_words > 131072:
        print(f"[bin2hex] 警告: 超过 Beha_Bitstream_ram_size+1 = 131072 word，尾部会被截断")
```

**格式**：**每行一个 16 bit word、大端序、高位在前**。这与
`Beha_BitStream_ram` 的 `reg [15:0]` 声明和 `BitStream_buffer` 的
`BS_buffer[i] <= BitStream_buffer_input[15-i]`（比特序翻转）配合。

**实测**：`akiyo300_1ref.txt` 131071 行 → 262144 字节 = **300 帧 QCIF**。
其中真实码流只占 **word 0..15517**（约 31 KB），其余是 `$readmemh`
没填到的 X（我们清零成 0）。

**这意味着**：`Beha_Bitstream_ram_size = 131071` 的 256 KB 是"最大容忍"，
真实需求只要 32 KB。**FPGA 移植时可以砍到 1/8。**

## 9.4 `compare_yuv.py`：逐像素比对

**核心论点**（脚本 docstring 原文）：

> H.264 解码器是"比特精确"的规范 —— 给定同一码流，任何符合标准的解码器在
> IDCT、帧内/帧间预测、去块滤波上都必须产生完全相同的像素值（标准只允许在
> IDCT 的中间运算精度上有极小的自由度，JM/x264/ffmpeg 都采用规范附件的
> 简化 IDCT，实际输出一致）。因此 **maxdiff 是否等于 0** 是判断 RTL 功能
> 正确性的最强判据，**比 PSNR 更有意义**。

**用法**：

```bash
python3 scripts/compare_yuv.py nova.yuv ref.yuv [--frames N] [--w 176] [--h 144] [--quiet]
```

**输出**：

```
[compare] nova.yuv vs ref.yuv
[compare] 尺寸 176x144, 单帧 38016 字节, 比对 10 帧
[compare] 帧    平面   maxdiff   mean     不同像素    PSNR(dB)
[compare] 0     Y      0         0.00     0           inf
[compare] 0     U      0         0.00     0           inf
[compare] 0     V      0         0.00     0           inf
...
[compare] 总像素数      : 380160
[compare] 不同像素总数  : 0
[compare] 整序列 PSNR   : inf (比特精确)
[compare] 结果: PASS —— 10 帧全部比特精确，与 ffmpeg 完全一致
```

**FAIL 时的输出**：

```
[compare] 最差单点 : 帧 3 / Y / maxdiff=24
[compare] 整序列 PSNR   : 46.35 dB (等效平均误差 0.38 LSB)
[compare] 结果: FAIL —— 5 帧存在差异 (首帧 0, 末帧 4)
```

**退出码**：`0` = PASS，`1` = FAIL。**这样才能被 `run_regression.sh` 自动判读。**

**为什么不用 PSNR 做判据？** 因为 **PSNR 46 dB 也可能是错的**：
- 一个像素差 24 级（在 8×8 块的边缘）→ 人眼可能看不出，但**规范上说这是 bug**
- 反过来，**一个像素差 1 级遍布全图** → PSNR 也有 48 dB，但**肯定是错的**

**`maxdiff == 0` 没有这种模糊性。**

## 9.5 `run_regression.sh`：一键 6 步

### 用法

```bash
./scripts/run_regression.sh [-b 码流] [-n 帧数] [-f freq] [-t tag] [--nodb] [--encode]

  -b, --bitstream <file>   输入码流（.264 裸流 或 .txt hex 文本；默认 akiyo300_1ref.txt）
  -n, --frames <n>         解码帧数（默认 10）
  -f, --freq <0..3>        freq_ctrl 档位（默认 1）
  -t, --tag <name>         输出文件前缀（默认 regress）
      --nodb               关闭去块滤波
      --encode             用 ffmpeg 现编一段测试码流（testsrc QCIF + libx264）
      --encode-from <yuv>  用指定的 YUV 编测试码流
```

### 6 个步骤

```
[1/6] 准备码流
[2/6] ffmpeg 参考解码
[3/6] iverilog 编译
[4/6] vvp 仿真
[5/6] 逐像素比对
[6/6] 帧数完整性检查
```

#### [1/6] 准备码流

**两条路径**：

**(a) 输入已经是 `.txt` hex 文本**（如 `akiyo300_1ref.txt`）：
内嵌一段 python 把它还原成 `.264`，供 ffmpeg 用。

```python
# 内嵌 heredoc
data = bytes.fromhex("".join(line.strip() for line in open(txt)))
open(raw264, "wb").write(data)
```

**(b) 输入是 `.264` 裸流**：调 `bin2hex.py` 转成 `.txt`。

**(c) `--encode`：现场用 ffmpeg 编一段**

```bash
# 生成 10 秒 QCIF 测试序列
ffmpeg -f lavfi -i "testsrc=size=176x144:rate=30:duration=10" \
       -pix_fmt yuv420p -f rawvideo vectors/testsrc_qcif.yuv
# 编成 H.264 baseline
ffmpeg -f rawvideo -pix_fmt yuv420p -s 176x144 -r 30 -i vectors/testsrc_qcif.yuv \
       -c:v libx264 -profile:v baseline -level 1.0 \
       -x264-params "keyint=30:min-keyint=30:ref=1:slices=1" \
       -qp 28 -f h264 vectors/testsrc_libx264.264
```

**注意 `-x264-params` 里的四个约束**：

| 参数 | 为什么 |
|---|---|
| `keyint=30` | 每 30 帧一个 IDR（便于单帧提取）|
| `min-keyint=30` | 固定 GOP，不做场景切换检测 |
| `ref=1` | **只 1 个参考帧**（nova 的 `mvx_mbAddrB_RF` 只有 11 位 = 32 个 8×8 块）|
| `slices=1` | **每帧单 slice**（nova 不支持多 slice）|

#### [2/6] ffmpeg 参考解码

```bash
ffmpeg -v error -i "$RAW264" -f rawvideo -pix_fmt yuv420p "$REF_YUV"
```

**`-f rawvideo -pix_fmt yuv420p`** = 输出裸 YUV420p，**与 nova 的输出格式完全一致**。

**踩过的坑**：**不要** `ffmpeg -i xxx.txt` —— ffmpeg 会把它当成
**文本文件**（因为有 `.txt` 扩展名？不，是因为内容不是合法 H.264），
输出 1 GB 的垃圾。**必须先 `bin2hex` 反着转回 `.264`。**

#### [3/6] iverilog 编译

```bash
iverilog -g2005 -o out/nova_tb.vvp -s tb_nova -I rtl tb/tb_nova.v rtl/*.v 2>&1 \
    | grep -v -i "inherited from another\|The inherited timescale\|sorry: implicit\|implicit definition" \
    > out/${TAG}_build.log.filtered
```

**`-g2005`**：Verilog-2005 模式（`-g2001` 也行，但 `-g2005` 更宽松）
**`-s tb_nova`**：指定顶层模块（因为 `rtl/*.v` 里没有别的顶层）
**`-I rtl`**：`include` 搜索路径（`nova_defines.v`、`timescale.v`）

**过滤掉的告警**（无害）：

- `timescale inherited from another`（147 条）—— 只有 `timescale.v` 有声明，
  其余文件继承
- `sorry: implicit definition`（4 条）—— 原 `nova_tb.v` 里没声明的 wire

**编译结果**：**零错误**，约 5 MB 的 `.vvp`。

#### [4/6] vvp 仿真

```bash
vvp out/nova_tb.vvp +bitstream="$HEX" +out="$NOVA_YUV" \
    +frames=$FRAMES +freq=$FREQ +maxcyc=$((FRAMES*120000+200000)) 2>&1 \
    | grep -v "screen size is bogus" > out/${TAG}.log
```

**`+maxcyc`** 的算法：`帧数 × 120000 + 200000`。**120000 是单帧最坏周期数**
（48000 × 2.5 倍余量），200000 是启动余量。

**`grep -v "screen size is bogus"`** —— iverilog 的 `$fwrite` 在某些
终端环境下会打这条无关告警。

#### [5/6] 逐像素比对

```bash
python3 scripts/compare_yuv.py "$NOVA_YUV" "$REF_YUV" --frames $FRAMES
CMP_RC=$?
```

#### [6/6] 帧数完整性检查

```bash
python3 - "$NOVA_YUV" "$FRAMES" <<'EOF'
import sys, pathlib
frame = 176*144*3//2     # 38016
size = pathlib.Path(sys.argv[1]).stat().st_size
want = int(sys.argv[2]) * frame
print(f"[check] {size} 字节 = {size//frame} 帧 (期望 {sys.argv[2]} 帧)")
sys.exit(0 if size == want else 1)
EOF
CHK_RC=$?
```

**为什么要单独检查帧数？** 因为 `compare_yuv.py` 只比对
`min(nova帧数, ref帧数)` 帧 —— 如果 nova 只吐出 9 帧而期望 10 帧，
**比对会 PASS（9 帧全对），但帧数不对**。

**最后**：`CMP_RC == 0 && CHK_RC == 0` 才打印 PASS。

## 9.6 最重要的结果：300 帧比特精确

### 命令

```bash
vvp out/nova_tb.vvp \
    +bitstream=../test/bitstream/akiyo300_1ref.txt \
    +out=out/nova_akiyo300.yuv +frames=300 +maxcyc=20000000
```

### 耗时

**约 19 分钟**（纯事件驱动软件仿真，1.47 MHz 的 1498 万周期）。

**为什么这么慢？** iverilog 是**解释执行**，每个时钟沿要跑 2 万多个
always 块。实测速度约 **3.8 秒/帧**（300 帧 / 19 分钟）。作为对比，
同样的码流用 `ffmpeg` 解码只要 **几十毫秒** —— 差了四个数量级。
这就是"用 RTL 仿真验证正确性"的代价。

### 结果

```
[TB] bitstream occupies ROM words 0..15517
[TB] emitted picture 1 at cycle 50067 (t=34046240)
[TB] emitted picture 2 at cycle 100071 (t=68048960)
...
[TB] emitted picture 298 at cycle 14901255 (t=10132854080)
[TB] emitted picture 299 at cycle 14951259 (t=10166856800)
[TB] end-of-stream flush (bitstream exhausted): emitting last picture from buffer 1
[TB] emitted picture 300 at cycle 14986141 (t=10190576560)
[TB] DONE: 300 pictures, 14986143 cycles, 49954 cycles/picture
```

注意 `[TB] end-of-stream flush` 在两处出现其实是**同一行日志**（第 300 帧），
它只在最后一帧触发：末帧后面没有下一帧的 slice header，所以走"码流耗尽"兜底。
**前 299 帧全部走 `slice_header_s6` 主路径** —— 这正是 9.2 节修正
`IDLE_FLUSH = 20000` 之后应有的行为（修正前是每帧都走兜底）。

**比对结果**：

```
[compare] nova_akiyo300.yuv vs akiyo300_ref.yuv
[compare] 尺寸 176x144, 单帧 38016 字节, 比对 300 帧
[compare] 帧    平面   maxdiff   mean     不同像素    PSNR(dB)
[compare] 0     Y      0         0.00     0           inf
[compare] 0     U      0         0.00     0           inf
[compare] 0     V      0         0.00     0           inf
...
[compare] 总像素数      : 11404800
[compare] 不同像素总数  : 0
[compare] 最差单点 : 无
[compare] 整序列 PSNR   : inf (比特精确)
[compare] 结果: PASS —— 300 帧全部比特精确，与 ffmpeg 完全一致
```

**11404800 个像素，零差异。** 这是整个项目最强的正确性证据。

### 这个结果证明了什么

**每一个实现细节都被验证了**：

| 被验证的设计 | 如果错会怎样 |
|---|---|
| CAVLC 熵解码 | 全图乱码 |
| 反量化 + IDCT 的移位/舍入 | 整帧偏色或出现块效应 |
| **IsHadamard 的两次变换归一化**（第 4 章）| **整帧 DC 偏移 2 倍** |
| 帧内 9 种模式的加权系数 | 预测块方向错 |
| **"种子"法的 16/4 bit 移位切换**（第 5 章）| **plane 模式整块偏色** |
| 6-tap 滤波的 `+16 >> 5` | 分数像素位置轻微偏差 |
| **`H_need_round` 的例外条件**（第 6 章）| **j 位置像素精度丢失** |
| 色度双线性的 `+32 >> 6` | 色度偏 |
| DF 的 **beta 表移位减法** | 阈值错 → 滤波不足或过度 |
| DF 的 `clip_to_c` 边界 | 边缘出现锯齿 |
| **40 个门控时钟的使能条件** | **某个寄存器少更新一次 → 局部错块** |

**特别是最后一条**：门控时钟写错一个 bit，某个寄存器就少更新一次。
**这种 bug 极难用波形看出来，但一定会在像素上暴露。**

## 9.7 性能测量：四档变频

### 先说说"怎么测才准"

这一节的数据我们测了**三遍**，前两遍都是错的。踩过的坑值得先讲清楚：

| 版本 | 做法 | 结果 | 为什么错 |
|---|---|---|---|
| 第一版 | `-n 4`，用第 3 帧完成周期 ÷ 3 | 41709 / 44209 / 47859 / 54209 | 混入了启动填充和帧边界等待，**不是稳态值** |
| 第二版 | `-n 8`，但 `IDLE_FLUSH` 还是 5000 | 每帧都被 flush 兜底抢先吐出 | **时间戳本身不可信**（见 9.2 节） |
| 第三版 | `-n 14`，`IDLE_FLUSH = 20000` | 见下 | ✅ |

**教训**：**性能数据和功能正确性一样，会被"兜底逻辑"污染**。
测性能之前先确认你测的那条路径是主路径。

### 逐帧时间戳（`freq=0`，`+frames=14`）

```
[TB] emitted picture 1 at cycle 45067
[TB] emitted picture 2 at cycle 90071
[TB] emitted picture 3 at cycle 135075
[TB] emitted picture 4 at cycle 180079
...
[TB] emitted picture 14 at cycle 630119
[TB] DONE: 14 pictures, 630121 cycles, 45009 cycles/picture
```

**每帧精确 +45004 周期**，一路线性。这是修好 tb 之后才有的干净曲线。

### 四档结果

```bash
for f in 0 1 2 3; do
    vvp out/nova_tb.vvp +bitstream=../test/bitstream/akiyo300_1ref.txt \
        +out=/tmp/f$f.yuv +frames=14 +freq=$f
done
```

| `freq_ctrl` | `cycles_per_frame` | 14 帧稳态 cycles/帧 | 逐帧增量 | 与设定值之差 |
|---|---|---|---|---|
| `0`（`00`）| 45000 | **45009** | 45004 | +4 |
| `1`（`01`，默认）| 50000 | **50009** | 50004 | +4 |
| `2`（`10`，default）| 57300 | **57046** | 53352~57937（抖动）| −254 |
| `3`（`11`）| 70000 | **68839** | 61265~70637（抖动）| −1161 |

### 观察 1：`freq=0/1` 时，每帧周期 = `cycles_per_frame` + 4

不是"约等于"，是**精确到 1 个周期**：

```
45004 = 45000 + 4
50004 = 50000 + 4
```

**这 4 个周期是帧边界握手开销**（`end_of_one_frame` 拉高到解析器真正启动）。
说明这两档下**重建流水线有富余，完全在等速率控制的放行信号**。

### 观察 2：`freq=2/3` 反而开始抖动

`freq=2` 的逐帧增量在 53352~57937 之间跳，`freq=3` 在 61265~70637 之间跳。
**抖动来自"重建偶尔追不上"**：某些帧的重建时间接近 `cycles_per_frame`，
于是这帧被算力主导、下一帧又被速率控制主导。

**这提示了一个重要事实**：`cycles_per_frame` 调到很大时，
瓶颈会从"速率控制"转移到"重建算力"，而后者是**内容相关的**（会抖）。

### 观察 3：MB 级速率与 `freq_ctrl` 完全无关

用一个探针统计**帧内相邻 MB 起始时刻的间隔**（跳过帧边界）：

```
cf=0  [RATE] in-frame avg MB period = 330 cycles over 980 MBs
cf=1  [RATE] in-frame avg MB period = 330 cycles over 980 MBs
cf=2  [RATE] in-frame avg MB period = 330 cycles over 980 MBs
cf=3  [RATE] in-frame avg MB period = 330 cycles over 980 MBs
```

**四档一模一样，都是 330 cycles/MB。**

这是本节最重要的一个结论：**`freq_ctrl` 只控制"解析器什么时候开始解下一帧"，
它完全不改变重建流水线跑一个 MB 的速度。** 想让每个 MB 更快，只能改 RTL；
想让帧率更高，才去调 `freq_ctrl`。这两件事是正交的。

### 真正的算力下限：二分法找到 42100

既然 `freq=0` 实测 45009，那 `cf0` 能不能设小一点？我们把
`nova_defines.v` 里的 `cycles_per_frame0` 一路往下改，跑 10 帧比对：

| `cycles_per_frame0` | 结果 | 不同像素数 |
|---|---|---|
| 40000 | FAIL | 179127 |
| 42000 | FAIL | 1536 |
| 42085 | FAIL | 440 |
| 42090 | FAIL | 240 |
| 42095 | FAIL | 40 |
| **42100** | **PASS** | **0** |
| 42105 | PASS | 0 |
| 43000 | PASS | 0 |
| 45000（出厂值）| PASS | 0 |

**阈值精确落在 42100**（`42095` 差 40 个像素，`42100` 干净）。
用 30 帧和 300 帧复验：

```
cf0=42095 (30f)  不同像素总数: 120    → FAIL
cf0=42100 (30f)  不同像素总数: 0      → PASS
cf0=42100 (300f) 300 帧全部比特精确，与 ffmpeg 完全一致
```

**所以 akiyo 的真实算力需求是 42100 cycles/帧，作者给的是 45000，余量 6.4%。**

**为什么差 40 个像素？** 因为 `cf0` 太小的时候，**下一帧的 slice header
会在上一帧的重建尾部（DF 写回帧存）还没结束时就到达**，
覆盖掉参考帧的最后一小块。这正好解释了"差一点点"的现象 ——
不是全错，是**帧尾最后几个像素被下一帧踩掉**。

**这也说明作者选 45000 是有道理的**：akiyo 是极端简单的序列
（83% 的 MB 是 skip），换成 foreman 需要更多余量 —— 这就是
`nova_defines.v` 注释里那串加码历史（50000→…→57300）的由来。

### 按 MB 类型分解每 MB 周期

```verilog
// 探针：在 end_of_MB_DEC 的上升沿读 mb_type_general，累计间隔
t = tb_nova.u_nova.mb_type_general;
cnt[t] = cnt[t] + 1;
tot[t] = tot[t] + ($time/680 - prev);
```

跑 41 帧（统计第 3~40 帧，避开 IDR 和启动），结果：

| `mb_type` | 含义 | 出现次数 | **cycles/MB** |
|---|---|---|---|
| `5` | P_skip | 3080（83%）| **326** |
| `0` | Inter16x16 | 239 | **422** |
| `1` | Inter16x8 | 92 | 432 |
| `2` | Inter8x16 | 136 | 433 |
| `4` | P_8x8 | 177 | **515** |

**这张表推翻了我们文档早期的说法**（旧版写"skip 634 / inter 441"，
那是 flush bug 时期的错误数据）。真实规律非常直觉：

- **skip MB 最快（326）**：跳过 MV 解码、跳过残差、跳过 IQIT，直接复制参考块；
- **P_8x8 最慢（515）**：4 个 8×8 子块各自有 MV，预加载窗口要跑 4 次；
- 16×16 / 16×8 / 8×16 介于中间（422~433），因为都只需预加载一次。

**加权平均**：`3080×326 + 239×422 + 92×432 + 136×433 + 177×515` ÷ 3724
≈ **337 cycles/MB**，与上面独立测到的 330 吻合（差 2%，来自统计窗口不同）。

### I 帧才是 `cf0` 下界的真正来源

再看第一帧（IDR，全 intra）的 MB 间隔：

```
[IF] mb=1 start=873  delta=401
[IF] mb=2 start=1211 delta=338
[IF] mb=3 start=1515 delta=304
...
[IF] mb=97 start=41651 delta=492
[IF] mb=98 start=41934 delta=283
[IF] === frame boundary at 42167, last MB start 41934, gap to boundary = 233 ===
```

第 1 帧从 MB1（873）到 MB98（41934）共 **41061 周期 / 97 个 MB = 423 cycles/MB**，
整帧约 **41.9k 周期** —— 与二分找到的 **42100** 几乎重合。

**而 P 帧只有 330 cycles/MB（99 MB ≈ 32.7k）。**

所以 `cf0` 的下界**不是由 P 帧决定的，是由那一帧 I 帧决定的**。
这是"混合编码"的典型特征：**平均算力看 P 帧，最坏算力看 I 帧**，
而速率控制必须按最坏情况设。

### DF 实测：209 cycles/MB（论文说 204）

**这是最有说服力的数据点。** 用一个探测模块测 `DF_duration` 的高电平宽度：

```verilog
// /tmp/df.v
always @ (posedge tb_nova.clk)
    if (tb_nova.u_nova.reconstruction.DF_top.DF_pipeline.DF_duration) df_width = df_width + 1;
    else if (df_width != 0) begin
        $display("[DF] duration = %0d cycles", df_width);
        df_width = 0;
    end
```

**结果**：

```
[DF] duration = 209 cycles
[DF] duration = 209 cycles
[DF] duration = 209 cycles
...（连续 90 个 MB 全是 209）
```

**209 vs 论文的 204，差 5 个周期（2.5%）**。

**这 5 个周期是什么？** **流水线填充与排空**：

```
        ┌─ MR ─┬─ TD ─┬─ PRE ─┬─ FIR ─┬─ MW ─┐
第 1 条边│  ●   │      │       │       │      │
第 2 条边│      │  ●   │       │       │      │
...
第 48 条 │      │      │       │       │  ●   │
         └──────┴──────┴───────┴───────┴──────┘
填充 4 拍 + 排空 1 拍 = 5 拍
```

**论文的 204 = 48×4 + 12 是"稳态吞吐"**（每 MB 平均），
**实测 209 是"端到端延迟"**（从第一个 MR 到最后一个 MW）。
两者都对，只是定义不同。

## 9.8 去块滤波关闭实验：量化 DF 的贡献

```bash
./scripts/run_regression.sh -b ../test/bitstream/akiyo300_1ref.txt \
    -n 5 --nodb -t nodb
```

`--nodb` 让 tb 把 `pin_disable_DF` 拉高 1，**nova 整个 DF 流水线被旁路**。

**结果**：

```
[compare] 帧 0 / Y / maxdiff=24  mean=0.83  不同像素=75947  PSNR=46.35 dB
[compare] 结果: FAIL —— 5 帧存在差异
```

**解读**：

- **maxdiff = 24** —— 最大单点差 24 级（在块边界，**这正是 DF 要修的东西**）
- **75947 / 190080 = 40%** 的像素不同 —— DF 影响 40% 的像素（每 4×4 块有
  4 条边，40% 合理）
- **PSNR = 46.35 dB** —— **听起来很好，但这就是"PSNR 不够用"的例子**：
  46 dB 通常被认为是"视觉无损"，但这里**规范上说这是错的**

**这个实验的价值**：

1. **量化了 DF 的贡献**：46 dB（不滤波）→ ∞（滤波）
2. **验证了"PSNR 不是好判据"**：46 dB 是 FAIL
3. **给读者一个"故意引入错误"的对照**：改一行 `pin_disable_DF` 就能看到
   DF 到底在做什么

## 9.9 重大发现：nova 不能解通用 x264 码流

**这是整个调研最重要的发现之一。**

### 实验

```bash
./scripts/run_regression.sh --encode -n 5 -t enc_test
```

用 ffmpeg `testsrc` + `libx264 -profile:v baseline -qp 28` 编 5 帧，
**期望**：nova 应该能解（Baseline Profile 嘛）。

**实际**：

```
[compare] 帧 0 / Y / maxdiff=255  mean=124.5  不同像素=25344  PSNR=4.93 dB
[compare] 结果: FAIL —— 5 帧存在差异
```

**PSNR 4.93 dB = 完全没解对。**

### 排查过程

**第 1 步：排除帧序错位**

逐帧交叉比对（nova 的 5 帧 × ref 的 5 帧，25 种组合）：

| nova 帧 \ ref 帧 | 0 | 1 | 2 | 3 | 4 |
|---|---|---|---|---|---|
| **0** | 4.93 | 4.93 | 4.93 | 4.93 | 4.93 |
| **1** | 4.93 | 4.93 | 4.93 | 4.93 | 4.93 |
| ... | ... | ... | ... | ... | ... |

**所有组合都是 4.93 dB** —— 不是错位，是**根本没解对**。

**第 2 步：看 nova 的输出**

```bash
python3 -c "
import numpy as np
y = np.fromfile('out/enc_test_nova.yuv', dtype=np.uint8)
print('均值:', y[:25344].mean())      # 0.54（应该 125）
print('不同取值数:', len(set(y[:25344].tolist())))   # 31
print('前 8 像素:', y[:8].tolist())   # [128, 0, 0, 0, 0, 0, 0, 0]
"
```

**均值 0.54、只有 31 种取值、首像素 128 后全 0** ——
**这不是"解错了"，这是"没解"**（只解出了第一个 MB 的 DC 然后停住）。

**第 3 步：去掉 SEI**

```bash
ffmpeg -i testsrc.264 -c copy -bsf:v filter_units=remove_types=6 testsrc_nosei.264
./scripts/run_regression.sh -b vectors/testsrc_nosei.264 -n 5 -t nosei
```

**仍然 FAIL（同样 4.93 dB）** —— **SEI 不是主因**。

**第 4 步：砍出单帧**

```bash
ffmpeg -i testsrc.264 -c copy -frames:v 1 vectors/testsrc_frame0.264
# 2902 字节，ffmpeg 能正常解出 1 帧，且与完整序列第 0 帧完全相同
vvp out/nova_tb.vvp +bitstream=out/testsrc_frame0.txt +frames=1 +maxcyc=320000
```

**结果**：**跑 320001 周期解不出任何帧**。

**第 5 步：看卡在哪**

```verilog
// /tmp/probe_tb.v
always @ (posedge tb_nova.clk) begin
    $display("[PROBE] parser=%0d nal=%0d sps=%0d slice_header=%0d slice_data=%0d pc=%0d valid_n=%b ram_addr=%0d",
        tb_nova.u_nova.BitStream_controller.parser_state,
        tb_nova.u_nova.BitStream_controller.nal_unit_state,
        tb_nova.u_nova.BitStream_controller.seq_parameter_set_state,
        tb_nova.u_nova.BitStream_controller.slice_header_state,
        tb_nova.u_nova.BitStream_controller.slice_data_state,
        tb_nova.u_nova.BitStream_controller.pc_decoding.pc,
        tb_nova.u_nova.BitStream_buffer.BitStream_buffer_valid_n,
        tb_nova.u_nova.BitStream_ram_addr);
end
```

**输出**（节选）：

```
[PROBE] parser=1 nal=0 sps=0 slice_header=0 slice_data=0 pc=96 valid_n=1 ram_addr=5
[PROBE] parser=1 nal=0 sps=0 slice_header=0 slice_data=0 pc=96 valid_n=1 ram_addr=5
[PROBE] parser=1 nal=0 sps=0 slice_header=0 slice_data=0 pc=96 valid_n=1 ram_addr=5
...
```

**`parser_state=1`（`start_code_prefix`）、`nal_unit_state=0`、`pc=96` 永远不动。**

**`ram_addr=5`** —— **只读了 5 个 word（10 字节）就停了！**

**第 6 步：对比 SPS**

用 ffmpeg 的 `trace_headers` 或手算，对比两个码流的 SPS：

| 字段 | JM94 akiyo | x264 testsrc |
|---|---|---|
| `profile_idc` | 66（Baseline）| 66（Baseline）|
| `level_idc` | 30 | 10 |
| **`pic_order_cnt_type`** | **0** | **2** ← 关键差异！ |
| `log2_max_frame_num_minus4` | 0 | 0 |
| `log2_max_pic_order_cnt_lsb_minus4` | 6 | （不存在！poc_type=2 时无此字段）|
| `vui_parameters_present_flag` | 0 | 1 |

### 根因：SPS 解析器是硬连线固定序列

**`BitStream_parser_FSM_gating.v:202-216`**：

```verilog
// SPS 解析状态机（原文，无 pic_order_cnt_type 分支！）
`seq_parameter_set_id_sps_s:
    seq_parameter_set_state <= `log2_max_frame_num_minus4_s;
`log2_max_frame_num_minus4_s:
    seq_parameter_set_state <= `pic_order_cnt_type_s;
`pic_order_cnt_type_s:
    seq_parameter_set_state <= `log2_max_pic_order_cnt_lsb_minus4_s;   // ← 无条件！
`log2_max_pic_order_cnt_lsb_minus4_s:
    seq_parameter_set_state <= `num_ref_frames_s;
`num_ref_frames_s:
    seq_parameter_set_state <= `gaps_in_frame_num_value_allowed_flag_s;
...
```

**问题**：H.264 规范说 `log2_max_pic_order_cnt_lsb_minus4` **只在
`pic_order_cnt_type == 0` 时存在**。`poc_type == 2` 时这个字段**根本不在码流里**。

**nova 无条件读它** → **整个字段序列错位**：

| 位置 | nova 以为在读 | 实际读到的是 |
|---|---|---|
| `log2_max_poc_lsb_m4` | 6 bit | x264 的 `num_ref_frames` |
| `num_ref_frames` | ue(v) | x264 的 `gaps_flag` + 后续位 |
| `gaps_in_frame_num_value_allowed_flag` | 1 bit | 错位的位 |
| `pic_width_in_mbs_minus1` | ue(v) | **错的宽高** |
| `pic_height_in_map_units_minus1` | ue(v) | **错的高** |

**结果**：`pic_width` / `pic_height` 全错 → 后续 `mb_num_h`/`mb_num_v`
比较全错 → **`mb_num == 98` 永远不成立 → 永远不吐帧**。

**`slice_header` 也一样**（`BitStream_parser_FSM_gating.v:257`）：

```verilog
`frame_num_s:
    // 无条件解析 pic_order_cnt_lsb（poc_type=2 时不存在）
    slice_header_state <= `pic_order_cnt_lsb_s;
```

### 第二个独立缺陷：NAL 类型缺分支

**`BitStream_parser_FSM_gating.v:170-176`**：

```verilog
// 原文
case (nal_unit_type)
    5'b00001: nal_unit_state <= `slice_layer_wo_partitioning_state;  // non-IDR
    5'b00101: nal_unit_state <= `slice_layer_wo_partitioning_state;  // IDR
    5'b00111: nal_unit_state <= `seq_parameter_set_state;            // SPS
    5'b01000: nal_unit_state <= `pic_parameter_set_state;            // PPS
    // ← 没有 default！
endcase
```

**缺 type 6（SEI）、type 9（AUD）**，**且没有 `default`**。

**后果**：遇到 SEI/AUD 时，状态机**保持当前状态不动**（case 无匹配就什么都不做），
**死锁在 `forbidden_zero_bit_2_nal_unit_type` 状态**。

**为什么 `--encode` 时去掉 SEI 仍然 FAIL？** 因为 **poc_type 的问题更严重**
（SPS 都解析错了，后面全错）。SEI 是"第二个独立的坑"。

### 为什么 JM94 可以，x264 不行

| | JM94（authors 用的参考软件）| x264（现代默认）|
|---|---|---|
| `pic_order_cnt_type` | **0**（默认）| **2**（baseline profile 强制）|
| SEI | 无 | **有**（x264 总是写 SEI user data）|
| AUD | 无 | 通常有 |
| 单 slice | 是 | 是（但 `slices` 参数可改）|

**JM94 的默认输出正好落在 nova 支持的子集里**，所以作者的 10 个测试序列全过。
**x264 的默认输出不在**，所以直接 FAIL。

### x264 能编出 poc_type=0 吗

```bash
# 加 -profile:v baseline → 强制 poc_type=2
ffmpeg ... -c:v libx264 -profile:v baseline ... → poc_type=2  ❌

# 去掉 profile，用 x264-params 关掉相关工具
ffmpeg ... -c:v libx264 -x264-params "bframes=0:cabac=0" ... → poc_type=0 ✓
# 但 profile 变成 High（8×8 变换、CABAC 相关工具都在），nova 仍不支持
```

**结论**：**用 x264 编不出"nova 能解的 Baseline 子集"**。
要测试 nova，只能用 **JM 参考软件**（或 JM 的编码配置）。

### 这个发现的意义

**对想复用 nova 的人**：

1. **别指望"喂什么码流都能解"** —— 它是个**论文验证载体**，不是产品解码器
2. **移植第一步是确认码流来源** —— 如果是现代编码器输出，**必须先修 SPS 解析器**
3. **修 SPS 解析器不难**（加一个 `pic_order_cnt_type` 分支，约 20 行），
   但**这是必须做的**

## 9.10 本章小结

### 环境的三层价值

| 层 | 文件 | 价值 |
|---|---|---|
| **能跑** | `setup_rtl.sh` + `tb_nova.v` | 把"作者的开发机"变成"任何机器" |
| **能验** | `compare_yuv.py` + `run_regression.sh` | 把"看着像"变成"零差异" |
| **能测** | plusargs + 四档变频 + `--nodb` | 把"功能对"变成"性能也对" |

### 关键数字

| 项 | 值 | 意义 |
|---|---|---|
| **300 帧比对** | **0 个像素不同** | 功能正确性的最强证据 |
| 单帧周期 | 49954（akiyo，300 帧均值）| 对上规格书 1.5 MHz |
| **MB 稳态** | **330 cycles/MB**（P 帧，与 `freq_ctrl` 无关）| 帧率与 MB 速度正交 |
| MB 类型差异 | skip 326 / 16×16 422 / P_8x8 515 | 差距来自 MC 预加载次数 |
| **DF 实测** | **209 cycles/MB** | 对上论文 204（+5 流水填充）|
| DF 占比 | 209/330 ≈ **63%** | 为什么 DF 论文值得单独写 |
| 速率控制下限 | `cf0 = 42100`（二分法）| 出厂 45000，余量 6.4% |
| 关 DF | PSNR 46.35 dB | 证明"PSNR 不是好判据" |
| x264 | PSNR 4.93 dB | **证明 nova 只支持 Baseline 子集** |

### 三个教训

1. **`$readmemh` 前必须清零，且同一个 initial 块** —— 拆块会擦码流
2. **末帧要自己 flush** —— nova 的帧边界来自"下一帧"
3. **`ffmpeg -i xxx.txt` 会生成垃圾** —— 必须先还原成 `.264`

---

**上一章** ← [08-存储组织与时钟门控.md](08-存储组织与时钟门控.md) ｜
**下一章** → [10-兼容性陷阱与移植指南.md](10-兼容性陷阱与移植指南.md)
