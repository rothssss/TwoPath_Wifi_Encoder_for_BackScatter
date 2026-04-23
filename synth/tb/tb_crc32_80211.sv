// =============================================================================
// tb_crc32_80211 : verify the reflected CRC-32 (IEEE 802.3 / 802.11 FCS)
// against the canonical "123456789" test vector.
//
//   Poly   = 0x04C11DB7   (reflected = 0xEDB88320)
//   Init   = 0xFFFFFFFF
//   RefIn  = true   (bits fed LSB-first within each byte)
//   RefOut = true   (reflection is inherent in the right-shift state machine)
//   XorOut = 0xFFFFFFFF
//
// Expected CRC-32("123456789") = 0xCBF43926.
// =============================================================================
`timescale 1ns/1ps

module tb_crc32_80211;

    reg         clk        = 1'b0;
    reg         rst_n      = 1'b0;
    reg         init       = 1'b0;
    reg         data_valid = 1'b0;
    reg         data_bit   = 1'b0;
    wire [31:0] crc_out;

    crc32_80211 dut (
        .clk(clk), .rst_n(rst_n),
        .init(init),
        .data_valid(data_valid),
        .data_bit(data_bit),
        .crc_out(crc_out)
    );

    always #5 clk = ~clk;

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
        $display(" tb_crc32_80211 : CRC-32('123456789') == 0xCBF43926");
        $display("============================================================");
        repeat (3) @(posedge clk);
        rst_n = 1'b1;

        @(posedge clk);
        init = 1'b1;
        @(posedge clk);
        init = 1'b0;

        // Feed LSB-first within each byte.
        for (i = 0; i < 9; i = i + 1) begin
            for (b = 0; b < 8; b = b + 1) begin
                data_bit   = msg[i][b];
                data_valid = 1'b1;
                @(posedge clk);
            end
        end
        data_valid = 1'b0;
        data_bit   = 1'b0;
        @(posedge clk);

        total = total + 1;
        if (crc_out === 32'hCBF43926) begin
            $display("  [PASS] crc_out = %08h  (expected 0xCBF43926)", crc_out);
        end else begin
            fails = fails + 1;
            $display("  [FAIL] crc_out = %08h  expected 0xCBF43926", crc_out);
        end

        $display("------------------------------------------------------------");
        $display(" total=%0d  failed=%0d  result=%s", total, fails,
                 (fails == 0) ? "*** PASS ***" : "*** FAIL ***");
        $display("============================================================");
        $finish;
    end

endmodule
