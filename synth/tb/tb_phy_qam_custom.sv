// =============================================================================
// tb_phy_qam_custom : serial-to-parallel QAM grouper checks.
//
// Behaviour (see rtl/path_b/phy_qam_custom.v):
//   - bits_per_sym picked from mod_config: 1/2/4/6/8 for OOK/QPSK/16/64/256.
//   - Incoming bits enter the shift-reg MSB; after N shifts the first bit
//     received sits at LSB of the N-bit packed symbol, matching
//     "first bit at symbol LSB".
//   - invalid_mode asserts for unsupported mod_config when bit_valid is high.
//
// Check plan:
//   T1  OOK             : one bit per symbol, 4 bits -> 4 symbols {1,0,1,0}.
//   T2  QPSK            : bits {1,0,1,1} -> symbols {2'b01, 2'b11}.
//   T3  16-QAM          : bits {1,1,0,0,1,0,1,0} -> symbols {4'b0011, 4'b0101}
//                         (first bit at LSB).
//   T4  Partial flush   : 64-QAM with 4 bits then end_pulse -> one symbol =
//                         4 bits placed at LSB, rest zero.
//   T5  Invalid mode    : mod_config=3'b111 with bit_valid=1 -> invalid_mode=1.
// =============================================================================
`timescale 1ns/1ps

module tb_phy_qam_custom;

    reg         clk         = 1'b0;
    reg         rst_n       = 1'b0;
    reg         start_pulse = 1'b0;
    reg         end_pulse   = 1'b0;
    reg  [2:0]  mod_config  = 3'b000;
    reg         bit_valid   = 1'b0;
    reg         bit_in      = 1'b0;

    wire        invalid_mode;
    wire [7:0]  path_b_symbol;
    wire        path_b_symbol_valid;

    phy_qam_custom dut (
        .clk(clk), .rst_n(rst_n),
        .start_pulse(start_pulse), .end_pulse(end_pulse),
        .mod_config(mod_config),
        .bit_valid(bit_valid), .bit_in(bit_in),
        .invalid_mode(invalid_mode),
        .path_b_symbol(path_b_symbol),
        .path_b_symbol_valid(path_b_symbol_valid)
    );

    always #5 clk = ~clk;

    integer total = 0;
    integer fails = 0;

    task automatic chk_eq(input [255:0] label, input [7:0] got, input [7:0] exp);
        begin
            total = total + 1;
            if (got === exp) $display("  [PASS] %0s got=%02h exp=%02h", label, got, exp);
            else begin
                fails = fails + 1;
                $display("  [FAIL] %0s got=%02h exp=%02h", label, got, exp);
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

    // Feed one bit with bit_valid asserted.
    task automatic feed_bit(input bit b);
        begin
            @(posedge clk); #1;
            bit_in    = b;
            bit_valid = 1'b1;
            @(posedge clk); #1;
            bit_valid = 1'b0;
        end
    endtask

    task automatic do_reset;
        begin
            rst_n       = 1'b0;
            start_pulse = 1'b0;
            end_pulse   = 1'b0;
            mod_config  = 3'b000;
            bit_valid   = 1'b0;
            bit_in      = 1'b0;
            repeat (3) @(posedge clk);
            rst_n = 1'b1;
            @(posedge clk);
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

    // ------------------------------------------------------------------
    // T1: OOK -> four bits 1,0,1,0 -> four symbols 1,0,1,0
    // ------------------------------------------------------------------
    reg [7:0] captured [0:15];
    integer   cap_cnt;

    always @(posedge clk) begin
        if (rst_n && path_b_symbol_valid) begin
            captured[cap_cnt] <= path_b_symbol;
            cap_cnt           <= cap_cnt + 1;
        end
    end

    initial cap_cnt = 0;

    task automatic reset_capture;
        begin
            cap_cnt = 0;
        end
    endtask

    initial begin : main
        bit [3:0] bits4;
        bit [7:0] bits8;
        integer   i;
        $display("============================================================");
        $display(" tb_phy_qam_custom : variable S2P QAM grouper");
        $display("============================================================");

        // ----- T1 : OOK -----
        $display("--- T1 OOK ---");
        do_reset;
        mod_config = 3'b000;  // OOK
        pulse_start;
        reset_capture;
        bits4 = 4'b1010;
        for (i = 0; i < 4; i = i + 1) feed_bit(bits4[i]);
        @(posedge clk);
        chk_true("OOK: 4 symbols captured", cap_cnt == 4);
        chk_eq("OOK sym[0]", captured[0], 8'h01);
        chk_eq("OOK sym[1]", captured[1], 8'h00);
        chk_eq("OOK sym[2]", captured[2], 8'h01);
        chk_eq("OOK sym[3]", captured[3], 8'h00);

        // ----- T2 : QPSK ----- bits 1,0,1,1 -> syms {2'b01, 2'b11}
        $display("--- T2 QPSK ---");
        do_reset;
        mod_config = 3'b001;
        pulse_start;
        reset_capture;
        bits4 = 4'b1101;  // fed LSB first: 1,0,1,1
        for (i = 0; i < 4; i = i + 1) feed_bit(bits4[i]);
        @(posedge clk);
        chk_true("QPSK: 2 symbols captured", cap_cnt == 2);
        chk_eq("QPSK sym[0]", captured[0], 8'h01);  // {0,1} -> first bit 1 at LSB, second 0
        chk_eq("QPSK sym[1]", captured[1], 8'h03);  // {1,1} -> 0b11

        // ----- T3 : 16-QAM ----- bits 1,1,0,0,1,0,1,0 -> syms 4'b0011, 4'b0101
        $display("--- T3 16-QAM ---");
        do_reset;
        mod_config = 3'b010;
        pulse_start;
        reset_capture;
        bits8 = 8'b01010011;  // fed LSB-first: 1,1,0,0,1,0,1,0
        for (i = 0; i < 8; i = i + 1) feed_bit(bits8[i]);
        @(posedge clk);
        chk_true("16-QAM: 2 symbols captured", cap_cnt == 2);
        chk_eq("16-QAM sym[0]", captured[0], 8'h03);  // 0b0011
        chk_eq("16-QAM sym[1]", captured[1], 8'h05);  // 0b0101

        // ----- T4 : 64-QAM partial flush ----- 4 bits then end_pulse
        $display("--- T4 64-QAM partial flush ---");
        do_reset;
        mod_config = 3'b011;  // 6 bits/sym
        pulse_start;
        reset_capture;
        bits4 = 4'b1011;  // feed LSB-first: 1,1,0,1
        for (i = 0; i < 4; i = i + 1) feed_bit(bits4[i]);
        @(posedge clk); #1;
        end_pulse = 1'b1;
        @(posedge clk); #1;
        end_pulse = 1'b0;
        @(posedge clk);
        chk_true("64-QAM partial: exactly 1 flushed symbol",  cap_cnt == 1);
        chk_eq("64-QAM partial flushed sym", captured[0], 8'h0B);  // 0b1011

        // ----- T5 : Invalid mode -----
        $display("--- T5 invalid mode ---");
        do_reset;
        mod_config = 3'b111;
        pulse_start;
        @(posedge clk); #1;
        bit_valid = 1'b1;
        bit_in    = 1'b1;
        #1;
        chk_true("invalid_mode high on unsupported mod_config", invalid_mode === 1'b1);
        @(posedge clk); #1;
        bit_valid = 1'b0;

        $display("------------------------------------------------------------");
        $display(" total=%0d  failed=%0d  result=%s", total, fails,
                 (fails == 0) ? "*** PASS ***" : "*** FAIL ***");
        $display("============================================================");
        $finish;
    end

    initial begin
        #500_000;
        $display("[TB-FATAL] phy_qam_custom timeout");
        $fatal(1, "timeout");
    end

endmodule
