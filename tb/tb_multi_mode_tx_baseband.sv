// =============================================================================
// tb_multi_mode_tx_baseband : functional testbench for the top-level TX
// baseband.
//
// Coverage (one test per datapath):
//
//   Path A (802.11b Long PLCP):
//     T_A1   1 Mbps DBPSK         mod_config = 4'b0000
//     T_A2   2 Mbps DQPSK         mod_config = 4'b0001
//     T_A3   5.5 Mbps CCK         mod_config = 4'b0010
//     T_A4   11  Mbps CCK         mod_config = 4'b0011
//
//   Path B (custom QAM, per Multi-Mode_TX_Architecture.md §1):
//     T_B1   OOK                  mod_config = 4'b1000
//     T_B2   QPSK                 mod_config = 4'b1001
//     T_B3   16-QAM               mod_config = 4'b1010
//     T_B4   64-QAM               mod_config = 4'b1011
//     T_B5   256-QAM              mod_config = 4'b1100
//
//   Control / error plumbing:
//     T_C1   illegal mod_config latches `invalid_mode`, tx stays idle
//     T_C2   back-to-back DBPSK packets produce two clean tx_done pulses
//
// Strategy
// --------
// For each datapath, compute the *expected* number of emitted chips
// (Path A) or symbols (Path B) from the PLCP framing rules, feed a
// deterministic payload into the FIFO, pulse `tx_enable`, count the
// `chip_valid` / `symbol_valid` pulses, then compare against the
// expectation.  A final report tallies pass/fail counts.
//
// The TB is not a bit-accurate 802.11 conformance checker: it verifies
// framing, control flow, CDC plumbing, error handling, and per-mode
// chip/symbol counts.  Focused Path A / Path B bit-level regressions live in
// `tb_mac_fsm_80211b_checks.sv` and `tb_mac_fsm_custom_checks.sv`;
// anything beyond that belongs in a per-module UVM environment.
//
// Run (Cadence Xcelium):
//   xrun -sv -f tb/filelist.f \
//        +define+ASSERT_ON \
//        -top tb_multi_mode_tx_baseband
// =============================================================================
`timescale 1ns/1ps

module tb_multi_mode_tx_baseband;

    // -------------------------------------------------------------------
    // Clocks and reset
    // -------------------------------------------------------------------
    // 11 MHz, 100 MHz, 50 MHz — nominal ratios chosen for realism.
    localparam real T_BCHIP  = 90.9;   // ns   -> 11 MHz
    localparam real T_CUSTOM = 10.0;   // ns   -> 100 MHz
    localparam real T_MCU    = 20.0;   // ns   -> 50 MHz

    reg clk_b_chip = 1'b0;
    reg clk_custom = 1'b0;
    reg clk_mcu    = 1'b0;
    reg rst_n      = 1'b0;

    always #(T_BCHIP  / 2.0) clk_b_chip = ~clk_b_chip;
    always #(T_CUSTOM / 2.0) clk_custom = ~clk_custom;
    always #(T_MCU    / 2.0) clk_mcu    = ~clk_mcu;

    // -------------------------------------------------------------------
    // DUT stimulus / observation signals
    // -------------------------------------------------------------------
    reg         tx_enable     = 1'b0;
    reg  [3:0]  mod_config    = 4'd0;
    reg  [15:0] payload_len   = 16'd0;
    reg  [15:0] length_us     = 16'd0;
    reg  [7:0]  payload_in    = 8'd0;
    reg         payload_write = 1'b0;

    wire        tx_busy;
    wire        fifo_full;
    wire        underrun;
    wire        invalid_mode;
    wire        tx_done;
    wire [7:0]  symbol_out;
    wire        symbol_valid;
    wire        chip_i;
    wire        chip_q;
    wire        chip_valid;

    multi_mode_tx_baseband dut (
        .clk_b_chip   (clk_b_chip),
        .clk_custom   (clk_custom),
        .clk_mcu      (clk_mcu),
        .rst_n        (rst_n),
        .tx_enable    (tx_enable),
        .mod_config   (mod_config),
        .payload_len  (payload_len),
        .length_us    (length_us),
        .payload_in   (payload_in),
        .payload_write(payload_write),
        .tx_busy      (tx_busy),
        .fifo_full    (fifo_full),
        .underrun     (underrun),
        .invalid_mode (invalid_mode),
        .tx_done      (tx_done),
        .symbol_out   (symbol_out),
        .symbol_valid (symbol_valid),
        .chip_i       (chip_i),
        .chip_q       (chip_q),
        .chip_valid   (chip_valid)
    );

    // -------------------------------------------------------------------
    // Free-running counters.  Each test snapshots them before/after.
    // -------------------------------------------------------------------
    integer chip_valid_cnt   = 0;
    integer symbol_valid_cnt = 0;
    integer tx_done_cnt      = 0;
    integer underrun_cnt     = 0;

    always @(posedge clk_b_chip or negedge rst_n) begin
        if (!rst_n)            chip_valid_cnt   <= 0;
        else if (chip_valid)   chip_valid_cnt   <= chip_valid_cnt + 1;
    end

    always @(posedge clk_custom or negedge rst_n) begin
        if (!rst_n)            symbol_valid_cnt <= 0;
        else if (symbol_valid) symbol_valid_cnt <= symbol_valid_cnt + 1;
    end

    always @(posedge clk_mcu or negedge rst_n) begin
        if (!rst_n) begin
            tx_done_cnt  <= 0;
            underrun_cnt <= 0;
        end else begin
            if (tx_done)  tx_done_cnt  <= tx_done_cnt + 1;
            if (underrun) underrun_cnt <= underrun_cnt + 1;
        end
    end

    // -------------------------------------------------------------------
    // Pass/fail ledger
    // -------------------------------------------------------------------
    integer tests_run  = 0;
    integer tests_pass = 0;
    integer tests_fail = 0;
    string  current_test = "<none>";

    task automatic check_eq(input string label,
                            input integer actual,
                            input integer expected);
        begin
            tests_run = tests_run + 1;
            if (actual === expected) begin
                tests_pass = tests_pass + 1;
                $display("    [PASS] %-55s got=%0d", label, actual);
            end else begin
                tests_fail = tests_fail + 1;
                $display("    [FAIL] %-55s got=%0d  expected=%0d",
                         label, actual, expected);
            end
        end
    endtask

    task automatic check_true(input string label, input bit cond);
        begin
            tests_run = tests_run + 1;
            if (cond) begin
                tests_pass = tests_pass + 1;
                $display("    [PASS] %s", label);
            end else begin
                tests_fail = tests_fail + 1;
                $display("    [FAIL] %s", label);
            end
        end
    endtask

    // -------------------------------------------------------------------
    // Reset sequence
    // -------------------------------------------------------------------
    task automatic do_reset;
        begin
            rst_n         = 1'b0;
            tx_enable     = 1'b0;
            mod_config    = 4'b0000;
            payload_len   = 16'd0;
            length_us     = 16'd0;
            payload_in    = 8'd0;
            payload_write = 1'b0;
            #(T_BCHIP * 5);
            rst_n = 1'b1;
            #(T_BCHIP * 5);
        end
    endtask

    // -------------------------------------------------------------------
    // FIFO ingress helpers (clk_mcu domain)
    // -------------------------------------------------------------------
    task automatic write_byte(input [7:0] b);
        begin
            @(posedge clk_mcu);
            while (fifo_full) @(posedge clk_mcu);
            #1;
            payload_in    = b;
            payload_write = 1'b1;
            @(posedge clk_mcu);
            #1;
            payload_write = 1'b0;
        end
    endtask

    task automatic write_bytes(input integer n, input [7:0] seed);
        integer i;
        begin
            for (i = 0; i < n; i = i + 1) write_byte(seed + i[7:0]);
        end
    endtask

    // -------------------------------------------------------------------
    // Trigger and wait-for-done helpers
    // -------------------------------------------------------------------
    task automatic pulse_tx_enable;
        begin
            @(posedge clk_mcu); #1;
            tx_enable = 1'b1;
            @(posedge clk_mcu); #1;
            tx_enable = 1'b0;
        end
    endtask

    // Wait up to `timeout_ns` simulation time for tx_done to pulse.
    // Returns 1 if seen, 0 on timeout.
    task automatic wait_for_tx_done(input integer timeout_ns,
                                    output bit done_seen);
        integer t_end;
        integer start_done_cnt;
        begin
            done_seen      = 1'b0;
            start_done_cnt = tx_done_cnt;
            t_end          = $time + timeout_ns;
            while ($time < t_end && !done_seen) begin
                @(posedge clk_mcu);
                if (tx_done_cnt != start_done_cnt) done_seen = 1'b1;
            end
            // Drain any pending CDC settling.
            #(T_BCHIP * 4);
        end
    endtask

    // -------------------------------------------------------------------
    // Configure DUT static inputs, must be stable across the packet.
    // -------------------------------------------------------------------
    task automatic configure(input [3:0]  mc,
                             input [15:0] plen,
                             input [15:0] lus);
        begin
            @(posedge clk_mcu); #1;
            mod_config  = mc;
            payload_len = plen;
            length_us   = lus;
        end
    endtask

    // -------------------------------------------------------------------
    // Per-test snapshot bookkeeping
    // -------------------------------------------------------------------
    integer snap_chip, snap_sym, snap_done, snap_ur;

    task automatic snap_counters;
        begin
            snap_chip = chip_valid_cnt;
            snap_sym  = symbol_valid_cnt;
            snap_done = tx_done_cnt;
            snap_ur   = underrun_cnt;
        end
    endtask

    function integer delta_chip;  begin delta_chip = chip_valid_cnt   - snap_chip; end endfunction
    function integer delta_sym;   begin delta_sym  = symbol_valid_cnt - snap_sym;  end endfunction
    function integer delta_done;  begin delta_done = tx_done_cnt      - snap_done; end endfunction
    function integer delta_ur;    begin delta_ur   = underrun_cnt     - snap_ur;   end endfunction

    // -------------------------------------------------------------------
    // Expected-count formulas
    // -------------------------------------------------------------------
    // Path A: preamble+header is ALWAYS 1 Mbps DBPSK/Barker = 192 bits * 11 chips.
    //   S_SYNC = 128 symbols, S_SFD = 16, S_HEAD = 32, S_HEC = 16.
    //   PSDU/FCS depends on rate:
    //     1 Mbps DBPSK   : 8*N data bits + 32 FCS bits, 1 sym/bit, 11 chip/sym
    //     2 Mbps DQPSK   : (8*N + 32) bits / 2 symbols, 11 chip/sym
    //     5.5 Mbps CCK   : 2*N + 8 CCK symbols, 8 chip/sym
    //     11  Mbps CCK   : N + 4 CCK symbols, 8 chip/sym
    // -------------------------------------------------------------------
    localparam integer HDR_SYMS_A   = 128 + 16 + 32 + 16;  // = 192
    localparam integer HDR_CHIPS_A  = HDR_SYMS_A * 11;     // = 2112

    function integer chips_path_a(input [1:0] rate, input integer n);
        integer psdu;
        begin
            case (rate)
                2'b00: psdu = (8*n + 32) * 11;              // DBPSK
                2'b01: psdu = ((8*n + 32) / 2) * 11;        // DQPSK
                2'b10: psdu = (2*n + 8) * 8;                // CCK-5.5
                2'b11: psdu = (n + 4) * 8;                  // CCK-11
                default: psdu = 0;
            endcase
            chips_path_a = HDR_CHIPS_A + psdu;
        end
    endfunction

    // FIFO byte consumption for a Path A packet (beyond the on-chip header).
    //   1/2 Mbps : payload_len bytes
    //   5.5 Mbps : 4*(payload_len + 4) bytes of MCU-encoded CCK words
    //   11  Mbps : 2*(payload_len + 4) bytes
    function integer fifo_bytes_path_a(input [1:0] rate, input integer n);
        begin
            case (rate)
                2'b00, 2'b01: fifo_bytes_path_a = n;
                2'b10:        fifo_bytes_path_a = 4 * (n + 4);
                2'b11:        fifo_bytes_path_a = 2 * (n + 4);
                default:      fifo_bytes_path_a = 0;
            endcase
        end
    endfunction

    // Path B: total bits = CUSTOM_PREAMBLE_LEN + 8*payload_len + 32(FCS).
    // Default preamble length is 32 (see dut default param).
    localparam integer CUSTOM_PREAMBLE_LEN = 32;

    function integer syms_path_b(input integer bits_per_sym, input integer n);
        integer total_bits;
        begin
            total_bits    = CUSTOM_PREAMBLE_LEN + 8*n + 32;
            syms_path_b   = (total_bits + bits_per_sym - 1) / bits_per_sym;
        end
    endfunction

    // -------------------------------------------------------------------
    // Per-test wrapper: reset, configure, feed FIFO, trigger, wait, check.
    // -------------------------------------------------------------------
    task automatic run_path_a_test(input string     name,
                                   input [3:0]      mc,
                                   input integer    plen,
                                   input integer    exp_chips);
        integer nbytes;
        integer timeout_ns;
        bit     done_seen;
        begin
            current_test = name;
            $display("\n--- %s : mod_config=%b payload_len=%0d ---",
                     name, mc, plen);
            do_reset;
            configure(mc, plen[15:0], 16'd0);
            // Pre-fill the FIFO (all tests fit within FIFO_DEPTH=32).
            nbytes = fifo_bytes_path_a(mc[1:0], plen);
            check_true("fifo bytes fit in 32-deep FIFO", nbytes <= 32);
            write_bytes(nbytes, 8'hA0);
            snap_counters;
            pulse_tx_enable;
            // Allow plenty of headroom: slowest packet is DBPSK ~ 2816 chips
            // * 91 ns ~ 256 us.  10x margin -> 3 ms.
            timeout_ns = 3_000_000;
            wait_for_tx_done(timeout_ns, done_seen);
            check_true      ("tx_done pulsed once",      done_seen);
            check_eq        ("tx_done pulse count",      delta_done(), 1);
            check_eq        ("chip_valid pulses",        delta_chip(), exp_chips);
            check_eq        ("symbol_valid pulses (Path B silent)",
                                                         delta_sym(),  0);
            check_eq        ("no underrun",              delta_ur(),   0);
            check_true      ("invalid_mode clear",       !invalid_mode);
            check_true      ("tx_busy returned low",     !tx_busy);
        end
    endtask

    task automatic run_path_b_test(input string  name,
                                   input [3:0]   mc,
                                   input integer plen,
                                   input integer bits_per_sym);
        integer exp_syms;
        integer timeout_ns;
        bit     done_seen;
        begin
            current_test = name;
            $display("\n--- %s : mod_config=%b payload_len=%0d ---",
                     name, mc, plen);
            do_reset;
            configure(mc, plen[15:0], 16'd0);
            check_true("payload_len fits in FIFO", plen <= 32);
            write_bytes(plen, 8'hB0);
            snap_counters;
            pulse_tx_enable;
            // 96 bits at 10 ns/cycle = ~1 us.  Use generous 100 us.
            timeout_ns = 100_000;
            wait_for_tx_done(timeout_ns, done_seen);
            exp_syms = syms_path_b(bits_per_sym, plen);
            check_true ("tx_done pulsed once",      done_seen);
            check_eq   ("tx_done pulse count",      delta_done(), 1);
            check_eq   ("symbol_valid pulses",      delta_sym(),  exp_syms);
            check_eq   ("chip_valid pulses (Path A silent)",
                                                    delta_chip(), 0);
            check_eq   ("no underrun",              delta_ur(),   0);
            check_true ("invalid_mode clear",       !invalid_mode);
            check_true ("tx_busy returned low",     !tx_busy);
        end
    endtask

    // -------------------------------------------------------------------
    // Optional waveform dump
    // -------------------------------------------------------------------
`ifdef WAVES
    initial begin
        $dumpfile("tb_multi_mode_tx_baseband.vcd");
        $dumpvars(0, tb_multi_mode_tx_baseband);
    end
`endif

    // -------------------------------------------------------------------
    // Main stimulus
    // -------------------------------------------------------------------
    initial begin
        $display("============================================================");
        $display(" tb_multi_mode_tx_baseband : functional TX-baseband tests  ");
        $display("============================================================");

        // ---------------------------------------------------------------
        // T_C1 : Illegal mod_config latches invalid_mode; no tx starts.
        // ---------------------------------------------------------------
        begin : t_c1
            bit done_seen;
            current_test = "T_C1 invalid mod_config";
            $display("\n--- %s ---", current_test);
            do_reset;
            // Path A illegal (allowed range is 000..011).
            configure(4'b0111, 16'd4, 16'd0);
            snap_counters;
            pulse_tx_enable;
            #(T_MCU * 10);
            check_true("invalid_mode latched high",      invalid_mode);
            check_true("tx_busy stayed low",             !tx_busy);
            check_eq  ("no tx_done pulse",               delta_done(), 0);
            check_eq  ("no chip_valid pulses",           delta_chip(), 0);
            check_eq  ("no symbol_valid pulses",         delta_sym(),  0);
            check_eq  ("no underrun",                    delta_ur(),   0);

            // Path B illegal (allowed range is 000..100 per spec).
            // Use 4'b1101 which is clearly above 100.
            configure(4'b1101, 16'd4, 16'd0);
            pulse_tx_enable;
            #(T_MCU * 10);
            check_true("invalid_mode still latched",     invalid_mode);
            check_true("tx_busy stayed low",             !tx_busy);
        end

        // ---------------------------------------------------------------
        // Path A datapaths.  Expected chip counts assume the Long PLCP
        // framing documented in design-docs/Multi-Mode_TX_Architecture.md.
        // ---------------------------------------------------------------
        run_path_a_test("T_A1 1 Mbps DBPSK",  4'b0000, 4, chips_path_a(2'b00, 4));
        run_path_a_test("T_A2 2 Mbps DQPSK",  4'b0001, 4, chips_path_a(2'b01, 4));
        run_path_a_test("T_A3 5.5 Mbps CCK",  4'b0010, 3, chips_path_a(2'b10, 3));
        run_path_a_test("T_A4 11  Mbps CCK",  4'b0011, 3, chips_path_a(2'b11, 3));

        // ---------------------------------------------------------------
        // Path B datapaths.  Bits-per-symbol values match the NEW
        // architecture doc (OOK=1, QPSK=2, 16QAM=4, 64QAM=6, 256QAM=8).
        // ---------------------------------------------------------------
        run_path_b_test("T_B1 OOK",     4'b1000, 4, 1);
        run_path_b_test("T_B2 QPSK",    4'b1001, 4, 2);
        run_path_b_test("T_B3 16-QAM",  4'b1010, 4, 4);
        run_path_b_test("T_B4 64-QAM",  4'b1011, 4, 6);
        run_path_b_test("T_B5 256-QAM", 4'b1100, 4, 8);
        run_path_b_test("T_B6 64-QAM partial flush", 4'b1011, 2, 6);

        // ---------------------------------------------------------------
        // T_C2 : Back-to-back DBPSK packets — regression for state
        // leakage across packet boundaries.  Expect two clean tx_done
        // pulses and 2x chip count with no underrun.
        // ---------------------------------------------------------------
        begin : t_c2
            bit     done_seen;
            integer exp_chips_one;
            current_test = "T_C2 back-to-back DBPSK";
            $display("\n--- %s ---", current_test);
            do_reset;
            exp_chips_one = chips_path_a(2'b00, 4);
            configure(4'b0000, 16'd4, 16'd0);

            // Packet 1
            write_bytes(4, 8'hC0);
            snap_counters;
            pulse_tx_enable;
            wait_for_tx_done(3_000_000, done_seen);
            check_true("packet 1 tx_done seen",      done_seen);
            check_eq  ("packet 1 chip count",        delta_chip(), exp_chips_one);

            // Packet 2
            write_bytes(4, 8'hD0);
            snap_counters;
            pulse_tx_enable;
            wait_for_tx_done(3_000_000, done_seen);
            check_true("packet 2 tx_done seen",      done_seen);
            check_eq  ("packet 2 chip count",        delta_chip(), exp_chips_one);
            check_eq  ("no underrun across pair",    underrun_cnt, 0);
            check_eq  ("total tx_done pulses == 2",  tx_done_cnt, 2);
        end

        // ---------------------------------------------------------------
        // Final report
        // ---------------------------------------------------------------
        #(T_MCU * 10);
        $display("\n============================================================");
        $display(" FUNCTIONAL TEST REPORT");
        $display("============================================================");
        $display("  tests run    : %0d", tests_run);
        $display("  tests passed : %0d", tests_pass);
        $display("  tests failed : %0d", tests_fail);
        if (tests_fail == 0)
            $display("  RESULT       : *** ALL TESTS PASSED ***");
        else
            $display("  RESULT       : *** %0d FAILURES ***", tests_fail);
        $display("============================================================\n");

        $finish;
    end

    // -------------------------------------------------------------------
    // Global simulation safety net (should never trigger if the timeouts
    // inside wait_for_tx_done work).
    // -------------------------------------------------------------------
    initial begin
        #(50_000_000);  // 50 ms hard cap
        $display("\n[TB-FATAL] global simulation timeout; current_test=%s",
                 current_test);
        $display("  tests run    : %0d", tests_run);
        $display("  tests passed : %0d", tests_pass);
        $display("  tests failed : %0d", tests_fail);
        $fatal(1, "global timeout");
    end

endmodule
