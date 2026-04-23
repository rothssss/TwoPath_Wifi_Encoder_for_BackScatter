// =============================================================================
// tb_mac_fsm_custom : focused check of the Path B MAC.
//
// With SCRAMBLER_SEED = 7'h00, the LFSR stays at 0 forever so scrambling is
// the identity.  Thus bit_out is equal to raw_bit_c, which makes expected
// bit streams easy to derive:
//
//   - Preamble : CUSTOM_PREAMBLE_PAT LSB-first (32 bits of 0xAAAAAAAA
//                => alternating 0,1,0,1,...).
//   - Payload  : each FIFO byte emitted LSB-first.
//   - FCS      : 32 bits of CRC-32('<payload bytes>') LSB-first, finalized
//                (i.e. XOR with 0xFFFFFFFF).
//
// Checks:
//   T1 total bit_valid count = CUSTOM_PREAMBLE_LEN + 8*payload_len + 32
//                            = 32 + 16 + 32 = 80 for payload_len=2.
//   T2 done_pulse fires exactly once.
//   T3 first 32 captured bits match 0xAAAAAAAA LSB-first.
//   T4 next 16 bits match payload bytes LSB-first = {0x5A, 0xA5}.
//   T5 no underrun_flag asserts.
// =============================================================================
`timescale 1ns/1ps

module tb_mac_fsm_custom;

    localparam integer CLK_T = 10;

    reg         clk         = 1'b0;
    reg         rst_n       = 1'b0;
    reg         start_pulse = 1'b0;
    reg  [15:0] payload_len = 16'd0;

    wire        busy;
    wire        done_pulse;
    wire        fifo_rd_en;
    wire        underrun_flag;
    wire [7:0]  fifo_rd_data;
    wire        bit_valid;
    wire        bit_out;

    reg  [7:0] fifo_mem [0:31];
    integer    fifo_size = 0;
    integer    rptr      = 0;
    wire       fifo_empty = (rptr >= fifo_size);

    assign fifo_rd_data = fifo_mem[rptr];

    mac_fsm_custom #(
        .SCRAMBLER_SEED(7'h00),
        .CUSTOM_PREAMBLE_LEN(32),
        .CUSTOM_PREAMBLE_PAT(32'hAAAAAAAA)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .start_pulse(start_pulse),
        .payload_len(payload_len),
        .busy(busy),
        .done_pulse(done_pulse),
        .fifo_rd_en(fifo_rd_en),
        .fifo_empty(fifo_empty),
        .fifo_rd_data(fifo_rd_data),
        .underrun_flag(underrun_flag),
        .bit_valid(bit_valid),
        .bit_out(bit_out)
    );

    always #(CLK_T/2) clk = ~clk;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)                              rptr <= 0;
        else if (fifo_rd_en && !fifo_empty)      rptr <= rptr + 1;
    end

    // Capture bit stream and done count.
    integer captured_bits = 0;
    integer done_count    = 0;
    reg [0:95] bit_capture;  // 96 bits plenty for our 80-bit test

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            captured_bits <= 0;
            done_count    <= 0;
        end else begin
            if (bit_valid) begin
                bit_capture[captured_bits] <= bit_out;
                captured_bits <= captured_bits + 1;
            end
            if (done_pulse) done_count <= done_count + 1;
        end
    end

    integer total = 0;
    integer fails = 0;
    integer i;

    task automatic chk_eq(input [255:0] label, input integer got, input integer exp);
        begin
            total = total + 1;
            if (got === exp) $display("  [PASS] %0s  got=%0d exp=%0d", label, got, exp);
            else begin
                fails = fails + 1;
                $display("  [FAIL] %0s  got=%0d exp=%0d", label, got, exp);
            end
        end
    endtask

    task automatic chk_bit(input integer idx, input bit exp);
        begin
            total = total + 1;
            if (bit_capture[idx] === exp) begin
                $display("  [PASS] bit[%0d] = %0b (exp %0b)", idx, bit_capture[idx], exp);
            end else begin
                fails = fails + 1;
                $display("  [FAIL] bit[%0d] = %0b (exp %0b)", idx, bit_capture[idx], exp);
            end
        end
    endtask

    task automatic chk_true(input [255:0] label, input bit cond);
        begin
            total = total + 1;
            if (cond) $display("  [PASS] %0s", label);
            else begin
                fails = fails + 1;
                $display("  [FAIL] %0s", label);
            end
        end
    endtask

    task automatic do_reset;
        begin
            rst_n       = 1'b0;
            start_pulse = 1'b0;
            payload_len = 16'd0;
            fifo_size   = 0;
            rptr        = 0;
            for (i = 0; i < 32; i = i + 1) fifo_mem[i] = 8'h00;
            repeat (4) @(posedge clk);
            rst_n = 1'b1;
            repeat (2) @(posedge clk);
        end
    endtask

    task automatic pulse_start;
        begin
            @(posedge clk); #1;
            start_pulse = 1'b1;
            @(posedge clk); #1;
            start_pulse = 1'b0;
        end
    endtask

    integer t_end;

    initial begin
        $display("============================================================");
        $display(" tb_mac_fsm_custom : Path B MAC with seed=0 (identity scr)");
        $display("============================================================");

        do_reset();
        payload_len = 16'd2;
        fifo_size   = 2;
        fifo_mem[0] = 8'h5A;  // LSB-first -> 0,1,0,1,1,0,1,0
        fifo_mem[1] = 8'hA5;  // LSB-first -> 1,0,1,0,0,1,0,1
        pulse_start();

        // Wait up to some cycles for done_pulse.
        t_end = 0;
        while (done_count == 0 && t_end < 5000) begin
            @(posedge clk);
            t_end = t_end + 1;
        end
        // let final updates settle
        repeat (4) @(posedge clk);

        $display("--- sequential bit-stream checks ---");
        chk_eq   ("total bit_valid pulses", captured_bits, 32 + 16 + 32);
        chk_eq   ("done_pulse count",       done_count,    1);
        chk_true ("no underrun",            !underrun_flag);

        // First 32 bits: 0xAAAAAAAA LSB first => 0,1,0,1,...
        // bit[2k]=0, bit[2k+1]=1 for k in 0..15.
        for (i = 0; i < 32; i = i + 1) begin
            chk_bit(i, i[0]);  // i even -> 0, odd -> 1
        end

        // Next 16 bits: {0x5A, 0xA5} LSB first.
        //   0x5A = 0101_1010  -> LSB-first: 0,1,0,1,1,0,1,0
        //   0xA5 = 1010_0101  -> LSB-first: 1,0,1,0,0,1,0,1
        chk_bit(32, 1'b0);  chk_bit(33, 1'b1);
        chk_bit(34, 1'b0);  chk_bit(35, 1'b1);
        chk_bit(36, 1'b1);  chk_bit(37, 1'b0);
        chk_bit(38, 1'b1);  chk_bit(39, 1'b0);
        chk_bit(40, 1'b1);  chk_bit(41, 1'b0);
        chk_bit(42, 1'b1);  chk_bit(43, 1'b0);
        chk_bit(44, 1'b0);  chk_bit(45, 1'b1);
        chk_bit(46, 1'b0);  chk_bit(47, 1'b1);

        $display("------------------------------------------------------------");
        $display(" total=%0d  failed=%0d  result=%s", total, fails,
                 (fails == 0) ? "*** PASS ***" : "*** FAIL ***");
        $display("============================================================");
        $finish;
    end

    initial begin
        #500_000;
        $display("[TB-FATAL] mac_fsm_custom timeout");
        $fatal(1, "timeout");
    end

endmodule
