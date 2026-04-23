// =============================================================================
// tb_sync_2ff : 2-flop synchronizer latency / reset-value check.
//
// Expected:
//   After reset the output equals RESET_VAL on both flops.
//   Changes on d_in appear on d_out after exactly 2 clk edges.
// =============================================================================
`timescale 1ns/1ps

module tb_sync_2ff;

    reg        clk = 1'b0;
    reg        rst_n = 1'b0;
    reg  [3:0] d_in = 4'h0;
    wire [3:0] d_out;

    sync_2ff #(.WIDTH(4), .RESET_VAL(1'b0)) dut (
        .clk(clk), .rst_n(rst_n),
        .d_in(d_in), .d_out(d_out)
    );

    always #5 clk = ~clk;

    integer total = 0;
    integer fails = 0;

    task automatic chk_eq(input [255:0] label, input [3:0] got, input [3:0] exp);
        begin
            total = total + 1;
            if (got === exp) $display("  [PASS] %0s got=%0h exp=%0h", label, got, exp);
            else begin
                fails = fails + 1;
                $display("  [FAIL] %0s got=%0h exp=%0h", label, got, exp);
            end
        end
    endtask

    initial begin
        $display("============================================================");
        $display(" tb_sync_2ff : 2FF synchronizer");
        $display("============================================================");

        d_in = 4'hA;
        repeat (3) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk); #1;
        chk_eq("reset output is 0", d_out, 4'h0);

        d_in = 4'hA;
        @(posedge clk); #1;
        // After 1 edge: meta=A, sync=0
        chk_eq("1 edge after change: d_out=0", d_out, 4'h0);
        @(posedge clk); #1;
        // After 2 edges: meta=A, sync=A
        chk_eq("2 edges after change: d_out=A", d_out, 4'hA);

        d_in = 4'h5;
        @(posedge clk); #1;
        chk_eq("1 edge after second change: d_out=A", d_out, 4'hA);
        @(posedge clk); #1;
        chk_eq("2 edges after second change: d_out=5", d_out, 4'h5);

        $display("------------------------------------------------------------");
        $display(" total=%0d  failed=%0d  result=%s", total, fails,
                 (fails == 0) ? "*** PASS ***" : "*** FAIL ***");
        $display("============================================================");
        $finish;
    end

endmodule
