// =============================================================================
// tb_scrambler_x7x4 : check the x^7+x^4+1 scrambler's output stream.
//
// Module behaviour (see rtl/common/scrambler_x7x4.v):
//   lfsr reset-value = DEFAULT_SEED = 7'h5D = 7'b1011101
//   data_out (combinational) = data_in ^ lfsr[6]
//   On data_valid: lfsr <= {lfsr[5:0], lfsr[6]^lfsr[3]}
//
// Expected output stream for data_in == 0, seed 7'h5D (precomputed):
//   step : lfsr[6] == data_out
//     0  :  1        (lfsr=1011101)
//     1  :  0        (lfsr=0111010)
//     2  :  1        (lfsr=1110101)
//     3  :  1        (lfsr=1101011)
//     4  :  1        (lfsr=1010110)
//     5  :  0        (lfsr=0101101)
//     6  :  1        (lfsr=1011011)
//     7  :  0        (lfsr=0110111)
// =============================================================================
`timescale 1ns/1ps

module tb_scrambler_x7x4;

    reg  clk       = 1'b0;
    reg  rst_n     = 1'b0;
    reg  seed_load = 1'b0;
    reg  data_valid= 1'b0;
    reg  data_in   = 1'b0;
    wire data_out;

    scrambler_x7x4 #(.DEFAULT_SEED(7'h5D)) dut (
        .clk(clk), .rst_n(rst_n),
        .seed_load(seed_load),
        .data_valid(data_valid),
        .data_in(data_in),
        .data_out(data_out)
    );

    always #5 clk = ~clk;

    integer total = 0;
    integer fails = 0;

    task automatic expect_out(input integer step, input bit exp);
        begin
            total = total + 1;
            if (data_out === exp) begin
                $display("  [PASS] step=%0d data_out=%0b exp=%0b", step, data_out, exp);
            end else begin
                fails = fails + 1;
                $display("  [FAIL] step=%0d data_out=%0b exp=%0b", step, data_out, exp);
            end
        end
    endtask

    // Precomputed stream for data_in = 0, seed 0x5D: 1 0 1 1 1 0 1 0
    bit [0:7] exp_stream = 8'b10111010;

    integer i;

    initial begin
        $display("============================================================");
        $display(" tb_scrambler_x7x4 : seed 0x5D, data_in=0 stream");
        $display("============================================================");
        data_in = 1'b0;
        repeat (2) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);

        // Before advancing: data_out is lfsr[6] at reset == 1
        expect_out(0, exp_stream[0]);

        // Advance the LFSR 7 more times with data_valid
        for (i = 1; i < 8; i = i + 1) begin
            data_valid = 1'b1;
            @(posedge clk);
            data_valid = 1'b0;
            #1;
            expect_out(i, exp_stream[i]);
        end

        // Seed reload restores lfsr => data_out should be 1 again
        seed_load = 1'b1;
        @(posedge clk);
        seed_load = 1'b0;
        #1;
        total = total + 1;
        if (data_out === 1'b1) begin
            $display("  [PASS] seed reload: data_out=%0b exp=1", data_out);
        end else begin
            fails = fails + 1;
            $display("  [FAIL] seed reload: data_out=%0b exp=1", data_out);
        end

        $display("------------------------------------------------------------");
        $display(" total=%0d  failed=%0d  result=%s", total, fails,
                 (fails == 0) ? "*** PASS ***" : "*** FAIL ***");
        $display("============================================================");
        $finish;
    end

endmodule
