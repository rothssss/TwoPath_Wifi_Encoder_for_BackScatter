`timescale 1ns/1ps

module tb_mac_fsm_80211b_checks;

    localparam integer CLK_T = 10;
    localparam [3:0]   S_PSDU_BARKER = 4'd5;
    localparam [3:0]   S_PSDU_CCK    = 4'd7;

    reg         clk         = 1'b0;
    reg         rst_n       = 1'b0;
    reg         start_pulse = 1'b0;
    reg  [1:0]  rate        = 2'b00;
    reg  [15:0] payload_len = 16'd0;
    reg  [15:0] length_us   = 16'd0;

    wire        busy;
    wire        done_pulse;
    wire        fifo_rd_en;
    wire        underrun_flag;
    wire [7:0]  fifo_rd_data;
    wire [1:0]  base_phase;
    wire [1:0]  delta_phi1;
    wire        update_phi1;
    wire        chip_valid;

    reg  [7:0] fifo_mem [0:63];
    integer    fifo_size = 0;
    integer    rptr      = 0;
    wire       fifo_empty = (rptr >= fifo_size);

    assign fifo_rd_data = fifo_mem[rptr];

    mac_fsm_80211b #(
        .SCRAMBLER_SEED(7'h00)
    ) dut (
        .clk          (clk),
        .rst_n        (rst_n),
        .start_pulse  (start_pulse),
        .rate         (rate),
        .payload_len  (payload_len),
        .length_us    (length_us),
        .busy         (busy),
        .done_pulse   (done_pulse),
        .fifo_rd_en   (fifo_rd_en),
        .fifo_empty   (fifo_empty),
        .fifo_rd_data (fifo_rd_data),
        .underrun_flag(underrun_flag),
        .base_phase   (base_phase),
        .delta_phi1   (delta_phi1),
        .update_phi1  (update_phi1),
        .chip_valid   (chip_valid)
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

    task automatic expect_eq16;
        input [767:0] label;
        input [15:0]  actual;
        input [15:0]  expected;
        begin
            checks_run = checks_run + 1;
            if (actual === expected) begin
                $display("  [PASS] %0s got=%04h", label, actual);
            end else begin
                checks_fail = checks_fail + 1;
                $display("  [FAIL] %0s got=%04h expected=%04h", label, actual, expected);
            end
        end
    endtask

    task automatic expect_eq2;
        input [767:0] label;
        input [1:0]   actual;
        input [1:0]   expected;
        begin
            checks_run = checks_run + 1;
            if (actual === expected) begin
                $display("  [PASS] %0s got=%0d", label, actual);
            end else begin
                checks_fail = checks_fail + 1;
                $display("  [FAIL] %0s got=%0d expected=%0d", label, actual, expected);
            end
        end
    endtask

    task automatic do_reset;
        integer i;
        begin
            rst_n       = 1'b0;
            start_pulse = 1'b0;
            rate        = 2'b00;
            payload_len = 16'd0;
            length_us   = 16'd0;
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

    task automatic test_barker_fifo_alignment;
        integer cycles;
        reg saw_first;
        reg saw_second;
        begin
            $display("\n--- test_barker_fifo_alignment ---");
            do_reset();
            rate        = 2'b00;
            payload_len = 16'd2;
            length_us   = 16'd16;
            fifo_size   = 2;
            fifo_mem[0] = 8'hA1;
            fifo_mem[1] = 8'hB2;
            pulse_start();

            saw_first  = 1'b0;
            saw_second = 1'b0;
            for (cycles = 0; cycles < 4000 && (!saw_first || !saw_second); cycles = cycles + 1) begin
                @(posedge clk);
                if (dut.state == S_PSDU_BARKER && dut.chip_cnt == 4'd0 && dut.bit_in_byte == 3'd0) begin
                    if (dut.byte_cnt == 16'd0 && !saw_first) begin
                        expect_eq8("first payload byte", dut.byte_sr, 8'hA1);
                        saw_first = 1'b1;
                    end
                    if (dut.byte_cnt == 16'd1 && !saw_second) begin
                        expect_eq8("second payload byte", dut.byte_sr, 8'hB2);
                        saw_second = 1'b1;
                    end
                end
            end
            expect_true("observed first payload byte window", saw_first);
            expect_true("observed second payload byte window", saw_second);
            expect_true("no underrun during Barker alignment test", !underrun_flag);
        end
    endtask

    task automatic test_dqpsk_mapping;
        integer cycles;
        reg     saw_first_symbol;
        begin
            $display("\n--- test_dqpsk_mapping ---");
            do_reset();
            rate        = 2'b01;
            payload_len = 16'd1;
            length_us   = 16'd8;
            fifo_size   = 1;
            fifo_mem[0] = 8'h02;  // first dibit on the wire is 0,1 (LSB first)
            pulse_start();

            saw_first_symbol = 1'b0;
            for (cycles = 0; cycles < 4000 && !saw_first_symbol; cycles = cycles + 1) begin
                @(posedge clk); #1;
                if (dut.state == S_PSDU_BARKER && dut.bit_in_byte == 3'd0 && update_phi1) begin
                    expect_eq8("first DQPSK payload byte", dut.byte_sr, 8'h02);
                    expect_eq2("delta_phi1 for dibit 01", delta_phi1, 2'd1);
                    saw_first_symbol = 1'b1;
                end
            end
            expect_true("observed first DQPSK payload symbol", saw_first_symbol);
            expect_true("no underrun during DQPSK mapping test", !underrun_flag);
        end
    endtask

    task automatic test_cck_word_assembly;
        integer cycles;
        reg [2:0] seen_words;
        begin
            $display("\n--- test_cck_word_assembly ---");
            do_reset();
            rate        = 2'b11;
            payload_len = 16'd1;
            length_us   = 16'd8;
            fifo_size   = 10;
            fifo_mem[0] = 8'h10; fifo_mem[1] = 8'h11;
            fifo_mem[2] = 8'h20; fifo_mem[3] = 8'h21;
            fifo_mem[4] = 8'h30; fifo_mem[5] = 8'h31;
            fifo_mem[6] = 8'h40; fifo_mem[7] = 8'h41;
            fifo_mem[8] = 8'h50; fifo_mem[9] = 8'h51;
            pulse_start();

            seen_words = 3'd0;
            for (cycles = 0; cycles < 5000 && seen_words < 3; cycles = cycles + 1) begin
                @(posedge clk);
                if (dut.state == S_PSDU_CCK && dut.chip_cnt == 4'd2) begin
                    case (dut.cck_sym_cnt)
                        16'd0: begin
                            expect_eq16("first CCK word", dut.cck_word, 16'h1110);
                            seen_words = seen_words + 1'b1;
                        end
                        16'd1: begin
                            expect_eq16("second CCK word", dut.cck_word, 16'h2120);
                            seen_words = seen_words + 1'b1;
                        end
                        16'd2: begin
                            expect_eq16("third CCK word", dut.cck_word, 16'h3130);
                            seen_words = seen_words + 1'b1;
                        end
                        default: ;
                    endcase
                end
            end
            expect_true("observed three CCK symbols", seen_words == 3);
            expect_true("no underrun during CCK word test", !underrun_flag);
        end
    endtask

    initial begin
        $display("============================================================");
        $display(" tb_mac_fsm_80211b_checks : focused Path A regressions     ");
        $display("============================================================");

        test_barker_fifo_alignment();
        test_dqpsk_mapping();
        test_cck_word_assembly();

        $display("\n============================================================");
        $display(" CHECKS RUN  : %0d", checks_run);
        $display(" CHECKS FAIL : %0d", checks_fail);
        if (checks_fail == 0)
            $display(" RESULT      : ALL CHECKS PASSED");
        else
            $display(" RESULT      : %0d CHECKS FAILED", checks_fail);
        $display("============================================================");

        if (checks_fail != 0) $fatal(1, "Path A regression checks failed");
        $finish;
    end

endmodule
