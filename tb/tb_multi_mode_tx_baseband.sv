// =============================================================================
// tb_multi_mode_tx_baseband : functional bench for the Wi-Fi-only TX.
//
// Supported compliant modes:
//   T_A1   1   Mbps DBPSK            mod_config = 4'b0000
//   T_A2   2   Mbps DQPSK            mod_config = 4'b0001
//   T_A3   5.5 Mbps CCK (offload)    mod_config = 4'b0010
//   T_A4   11  Mbps CCK (offload)    mod_config = 4'b0011
//
// Control / error checks:
//   T_C1   illegal mod_config values are refused and latch invalid_mode
//   T_C2   back-to-back DBPSK packets complete cleanly
//
// CCK tests stream MCU-precomputed 4-byte symbol words and only verify
// chip-stream geometry (symbol count, chip count, FIFO drain).  Bit-level
// validation against a golden CCK encoder is left as a TODO; the stub
// pattern below uses delta_phi1 = 0 and c_k = 0 so the chip output reduces
// to a constant phase.
// =============================================================================
`timescale 1ns/1ps

module tb_multi_mode_tx_baseband;

    localparam real T_BCHIP = 90.9;
    localparam real T_MCU   = 20.0;

    reg clk_b_chip = 1'b0;
    reg clk_custom = 1'b0;
    reg clk_mcu    = 1'b0;
    reg rst_n      = 1'b0;

    always #(T_BCHIP / 2.0) clk_b_chip = ~clk_b_chip;
    always #(10.0   / 2.0)  clk_custom = ~clk_custom;
    always #(T_MCU   / 2.0) clk_mcu    = ~clk_mcu;

    reg         tx_enable        = 1'b0;
    reg  [3:0]  mod_config       = 4'd0;
    reg  [15:0] payload_len      = 16'd0;
    reg  [15:0] length_field     = 16'd0;
    reg  [7:0]  service_field    = 8'd0;
    reg  [15:0] cck_symbol_count = 16'd0;
    reg  [7:0]  payload_in       = 8'd0;
    reg         payload_write    = 1'b0;

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
        .clk_b_chip      (clk_b_chip),
        .clk_custom      (clk_custom),
        .clk_mcu         (clk_mcu),
        .rst_n           (rst_n),
        .tx_enable       (tx_enable),
        .mod_config      (mod_config),
        .payload_len     (payload_len),
        .length_field    (length_field),
        .service_field   (service_field),
        .cck_symbol_count(cck_symbol_count),
        .payload_in      (payload_in),
        .payload_write   (payload_write),
        .tx_busy         (tx_busy),
        .fifo_full       (fifo_full),
        .underrun        (underrun),
        .invalid_mode    (invalid_mode),
        .tx_done         (tx_done),
        .symbol_out      (symbol_out),
        .symbol_valid    (symbol_valid),
        .chip_i          (chip_i),
        .chip_q          (chip_q),
        .chip_valid      (chip_valid)
    );

    integer chip_valid_cnt   = 0;
    integer symbol_valid_cnt = 0;
    integer tx_done_cnt      = 0;
    integer underrun_cnt     = 0;

    always @(posedge clk_b_chip or negedge rst_n) begin
        if (!rst_n)          chip_valid_cnt <= 0;
        else if (chip_valid) chip_valid_cnt <= chip_valid_cnt + 1;
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

    integer tests_run  = 0;
    integer tests_pass = 0;
    integer tests_fail = 0;
    string  current_test = "<none>";

    task automatic check_eq(input string label, input integer actual, input integer expected);
        begin
            tests_run = tests_run + 1;
            if (actual === expected) begin
                tests_pass = tests_pass + 1;
                $display("    [PASS] %-55s got=%0d", label, actual);
            end else begin
                tests_fail = tests_fail + 1;
                $display("    [FAIL] %-55s got=%0d expected=%0d", label, actual, expected);
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

    task automatic do_reset;
        begin
            rst_n            = 1'b0;
            tx_enable        = 1'b0;
            mod_config       = 4'b0000;
            payload_len      = 16'd0;
            length_field     = 16'd0;
            service_field    = 8'd0;
            cck_symbol_count = 16'd0;
            payload_in       = 8'd0;
            payload_write    = 1'b0;
            #(T_BCHIP * 5);
            rst_n = 1'b1;
            #(T_BCHIP * 5);
        end
    endtask

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

    task automatic pulse_tx_enable;
        begin
            @(posedge clk_mcu); #1;
            tx_enable = 1'b1;
            @(posedge clk_mcu); #1;
            tx_enable = 1'b0;
        end
    endtask

    task automatic wait_for_tx_done(input integer timeout_ns, output bit done_seen);
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
            #(T_BCHIP * 4);
        end
    endtask

    task automatic configure(input [3:0] mc, input [15:0] plen);
        integer length_us_eq;
        begin
            // Default LENGTH for Barker rates (cheap on-chip math the MCU
            // would mirror in software):
            //   1 Mbps : LENGTH = 8 * N
            //   2 Mbps : LENGTH = 4 * N
            // CCK rates set length_field/service_field/cck_symbol_count
            // directly via configure_cck before pulse_tx_enable.
            length_us_eq = (mc[1:0] == 2'b00) ? (plen << 3) :
                           (mc[1:0] == 2'b01) ? (plen << 2) : 0;
            @(posedge clk_mcu); #1;
            mod_config       = mc;
            payload_len      = plen;
            length_field     = length_us_eq[15:0];
            service_field    = 8'h00;
            cck_symbol_count = 16'd0;
        end
    endtask

    task automatic configure_cck(input [3:0]  mc,
                                 input [15:0] plen,
                                 input [15:0] sym_count,
                                 input [15:0] length_us_in,
                                 input [7:0]  service_in);
        begin
            @(posedge clk_mcu); #1;
            mod_config       = mc;
            payload_len      = plen;
            length_field     = length_us_in;
            service_field    = service_in;
            cck_symbol_count = sym_count;
        end
    endtask

    integer snap_chip, snap_sym, snap_done, snap_ur;

    task automatic snap_counters;
        begin
            snap_chip = chip_valid_cnt;
            snap_sym  = symbol_valid_cnt;
            snap_done = tx_done_cnt;
            snap_ur   = underrun_cnt;
        end
    endtask

    function integer delta_chip; begin delta_chip = chip_valid_cnt - snap_chip; end endfunction
    function integer delta_sym;  begin delta_sym  = symbol_valid_cnt - snap_sym; end endfunction
    function integer delta_done; begin delta_done = tx_done_cnt - snap_done; end endfunction
    function integer delta_ur;   begin delta_ur   = underrun_cnt - snap_ur; end endfunction

    localparam integer HDR_SYMS_A  = 128 + 16 + 32 + 16;
    localparam integer HDR_CHIPS_A = HDR_SYMS_A * 11;

    function integer chips_path_a(input bit rate_2mbps, input integer n);
        integer psdu;
        begin
            psdu = rate_2mbps ? ((8*n + 32) / 2) * 11
                              : (8*n + 32) * 11;
            chips_path_a = HDR_CHIPS_A + psdu;
        end
    endfunction

    task automatic run_path_a_test(input string name,
                                   input [3:0]  mc,
                                   input integer plen,
                                   input integer exp_chips);
        integer timeout_ns;
        bit     done_seen;
        begin
            current_test = name;
            $display("\n--- %s : mod_config=%b payload_len=%0d ---", name, mc, plen);
            do_reset;
            configure(mc, plen[15:0]);
            check_true("payload bytes fit in 16-deep FIFO", plen <= 16);
            write_bytes(plen, 8'hA0);
            snap_counters;
            pulse_tx_enable;
            timeout_ns = 3_000_000;
            wait_for_tx_done(timeout_ns, done_seen);
            check_true("tx_done pulsed once", done_seen);
            check_eq  ("tx_done pulse count", delta_done(), 1);
            check_eq  ("chip_valid pulses", delta_chip(), exp_chips);
            check_eq  ("symbol_valid remains low", delta_sym(), 0);
            check_eq  ("no underrun", delta_ur(), 0);
            check_true("invalid_mode clear", !invalid_mode);
            check_true("tx_busy returned low", !tx_busy);
            check_eq  ("symbol_out tied low", symbol_out, 0);
            check_true("symbol_valid pin low", !symbol_valid);
        end
    endtask

    // CCK directed test stub.  Streams `cck_sym_count` symbols of a stand-in
    // pre-encoded pattern (delta_phi1=0, c_k=0) through the FIFO and confirms
    // the chip drains the right number of FIFO bytes and emits the right
    // number of chips.  Bit-level golden-vector check is a TODO.
    task automatic run_cck_test(input string  name,
                                input [3:0]   mc,
                                input integer cck_sym_count_in,
                                input [15:0]  length_us_in,
                                input [7:0]   service_in);
        integer timeout_ns;
        integer i;
        integer exp_chips;
        bit     done_seen;
        localparam integer HDR_SYMS_A_LOC  = 128 + 16 + 32 + 16;
        localparam integer HDR_CHIPS_A_LOC = HDR_SYMS_A_LOC * 11;
        begin
            current_test = name;
            $display("\n--- %s : mod_config=%b cck_sym_count=%0d ---",
                     name, mc, cck_sym_count_in);
            do_reset;
            configure_cck(mc, 16'd0, cck_sym_count_in[15:0], length_us_in, service_in);

            // Push 4 bytes per CCK symbol.  Stub pattern: all zeros (i.e.
            // delta_phi1=0, c_k0..c_k7=0).  Replace with a golden pattern
            // generated from MATLAB wlanWaveformGenerator or equivalent.
            for (i = 0; i < 4 * cck_sym_count_in; i = i + 1) begin
                write_byte(8'h00);
            end

            snap_counters;
            pulse_tx_enable;
            timeout_ns = 5_000_000;
            wait_for_tx_done(timeout_ns, done_seen);

            exp_chips = HDR_CHIPS_A_LOC + 8 * cck_sym_count_in;

            check_true("tx_done pulsed once", done_seen);
            check_eq  ("tx_done pulse count", delta_done(), 1);
            check_eq  ("chip_valid pulses", delta_chip(), exp_chips);
            check_eq  ("symbol_valid remains low", delta_sym(), 0);
            check_eq  ("no underrun", delta_ur(), 0);
            check_true("invalid_mode clear", !invalid_mode);
            check_true("tx_busy returned low", !tx_busy);
        end
    endtask

`ifdef WAVES
    initial begin
        $dumpfile("tb_multi_mode_tx_baseband.vcd");
        $dumpvars(0, tb_multi_mode_tx_baseband);
    end
`endif

    initial begin
        $display("============================================================");
        $display(" tb_multi_mode_tx_baseband : Wi-Fi-only functional tests   ");
        $display("============================================================");

        begin : t_c1
            current_test = "T_C1 invalid mod_config";
            $display("\n--- %s ---", current_test);
            do_reset;
            configure(4'b0100, 16'd4);
            snap_counters;
            pulse_tx_enable;
            #(T_MCU * 10);
            check_true("0100 mode is rejected", invalid_mode);
            check_true("tx_busy stayed low", !tx_busy);
            check_eq  ("no tx_done pulse", delta_done(), 0);
            check_eq  ("no chip_valid pulses", delta_chip(), 0);
            check_eq  ("no symbol_valid pulses", delta_sym(), 0);
            check_eq  ("no underrun", delta_ur(), 0);

            configure(4'b1000, 16'd4);
            pulse_tx_enable;
            #(T_MCU * 10);
            check_true("1000 mode is rejected", invalid_mode);
            check_true("tx_busy stayed low", !tx_busy);
        end

        run_path_a_test("T_A1 1 Mbps DBPSK", 4'b0000, 4, chips_path_a(1'b0, 4));
        run_path_a_test("T_A2 2 Mbps DQPSK", 4'b0001, 4, chips_path_a(1'b1, 4));

        // CCK regression: 5.5 Mbps with a 2-symbol stub stream.  4 bytes per
        // symbol => 8 FIFO bytes total, comfortably inside the 16-byte FIFO.
        // length_us / service stub values match a 1-octet payload at 5.5 Mbps
        // (LENGTH = ceil(8*1/4) = 2 us, SERVICE = 0).
        run_cck_test("T_A3 5.5 Mbps CCK stub", 4'b0010, 2, 16'd2, 8'h00);

        // CCK regression: 11 Mbps, 2 symbols.
        run_cck_test("T_A4 11 Mbps CCK stub", 4'b0011, 2, 16'd2, 8'h00);

        begin : t_c2
            bit     done_seen;
            integer exp_chips_one;
            current_test = "T_C2 back-to-back DBPSK";
            $display("\n--- %s ---", current_test);
            do_reset;
            exp_chips_one = chips_path_a(1'b0, 4);
            configure(4'b0000, 16'd4);

            write_bytes(4, 8'hC0);
            snap_counters;
            pulse_tx_enable;
            wait_for_tx_done(3_000_000, done_seen);
            check_true("packet 1 tx_done seen", done_seen);
            check_eq  ("packet 1 chip count", delta_chip(), exp_chips_one);

            write_bytes(4, 8'hD0);
            snap_counters;
            pulse_tx_enable;
            wait_for_tx_done(3_000_000, done_seen);
            check_true("packet 2 tx_done seen", done_seen);
            check_eq  ("packet 2 chip count", delta_chip(), exp_chips_one);
            check_eq  ("no underrun across pair", underrun_cnt, 0);
            check_eq  ("total tx_done pulses == 2", tx_done_cnt, 2);
        end

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

    initial begin
        #(50_000_000);
        $display("\n[TB-FATAL] global simulation timeout; current_test=%s", current_test);
        $display("  tests run    : %0d", tests_run);
        $display("  tests passed : %0d", tests_pass);
        $display("  tests failed : %0d", tests_fail);
        $fatal(1, "global timeout");
    end

endmodule
