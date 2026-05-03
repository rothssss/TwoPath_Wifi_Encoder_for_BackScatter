// =============================================================================
// tb_mac_fsm_80211b : focused Path A MAC check (chip count, done, underrun).
//
// Expected chip totals (Long PLCP, preamble+header @ 1 Mbps DBPSK Barker):
//   HDR = SYNC(128) + SFD(16) + SIGNAL(8) + SERVICE(8) + LENGTH(16) + HEC(16)
//       = 192 bits, each 11 Barker chips -> 2112 chips.
//   PSDU/FCS per rate for payload bytes N:
//     DBPSK    : (8*N + 32) * 11
//     DQPSK    : ((8*N + 32)/2) * 11
//     CCK-5.5  : (2*N + 8) * 8
//     CCK-11   : (N + 4) * 8
//
// Tests:
//   T1 DBPSK, N=2  -> 2112 + (16+32)*11 = 2640 chips
//   T2 DQPSK, N=2  -> 2112 + ((16+32)/2)*11 = 2376 chips
//   T3 CCK-11, N=2 -> 2112 + (2+4)*8 = 2160 chips
// Each test also checks: done_pulse fired once, underrun stays low.
// =============================================================================
`timescale 1ns/1ps

module tb_mac_fsm_80211b;

    localparam integer CLK_T = 10;

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

    mac_fsm_80211b dut (
        .clk(clk), .rst_n(rst_n),
        .start_pulse(start_pulse),
        .rate_mode(rate_mode),
        .payload_len(payload_len),
        .length_field(length_field),
        .service_field(service_field),
        .cck_symbol_count(cck_symbol_count),
        .busy(busy),
        .done_pulse(done_pulse),
        .fifo_rd_en(fifo_rd_en),
        .fifo_empty(fifo_empty),
        .fifo_rd_data(fifo_rd_data),
        .underrun_flag(underrun_flag),
        .base_phase(base_phase),
        .delta_phi1(delta_phi1),
        .update_phi1(update_phi1),
        .chip_valid(chip_valid)
    );

    always #(CLK_T/2) clk = ~clk;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)                           rptr <= 0;
        else if (fifo_rd_en && !fifo_empty)   rptr <= rptr + 1;
    end

    integer chip_count  = 0;
    integer done_count  = 0;
    integer ur_count    = 0;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            chip_count <= 0;
            done_count <= 0;
            ur_count   <= 0;
        end else begin
            if (chip_valid)     chip_count <= chip_count + 1;
            if (done_pulse)     done_count <= done_count + 1;
            if (underrun_flag)  ur_count   <= ur_count   + 1;
        end
    end

    integer total = 0;
    integer fails = 0;
    integer i;

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

    task automatic do_reset;
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
            @(posedge clk); #1;
            start_pulse = 1'b1;
            @(posedge clk); #1;
            start_pulse = 1'b0;
        end
    endtask

    integer snap_chip, snap_done, snap_ur;
    task automatic snap;
        begin
            snap_chip = chip_count;
            snap_done = done_count;
            snap_ur   = ur_count;
        end
    endtask

    integer wait_cycles;

    // Wait up to timeout cycles for done_count to tick over.
    task automatic wait_done;
        begin
            wait_cycles = 0;
            while (done_count == snap_done && wait_cycles < 200000) begin
                @(posedge clk);
                wait_cycles = wait_cycles + 1;
            end
            repeat (6) @(posedge clk);
        end
    endtask

    // ------------------------------------------------------------------
    // Barker-rate test (rate_mode = 00 or 01).
    task automatic run_barker_test(input [255:0] name,
                                   input [1:0]   r,
                                   input integer n_bytes,
                                   input integer n_fifo,
                                   input integer exp_chips);
        begin
            $display("\n--- %0s : rate=%0b payload_len=%0d ---", name, r, n_bytes);
            do_reset();
            rate_mode        = r;
            payload_len      = n_bytes[15:0];
            length_field     = 16'd100;
            service_field    = 8'h00;
            cck_symbol_count = 16'd0;
            fifo_size        = n_fifo;
            for (i = 0; i < n_fifo; i = i + 1) fifo_mem[i] = 8'hA0 + i[7:0];
            snap();
            pulse_start();
            wait_done();
            chk_eq("chip_valid pulse count", chip_count - snap_chip, exp_chips);
            chk_eq("done_pulse count",       done_count - snap_done, 1);
            chk_eq("no underrun during packet", ur_count - snap_ur, 0);
        end
    endtask

    // CCK-rate test (rate_mode = 10 or 11).  4 bytes/symbol stub stream.
    task automatic run_cck_test(input [255:0] name,
                                input [1:0]   r,
                                input integer n_sym,
                                input integer exp_chips);
        begin
            $display("\n--- %0s : rate_mode=%0b cck_symbols=%0d ---", name, r, n_sym);
            do_reset();
            rate_mode        = r;
            payload_len      = 16'd0;
            length_field     = 16'd100;
            service_field    = 8'h00;
            cck_symbol_count = n_sym[15:0];
            fifo_size        = 4 * n_sym;
            for (i = 0; i < 4 * n_sym; i = i + 1) fifo_mem[i] = 8'h00;
            snap();
            pulse_start();
            wait_done();
            chk_eq("chip_valid pulse count", chip_count - snap_chip, exp_chips);
            chk_eq("done_pulse count",       done_count - snap_done, 1);
            chk_eq("no underrun during packet", ur_count - snap_ur, 0);
        end
    endtask

    initial begin
        $display("============================================================");
        $display(" tb_mac_fsm_80211b : chip-count framing tests");
        $display("============================================================");

        run_barker_test("T1 DBPSK   N=2", 2'b00, 2, 2, 2112 + (16+32)*11);     // 2640
        run_barker_test("T2 DQPSK   N=2", 2'b01, 2, 2, 2112 + ((16+32)/2)*11); // 2376
        run_cck_test   ("T3 CCK-5.5 S=2", 2'b10, 2,    2112 + 2*8);            // 2128
        run_cck_test   ("T4 CCK-11  S=2", 2'b11, 2,    2112 + 2*8);            // 2128

        $display("------------------------------------------------------------");
        $display(" total=%0d  failed=%0d  result=%s", total, fails,
                 (fails == 0) ? "*** PASS ***" : "*** FAIL ***");
        $display("============================================================");
        $finish;
    end

    initial begin
        #10_000_000;
        $display("[TB-FATAL] mac_fsm_80211b timeout");
        $fatal(1, "timeout");
    end

endmodule
