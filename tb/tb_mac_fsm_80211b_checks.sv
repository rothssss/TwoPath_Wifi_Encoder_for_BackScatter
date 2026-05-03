`timescale 1ns/1ps

module tb_mac_fsm_80211b_checks;

    localparam integer CLK_T = 10;
    localparam [2:0]   S_HEAD        = 3'd3;
    localparam [2:0]   S_PSDU_BARKER = 3'd5;

    reg         clk              = 1'b0;
    reg         rst_n            = 1'b0;
    reg         start_pulse      = 1'b0;
    reg  [1:0]  rate_mode        = 2'b00;
    reg  [15:0] payload_len      = 16'd0;
    reg  [15:0] length_field     = 16'd0;
    reg  [7:0]  service_field    = 8'd0;
    reg  [15:0] cck_symbol_count = 16'd0;

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
        .SCRAMBLER_SEED(7'h5D)
    ) dut (
        .clk             (clk),
        .rst_n           (rst_n),
        .start_pulse     (start_pulse),
        .rate_mode       (rate_mode),
        .payload_len     (payload_len),
        .length_field    (length_field),
        .service_field   (service_field),
        .cck_symbol_count(cck_symbol_count),
        .busy            (busy),
        .done_pulse      (done_pulse),
        .fifo_rd_en      (fifo_rd_en),
        .fifo_empty      (fifo_empty),
        .fifo_rd_data    (fifo_rd_data),
        .underrun_flag   (underrun_flag),
        .base_phase      (base_phase),
        .delta_phi1      (delta_phi1),
        .update_phi1     (update_phi1),
        .chip_valid      (chip_valid)
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
            if (cond) $display("  [PASS] %0s", label);
            else begin
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
            if (actual === expected) $display("  [PASS] %0s got=%02h", label, actual);
            else begin
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
            if (actual === expected) $display("  [PASS] %0s got=%04h", label, actual);
            else begin
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
            if (actual === expected) $display("  [PASS] %0s got=%0d", label, actual);
            else begin
                checks_fail = checks_fail + 1;
                $display("  [FAIL] %0s got=%0d expected=%0d", label, actual, expected);
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

    function automatic [1:0] ref_dqpsk_delta;
        input bit0;
        input bit1;
        begin
            case ({bit1, bit0})
                2'b00 : ref_dqpsk_delta = 2'd0;
                2'b10 : ref_dqpsk_delta = 2'd1;
                2'b11 : ref_dqpsk_delta = 2'd2;
                2'b01 : ref_dqpsk_delta = 2'd3;
                default: ref_dqpsk_delta = 2'd0;
            endcase
        end
    endfunction

    task automatic do_reset;
        integer i;
        begin
            rst_n            = 1'b0;
            start_pulse      = 1'b0;
            rate_mode        = 2'b00;
            payload_len      = 16'd0;
            length_field     = 16'd0;
            service_field    = 8'd0;
            cck_symbol_count = 16'd0;
            fifo_size        = 0;
            rptr             = 0;
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
            rate_mode    = 2'b00;
            payload_len  = 16'd2;
            length_field = 16'd16;  // 1 Mbps: 8 * 2
            fifo_size    = 2;
            fifo_mem[0]  = 8'hA1;
            fifo_mem[1]  = 8'hB2;
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

    task test_dqpsk_mapping;
        reg [6:0] ref_state_0;
        reg [6:0] ref_state_1;
        reg [1:0] exp_delta;
        reg       s0;
        reg       s1;
        begin
            $display("\n--- test_dqpsk_mapping ---");
            do_reset();
            ref_state_0 = 7'h5D;
            s0          = ref_scramble_bit(ref_state_0, 1'b1);
            ref_state_1 = ref_scramble_state(ref_state_0, 1'b1);
            s1          = ref_scramble_bit(ref_state_1, 1'b0);
            exp_delta   = ref_dqpsk_delta(s0, s1);

            force dut.state         = S_PSDU_BARKER;
            force dut.rate_mode_q   = 2'b01;
            force dut.payload_len_q = 16'd2;
            force dut.byte_cnt      = 16'd0;
            force dut.bit_in_byte   = 3'd0;
            force dut.byte_sr       = 8'h01;
            force dut.chip_cnt      = 4'd0;
            force dut.lfsr          = ref_state_0;
            @(posedge clk); #1;
            expect_eq2("delta_phi1 for legal-seed DQPSK symbol", delta_phi1, exp_delta);
            expect_true("update_phi1 asserted for forced DQPSK symbol", update_phi1);
            release dut.state;
            release dut.rate_mode_q;
            release dut.payload_len_q;
            release dut.byte_cnt;
            release dut.bit_in_byte;
            release dut.byte_sr;
            release dut.chip_cnt;
            release dut.lfsr;
        end
    endtask

    task automatic test_header_length_dbpsk;
        integer cycles;
        reg saw_head;
        begin
            $display("\n--- test_header_length_dbpsk ---");
            do_reset();
            rate_mode    = 2'b00;
            payload_len  = 16'd3;
            length_field = 16'd24;   // 1 Mbps: 8 * 3
            service_field = 8'h00;
            pulse_start();

            saw_head = 1'b0;
            for (cycles = 0; cycles < 4000 && !saw_head; cycles = cycles + 1) begin
                @(posedge clk);
                if (dut.state == S_HEAD && dut.sym_cnt == 8'd0 && dut.chip_cnt == 4'd0) begin
                    expect_eq8 ("1 Mbps SIGNAL byte", dut.header_sr[7:0], 8'h0A);
                    expect_eq8 ("1 Mbps SERVICE byte", dut.header_sr[15:8], 8'h00);
                    expect_eq16("1 Mbps LENGTH field", dut.header_sr[31:16], 16'd24);
                    saw_head = 1'b1;
                end
            end
            expect_true("observed first header symbol for DBPSK", saw_head);
        end
    endtask

    task automatic test_header_length_dqpsk;
        integer cycles;
        reg saw_head;
        begin
            $display("\n--- test_header_length_dqpsk ---");
            do_reset();
            rate_mode    = 2'b01;
            payload_len  = 16'd3;
            length_field = 16'd12;   // 2 Mbps: 4 * 3
            service_field = 8'h00;
            pulse_start();

            saw_head = 1'b0;
            for (cycles = 0; cycles < 4000 && !saw_head; cycles = cycles + 1) begin
                @(posedge clk);
                if (dut.state == S_HEAD && dut.sym_cnt == 8'd0 && dut.chip_cnt == 4'd0) begin
                    expect_eq8 ("2 Mbps SIGNAL byte", dut.header_sr[7:0], 8'h14);
                    expect_eq8 ("2 Mbps SERVICE byte", dut.header_sr[15:8], 8'h00);
                    expect_eq16("2 Mbps LENGTH field", dut.header_sr[31:16], 16'd12);
                    saw_head = 1'b1;
                end
            end
            expect_true("observed first header symbol for DQPSK", saw_head);
        end
    endtask

    initial begin
        $display("============================================================");
        $display(" tb_mac_fsm_80211b_checks : focused Path A regressions     ");
        $display("============================================================");

        test_barker_fifo_alignment();
        test_dqpsk_mapping();
        test_header_length_dbpsk();
        test_header_length_dqpsk();

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
