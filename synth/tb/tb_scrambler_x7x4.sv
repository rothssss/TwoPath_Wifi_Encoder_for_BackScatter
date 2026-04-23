// =============================================================================
// tb_scrambler_x7x4 : check the x^7+x^4+1 self-synchronous scrambler.
//
// Module behaviour:
//   data_out  = data_in ^ state[6] ^ state[3]
//   state_next = {data_out, state[6:1]} on data_valid
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

    task automatic expect_out(input integer step, input bit got, input bit exp);
        begin
            total = total + 1;
            if (got === exp) begin
                $display("  [PASS] step=%0d data_out=%0b exp=%0b", step, got, exp);
            end else begin
                fails = fails + 1;
                $display("  [FAIL] step=%0d data_out=%0b exp=%0b", step, got, exp);
            end
        end
    endtask

    function automatic ref_scramble_bit;
        input [6:0] state_in;
        input       raw_bit;
        begin
            ref_scramble_bit = raw_bit ^ state_in[6] ^ state_in[3];
        end
    endfunction

    function automatic [6:0] ref_scramble_state;
        input [6:0] state_in;
        input       raw_bit;
        reg         scrambled;
        begin
            scrambled = ref_scramble_bit(state_in, raw_bit);
            ref_scramble_state = {scrambled, state_in[6:1]};
        end
    endfunction

    reg [6:0] ref_state;
    reg [6:0] prev_state;
    reg [7:0] stim_bits;
    integer i;

    initial begin
        $display("============================================================");
        $display(" tb_scrambler_x7x4 : self-synchronous stream check");
        $display("============================================================");
        stim_bits = 8'b10110010;
        repeat (2) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);

        for (i = 0; i < 8; i = i + 1) begin
            @(negedge clk);
            data_in = stim_bits[i];
            prev_state = dut.lfsr;
            #1;
            expect_out(i, data_out, ref_scramble_bit(prev_state, stim_bits[i]));
            data_valid = 1'b1;
            @(posedge clk);
            #1;
            data_valid = 1'b0;
            total = total + 1;
            if (dut.lfsr === ref_scramble_state(prev_state, stim_bits[i])) begin
                $display("  [PASS] step=%0d state update", i);
            end else begin
                fails = fails + 1;
                $display("  [FAIL] step=%0d state update", i);
            end
        end

        @(negedge clk);
        seed_load = 1'b1;
        @(posedge clk);
        #1;
        seed_load = 1'b0;
        total = total + 1;
        if (dut.lfsr === 7'h5D) begin
            $display("  [PASS] seed state reload");
        end else begin
            fails = fails + 1;
            $display("  [FAIL] seed state reload");
        end
        data_in = 1'b0;
        #1;
        total = total + 1;
        if (data_out === ref_scramble_bit(7'h5D, 1'b0)) begin
            $display("  [PASS] seed reload output");
        end else begin
            fails = fails + 1;
            $display("  [FAIL] seed reload output");
        end

        $display("------------------------------------------------------------");
        $display(" total=%0d  failed=%0d  result=%s", total, fails,
                 (fails == 0) ? "*** PASS ***" : "*** FAIL ***");
        $display("============================================================");
        $finish;
    end

endmodule
