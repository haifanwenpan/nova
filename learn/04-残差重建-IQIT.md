# 第 4 章 残差重建：IQIT（反量化 + 反变换）与像素求和

`src/IQIT.v`（849 行）把 CAVLC 解出的量化系数还原为像素域残差，再交给 `src/sum.v`（509 行）与帧内/帧间预测像素相加并饱和裁剪到 `[0, 255]`。名字 **IQIT** 即 **I**nverse **Q**uantization（反量化）+ **I**nverse **T**ransform（反变换）。

> 📖 **概念预热**：为什么先做 DCT 再量化、QP 每 +6 步长翻倍、Zig-Zag 扫描序是什么 —— 见 [第 0 章 0.4 & 0.7 节](00-H.264基础.md)。

---

## 4.1 三种残差块的处理顺序与流水重叠

打开 `IQIT.v:10-16` 的头部设计说明，先把三条不同路径的顺序记死：

| 残差块类型 | `residual_state` | 处理顺序 | 实际耗时（含流水重叠） |
|---|---|---|---|
| **普通 AC 块**（Intra4×4 / Inter 亮度，Intra16×16 AC，色度 AC） | `LumaLevel_s` / `Intra16x16ACLevel_s` / `ChromaACLevel_Cb/Cr_s` | **Rescale(4) → 1D IDCT(4) → 2D IDCT(4) → Rounding(4)** | **10 拍**（Rescale 与 1D 重叠 3 拍；2D 与 Rounding 重叠 3 拍） |
| **Intra16×16 亮度 DC 块**（4×4） | `Intra16x16DCLevel_s` | **1D Hadamard(4) → 2D Hadamard(4) → Rescale(4)**（无 Rounding） | **9 拍**（2D 与 Rescale 重叠 3 拍） |
| **色度 DC 块**（2×2 Cb / Cr） | `ChromaDCLevel_Cb_s` / `ChromaDCLevel_Cr_s` | **1D Hadamard(1) → Rescale(1)**（无 2D，无 Rounding） | **2 拍** |

**为什么 DC 块是“先反变换再反量化”，而 AC 块是“先反量化再反变换”？**
因为 H.264 对 Intra16×16 的 16 个 DC（4×4）和色度的 4 个 DC（2×2）额外做了二级 **Hadamard 变换**（系数全是 `±1`）。规范要求解码时先把 DC 块做完 Hadamard 反变换，**然后再统一乘以量化步长 `LevelScale` 并右移/左移缩放**；算出来的 16 个（或 4 个）DC 值存在 `DC_output[0..15]` 里，等后面解每一个 4×4 AC 块时，再把对应的那一个 DC 塞回该块 `(0,0)` 位置参与 4×4 IDCT！

---

## 4.2 反量化（Rescale）：查表消灭除法 + 仅 4 个小乘法器

H.264 反量化公式的核心是把量化参数 `QP ∈ [0, 51]` 拆成商 `QP/6` 和余数 `QP%6`：

```text
AC 系数反量化：        d[i][j] = ( c[i][j] × LevelScale[QP % 6][pos(i,j)] ) << (QP / 6)
Intra16×16 DC 反量化： d_dc    = ( h_dc    × LevelScale[QP % 6][0] ) × 2^(QP / 6 - 2)
色度 DC 反量化：       d_dc    = ( h_dc    × LevelScale[QP % 6][0] ) × 2^(QP / 6 - 1)
```

### 1. 用纯 `case` 查表消灭 `/ 6` 和 `% 6`（`IQIT.v:793-826`）

硬件除法器极其昂贵，而 `QP` 只有 `0..51` 共 52 个可能值。`nova` 写了两个纯组合查表子模块：

```verilog
// IQIT.v:793-807 —— mod6 子模块（52 项按余数分组的纯 LUT）
case (qp)
    0, 6,12,18,24,30,36,42,48: mod <= 3'b000;
    1, 7,13,19,25,31,37,43,49: mod <= 3'b001;
    2, 8,14,20,26,32,38,44,50: mod <= 3'b010;
    3, 9,15,21,27,33,39,45,51: mod <= 3'b011;
    4,10,16,22,28,34,40,46   : mod <= 3'b100;
    5,11,17,23,29,35,41,47   : mod <= 3'b101;
    default                  : mod <= 3'b000;
endcase

// IQIT.v:809-826 —— div6 子模块（同样是纯 case LUT，没有比较器链！）
case (qp)
    0, 1, 2, 3, 4, 5 : div <= 4'b0000;
    6, 7, 8, 9, 10,11: div <= 4'b0001;
    ...
    48,49,50,51      : div <= 4'b1000;
    default          : div <= 4'b0000;
endcase
```

### 2. 6×3 `LevelScale` 表与全芯片仅有的 4 个乘法器（`IQIT.v:444-492, 558-561`）

在一个 4×4 块内，按行列坐标 `(i, j)` 的奇偶性，`LevelScale` 只有 **3 种幅值**（全部为正整数，5-bit 无符号，范围 **`10..29`**）：
- **`v0`（偶行偶列，如 `(0,0), (0,2), (2,0), (2,2)`）** —— DC 块全部用这一列
- **`v1`（奇行奇列，如 `(1,1), (1,3), (3,1), (3,3)`）**
- **`v2`（一奇一偶，如 `(0,1), (1,0), ...`）**

| `QP % 6` | `v0`（偶,偶 / DC） | `v2`（偶,奇 & 奇,偶） | `v1`（奇,奇） |
|---|---|---|---|
| **0** | 10 | 13 | 16 |
| **1** | 11 | 14 | 18 |
| **2** | 13 | 16 | 20 |
| **3** | 14 | 18 | 23 |
| **4** | 16 | 20 | 25 |
| **5** | 18 | 23 | **29** |

在 `IQIT.v:458-487` 里，每拍处理 1 行共 4 个系数：
- 第 0、2 行（`rescale_counter == 4, 2`）4 路系数分别乘 `[v0, v2, v0, v2]`；
- 第 1、3 行（`rescale_counter == 3, 1`）4 路系数分别乘 `[v2, v1, v2, v1]`。

```verilog
// IQIT.v:558-561 —— 全项目唯一一处综合成真乘法器的代码（16-bit 有符号 × 6-bit 正整数）
assign product0 = (rescale_counter == 0) ? 0 : mult0_a * {1'b0, LevelScale[0]};
assign product1 = (rescale_counter == 0) ? 0 : mult1_a * {1'b0, LevelScale[1]};
assign product2 = (rescale_counter == 0) ? 0 : mult2_a * {1'b0, LevelScale[2]};
assign product3 = (rescale_counter == 0) ? 0 : mult3_a * {1'b0, LevelScale[3]};
```

> **为什么作者没有把这 4 个乘法拆成移位加法？** ① 乘数只有 5 bit 有效位（≤29），综合出的面积很小（4 个合计仅 ~800 门）；② `LevelScale` 随 `QP%6` 运行时动态变化，手写移位加法反而需要多层大 MUX；③ 4 个乘法器被 4 拍分时复用，效率已经很高。

### 3. 方向与移位量：`IsLeftShift` 与 `shift_len`（`IQIT.v:563-589, 828-835`）

```verilog
// IQIT.v:563-569：判断左移还是右移
if (res_AC == 1'b1)        IsLeftShift <= 1'b1;                  // AC 恒左移 QPdiv6 位
else if (res_luma == 1'b1) IsLeftShift <= (QPy < 12) ? 1'b0 : 1'b1; // 亮度 DC：QPy<12 时 QP/6-2 < 0，改右移！
else                       IsLeftShift <= (QPc < 6)  ? 1'b0 : 1'b1; // 色度 DC：QPc<6  时 QP/6-1 < 0，改右移！

// IQIT.v:576-589：计算无符号移位位数
if (residual_state == `Intra16x16DCLevel_s)
    case (QPdiv6)
        4'b0000: shift_len <= 2;          // 右移 2 位（2^(0-2) = 1/4）
        4'b0001: shift_len <= 1;          // 右移 1 位（2^(1-2) = 1/2）
        default: shift_len <= QPdiv6 - 2; // 左移 QPdiv6-2 位
    endcase
else if (res_DC) // ChromaDC
    case (QPdiv6)
        4'b0000: shift_len <= 1;          // 右移 1 位（2^(0-1) = 1/2）
        default: shift_len <= QPdiv6 - 1; // 左移 QPdiv6-1 位
    endcase
else
    shift_len <= QPdiv6;                  // AC 左移 QPdiv6 位
```

**背后的数学原理**：
- 4×4 Hadamard 变换（`Intra16x16DC`）正反两次各放大 2 倍，总增益是 `4 = 2²`，所以反量化少左移 **2 位**（`QPdiv6 - 2`）除回来；
- 2×2 Hadamard 变换（`ChromaDC`）总增益是 `2 = 2¹`，所以少左移 **1 位**（`QPdiv6 - 1`）；
- `rescale_shift`（`:828-835`）用带符号算术移位 `<<<` / `>>>` 保证负数符号位不丢。*(注：H.264 规范在 `QPy < 12` 对 LumaDC 有 `+ (1 << (1 - QPy/6))` 的四舍五入偏置，此处 `nova` 直接算术右移，在常见 `QP >= 12` 如 `akiyo300` 的 `QP = 28` 下完全无差异。)*

---

## 4.3 反变换（IDCT / Hadamard）：共用蝶形单元

### 1. 4 点蝶形电路（`IQIT.v:771-791`）

```verilog
module butterfly (IsHadamard, D0, D1, D2, D3, F0, F1, F2, F3);
    input IsHadamard;
    input [15:0] D0, D1, D2, D3;
    output [15:0] F0, F1, F2, F3;

    // 核心一行：Hadamard 系数为 1（直通）；IDCT 系数为 1/2（带符号算术右移 1 位）
    assign D1_scale = (IsHadamard == 1'b1) ? D1 : {D1[15], D1[15:1]};
    assign D3_scale = (IsHadamard == 1'b1) ? D3 : {D3[15], D3[15:1]};

    // 第一级蝶形
    assign T0 = D0 + D2;
    assign T1 = D0 - D2;
    assign T2 = D1_scale - D3;
    assign T3 = D1 + D3_scale;

    // 第二级蝶形
    assign F0 = T0 + T3;
    assign F1 = T1 + T2;
    assign F2 = T1 - T2;
    assign F3 = T0 - T3;
endmodule
```

### 2. ⚠️ 核实纠正：`IsHadamard` 的真实含义（`IQIT.v:279`）

```verilog
assign IsHadamard = (res_DC == 1'b1 && (OneD_counter != 0 || TwoD_counter != 0)) ? 1'b1 : 1'b0;
```

请仔细看这个布尔表达式：
- 当处理 **DC 块**（`res_DC == 1`，即 `Intra16x16DCLevel_s` 或 `ChromaDCLevel_Cb/Cr_s`）时，**无论是 1D 行变换（`OneD_counter != 0`）还是 2D 列变换（`TwoD_counter != 0`），`IsHadamard` 全部为 `1`**！因为二维 Hadamard 变换 $H X H^T$ 在行方向和列方向系数都是纯 `±1`，两个方向都**不能**对 `D1/D3` 右移 1 位（除以 4 或 2 是在后面的 `rescale_shift` 通过 `QPdiv6 - 2` / `- 1` 统一完成的）。
- 当处理 **AC 块**（`res_DC == 0`）时，**1D 和 2D 阶段 `IsHadamard` 全部为 `0`**，两个方向都执行 H.264 4×4 IDCT 的 `D1 >> 1` 和 `D3 >> 1`！
- 括号里的 `(OneD_counter != 0 || TwoD_counter != 0)` 只是**空闲门控**：蝶形不工作时把 `IsHadamard` 拉回 0 省电。
- 如果像 [第 11 章实验 8a](11-动手实验.md) 那样把 `IsHadamard` 强行改成恒 `1`，就会把所有 **AC 块的 4×4 IDCT** 错误地变成 Hadamard（去掉了 `>> 1`），导致 Y/U/V 全平面严重失真（PSNR 掉到 32.96 dB）！

### 3. 绝妙优化：把 ChromaDC 2×2 二维 Hadamard 塞进 1 拍 1D 蝶形！

色度 DC 块只有 4 个系数 `[c0, c1; c2, c3]`，标准 2×2 Hadamard 输出为：

```text
[ c0 + c1 + c2 + c3    c0 - c1 + c2 - c3 ]
[ c0 + c1 - c2 - c3    c0 - c1 - c2 + c3 ]
```

把 `(D0, D1, D2, D3) = (c0, c1, c2, c3)` 送进 `IsHadamard = 1` 的 4 点蝶形算 1 拍（`OneD_counter == 1`，`TwoD_counter` 保持 `0` 彻底跳过 2D！），看 `F0..F3` 恰好算出了什么（`IQIT.v:385-389, 656-657`）：
- `F0 = (c0+c2) + (c1+c3) = c0 + c1 + c2 + c3` → 存入 `OneD_output[12]`
- `F1 = (c0-c2) + (c1-c3) = c0 + c1 - c2 - c3` → 存入 `OneD_output[13]`
- `F2 = (c0-c2) - (c1-c3) = c0 - c1 - c2 + c3` → 存入 `OneD_output[14]`
- `F3 = (c0+c2) - (c1+c3) = c0 - c1 + c2 - c3` → 存入 `OneD_output[15]`

注意 `F1` 和 `F3` 位置正好对调了！所以在下一拍 `rescale`（`IQIT.v:510-514`）取数时，按 **`[12, 15, 13, 14]`** 重排一次：
`mult0_a = OneD_output[12]`（位置 0,0），`mult1_a = OneD_output[15]`（位置 0,1），`mult2_a = OneD_output[13]`（位置 1,0），`mult3_a = OneD_output[14]`（位置 1,1），**1 拍完成整个 2×2 二维 Hadamard**，还直接关掉了 `gclk_2D` 时钟！

---

## 4.4 Zig-Zag → 光栅转换、DC 回填与流水节拍

### 1. 端口与内部寄存器真相（对照 `IQIT.v:63-108`）

- **数据输入**：`coeffLevel_ext_0..15` 各 **16-bit**（在 `reconstruction.v:310-325` 里把 CAVLC 输出的 9-bit `coeffLevel_0..15` 符号扩展到 16-bit），顺序为 **Zig-Zag 序**；
- **4 组内部中间寄存器**（都是 **16-bit 内部 reg**，不是模块输出！）：
  - `rescale_output [3:0]`（仅 **4** 个 × 16-bit，存当前刚反量化完的 1 行）
  - `OneD_output [15:0]`（16 个 × 16-bit，存 1D 行变换后的 4×4 矩阵，供 2D 按列读）
  - `TwoD_output [3:0]`（仅 **4** 个 × 16-bit，存当前刚做完 2D 列变换的 1 列）
  - `DC_output [15:0]`（16 个 × 16-bit：存 Intra16×16 的 16 个 DC，按双 Z 块号排列；或者 `[0..3]` 存 Cb DC、`[4..7]` 存 Cr DC）
- **数据输出**：`rounding_output_0..15`（16 个 **9-bit 有符号**，光栅序）和 `curr_DC_scaled`（9-bit 有符号，用于“仅有 DC、AC 全零”的快捷通道）。

### 2. Zig-Zag → 光栅转换在哪发生？

**无需专门重排网络，读取输入时顺手按表抓数即可**：
- 对 **AC 块**：转换发生在 **Rescale 级**（`IQIT.v:515-544` 选 `mult0_a..mult3_a` 时）：
  - `rescale_counter == 4`（第 0 行）：抓 Zig-Zag 下标 `0, 1, 5, 6`
  - `rescale_counter == 3`（第 1 行）：抓 Zig-Zag 下标 `2, 4, 7, 12`
  - `rescale_counter == 2`（第 2 行）：抓 Zig-Zag 下标 `3, 8, 11, 13`
  - `rescale_counter == 1`（第 3 行）：抓 Zig-Zag 下标 `9, 10, 14, 15`
- 对 **Intra16×16 DC 块**：因为先做 1D 再做 Rescale，转换发生在 **1D 蝶形级**（`IQIT.v:356-383` 选 `butterfly_D0..D3` 时），查的是同一张 Zig-Zag 表！

### 3. `Intra16x16AC` 与 `ChromaAC` 的“后移一位 + DC 回填”

H.264 规定：对于 Intra16×16 的 AC 块和色度 AC 块，码流里只传了 15 个 AC 系数（放在 `coeffLevel_ext_0..14`），左上角 `(0,0)` 的 DC 已经提前在 DC 块里算好存进 `DC_output` 了。`IQIT.v` 分两步完美衔接：
1. **Rescale 级（`:517-544`）**：第 0 行位置 `(0,0)` 强制乘 `0`，其余 15 个位置把 `coeffLevel_ext_0..14` 整体向后错一位填进 Zig-Zag 槽 `1..15`（丢弃 `coeffLevel_ext_15`）；
2. **1D 蝶形级（`:312-357`）**：在 `OneD_counter == 4`（处理第 0 行）时，`butterfly_D0` **跳过 `rescale_output[0]`**，直接从 `DC_output[...]` 抓出当前块的 DC 值（若对应 `res_*DCBlk_IsZero == 1` 则给 `0`）送进蝶形！

### 4. AC 块的 10 拍重叠流水时序图

很多初学者以为 4 级 × 4 拍 = 16 拍，其实 `IQIT` 用 4 寄存器缓冲区把相邻两级高度重叠，**一个 4×4 AC 块只要 10 拍**：

```text
拍号:        T1    T2    T3    T4    T5    T6    T7    T8    T9    T10
rescale:    Row0  Row1  Row2  Row3
1D IDCT:          Row0  Row1  Row2  Row3   (写满 OneD_output[0..15] 转置阵)
2D IDCT:                                  Col0  Col1  Col2  Col3
rounding:                                       Col0  Col1  Col2  Col3 (输出完整 4×4)
```

- `rescale`（4 拍）与 `1D`（4 拍）都是**按行**处理，相差 1 拍并行跑（共 5 拍）；
- 等 4 行全部写进 16-reg `OneD_output` 后，`2D`（4 拍）与 `rounding`（4 拍）再**按列**相差 1 拍并行跑（共 5 拍）；
- `rescale_counter` 有三个触发源（`IQIT.v:249-255`）：① `end_of_NonZeroCoeff_CAVLC`（AC 路径）；② `OneD_counter == 1 && ChromaDC`（色度 DC，1 拍）；③ `TwoD_counter == 4 && Intra16x16DC`（亮度 DC，4 拍）。

### 5. 舍入（Rounding，`IQIT.v:618-626, 736-765`）

H.264 规定 2D IDCT 结果要算 `(TwoD + 32) >>> 6`。`IQIT.v` 写成了一个省位的等价技巧：

```verilog
assign before_rounding0 = (rounding_counter != 0) ? TwoD_output[0] : 0; // 16-bit 有符号
assign rounding_sum0    = before_rounding0[14:5] + 1;                   // 先右移 5 位再 +1
// 锁存到输出：
rounding_output_0      <= rounding_sum0[9:1];                           // 再右移 1 位 = (x + 32) >>> 6
```

**注意**：`IQIT.v` 内部**没有任何饱和裁剪逻辑**，直接截取 9-bit 有符号数送给 `sum.v`。如果一个 4×4 块只有 DC（AC 全零），干脆彻底跳过 10 拍 IDCT，直接走组合快捷路径 `curr_DC_scaled = (curr_DC + 32)[14:6]`（`IQIT.v:204-207`），把这 1 个值广播到 16 个像素！

---

## 4.5 手算一个具体例子：从量化系数到最终重建像素

假设一个普通 4×4 亮度块（`LumaLevel_s`），`QPy = 24`（`QPdiv6 = 4`, `QPmod6 = 0` → `v0 = 10, v1 = 16, v2 = 13`），CAVLC 解出只有 1 个非零系数 `coeffLevel_0 = 2`（DC 位置 `(0,0)`），其余 15 个全为 `0`，当前块预测像素全是 `100`：

1. **Rescale（T1）**：`mult0_a = 2`，`LevelScale[0] = v0 = 10` → `product0 = 2 × 10 = 20`；AC 左移 `QPdiv6 = 4` 位 → `rescale_output[0] = 20 << 4 = 320`；其余 15 个全 0。
2. **1D IDCT（T2，第 0 行）**：`D = (320, 0, 0, 0)`，`IsHadamard = 0` → `T0=320, T1=320, T2=0, T3=0` → `F = (320, 320, 320, 320)`，写入 `OneD_output[0..3]`。其余 3 行全 0。
3. **2D IDCT（T6~T9，每列）**：每列输入都是 `D = (320, 0, 0, 0)` → 每列输出都是 `(320, 320, 320, 320)`。
4. **Rounding（T7~T10）**：`320[14:5] = 10` → `10 + 1 = 11` → `11 >> 1 = 5`（验算 `(320 + 32) >> 6 = 352 / 64 = 5.5 → 5` ✓）。于是 16 个残差像素全为 `+5`。
5. **`sum.v` 相加与饱和**：每个像素 `100 + 5 = 105`，落入 `[0, 255]`，最终重建像素全为 `105`！

---

## 4.6 残差 + 预测求和与饱和裁剪（`sum.v`）

`src/sum.v`（509 行）负责把 8-bit 无符号预测像素 `b` 和 9-bit 有符号残差 `a` 相加，并在 4 拍内**按行**（每拍 4 个像素，4 个并行 `sum_PE`）输出一个完整的 4×4 重建块：

```verilog
// sum.v:507-508 —— sum_PE 子模块（4 个实例并行算一行 4 像素）
assign sum = (bypass) ? 0 : ({2'b0, b} + {a[8], a});                  // 10-bit 带符号和
assign c   = (bypass) ? b :                                           // 全零残差直接旁路预测值！
             ((sum[9] == 1'b1) ? 8'd0   :                             // 最高位=1 → 负数，裁到 0
             ((sum[8] == 1'b1) ? 8'd255 : sum[7:0]));                 // [9]=0 且 [8]=1 → ≥256，裁到 255
```

- **三种快捷模式**（`sum.v:252-304`）：
  1. `res_blk4x4_IsAllZero == 1`（如 P_Skip、CBP=0、TotalCoeff=0）：拉高 `sum_PE_bypass = 1`，加法器输入清零省电，直接输出预测像素 `b`；
  2. `res_blk4x4_onlyDC == 1`（有非零 DC 但 AC 全零）：4 个 `sum_PE` 直接把 `IQIT` 算好的 `curr_DC_scaled` 当残差加进去，免跑 10 拍 IDCT；
  3. 正常块：按行取 `rounding_output_0..15` 相加。
- **`blk4x4_sum_counter`（0..4）**：复位/空闲为 `4`；收到 `trigger_blk4x4_rec_sum` 后从 `0 → 1 → 2 → 3 → 4` 逐行累加 4 拍；`blk4x4_sum_counter == 3` 时拉高 `end_of_one_blk4x4_sum` 并将 `blk4x4_rec_counter` 递增（`0..23` 循环）。
- **回喂后续帧内预测**：`sum.v:390-398` 用 24-bit 寄存器 `sum_right_column_reg[23:0]` 暂存前 3 行的最右像素 `PE3_out`，在第 4 拍（`cnt == 3`）连同第 3 行最右像素一起凑齐 4 像素右列，送给 `Intra_pred_reg_ctrl` 更新左邻缓存 `Intra_mbAddrA`；同时把第 3 行底边 4 像素送去更新 `Intra_mbAddrB`。

---

## 4.7 本章小结：IQIT + sum 的省电账本

| 技巧 | 传统做法 | `nova` 实际做法 | 收益 |
|---|---|---|---|
| `qp % 6` / `qp / 6` | 除法器 | 两张纯 `case` 查表（`IQIT.v:793-826`） | 省 ~500 门 |
| IDCT 与 Hadamard | 两套独立变换阵 | 共用 1 个蝶形，`IsHadamard` 切换是否 `>> 1` | 省一整套变换逻辑 |
| Zig-Zag → 光栅 | 16-reg 重排交换网 | Rescale/1D 读数时顺手按表索引 | 省 16 个寄存器与交换网 |
| ChromaDC 2×2 Hadamard | 2 级二维变换 | 塞进 1 拍 1D 蝶形 + 重排 `[12,15,13,14]` | 跳过 2D 且关断 `gclk_2D` |
| 全零块 / 仅 DC 块 | 照常跑 10 拍 IQIT | `sum_PE_bypass` 直通 / `curr_DC_scaled` 广播 | 跳过绝大部分块的反变换功耗 |

---

**上一章** ← [03-位流解析链路.md](03-位流解析链路.md) ｜
**下一章** → [05-帧内预测.md](05-帧内预测.md)
