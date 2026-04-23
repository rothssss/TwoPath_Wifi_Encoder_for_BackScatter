// =============================================================================
// tb_reset_sync : async-assert / sync-deassert reset synchronizer.
//
// Expected:
//   Async deassertion of async_rst_n drives sync_rst_n low immediately (async).
//   After async_rst_n rises, sync_rst_n returns high after exactly 2 clk edges.
// =============================================================================
`timescale 1ns/1ps

module tb_reset_sync;

    reg  clk         = 1'b0;
    reg  async_rst_n = 1'b0;
    wire sync_rst_n;

    reset_sync dut (.clk(clk), .async_rst_n(async_rst_n), .sync_rst_n(sync_rst_n));

    always #5 clk = ~clk;

    integer total = 0;
    integer fails = 0;

    task automatic chk(input [255:0] label, input bit cond);
        begin
            total = total + 1;
            if (cond) $display("  [PASS] %0s", label);
            else begin
                fails = fails + 1;
                $display("  [FAIL] %0s", label);
            end
        end
    endtask

    initial begin
        $display("============================================================");
        $display(" tb_reset_sync : async assert / sync deassert");
        $display("============================================================");

        async_rst_n = 1'b0;
        repeat (3) @(posedge clk);
        chk("sync_rst_n low during async reset", sync_rst_n === 1'b0);

        // Deassert async reset between clock edges.
        #2;
        async_rst_n = 1'b1;
        // Immediately: sync_rst_n still 0
        chk("sync_rst_n still 0 right after deassert", sync_rst_n === 1'b0);

        @(posedge clk); #1;
        chk("1 edge after deassert: sync_rst_n still 0", sync_rst_n === 1'b0);
        @(posedge clk); #1;
        chk("2 edges after deassert: sync_rst_n high", sync_rst_n === 1'b1);

        // Reassert async reset -> sync_rst_n drops immediately (async path).
        async_rst_n = 1'b0;
        #1;
        chk("async reassert: sync_rst_n immediately low", sync_rst_n === 1'b0);

        $display("------------------------------------------------------------");
        $display(" total=%0d  failed=%0d  result=%s", total, fails,
                 (fails == 0) ? "*** PASS ***" : "*** FAIL ***");
        $display("============================================================");
        $finish;
    end

endmodule
