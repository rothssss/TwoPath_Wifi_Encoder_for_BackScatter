`timescale 1ns/1ps

module tb_mac_fsm_custom_checks;

    localparam integer CLK_T = 10;
    localparam [2:0]   S_PAYLOAD = 3'd2;

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

    reg  [7:0] fifo_mem [0:63];
    integer    fifo_size = 0;
    integer    rptr      = 0;
    wire       fifo_empty = (rptr >= fifo_size);

    assign fifo_rd_data = fifo_mem[rptr];

    mac_fsm_custom #(
        .SCRAMBLER_SEED(7'h00)
    ) dut (
        .clk          (clk),
        .rst_n        (rst_n),
        .start_pulse  (start_pulse),
        .payload_len  (payload_len),
        .busy         (busy),
        .done_pulse   (done_pulse),
        .fifo_rd_en   (fifo_rd_en),
        .fifo_empty   (fifo_empty),
        .fifo_rd_data (fifo_rd_data),
        .underrun_flag(underrun_flag),
        .bit_valid    (bit_valid),
        .bit_out      (bit_out)
    );

    always #(CLK_T/2) clk = ~clk;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rptr <= 0;
        end else if (fifo_rd_en && !fifo_empty) begin
            rptr <= rptr + 1;
        end
    end

    integer checks_run  = 0;
    integer checks_fail = 0;

    task automatic expect_true;
        input [767:0] label;
        input         cond;
        begin
            checks_run = checks_run + 1;
            if (cond) begin
                $display("  [PASS] %0s", label);
            end else begin
                checks_fail = checks_fail + 1;
                $display("  [FAIL] %0s", label);
            end
        end
    endtask

    task automatic expect_eq8;
        input [767:0] label;
        input [7:0]   actual;
        input [7:0]   expected;
        begin
            checks_run = checks_run + 1;
            if (actual === expected) begin
                $display("  [PASS] %0s got=%02h", label, actual);
            end else begin
                checks_fail = checks_fail + 1;
                $display("  [FAIL] %0s got=%02h expected=%02h", label, actual, expected);
            end
        end
    endtask

    task automatic do_reset;
        integer i;
        begin
            rst_n       = 1'b0;
            start_pulse = 1'b0;
            payload_len = 16'd0;
            fifo_size   = 0;
            rptr        = 0;
            for (i = 0; i < 64; i = i + 1) fifo_mem[i] = 8'h00;
            repeat (4) @(posedge clk);
            rst_n = 1'b1;
            repeat (2) @(posedge clk);
        end
    endtask

    task automatic pulse_start;
        begin
            @(posedge clk);
            start_pulse = 1'b1;
            @(posedge clk);
            start_pulse = 1'b0;
        end
    endtask

    task automatic test_fifo_alignment;
        integer cycles;
        reg saw_first_byte;
        reg saw_second_byte;
        begin
            $display("\n--- test_fifo_alignment ---");
            do_reset();
            payload_len = 16'd2;
            fifo_size   = 2;
            fifo_mem[0] = 8'hA1;
            fifo_mem[1] = 8'hB2;
            pulse_start();

            saw_first_byte   = 1'b0;
            saw_second_byte  = 1'b0;

            for (cycles = 0; cycles < 4000 && (!saw_first_byte || !saw_second_byte); cycles = cycles + 1) begin
                @(posedge clk); #1;
                if (dut.state == S_PAYLOAD && dut.bit_in_byte == 3'd0) begin
                    if (dut.byte_cnt == 16'd0 && !saw_first_byte) begin
                        expect_eq8("first payload byte", dut.byte_sr, 8'hA1);
                        saw_first_byte = 1'b1;
                    end
                    if (dut.byte_cnt == 16'd1 && !saw_second_byte) begin
                        expect_eq8("second payload byte", dut.byte_sr, 8'hB2);
                        saw_second_byte = 1'b1;
                    end
                end
            end

            expect_true("observed first payload byte window", saw_first_byte);
            expect_true("observed second payload byte window", saw_second_byte);
            expect_true("no underrun during custom MAC alignment test", !underrun_flag);
        end
    endtask

    initial begin
        $display("============================================================");
        $display(" tb_mac_fsm_custom_checks : focused Path B regressions      ");
        $display("============================================================");

        test_fifo_alignment();

        $display("\n============================================================");
        $display(" CHECKS RUN  : %0d", checks_run);
        $display(" CHECKS FAIL : %0d", checks_fail);
        if (checks_fail == 0) begin
            $display(" RESULT      : ALL CHECKS PASSED");
        end else begin
            $display(" RESULT      : FAILURE");
        end
        $display("============================================================");
        $finish;
    end

endmodule
