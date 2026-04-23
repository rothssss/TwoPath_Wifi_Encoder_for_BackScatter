// =============================================================================
// tb_pulse_sync : single-pulse CDC.
//
// Behaviour:
//   Each src_pulse toggles toggle_src; the toggle is 2FF-synced into dst and
//   edge-detected to regenerate a 1-cycle dst_pulse.  Source and destination
//   clocks can run at any ratio, provided src pulses are separated by more
//   than a couple of dst cycles.
//
// Expected:
//   Each src pulse produces exactly one dst pulse (possibly several dst
//   cycles later due to the 2FF sync latency).
// =============================================================================
`timescale 1ns/1ps

module tb_pulse_sync;

    reg  src_clk   = 1'b0;
    reg  dst_clk   = 1'b0;
    reg  src_rst_n = 1'b0;
    reg  dst_rst_n = 1'b0;
    reg  src_pulse = 1'b0;
    wire dst_pulse;

    pulse_sync dut (
        .src_clk(src_clk), .src_rst_n(src_rst_n), .src_pulse(src_pulse),
        .dst_clk(dst_clk), .dst_rst_n(dst_rst_n), .dst_pulse(dst_pulse)
    );

    always #10 src_clk = ~src_clk;  // 20 ns src
    always #7  dst_clk = ~dst_clk;  // 14 ns dst (asynchronous)

    integer dst_pulse_cnt = 0;
    always @(posedge dst_clk) if (dst_pulse) dst_pulse_cnt <= dst_pulse_cnt + 1;

    integer total = 0;
    integer fails = 0;

    task automatic chk_eq(input [255:0] label, input integer got, input integer exp);
        begin
            total = total + 1;
            if (got === exp) $display("  [PASS] %0s got=%0d exp=%0d", label, got, exp);
            else begin
                fails = fails + 1;
                $display("  [FAIL] %0s got=%0d exp=%0d", label, got, exp);
            end
        end
    endtask

    task automatic fire_pulse;
        begin
            @(posedge src_clk); #1;
            src_pulse = 1'b1;
            @(posedge src_clk); #1;
            src_pulse = 1'b0;
            // Let the toggle cross and the edge detector fire (several dst cycles).
            repeat (6) @(posedge dst_clk);
        end
    endtask

    initial begin
        $display("============================================================");
        $display(" tb_pulse_sync : 3 src pulses -> 3 dst pulses");
        $display("============================================================");
        src_rst_n = 1'b0;
        dst_rst_n = 1'b0;
        repeat (3) @(posedge src_clk);
        src_rst_n = 1'b1;
        dst_rst_n = 1'b1;
        repeat (3) @(posedge dst_clk);

        fire_pulse();
        fire_pulse();
        fire_pulse();

        repeat (8) @(posedge dst_clk);
        chk_eq("dst_pulse count", dst_pulse_cnt, 3);

        $display("------------------------------------------------------------");
        $display(" total=%0d  failed=%0d  result=%s", total, fails,
                 (fails == 0) ? "*** PASS ***" : "*** FAIL ***");
        $display("============================================================");
        $finish;
    end

endmodule
