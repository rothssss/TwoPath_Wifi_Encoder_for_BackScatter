// =============================================================================
// tb_crc16_hec : verify crc16_80211_hec against the classic "123456789" vector.
//
// The module implements CRC-16 with:
//   Poly    = 0x1021    (CCITT)
//   Init    = 0xFFFF
//   RefIn   = false     (bits fed MSB-first, shift-left register)
//   RefOut  = false
//   XorOut  = 0xFFFF
//
// This corresponds to CRC-16/GENIBUS.  Processing the 9 ASCII bytes
// "123456789" (0x31..0x39), MSB-first within each byte, yields:
//     crc_out  =  0xD64E
//
// Explanation: the "CRC-16/CCITT-FALSE" variant (same params except
// XorOut=0x0000) gives 0x29B1, and 0x29B1 ^ 0xFFFF = 0xD64E.
// =============================================================================
`timescale 1ns/1ps

module tb_crc16_hec;

    reg         clk        = 1'b0;
    reg         rst_n      = 1'b0;
    reg         init       = 1'b0;
    reg         data_valid = 1'b0;
    reg         data_bit   = 1'b0;
    wire [15:0] crc_out;

    crc16_80211_hec dut (
        .clk(clk), .rst_n(rst_n),
        .init(init),
        .data_valid(data_valid),
        .data_bit(data_bit),
        .crc_out(crc_out)
    );

    always #5 clk = ~clk;

    // Test bytes.
    reg [7:0] msg [0:8];
    initial begin
        msg[0] = 8'h31; msg[1] = 8'h32; msg[2] = 8'h33;
        msg[3] = 8'h34; msg[4] = 8'h35; msg[5] = 8'h36;
        msg[6] = 8'h37; msg[7] = 8'h38; msg[8] = 8'h39;
    end

    integer total = 0;
    integer fails = 0;

    integer i, b;

    initial begin
        $display("============================================================");
        $display(" tb_crc16_hec : CRC-16/0x1021 xorOut=0xFFFF of '123456789'");
        $display("============================================================");
        repeat (3) @(posedge clk);
        rst_n = 1'b1;

        // Pulse init one cycle before the first data bit.
        @(posedge clk);
        init = 1'b1;
        @(posedge clk);
        init = 1'b0;

        // Feed MSB-first.
        for (i = 0; i < 9; i = i + 1) begin
            for (b = 7; b >= 0; b = b - 1) begin
                data_bit   = msg[i][b];
                data_valid = 1'b1;
                @(posedge clk);
            end
        end
        data_valid = 1'b0;
        data_bit   = 1'b0;
        @(posedge clk);

        total = total + 1;
        if (crc_out === 16'hD64E) begin
            $display("  [PASS] crc_out = %04h  (expected 0xD64E)", crc_out);
        end else begin
            fails = fails + 1;
            $display("  [FAIL] crc_out = %04h  expected 0xD64E", crc_out);
        end

        $display("------------------------------------------------------------");
        $display(" total=%0d  failed=%0d  result=%s", total, fails,
                 (fails == 0) ? "*** PASS ***" : "*** FAIL ***");
        $display("============================================================");
        $finish;
    end

endmodule
