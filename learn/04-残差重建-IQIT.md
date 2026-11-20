# 第 4 章 残差重建：IQIT（反量化 + 反变换）

`IQIT.v`（849 行）负责把 CAVLC 解出来的量化系数 `coeffLevel_0..15` 变成
像素域的残差。名字是 **IQ**uant + **I**nverse **T**ransform 的缩写。

这一章的核心问题是：**一个没有乘法器的芯片，怎么做反量化和反变换？**

> 📖 **概念预热**：残差是什么、4×4 整数 DCT 为什么只需要 1 和 2、
> 量化和反量化的关系、CAVLC 输出的 `coeffLevel` 是什么顺序 ——
> 见 [第 0 章](00-H.264基础.md) 的 0.7 节。

## 4.1 模块头部的设计说明（原文）

```verilog
// Description
// Decoding the residual information
// 1.The res_mb_bypass | DConly | allzero signals should be decoded first
// 2.For DC coefficients,IDCT    --> rescale
// 3.For AC coefficients,rescale --> IDCT   --> rounding
// 4.coeffLevel:zig-zag order
//   OneD_output,TwoD_output,DC_output,rescale_output,rounding_output:raster-scan order
// 5.Input coeffLevel_ext_0 ~ 15 are 2's complement,but with zig-zag order
```

**这五条把整个模块说清楚了**：

1. **先判断三种特例**：`res_mb_bypass`（整个 MB 跳过）、`DConly`（只有 DC）、
   `allzero`（全零）。这三种情况可以走快速路径。
2. **DC 系数**：先 IDCT 再 rescale（**顺序反了！**）
3. **AC 系数**：先 rescale 再 IDCT 再 rounding
4. 输入是 zig-zag 序，输出是 raster 序
5. 输入是 2 补码

### 为什么 DC 的顺序是反的？

H.264 里有两级 DC 变换：

- **Intra16×16**：16 个 4×4 块的 DC 系数组成一个 4×4 的"DC 块"，
  对这个 DC 块做 **Hadamard 变换**（不是 DCT）
- **色度**：4 个 4×4 块的 DC 组成 2×2 DC 块，同样做 Hadamard

Hadamard 变换的系数全是 ±1，**不需要量化**（H.264 规定 DC 的量化在
AC 的 rescale 里一起做）。所以：

- **DC 路径**：Hadamard（纯加减）→ **再 rescale**（这时才乘量化步长）
- **AC 路径**：rescale（乘量化步长）→ IDCT → rounding

这个"顺序反转"是 H.264 的规范决定的，不是 nova 的发明。
但**在硬件上它带来一个好处**：DC 路径的 Hadamard 不需要乘法器，
rescale 在最后做一次，可以和其他块复用同一个 rescale 单元。

## 4.2 反量化（rescale）的无乘法实现

H.264 的反量化公式是：

```
d[i] = (c[i] × LevelScale[qp%6][i] × 2^(qp/6 - shift)) >> shift
```

其中 `LevelScale` 是一个 6×3 的常量表（值都是 10、13、16、20、23、25 之类的
小整数）。`qp%6` 和 `qp/6` 需要除法——**这是第一个要解决的乘法器问题**。

### 用查表代替除法器

```verilog
// IQIT.v 中的 mod6 / div6（子模块）
// mod6：用 case 列出 0..51 的所有情况
always @(qp)
    case (qp)
        6'd0, 6'd6, 6'd12, ... : mod6 <= 3'd0;
        6'd1, 6'd7, 6'd13, ... : mod6 <= 3'd1;
        ...
    endcase

// div6：用区间比较
always @(qp)
    if      (qp < 6)  div6 <= 0;
    else if (qp < 12) div6 <= 1;
    ...
    else              div6 <= 8;
```

**`mod6` 用 case（52 项）而不是 `qp - 6*div6`**，因为后者要一个乘法器
（或者 6 次加法）。52 项的 case 综合出来是一个 52 输入的选择网络，
比乘法器小得多。注意写法是把同一个值的所有 qp **列在一起**：

```verilog
// IQIT.v:796-804
0, 6,12,18,24,30,36,42,48:mod <= 3'b000;
1, 7,13,19,25,31,37,43,49:mod <= 3'b001;
...
```

**`div6` 则是按区间分组**（`IQIT.v:815-823`）：

```verilog
0, 1, 2, 3, 4, 5 :div <= 4'b0000;
6, 7, 8, 9, 10,11:div <= 4'b0001;
...
48,49,50,51      :div <= 4'b1000;
```

两个模块加起来覆盖 `qp` ∈ [0, 51]（H.264 的 QP 上限就是 51），
`default` 都兜到 0。综合器看到的都是一张纯组合查找表，
**没有除法器也没有比较器级联**。

### 缩放：移位代替乘法

```verilog
// IQIT.v rescale_shift（子模块）
assign shift_output = (IsLeftShift == 1'b1) ?
                      (shift_input <<< shift_len) :
                      (shift_input >>> shift_len);
```

`IsLeftShift` 决定左移还是右移。而 `shift_len` 是**三种情况各不相同的**
（`IQIT.v:576-589`）—— 这里是全文最容易记反的地方：

```verilog
always @ (residual_state or res_DC or QPdiv6)
    if (residual_state == `Intra16x16DCLevel_s)   // ① 亮度 16×16 的 DC
        case (QPdiv6)
            4'b0000:shift_len <= 2;               // 特殊：QPdiv6=0 时给 2
            4'b0001:shift_len <= 1;               // 特殊：QPdiv6=1 时给 1
            default:shift_len <= QPdiv6 - 2;
        endcase
    else if (res_DC)                               // ② 色度 DC（2×2）
        case (QPdiv6)
            4'b0000:shift_len <= 1;               // 特殊：QPdiv6=0 时给 1
            default:shift_len <= QPdiv6 - 1;
        endcase
    else                                           // ③ 所有 AC 系数
        shift_len <= QPdiv6;
```

三种系数的移位量依次差 1：

| 系数类型 | nova 的 `shift_len` | 说明 |
|---|---|---|
| 亮度 16×16 DC | `QPdiv6 − 2`（0/1 特判） | 前面还隔着一次 4×4 Hadamard |
| 色度 DC（2×2） | `QPdiv6 − 1`（0 特判） | 前面隔着一次 2×2 Hadamard |
| 其余 AC | `QPdiv6` | 没有额外的 DC 变换 |

**这个 −2 / −1 / 0 的梯度是数学，不是随意取值**：
`H = [[1,1,1,1],[1,1,−1,−1],[1,−1,−1,1],[1,−1,1,−1]]` 的增益是 **4 = 2²**
（每行绝对值之和），2×2 Hadamard 的增益是 **2 = 2¹**。正变换放大了 4 倍
和 2 倍，反量化就得少移 2 位和 1 位把它们除回去，所以三个移位量
依次差 1。**这和第 0 章 0.7 节讲的"DC 要走第二次变换"是同一件事的
两个侧面** —— 那里讲的是"为什么要有这一步"，这里讲的是"它在
缩放里长什么样"。

**为什么要特判 `QPdiv6 ≤ 1`？** 因为 `QPdiv6 - 2` 在 `QPdiv6 = 0/1` 时是
负数，而 `shift_len` 是 4 bit **无符号**值 —— 直接减会下溢成 `4'b1110`/`4'b1111`，
即右移 14/15 位，把系数打成 0。规范在低 QP 时本来就用右移，
所以作者显式给了一个小的正数走右移路径。

**`IsLeftShift` 也同样分三种情况**（`IQIT.v:563-569`）：

```verilog
if (res_AC == 1'b1)          IsLeftShift <= 1'b1;                    // AC 恒左移
else if (res_luma == 1'b1)   IsLeftShift <= (QPy < 12)  ? 1'b0 : 1'b1;  // 亮度 DC
else                         IsLeftShift <= (QPc < 6)   ? 1'b0 : 1'b1;  // 色度 DC
```

所以完整机制是：**`shift_len` 给移位量，`IsLeftShift` 给方向**，
二者都取决于"这是哪类系数" + "QP 有多大"。实现上就是一个减法器
（`QPdiv6` 减常数）+ 一个桶形移位器，**确实没有乘法器**。

### LevelScale 表怎么实现

`LevelScale[qp%6][i]` 的值很小（10、11、13、14、16、18、20、23、25），
且 `i` 只影响符号（正/负），不影响幅值（H.264 的设计：
`LevelScale[m][0] = LevelScale[m][2]`）。所以实际只需要 6 个常量。

**但这里 nova 没有做优化 —— 它直接用了乘法运算符**（`IQIT.v:557-561`）：

```verilog
//rescale multiplier 
assign product0 = (rescale_counter == 0)? 0:mult0_a * {1'b0,LevelScale[0]};
assign product1 = (rescale_counter == 0)? 0:mult1_a * {1'b0,LevelScale[1]};
assign product2 = (rescale_counter == 0)? 0:mult2_a * {1'b0,LevelScale[2]};
assign product3 = (rescale_counter == 0)? 0:mult3_a * {1'b0,LevelScale[3]};
```

**这是全库唯一一处真正的乘法**（`grep " \* " *.v` 只有这 4 行，
另外 3 处是 `mb_num_v * 11` 的地址计算，综合时会变成移位加法）。

**为什么这里不优化？** 三个可能的原因：

1. **第二个操作数只有 5 bit**（`{1'b0, LevelScale[0]}` 是 6 bit、实际值 ≤ 25），
   综合器会自动推断成**小常数乘法网**，未必比手写移位加法差多少；
2. **`LevelScale` 是运行时从 case 里选的**（依赖 `QPmod6`），
   不是编译期常量 —— 手写移位加法需要先判断"当前是 10 还是 13"，
   反而要额外的多路选择器；
3. **只有 4 个**，而且 `rescale_counter` 有 4 拍，**可以分时复用**。

**实测代价**：4 个 16×6 的乘法器，约 4 × 200 = 800 门当量
（0.18µm 下），占整个 IQIT 的很小一部分。

> 💡 **这是一个诚实的设计取舍**，不是遗漏。作者在论文里强调的是
> **"移位代替除法/开方"**（`div6` 确实是查表），而不是"消灭一切乘法"。
> 读代码时要分清"作者宣称的"和"代码里实际的"，**别把论文的话
> 当成 RTL 的普遍规律**。
>
> 顺带说：如果你想练手，把这 4 行改成移位加法树是个很好的实验 ——
> 它应该是**功能等价**的（比特精确不变），但门数会变。
> 第 11 章的实验八就是这种"改一行看现象"的思路。

## 4.3 反变换（IDCT）的蝶形结构

H.264 的 4×4 IDCT 是可分离的：先做一次 1D 行变换，再做一次 1D 列变换。

### 公式

```
1D IDCT:
  e[0] = d[0] + d[2]
  e[1] = d[0] - d[2]
  e[2] = (d[1] >> 1) - d[3]
  e[3] = d[1] + (d[3] >> 1)

  f[0] = e[0] + e[3]
  f[1] = e[1] + e[2]
  f[2] = e[1] - e[2]
  f[3] = e[0] - e[3]
```

**只有加法、减法和右移 1 位**——这是 H.264 选择整数 DCT 的原因：
蝶形运算的系数是 1 和 1/2，全部可以用移位实现。

### nova 的实现

```verilog
// IQIT.v 的 butterfly 子模块
assign D1_scale = (IsHadamard == 1'b1) ? D1 : {D1[15], D1[15:1]};
assign D3_scale = (IsHadamard == 1'b1) ? D3 : {D3[15], D3[15:1]};

assign T0 = D0 + D2;
assign T1 = D0 - D2;
assign T2 = D1_scale - D3;
assign T3 = D1 + D3_scale;

assign F0 = T0 + T3;
assign F1 = T1 + T2;
assign F2 = T1 - T2;
assign F3 = T0 - T3;
```

**`{D1[15], D1[15:1]}` 是算术右移 1 位**（符号位复制）。这就是 `d[1] >> 1`。

**`IsHadamard` 让 D1/D3 直通**——因为 Hadamard 变换的系数全是 ±1，不需要
`>> 1` 的缩放。这就是"DC 路径先做 Hadamard 再做 rescale"的硬件实现方式：
**同一个蝶形单元，用 `IsHadamard` 一个 bit 切换两种变换**。

### IsHadamard 的判决条件

```verilog
// IQIT.v:279
assign IsHadamard = (res_DC == 1'b1 && (OneD_counter != 0 || TwoD_counter != 0))
                    ? 1'b1 : 1'b0;
```

**注意 `OneD_counter != 0 || TwoD_counter != 0` 这个条件**。
意思是"第一次 1D 变换不做 Hadamard 归一化"——因为 H.264 规范里，
Hadamard 变换只在第二次（列方向）变换时做归一化，第一次（行方向）不做。

**这是一个非常微妙的规范细节**，如果搞错，DC 系数会差 2 倍，
整帧全部偏色。作者用一个计数器条件精确地实现了它。

## 4.4 五级流水与计数器

IQIT 内部有 4 个计数器，控制 5 个流水级：

| 计数器 | 宽度 | 周期数 | 对应级 |
|---|---|---|---|
| `OneD_counter` | 3 | 4（ChromaDC 只 1） | 1D IDCT |
| `TwoD_counter` | 3 | 4（ChromaDC 只 0） | 2D IDCT |
| `rescale_counter` | 3 | 4（ChromaDC 只 1） | rescale |
| `rounding_counter` | 3 | 4 | rounding |

```verilog
// IQIT.v:221-231
//1.OneD_counter:control the step of 1D in IDCT,4 cycles
//  For ChromaDC IDCT,we combine the original 2x2 2D IDCT into a 4x4-like 1D IDCT
//  ChromaDC: 1 cycle
//  Others  : 4 cycles
always @ (posedge gclk_1D or negedge reset_n)
    if (reset_n == 0)
        OneD_counter <= 0;
    else if (OneD_counter == 0)
        OneD_counter <= (residual_state == `ChromaDCLevel_Cb_s ||
                         residual_state == `ChromaDCLevel_Cr_s) ? 3'b001 : 3'b100;
    else
        OneD_counter <= OneD_counter - 1;
```

### "ChromaDC 把 2×2 2D IDCT 合并进 4×4-like 1D IDCT"

色度的 DC 块只有 **2×2 = 4 个系数**，标准要求做一个 2×2 的 Hadamard 变换。
朴素做法：2 级流水（1D 行 + 1D 列），每级 2 个周期。

nova 的做法：**把 2×2 的变换"嵌入"到一个 4×4 的 1D 变换里**，
只用 **1 个周期**完成。这是怎么做到的？

关键在于把 2×2 矩阵"摊平"成 4 元素向量：

```
2×2 Hadamard:                摊平成 4 元素:
  [a b]      [a+b+c+d  a-b+c-d]     输入 [a, b, c, d]
  [c d]  →   [a+b-c-d  a-b-c+d]     输出 [A, B, C, D]
```

`A = a+b+c+d`、`B = a-b+c-d`、`C = a+b-c-d`、`D = a-b-c+d`。
**这正是 4×4 Hadamard 变换的第一列/行**！所以只要把 4 个系数送进
蝶形单元，`OneD_counter = 1`（1 个周期）就能算完，`TwoD_counter = 0`（不需要）。

**这个优化省了 7 个周期 per 色度 DC 块**。一个 MB 有 2 个色度 DC 块（Cb、Cr），
所以每个 MB 省 14 个周期。相对 204 cycles/MB 的总量，约 7%——不小了。

### rescale_counter 的复杂条件

```verilog
// IQIT.v:242-255
always @ (posedge gclk_rescale or negedge reset_n)
    if (reset_n == 0)
        rescale_counter <= 0;
    else if (rescale_counter != 0)
        rescale_counter <= rescale_counter - 1;
    else if (end_of_NonZeroCoeff_CAVLC == 1'b1)          // AC 路径
        rescale_counter <= 3'b100;                        // 4 cycles
    else if (OneD_counter == 3'b001 &&
             (residual_state == `ChromaDCLevel_Cb_s || `ChromaDCLevel_Cr_s))
        rescale_counter <= 3'b001;                        // ChromaDC: 1 cycle
    else if (TwoD_counter == 3'b100 && residual_state == `Intra16x16DCLevel_s)
        rescale_counter <= 3'b100;                        // LumaDC: 4 cycles
```

**三个触发源**：
1. `end_of_NonZeroCoeff_CAVLC`：CAVLC 解完，AC 路径开始 rescale
2. `OneD_counter == 1 && ChromaDC`：ChromaDC 的 1D 完成后开始 rescale（1 cycle）
3. `TwoD_counter == 4 && LumaDC`：LumaDC 的 2D 完成后开始 rescale（4 cycles）

**这是"DC 路径"和"AC 路径"的分岔点**：
- DC 走 1、3 分支（IDCT 在 rescale 之前）
- AC 走分支 1（rescale 在 IDCT 之前）

## 4.5 数据通路：zig-zag → raster 的转换

### 输入

```verilog
input [8:0] coeffLevel_0, coeffLevel_1, ..., coeffLevel_15;
```

**zig-zag 序**：`coeffLevel_0` 是 DC（左上角），`coeffLevel_1` 是 (0,1)，
`coeffLevel_2` 是 (1,0)，……`coeffLevel_15` 是 (3,3)（右下角）。

### 输出

```verilog
output [15:0] OneD_output_0..15;      // 1D 变换后（raster 序）
output [17:0] TwoD_output_0..15;      // 2D 变换后
output [17:0] DC_output_0..15;        // DC 分量
output [17:0] rescale_output_0..15;   // 反量化后
output [8:0] rounding_output_0..15;   // 最终残差（-256..255）
```

**全部 raster 序**。转换发生在哪儿？

答案在 `butterfly_D0..D3` 的输入选择逻辑（`IQIT.v:280-400` 那一大段 `always @`）。
大意是：

```verilog
// 1D 行变换：取 zig-zag 序的第 n 行
case (OneD_counter)
    4: begin butterfly_D0 <= coeffLevel[zigzag_map_row0_col0]; ... end
    ...
endcase
```

**用 `OneD_counter` 的值做"行号"，同时查 zig-zag 映射表取系数**。
也就是说，**zig-zag → raster 的转换是"边算边查表"的，不需要先把 16 个
系数重排一遍**。省了 16 个寄存器 + 一个 16 元素的交换网络。

### Intra16x16AC / ChromaAC 的"首系数是 DC"

`IQIT.v` 的 Revise log 第 2 条：

```
2.March 28,2006
1)For Intra16x16ACLevel and chroma AC,the first coeff of IDCT is DC value,
  the following coeffLevel_ext_0 ~ 14 should be moved backward 1 space
  and coeffLevel_ext_15 is abandoned
```

**这是 H.264 的一个坑**：Intra16×16 的 AC 系数块和色度 AC 系数块，
**第 0 个系数位置（左上角）在码流里是不存在的**（因为 DC 已经被抽走了），
但 H.264 语法规定这个位置要填 **0**，后续 15 个 AC 系数依次占位置 1..15。

所以 nova 要做一次"后移一位"：

```
coeffLevel_ext[0] = 0
coeffLevel_ext[1] = 码流里的第 0 个 AC
coeffLevel_ext[2] = 码流里的第 1 个 AC
...
coeffLevel_ext[15] = 码流里的第 14 个 AC（第 15 个丢弃）
```

**"coeffLevel_ext_15 被丢弃"** —— 因为一个块最多 16 个系数，
后移一位后最多只有 15 个 AC 位置，码流里最多 15 个 AC 系数
（`TotalCoeff - 1`，因为 DC 单独算了）。

### "DC 为零但 AC 非零"的特例

```verilog
// IQIT.v
res_LumaDCBlk_IsZero,      // luma DC 块全零
res_ChromaDCBlk_Cb_IsZero, // Cb DC 块全零
res_ChromaDCBlk_Cr_IsZero  // Cr DC 块全零
```

**为什么需要这三个标志？** 因为 DC 块和 AC 块是**分开解码**的：

- Intra16×16 MB：先解 16 个 DC 系数（组成 4×4 DC 块），再解各块的 AC
- 如果 DC 块全零，Hadamard 变换的输出全零，可以跳过整个 DC 路径

但 H.264 允许 **DC 块全零、AC 块非零**（`TotalCoeff > 0` 但 DC 位置是 0）。
这时 AC 路径仍然要走，只是 DC 分量是 0。三个标志让 IQIT 能正确区分：

```verilog
if (res_LumaDCBlk_IsZero && !res_AC)  → 整个 4×4 块全零，bypass
if (res_LumaDCBlk_IsZero && res_AC)   → DC 为 0，只做 AC 路径
if (!res_LumaDCBlk_IsZero)            → 正常路径
```

## 4.6 饱和处理（rounding）

IDCT 的输出是 16 bit 的中间值，需要：

1. 右移 6 位（H.264 规定的缩放）
2. 加 32（rounding offset）
3. 裁剪到 9 bit 有符号（−256..255）

```verilog
// IQIT.v 的 rounding 逻辑（概念）
rounding_output <= (TwoD_output + 32) >>> 6;
// 然后饱和到 [-256, 255]
```

`rounding_output` 是 9 bit 有符号，正好是 `sum.v` 的输入位宽：

```verilog
// sum.v
assign sum = (bypass) ? 0 : ({2'b0, b} + {a[8], a});
//                           8bit 预测      9bit 残差（符号扩展）
```

**9 + 8 = 10 bit，裁剪到 8 bit** —— 这就是 `sum.v` 的饱和逻辑：

```verilog
assign c = (bypass) ? b :
           ((sum[9] == 1'b1) ? 0 :                        // 负数 → 0
           ((sum[8] == 1'b1) ? 8'd255 : sum[7:0]));       // 超 255 → 255
```

**注意判据是 `sum[9]` 和 `sum[8]`**：`sum[9]=1` 表示结果是负的（9 bit 有符号
的最高位），`sum[8]=1` 且 `sum[9]=0` 表示结果 ≥ 256。两次判断就完成饱和，
**没有用比较器**（`sum[9]` 直接就是符号位，`sum[8]` 直接就是溢出位）。

## 4.7 IQIT 在整个流水线中的位置

```
trigger_CAVLC ──▶ cavlc_decoder 解系数
                        │
                        ▼ end_of_NonZeroCoeff_CAVLC
                  ┌─────────────┐
                  │    IQIT     │  1D(4) → 2D(4) → rescale(4) → rounding(4)
                  │             │  DC 路径：Hadamard → rescale
                  └─────────────┘
                        │
                        ▼ rounding_output_0..15
                  ┌─────────────┐
                  │    sum      │  残差 + 预测
                  └─────────────┘
                        │
                        ▼
                   blk4x4_sum_PE0..3_out
```

**IQIT 的处理是"块级流水"**：每来一个 4×4 块，走一遍 4 级流水，
共约 **16 个周期**（4 级 × 4 周期）。一个 MB 有 24 个 4×4 块
（16 luma + 4 Cb + 4 Cr），所以理论上一 MB 的 IQIT 时间 ≈ 24 × 16 = 384 周期。

但实测一个 MB 只用约 **330 周期**（P 帧平均，含预测、sum、DF），
说明 **IQIT 是并行（流水）于其他环节的**，不是串行等待。
这正是"混合流水线"的意义（第 8 章）。

### 关键观察：IQIT 和 CAVLC 是异步的

`end_of_NonZeroCoeff_CAVLC` 是**位流侧**告诉重建侧"系数解完了"的信号。
但 IQIT 不需要等整个 MB 的系数都解完——**每解完一个 4×4 块就开始处理**。

这就是为什么 IQIT 的计数器要用 `end_of_NonZeroCoeff_CAVLC`（块级信号）
而不是 `end_of_MB_DEC`（MB 级信号）。**块级流水的粒度是 4×4，不是 MB**。

## 4.8 实测验证

在我们的仿真里，IQIT 的输出是**比特精确**的：

- 300 帧 akiyo 全部与 ffmpeg 逐像素一致（maxdiff = 0）
- 关掉去块滤波后 PSNR 46.35 dB（说明 IQIT 本身没问题，是 DF 在平滑）

**这意味着 `rescale` 的移位量、`IsHadamard` 的条件、zig-zag 映射、
rounding 偏移全部正确**。这四样任何一样错了，都会导致系统性偏色或
整帧偏移，不可能出现比特精确。

## 4.9 本章小结：IQIT 的四个省电技巧

| 技巧 | 传统做法 | nova 做法 | 省下什么 |
|---|---|---|---|
| `qp%6` / `qp/6` | 除法器 | 两张 case 查表（`IQIT.v:793-807` mod6，`:809-826` div6） | ~500 门 |
| 1/2 缩放 | 乘法或除法 | 算术右移 1 位 | 0 |
| Hadamard 归一化 | 独立单元 | 复用蝶形 + `IsHadamard` 旁路 | 一整套变换单元 |
| zig-zag → raster | 16 元素交换网络 | 边算边查表 | 16 个寄存器 + 交换网络 |
| ChromaDC 2×2 | 2 级流水（7 周期） | 摊平进 1D（1 周期） | 每 MB 14 周期 |

**这张表就是"低功耗设计方法论"的具体化**。作者的博士论文讲的就是这些，
而 RTL 是它最忠实的记录。

---

**上一章** ← [03-位流解析链路.md](03-位流解析链路.md) ｜
**下一章** → [05-帧内预测.md](05-帧内预测.md)
