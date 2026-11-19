//--------------------------------------------------------------------------------------------------
// Testbench : tb_nova
// Purpose   : Standalone regression testbench for the nova H.264/AVC baseline decoder.
//             Replaces the original nova_tb + ext_frame_RAM*_wrapper pair, which only wrote
//             text-formatted dumps (nova_display.log / nova_MB_output.log) and required an
//             external C program to convert back to YUV.
//
//             This testbench writes a raw YUV420p file directly, one frame per decoded picture,
//             so the output can be compared bit-exactly against `ffmpeg -i in.264 -f rawvideo`.
//
// Plusargs  : +bitstream=<file.hex>   hex text file produced by test/bin2hex.pl   (required)
//             +out=<file.yuv>         decoded YUV420p output                      (default nova_out.yuv)
//             +frames=<n>             stop after n decoded pictures                (default 1)
//             +freq=<0..3>            freq_ctrl rate-control setting               (default 1)
//             +nodb                   disable the deblocking filter (pin_disable_DF=1)
//             +maxcyc=<n>             absolute cycle guard                         (default 60e6)
//
// Frame memory model
//-------------------
// nova keeps two external frame buffers and ping-pongs between them (see ext_RAM_ctrl.v):
// the buffer being written is the "display" buffer, the other one is the "reference" buffer.
// Both are 9504 x 32 bit for QCIF:
//   words    0..6335 : luma   25344 B = 176x144, 4 pixels packed per word, row stride 44 words
//   words 6336..7919 : Cb      6336 B =  88x72,  4 pixels packed per word, row stride 22 words
//   words 7920..9503 : Cr      6336 B =  88x72,  same layout
// Within a word the first (left-most) pixel is in bits [7:0].
//
// Instead of relying on the pic_num parity trick used by the original wrappers, this bench
// records which buffer was written since the last emitted picture and dumps that one when the
// next slice header starts, which is exactly when the previous picture is guaranteed complete.
//--------------------------------------------------------------------------------------------------

`timescale 1ns/1ns
`include "nova_defines.v"

module tb_nova;

  //----------------------------------------------------------------------------------------------
  // Parameters
  //----------------------------------------------------------------------------------------------
  localparam integer RAM_DEPTH   = 9504;   // 32-bit words per QCIF frame buffer
  localparam integer LUMA_WORDS  = 6336;
  localparam integer CHROMA_WORDS= 1584;
  localparam integer MB_W        = 11;     // macroblocks per row  (176/16)
  localparam integer MB_H        = 9;      // macroblock rows      (144/16)

  //----------------------------------------------------------------------------------------------
  // DUT connections
  //----------------------------------------------------------------------------------------------
  reg clk;
  reg reset_n;
  reg pin_disable_DF;
  reg freq_ctrl0;
  reg freq_ctrl1;

  wire        BitStream_ram_ren;
  wire [16:0] BitStream_ram_addr;
  wire [15:0] BitStream_buffer_input;
  wire [5:0]  pic_num;

  wire        ext_frame_RAM0_cs_n;
  wire        ext_frame_RAM0_wr;
  wire [13:0] ext_frame_RAM0_addr;
  wire [31:0] ext_frame_RAM0_data;
  wire        ext_frame_RAM1_cs_n;
  wire        ext_frame_RAM1_wr;
  wire [13:0] ext_frame_RAM1_addr;
  wire [31:0] ext_frame_RAM1_data;
  wire [31:0] dis_frame_RAM_din;
  wire        slice_header_s6;

  //----------------------------------------------------------------------------------------------
  // Bitstream ROM (behavioural, replaces Beha_BitStream_ram.v)
  //----------------------------------------------------------------------------------------------
  reg [15:0] bs_ram [0:`Beha_Bitstream_ram_size];
  reg [15:0] bs_dout;
  integer    bs_init_i;

  // 注意: 清零与 $readmemh 必须放在同一个 initial 块里按顺序执行。
  //   拆成两个 initial 块时，仿真器不保证执行顺序，可能先 readmemh 再清零，
  //   把码流擦掉。$readmemh 只填文件里有的那些行，其余位置在仿真里是 X；
  //   若不去清，码流读完后 bitstream 缓冲里就全是 X，状态机卡在 X 上永远不前进
  //   ——表现为"小码流跑几十万周期也解不出一帧"。真实 ROM 未编程区为 0，
  //   所以清零才是对硬件行为的正确建模。
  always @(posedge clk)
    if (BitStream_ram_ren == 1'b0)
      bs_dout <= bs_ram[BitStream_ram_addr];

  assign BitStream_buffer_input = bs_dout;

  //----------------------------------------------------------------------------------------------
  // Frame buffer models (behavioural, replace ext_frame_RAM*_wrapper.v)
  //----------------------------------------------------------------------------------------------
  reg [31:0] mem0 [0:RAM_DEPTH-1];
  reg [31:0] mem1 [0:RAM_DEPTH-1];

  reg        dout0_valid, dout1_valid;
  reg [31:0] dout0, dout1;

  // "dirty" flags tell us which buffer holds the picture that is ready to be emitted
  reg buf0_written, buf1_written;

  // 任一帧存本周期发生写入 —— 给 end-of-stream 空闲检测用
  wire ram_write_pulse = (ext_frame_RAM0_cs_n == 1'b0 && ext_frame_RAM0_wr == 1'b1) ||
                         (ext_frame_RAM1_cs_n == 1'b0 && ext_frame_RAM1_wr == 1'b1);

  always @(posedge clk) begin
    // ---- RAM0 ----
    if (ext_frame_RAM0_cs_n == 1'b0) begin
      if (ext_frame_RAM0_wr == 1'b1) begin
        mem0[ext_frame_RAM0_addr] <= dis_frame_RAM_din;
        buf0_written              <= 1'b1;
      end else begin
        dout0       <= mem0[ext_frame_RAM0_addr];
        dout0_valid <= 1'b1;
      end
    end else begin
      dout0_valid <= 1'b0;
    end

    // ---- RAM1 ----
    if (ext_frame_RAM1_cs_n == 1'b0) begin
      if (ext_frame_RAM1_wr == 1'b1) begin
        mem1[ext_frame_RAM1_addr] <= dis_frame_RAM_din;
        buf1_written              <= 1'b1;
      end else begin
        dout1       <= mem1[ext_frame_RAM1_addr];
        dout1_valid <= 1'b1;
      end
    end else begin
      dout1_valid <= 1'b0;
    end
  end

  assign ext_frame_RAM0_data = dout0_valid ? dout0 : 32'd0;
  assign ext_frame_RAM1_data = dout1_valid ? dout1 : 32'd0;

  //----------------------------------------------------------------------------------------------
  // DUT
  //----------------------------------------------------------------------------------------------
  nova u_nova (
    .clk                    (clk),
    .reset_n                (reset_n),
    .freq_ctrl0             (freq_ctrl0),
    .freq_ctrl1             (freq_ctrl1),
    .BitStream_buffer_input (BitStream_buffer_input),
    .BitStream_ram_ren      (BitStream_ram_ren),
    .BitStream_ram_addr     (BitStream_ram_addr),
    .pic_num                (pic_num),
    .pin_disable_DF         (pin_disable_DF),
    .ext_frame_RAM0_cs_n    (ext_frame_RAM0_cs_n),
    .ext_frame_RAM0_wr      (ext_frame_RAM0_wr),
    .ext_frame_RAM0_addr    (ext_frame_RAM0_addr),
    .ext_frame_RAM0_data    (ext_frame_RAM0_data),
    .ext_frame_RAM1_cs_n    (ext_frame_RAM1_cs_n),
    .ext_frame_RAM1_wr      (ext_frame_RAM1_wr),
    .ext_frame_RAM1_addr    (ext_frame_RAM1_addr),
    .ext_frame_RAM1_data    (ext_frame_RAM1_data),
    .dis_frame_RAM_din      (dis_frame_RAM_din),
    .slice_header_s6        (slice_header_s6)
  );

  //----------------------------------------------------------------------------------------------
  // Clock / reset
  //----------------------------------------------------------------------------------------------
  initial clk = 1'b1;
  always #340 clk = ~clk;   // ~1.47 MHz, mirrors the original testbench (680 ns period)

  //----------------------------------------------------------------------------------------------
  // Test control
  //----------------------------------------------------------------------------------------------
  integer    fd_yuv;
  integer    frames_done;
  integer    frames_target;
  integer    max_cycles;
  integer    cycle_count;
  reg [1023:0] bs_file;
  reg [1023:0] yuv_file;

  // one YUV picture, filled from a frame buffer then written to disk
  reg [7:0]  y_plane [0:176*144-1];
  reg [7:0]  u_plane [0:88*72-1];
  reg [7:0]  v_plane [0:88*72-1];

  task automatic emit_picture(input integer idx);
    integer w, r, c, p;
    reg [31:0] word;
    reg [31:0] src [0:RAM_DEPTH-1];
    begin
      if (idx == 0) for (w = 0; w < RAM_DEPTH; w = w + 1) src[w] = mem0[w];
      else          for (w = 0; w < RAM_DEPTH; w = w + 1) src[w] = mem1[w];

      // ---- luma: 176x144, 44 words per row, 4 pixels per word ----
      for (r = 0; r < 144; r = r + 1)
        for (c = 0; c < 44; c = c + 1) begin
          word = src[r*44 + c];
          y_plane[r*176 + c*4 + 0] = word[ 7: 0];
          y_plane[r*176 + c*4 + 1] = word[15: 8];
          y_plane[r*176 + c*4 + 2] = word[23:16];
          y_plane[r*176 + c*4 + 3] = word[31:24];
        end

      // ---- Cb: 88x72, 22 words per row ----
      for (r = 0; r < 72; r = r + 1)
        for (c = 0; c < 22; c = c + 1) begin
          word = src[LUMA_WORDS + r*22 + c];
          u_plane[r*88 + c*4 + 0] = word[ 7: 0];
          u_plane[r*88 + c*4 + 1] = word[15: 8];
          u_plane[r*88 + c*4 + 2] = word[23:16];
          u_plane[r*88 + c*4 + 3] = word[31:24];
        end

      // ---- Cr: 88x72 ----
      for (r = 0; r < 72; r = r + 1)
        for (c = 0; c < 22; c = c + 1) begin
          word = src[LUMA_WORDS + CHROMA_WORDS + r*22 + c];
          v_plane[r*88 + c*4 + 0] = word[ 7: 0];
          v_plane[r*88 + c*4 + 1] = word[15: 8];
          v_plane[r*88 + c*4 + 2] = word[23:16];
          v_plane[r*88 + c*4 + 3] = word[31:24];
        end

      for (p = 0; p < 176*144; p = p + 1) $fwrite(fd_yuv, "%c", y_plane[p]);
      for (p = 0; p < 88*72;   p = p + 1) $fwrite(fd_yuv, "%c", u_plane[p]);
      for (p = 0; p < 88*72;   p = p + 1) $fwrite(fd_yuv, "%c", v_plane[p]);

      frames_done = frames_done + 1;
      $display("[TB] emitted picture %0d at cycle %0d (t=%0t)", frames_done, cycle_count, $time);
    end
  endtask

  // emit the buffer that was written since the previous picture, then mark it clean
  always @(posedge clk) begin
    if (reset_n === 1'b1 && slice_header_s6 === 1'b1) begin
      if (buf0_written === 1'b1) begin
        buf0_written <= 1'b0;
        emit_picture(0);
      end else if (buf1_written === 1'b1) begin
        buf1_written <= 1'b0;
        emit_picture(1);
      end
    end
  end

  //----------------------------------------------------------------------------------------------
  // End-of-stream flush
  //   nova 的帧边界信号 slice_header_s6 来自"下一帧的 slice header 里 frame_num 字段"，
  //   所以最后一帧后面没有下一帧时，最后一帧永远等不到吐帧时机。这里用"空闲检测"兜底：
  //   若已写出若干帧、请求的帧数还没满，且连续 IDLE_FLUSH 个周期既没有 slice_header_s6
  //   也没有对帧存的新写入，就认为码流已结束，把最后一块脏缓冲吐出来。
  //   IDLE_FLUSH 取 5000 周期：一帧约 50000 周期，帧内 DF 回写是连续的，
  //   帧间最长空闲（切帧）远小于这个值，因此不会误触发。
  //----------------------------------------------------------------------------------------------
  //   第二个判据更硬：ROM 里真实码流之后全是补齐的 0，nova 会把它们当作 skip MB 一直
  //   解下去（end_of_MB_DEC 持续翻转），因此空闲检测在长码流上不可靠。改用地址判据：
  //   BitStream_ram_addr 一旦越过真实码流末地址 bs_end_addr，且连续 SAT_FLUSH 个周期
  //   没有新的 MB 解码结束，就认为码流真正耗尽。解码过程中每个 MB 都会拉高
  //   end_of_MB_DEC，所以正常解码绝不会误触发。
  //----------------------------------------------------------------------------------------------
  //   IDLE_FLUSH 的取值很关键：必须大于"帧内末次写帧存 → 下一帧 slice header"的间隙，
  //   否则每一帧都会被空闲检测抢先吐出，主路径（slice_header_s6）形同虚设。
  //   实测 akiyo300：末次写帧存约在 cycle 42154，下一个 slice_header_s6 在 50067，
  //   间隙约 7900 周期。因此取 20000（仍远小于一帧的 50000 周期，不会跨帧误判）。
  localparam IDLE_FLUSH = 20000;
  localparam SAT_FLUSH  = 2000;

  // 码流在 ROM 中的真实结束地址：bin2hex 生成的 hex 文件按 256 KB ROM 大小补齐 0，
  // 因此文件长度不是码流长度。这里在 $readmemh 之后扫描一遍，记下最后一个非零 word，
  // 供下面的"码流耗尽"检测把 BitStream_ram_addr 与真实结尾比较。
  integer bs_end_addr;
  integer idle_count;
  integer sat_count;
  initial begin
    idle_count = 0;
    sat_count  = 0;
  end

  always @(posedge clk) begin
    if (reset_n !== 1'b1) begin
      sat_count <= 0;
    end else if ((BitStream_ram_addr < bs_end_addr) || u_nova.end_of_MB_DEC === 1'b1) begin
      sat_count <= 0;
    end else if (sat_count < SAT_FLUSH) begin
      sat_count <= sat_count + 1;
    end else if (frames_done < frames_target) begin
      if (buf0_written === 1'b1) begin
        buf0_written <= 1'b0;
        sat_count    <= 0;
        $display("[TB] end-of-stream flush (bitstream exhausted): emitting last picture from buffer 0");
        emit_picture(0);
      end else if (buf1_written === 1'b1) begin
        buf1_written <= 1'b0;
        sat_count    <= 0;
        $display("[TB] end-of-stream flush (bitstream exhausted): emitting last picture from buffer 1");
        emit_picture(1);
      end
    end
    if (idle_count > IDLE_FLUSH && frames_done >= frames_target) begin
      $display("[TB] all %0d pictures decoded, finishing", frames_done);
      $finish;
    end
  end

  always @(posedge clk) begin
    if (reset_n !== 1'b1) begin
      idle_count <= 0;
    end else if (slice_header_s6 === 1'b1 || ram_write_pulse === 1'b1) begin
      idle_count <= 0;
    end else if (idle_count < IDLE_FLUSH) begin
      idle_count <= idle_count + 1;
    end else if (frames_done < frames_target) begin
      if (buf0_written === 1'b1) begin
        buf0_written <= 1'b0;
        idle_count   <= 0;
        $display("[TB] end-of-stream flush: emitting last picture from buffer 0");
        emit_picture(0);
      end else if (buf1_written === 1'b1) begin
        buf1_written <= 1'b0;
        idle_count   <= 0;
        $display("[TB] end-of-stream flush: emitting last picture from buffer 1");
        emit_picture(1);
      end
    end
  end

  //----------------------------------------------------------------------------------------------
  // Main sequence
  //----------------------------------------------------------------------------------------------
  initial begin
    frames_done   = 0;
    cycle_count   = 0;
    frames_target = 1;
    max_cycles    = 60000000;

    if (!$value$plusargs("frames=%d", frames_target))    frames_target = 1;
    if (!$value$plusargs("maxcyc=%d", max_cycles))       max_cycles    = 60000000;
    if ($test$plusargs("nodb"))                          pin_disable_DF = 1'b1;
    else                                                 pin_disable_DF = 1'b0;

    if (!$value$plusargs("bitstream=%s", bs_file)) begin
      $display("[TB] ERROR: +bitstream=<file.hex> is required");
      $finish;
    end
    if (!$value$plusargs("out=%s", yuv_file)) yuv_file = "nova_out.yuv";

    begin : freq_sel
      integer f;
      if (!$value$plusargs("freq=%d", f)) f = 1;
      freq_ctrl0 = f[0];
      freq_ctrl1 = f[1];
    end

    $display("[TB] bitstream = %0s", bs_file);
    $display("[TB] output    = %0s", yuv_file);
    $display("[TB] frames    = %0d", frames_target);

    // 先清零整个 ROM，再读入码流 —— 顺序在同一 initial 块里，保证生效
    for (bs_init_i = 0; bs_init_i <= `Beha_Bitstream_ram_size; bs_init_i = bs_init_i + 1)
      bs_ram[bs_init_i] = 16'h0000;
    $readmemh(bs_file, bs_ram);

    // 扫描真实码流末尾（文件按 ROM 尺寸补 0，长度 != 码流长度）
    bs_end_addr = 1;
    for (bs_init_i = `Beha_Bitstream_ram_size; bs_init_i >= 0; bs_init_i = bs_init_i - 1)
      if (bs_ram[bs_init_i] !== 16'h0000) begin
        bs_end_addr = bs_init_i + 1;
        bs_init_i   = -1;   // break
      end
    $display("[TB] bitstream occupies ROM words 0..%0d", bs_end_addr - 1);

    fd_yuv = $fopen(yuv_file, "wb");
    if (fd_yuv == 0) begin
      $display("[TB] ERROR: cannot open %0s for writing", yuv_file);
      $finish;
    end

    reset_n = 1'b1;
    #1100 reset_n = 1'b0;
    #1000 reset_n = 1'b1;
  end

  // cycle counter + guard
  always @(posedge clk) begin
    cycle_count <= cycle_count + 1;
    if (cycle_count > max_cycles) begin
      $display("[TB] TIMEOUT after %0d cycles, %0d pictures decoded", cycle_count, frames_done);
      $fclose(fd_yuv);
      $finish;
    end
  end

  // stop once the requested number of pictures has been written
  always @(posedge clk) begin
    if (frames_done >= frames_target) begin
      #1;
      $display("[TB] DONE: %0d pictures, %0d cycles, %0.0f cycles/picture",
               frames_done, cycle_count,
               (frames_done > 0) ? (cycle_count * 1.0 / frames_done) : 0.0);
      $fclose(fd_yuv);
      $finish;
    end
  end

endmodule
