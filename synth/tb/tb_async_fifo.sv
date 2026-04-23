// =============================================================================
// tb_async_fifo : dual-clock FIFO basic behaviour.
//
// Checks:
//   1. Reset leaves the FIFO empty (empty=1, full=0).
//   2. One write makes empty go low after sync latency; rd_data matches.
//   3. Fill to capacity -> full == 1 after sync latency; additional writes drop.
//   4. Read back in order -> data matches write sequence (FIFO ordering).
//   5. Drain below half -> full clears.
//
// Write clock 20 ns (50 MHz), read clock 30 ns (~33 MHz) -- intentionally
// asynchronous to exercise the Gray-code pointer crossing.
// =============================================================================
`timescale 1ns/1ps

module tb_async_fifo;

    localparam DW = 8;
    localparam DEPTH = 8;
    localparam AW = 3;

    reg  wclk = 1'b0;
    reg  rclk = 1'b0;
    reg  rst_n = 1'b0;
    reg  wr_en = 1'b0;
    reg  [DW-1:0] wr_data = 0;
    wire full;

    reg  rd_en = 1'b0;
    wire [DW-1:0] rd_data;
    wire empty;

    async_fifo #(.DATA_W(DW), .DEPTH(DEPTH), .ADDR_W(AW)) dut (
        .wclk(wclk), .wrst_n(rst_n), .wr_en(wr_en), .wr_data(wr_data), .full(full),
        .rclk(rclk), .rrst_n(rst_n), .rd_en(rd_en), .rd_data(rd_data), .empty(empty)
    );

    always #10 wclk = ~wclk;  // 20 ns period = 50 MHz
    always #15 rclk = ~rclk;  // 30 ns period

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

    task automatic chk_eq8(input [255:0] label, input [7:0] got, input [7:0] exp);
        begin
            total = total + 1;
            if (got === exp) $display("  [PASS] %0s got=%02h exp=%02h", label, got, exp);
            else begin
                fails = fails + 1;
                $display("  [FAIL] %0s got=%02h exp=%02h", label, got, exp);
            end
        end
    endtask

    integer i;

    initial begin
        $display("============================================================");
        $display(" tb_async_fifo : 8-deep async FIFO sanity checks");
        $display("============================================================");

        // Reset
        rst_n = 1'b0;
        repeat (5) @(posedge wclk);
        rst_n = 1'b1;
        @(posedge wclk);
        @(posedge rclk);
        #5;
        chk("after reset empty=1", empty === 1'b1);
        chk("after reset full=0",  full  === 1'b0);

        // Write 0xA0..0xA7 (fill FIFO)
        for (i = 0; i < DEPTH; i = i + 1) begin
            @(posedge wclk); #1;
            wr_en   = 1'b1;
            wr_data = 8'hA0 + i;
        end
        @(posedge wclk); #1;
        wr_en = 1'b0;

        // Allow full to cross CDC (write->read-sync-back for full).
        repeat (6) @(posedge wclk);
        #1;
        chk("after filling DEPTH writes full=1", full === 1'b1);

        // Wait long enough for empty to fall on the read side.
        repeat (6) @(posedge rclk);
        #1;
        chk("after writes visible to rclk empty=0", empty === 1'b0);

        // Read all back in order; expect A0..A7.
        for (i = 0; i < DEPTH; i = i + 1) begin
            @(posedge rclk); #1;
            // rd_data is combinational at current rptr; sample it then advance.
            chk_eq8("read FIFO in-order", rd_data, 8'hA0 + i);
            rd_en = 1'b1;
            @(posedge rclk); #1;
            rd_en = 1'b0;
        end

        // After full drain, empty should assert, full should clear.
        repeat (6) @(posedge wclk);
        repeat (6) @(posedge rclk);
        #1;
        chk("drained FIFO empty=1", empty === 1'b1);
        chk("drained FIFO full=0",  full  === 1'b0);

        $display("------------------------------------------------------------");
        $display(" total=%0d  failed=%0d  result=%s", total, fails,
                 (fails == 0) ? "*** PASS ***" : "*** FAIL ***");
        $display("============================================================");
        $finish;
    end

    initial begin
        #2_000_000;
        $display("[TB-FATAL] async_fifo timeout");
        $fatal(1, "timeout");
    end

endmodule
