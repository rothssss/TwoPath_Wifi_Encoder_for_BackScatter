// =============================================================================
// tb_mac_fsm_80211b_cck_golden : golden-vector regression for the CCK PSDU
// streamer.
//
// What this checks
// ----------------
//   The MCU offload contract makes the chip side a "replay" engine: per CCK
//   symbol, the chip pulls one packed 4-byte word from the FIFO and drives 8
//   QPSK chips through phy_a_rotator.  This bench drives mac_fsm_80211b
//   directly with a behavioural FIFO model and verifies, chip-by-chip, that:
//
//     1. base_phase[chip_cnt=k] matches cck_word[2*k+2 +: 2] for each of the
//        8 chips of every CCK symbol.
//     2. update_phi1 is asserted on chip 0 of every CCK symbol AND nowhere
//        else inside the PSDU window.
//     3. delta_phi1 at that update_phi1 pulse matches cck_word[1:0].
//     4. Exactly cck_symbol_count CCK symbols emit (8 chips per symbol).
//     5. Exactly 4 * cck_symbol_count FIFO bytes are consumed.
//     6. done_pulse fires once and busy returns low.
//     7. The prefetch buffer does NOT leak the next symbol's data into the
//        current symbol's chips (test_prefetch_isolation).
//
// What this bench is NOT
// ----------------------
//   * It does not validate the MCU-side CCK encoder against IEEE 802.11-2016
//     sec 16.4.6 reference vectors.  That requires a MATLAB / ns-3 / GNURadio
//     reference and is a separate deliverable.  When those vectors land,
//     they can be packed via `pack_cck` and fed into the same harness here.
//   * It does not validate spec axis alignment (phase_to_iq emits at +/- pi/4
//     so the analog front end sees a 45-deg rotated constellation; receiver
//     carrier recovery handles it).
//   * It does not exercise the rotator math; that is shared with Barker rates
//     and is covered by tb_phy_a_rotator and tb_mac_fsm_80211b_checks.
//
// To shorten simulation, PREAMBLE_SYNC_LEN is overridden to 8 (vs the default
// 128); the FSM behaviour we care about (HEC -> S_PSDU_CCK transition,
// prefetch, symbol streaming) is unchanged.
// =============================================================================
`timescale 1ns/1ps

module tb_mac_fsm_80211b_cck_golden;

    localparam integer CLK_T          = 10;
    localparam integer SHORT_SYNC_LEN = 8;
    // Header chip count = (SYNC + SFD + HEAD + HEC) symbols * 11 chips/sym.
    localparam integer HDR_SYMS  = SHORT_SYNC_LEN + 16 + 32 + 16;
    localparam integer HDR_CHIPS = HDR_SYMS * 11;

    localparam [3:0] S_PSDU_CCK = 4'd7;

    reg         clk              = 1'b0;
    reg         rst_n            = 1'b0;
    reg         start_pulse      = 1'b0;
    reg  [1:0]  rate_mode        = 2'b11;
    reg  [15:0] payload_len      = 16'd0;
    reg  [15:0] length_field     = 16'd16;
    reg  [7:0]  service_field    = 8'h00;
    reg  [15:0] cck_symbol_count = 16'd0;

    wire        busy;
    wire        done_pulse;
    wire        fifo_rd_en;
    wire        underrun_flag;
    wire [1:0]  base_phase;
    wire [1:0]  delta_phi1;
    wire        update_phi1;
    wire        chip_valid;

    // Behavioural FIFO: linear array of bytes the FSM drains via fifo_rd_en.
    reg  [7:0]  fifo_mem [0:511];
    integer     fifo_size  = 0;
    integer     rptr       = 0;
    wire        fifo_empty = (rptr >= fifo_size);
    wire [7:0]  fifo_rd_data = fifo_mem[rptr];

    mac_fsm_80211b #(
        .PREAMBLE_SYNC_LEN(SHORT_SYNC_LEN),
        .SCRAMBLER_SEED   (7'h6D)
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
        if (!rst_n)                          rptr <= 0;
        else if (fifo_rd_en && !fifo_empty)  rptr <= rptr + 1;
    end

    // ---------------------------------------------------------------------
    // Aggregate counters reset by rst_n.  cck_update_count is gated by the
    // FSM being in S_PSDU_CCK so it only counts CCK-symbol delta pulses.
    // (Barker preamble/header symbols also pulse update_phi1, so a global
    // count would include all 72 header symbols.)
    // ---------------------------------------------------------------------
    integer chip_count       = 0;
    integer done_count       = 0;
    integer ur_count         = 0;
    integer rd_count         = 0;
    integer cck_update_count = 0;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            chip_count       <= 0;
            done_count       <= 0;
            ur_count         <= 0;
            rd_count         <= 0;
            cck_update_count <= 0;
        end else begin
            if (chip_valid)                                 chip_count       <= chip_count + 1;
            if (done_pulse)                                 done_count       <= done_count + 1;
            if (underrun_flag)                              ur_count         <= ur_count   + 1;
            if (fifo_rd_en && !fifo_empty)                  rd_count         <= rd_count   + 1;
            if (update_phi1 && dut.state === S_PSDU_CCK)    cck_update_count <= cck_update_count + 1;
        end
    end

    // ---------------------------------------------------------------------
    // Test-result tally.
    // ---------------------------------------------------------------------
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

    task automatic chk_true(input [255:0] label, input integer cond);
        begin
            total = total + 1;
            if (cond) $display("  [PASS] %0s", label);
            else begin
                fails = fails + 1;
                $display("  [FAIL] %0s", label);
            end
        end
    endtask

    task automatic do_reset;
        integer i;
        begin
            rst_n            = 1'b0;
            start_pulse      = 1'b0;
            rate_mode        = 2'b00;
            payload_len      = 16'd0;
            length_field     = 16'd16;
            service_field    = 8'h00;
            cck_symbol_count = 16'd0;
            fifo_size        = 0;
            rptr             = 0;
            for (i = 0; i < 512; i = i + 1) fifo_mem[i] = 8'h00;
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

    // ---------------------------------------------------------------------
    // CCK-symbol packing helper.  Mirrors rtl/path_a/mac_fsm_80211b.v's
    // unpacking convention, LSB-first across the 4 FIFO bytes:
    //   bits[1:0]   = delta_phi1
    //   bits[3:2]   = c_k0
    //   bits[5:4]   = c_k1
    //   bits[7:6]   = c_k2
    //   bits[9:8]   = c_k3   (already includes the chip-3 +pi when MCU encodes)
    //   bits[11:10] = c_k4
    //   bits[13:12] = c_k5
    //   bits[15:14] = c_k6   (already includes the chip-6 +pi when MCU encodes)
    //   bits[17:16] = c_k7
    //   bits[31:18] = 0
    // ---------------------------------------------------------------------
    function automatic [31:0] pack_cck(input [1:0] delta,
                                       input [1:0] c0, input [1:0] c1,
                                       input [1:0] c2, input [1:0] c3,
                                       input [1:0] c4, input [1:0] c5,
                                       input [1:0] c6, input [1:0] c7);
        pack_cck = {14'd0, c7, c6, c5, c4, c3, c2, c1, c0, delta};
    endfunction

    task automatic load_cck_word(input [31:0] w);
        begin
            fifo_mem[fifo_size + 0] = w[ 7: 0];
            fifo_mem[fifo_size + 1] = w[15: 8];
            fifo_mem[fifo_size + 2] = w[23:16];
            fifo_mem[fifo_size + 3] = w[31:24];
            fifo_size               = fifo_size + 4;
        end
    endtask

    // ---------------------------------------------------------------------
    // Expected words (one per CCK symbol).  Filled by each test before
    // pulse_start, then consumed by verify_cck_window.
    // ---------------------------------------------------------------------
    reg [31:0] expect_words [0:31];

    // ---------------------------------------------------------------------
    // verify_cck_window : monitor the FSM's outputs through the entire CCK
    // PSDU window, comparing chip-by-chip against expect_words[0 .. n_sym-1].
    //
    // Sampling timing notes:
    //   * chip_valid is registered, so the cycle on which dut.state first
    //     equals S_PSDU_CCK still has chip_valid driven by the previous
    //     state's emit_chip_c (it represents the LAST HEC chip, with
    //     base_phase coming from chip_cnt=10 of the last HEC bit).  We
    //     skip that first pulse.
    //   * After that, the next 8*n_sym chip_valid pulses correspond to
    //     CCK chip 0..7 of symbol 0 .. n_sym-1.
    //   * The very last CCK pulse arrives in the cycle where dut.state has
    //     already transitioned to S_DONE; we therefore gate the loop on
    //     chip_valid (not on state) once we have entered S_PSDU_CCK at
    //     least once.
    // ---------------------------------------------------------------------
    task automatic verify_cck_window(input integer n_sym);
        integer cycles, idx, s, k, total_pulses;
        integer base_mismatches, delta_mismatches, update_mismatches;
        reg     entered;
        reg [31:0] w;
        reg [1:0]  exp_c, exp_delta;
        begin
            cycles            = 0;
            idx               = 0;
            total_pulses      = 0;
            entered           = 1'b0;
            base_mismatches   = 0;
            delta_mismatches  = 0;
            update_mismatches = 0;

            while (!entered && cycles < 200000) begin
                @(posedge clk);
                cycles = cycles + 1;
                if (dut.state === S_PSDU_CCK) entered = 1'b1;
            end
            chk_true("entered S_PSDU_CCK", entered);

            while (idx < 8 * n_sym && cycles < 200000) begin
                if (chip_valid) begin
                    total_pulses = total_pulses + 1;
                    if (total_pulses == 1) begin
                        // Late-registered last HEC chip; skip.
                    end else begin
                        s = idx / 8;
                        k = idx % 8;
                        w = expect_words[s];
                        case (k[2:0])
                            3'd0: exp_c = w[ 3: 2];
                            3'd1: exp_c = w[ 5: 4];
                            3'd2: exp_c = w[ 7: 6];
                            3'd3: exp_c = w[ 9: 8];
                            3'd4: exp_c = w[11:10];
                            3'd5: exp_c = w[13:12];
                            3'd6: exp_c = w[15:14];
                            3'd7: exp_c = w[17:16];
                        endcase

                        if (base_phase !== exp_c) begin
                            $display("  [FAIL] base_phase mismatch sym=%0d chip=%0d got=%b exp=%b",
                                     s, k, base_phase, exp_c);
                            $display("         dut.chip_cnt=%0d dut.cck_sym_cnt=%0d dut.state=%0d",
                                     dut.chip_cnt, dut.cck_sym_cnt, dut.state);
                            $display("         dut.cck_word_curr=%h dut.cck_word_next=%h expect_words[s]=%h",
                                     dut.cck_word_curr, dut.cck_word_next, w);
                            base_mismatches = base_mismatches + 1;
                        end

                        if (k == 0) begin
                            exp_delta = w[1:0];
                            if (!update_phi1) begin
                                $display("  [FAIL] update_phi1 not asserted at chip 0 sym=%0d", s);
                                update_mismatches = update_mismatches + 1;
                            end
                            if (delta_phi1 !== exp_delta) begin
                                $display("  [FAIL] delta_phi1 mismatch sym=%0d got=%b exp=%b",
                                         s, delta_phi1, exp_delta);
                                delta_mismatches = delta_mismatches + 1;
                            end
                        end else begin
                            if (update_phi1) begin
                                $display("  [FAIL] update_phi1 asserted at non-zero chip sym=%0d chip=%0d",
                                         s, k);
                                update_mismatches = update_mismatches + 1;
                            end
                        end

                        idx = idx + 1;
                    end
                end
                @(posedge clk);
                cycles = cycles + 1;
            end

            chk_eq  ("CCK chips sampled",            idx,               8 * n_sym);
            chk_eq  ("base_phase mismatches",        base_mismatches,   0);
            chk_eq  ("delta_phi1 mismatches",        delta_mismatches,  0);
            chk_eq  ("update_phi1 timing errors",    update_mismatches, 0);
        end
    endtask

    integer wait_cycles;
    task automatic wait_done;
        begin
            wait_cycles = 0;
            while (done_count == 0 && wait_cycles < 200000) begin
                @(posedge clk);
                wait_cycles = wait_cycles + 1;
            end
            repeat (4) @(posedge clk);
        end
    endtask

    integer ix;

    // =====================================================================
    // Test 1 : 4 hand-crafted symbols stressing every phase code on every
    //          chip position and every delta value.
    //
    //   sym 0 : delta=00, c_k all 00     (uniform reference)
    //   sym 1 : delta=01, c_k all 01
    //   sym 2 : delta=11, c_k all 11
    //   sym 3 : delta=10, c_k mixed 00/01/11/10/00/01/11/10
    // =====================================================================
    task automatic test_uniform_and_mixed;
        begin
            $display("\n--- test_uniform_and_mixed ---");
            do_reset();
            rate_mode        = 2'b11;
            payload_len      = 16'd0;
            length_field     = 16'd4;
            service_field    = 8'h00;
            cck_symbol_count = 16'd4;

            expect_words[0] = pack_cck(2'b00, 2'b00,2'b00,2'b00,2'b00, 2'b00,2'b00,2'b00,2'b00);
            expect_words[1] = pack_cck(2'b01, 2'b01,2'b01,2'b01,2'b01, 2'b01,2'b01,2'b01,2'b01);
            expect_words[2] = pack_cck(2'b11, 2'b11,2'b11,2'b11,2'b11, 2'b11,2'b11,2'b11,2'b11);
            expect_words[3] = pack_cck(2'b10, 2'b00,2'b01,2'b11,2'b10, 2'b00,2'b01,2'b11,2'b10);

            for (ix = 0; ix < 4; ix = ix + 1) load_cck_word(expect_words[ix]);

            pulse_start();
            verify_cck_window(4);
            wait_done();

            chk_eq ("done_pulse count",        done_count,    1);
            chk_eq ("no underrun",             ur_count,      0);
            chk_eq ("chip_valid total",        chip_count,    HDR_CHIPS + 4 * 8);
            chk_eq ("FIFO bytes consumed",     rd_count,      4 * 4);
            chk_eq ("update_phi1 total = N",   cck_update_count,  4);
            chk_true("busy returned low",      !busy);
        end
    endtask

    // =====================================================================
    // Test 2 : Single-symbol packet, exercising the corner case where
    //          cck_symbol_count == 1 (no concurrent prefetch ever fires).
    // =====================================================================
    task automatic test_single_symbol;
        begin
            $display("\n--- test_single_symbol ---");
            do_reset();
            rate_mode        = 2'b10;     // 5.5 Mbps CCK
            payload_len      = 16'd0;
            length_field     = 16'd2;
            service_field    = 8'h00;
            cck_symbol_count = 16'd1;

            expect_words[0] = pack_cck(2'b11, 2'b00,2'b01,2'b10,2'b11, 2'b11,2'b10,2'b01,2'b00);
            load_cck_word(expect_words[0]);

            pulse_start();
            verify_cck_window(1);
            wait_done();

            chk_eq ("done_pulse count",        done_count,    1);
            chk_eq ("chip_valid total",        chip_count,    HDR_CHIPS + 8);
            chk_eq ("FIFO bytes consumed",     rd_count,      4);
            chk_eq ("update_phi1 total",       cck_update_count,  1);
            chk_true("busy returned low",      !busy);
        end
    endtask

    // =====================================================================
    // Test 3 : Prefetch isolation.  Two symbols whose c_k fields are
    //          maximally different (all 00 then all 11) so any leak from
    //          the prefetch buffer into the current symbol shows up as a
    //          base_phase mismatch.
    // =====================================================================
    task automatic test_prefetch_isolation;
        begin
            $display("\n--- test_prefetch_isolation ---");
            do_reset();
            rate_mode        = 2'b11;
            payload_len      = 16'd0;
            length_field     = 16'd4;
            service_field    = 8'h00;
            cck_symbol_count = 16'd2;

            expect_words[0] = pack_cck(2'b00, 2'b00,2'b00,2'b00,2'b00, 2'b00,2'b00,2'b00,2'b00);
            expect_words[1] = pack_cck(2'b00, 2'b11,2'b11,2'b11,2'b11, 2'b11,2'b11,2'b11,2'b11);

            load_cck_word(expect_words[0]);
            load_cck_word(expect_words[1]);

            pulse_start();
            verify_cck_window(2);
            wait_done();

            chk_eq ("done_pulse count",        done_count,    1);
            chk_eq ("chip_valid total",        chip_count,    HDR_CHIPS + 2 * 8);
            chk_eq ("FIFO bytes consumed",     rd_count,      4 * 2);
            chk_true("busy returned low",      !busy);
        end
    endtask

    // =====================================================================
    // Test 4 : Many-symbol packet (8 symbols) to confirm the prefetch
    //          continues correctly across all symbol boundaries.  Each
    //          symbol has a distinguishable c_k pattern so a stuck-on
    //          prefetch buffer would surface as repeated base_phase.
    // =====================================================================
    task automatic test_eight_symbols;
        integer i;
        begin
            $display("\n--- test_eight_symbols ---");
            do_reset();
            rate_mode        = 2'b11;
            payload_len      = 16'd0;
            length_field     = 16'd16;
            service_field    = 8'h00;
            cck_symbol_count = 16'd8;

            for (i = 0; i < 8; i = i + 1) begin
                expect_words[i] = pack_cck(i[1:0],
                    i[1:0],       (i+1)&2'h3, (i+2)&2'h3, (i+3)&2'h3,
                    (i+4)&2'h3,   (i+5)&2'h3, (i+6)&2'h3, (i+7)&2'h3);
                load_cck_word(expect_words[i]);
            end

            pulse_start();
            verify_cck_window(8);
            wait_done();

            chk_eq ("done_pulse count",        done_count,    1);
            chk_eq ("chip_valid total",        chip_count,    HDR_CHIPS + 8 * 8);
            chk_eq ("FIFO bytes consumed",     rd_count,      4 * 8);
            chk_eq ("update_phi1 total",       cck_update_count,  8);
            chk_true("busy returned low",      !busy);
        end
    endtask

    initial begin
        $display("============================================================");
        $display(" tb_mac_fsm_80211b_cck_golden : MCU-offload streamer regression");
        $display("============================================================");

        test_uniform_and_mixed();
        test_single_symbol();
        test_prefetch_isolation();
        test_eight_symbols();

        $display("------------------------------------------------------------");
        $display(" total=%0d  failed=%0d  result=%s",
                 total, fails, (fails == 0) ? "*** PASS ***" : "*** FAIL ***");
        $display("============================================================");
        $finish;
    end

    initial begin
        #20_000_000;
        $display("[TB-FATAL] tb_mac_fsm_80211b_cck_golden timeout");
        $fatal(1, "timeout");
    end

endmodule
