// =============================================================================
// tb_top_flat : end-to-end smoke test of the flattened top module.
//
// This is a trimmed version of tb_multi_mode_tx_baseband.sv aimed at
// confirming that the flattened single-file RTL compiles and functions at
// the top level.  It exercises:
//
//   T_A1  1 Mbps DBPSK   (Path A)                expected 2640 chip pulses
//   T_B1  QPSK           (Path B, 2 bits/sym)    expected (32 + 8*4 + 32)/2 = 48 syms
//   T_C1  Illegal mode   (Path A mod_config 111) -> invalid_mode latched
//
// Pass/fail on each check; final tally printed.
// =============================================================================
`timescale 1ns/1ps

module tb_top_flat;

    // Clocks
    localparam real T_BCHIP  = 90.9;   // 11 MHz
    localparam real T_CUSTOM = 10.0;   // 100 MHz
    localparam real T_MCU    = 20.0;   // 50 MHz

    reg clk_b_chip = 1'b0;
    reg clk_custom = 1'b0;
    reg clk_mcu    = 1'b0;
    reg rst_n      = 1'b0;

    always #(T_BCHIP  / 2.0) clk_b_chip = ~clk_b_chip;
    always #(T_CUSTOM / 2.0) clk_custom = ~clk_custom;
    always #(T_MCU    / 2.0) clk_mcu    = ~clk_mcu;

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
        .clk_b_chip(clk_b_chip), .clk_custom(clk_custom), .clk_mcu(clk_mcu),
        .rst_n(rst_n),
        .tx_enable(tx_enable), .mod_config(mod_config),
        .payload_len(payload_len), .length_us(length_us),
        .payload_in(payload_in), .payload_write(payload_write),
        .tx_busy(tx_busy), .fifo_full(fifo_full), .underrun(underrun),
        .invalid_mode(invalid_mode), .tx_done(tx_done),
        .symbol_out(symbol_out), .symbol_valid(symbol_valid),
        .chip_i(chip_i), .chip_q(chip_q), .chip_valid(chip_valid)
    );

    integer chip_valid_cnt   = 0;
    integer symbol_valid_cnt = 0;
    integer tx_done_cnt      = 0;
    integer underrun_cnt     = 0;

    always @(posedge clk_b_chip or negedge rst_n) begin
        if (!rst_n)             chip_valid_cnt   <= 0;
        else if (chip_valid)    chip_valid_cnt   <= chip_valid_cnt + 1;
    end
    always @(posedge clk_custom or negedge rst_n) begin
        if (!rst_n)             symbol_valid_cnt <= 0;
        else if (symbol_valid)  symbol_valid_cnt <= symbol_valid_cnt + 1;
    end
    always @(posedge clk_mcu or negedge rst_n) begin
        if (!rst_n) begin
            tx_done_cnt  <= 0;
            underrun_cnt <= 0;
        end else begin
            if (tx_done)  tx_done_cnt  <= tx_done_cnt  + 1;
            if (underrun) underrun_cnt <= underrun_cnt + 1;
        end
    end

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

    task automatic do_reset;
        begin
            rst_n         = 1'b0;
            tx_enable     = 1'b0;
            mod_config    = 4'd0;
            payload_len   = 16'd0;
            length_us     = 16'd0;
            payload_in    = 8'd0;
            payload_write = 1'b0;
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
            @(posedge clk_mcu); #1;
            payload_write = 1'b0;
        end
    endtask

    task automatic write_bytes(input integer n, input [7:0] seed);
        integer i;
        begin
            for (i = 0; i < n; i = i + 1) write_byte(seed + i[7:0]);
        end
    endtask

    task automatic configure(input [3:0] mc, input [15:0] plen, input [15:0] lus);
        begin
            @(posedge clk_mcu); #1;
            mod_config  = mc;
            payload_len = plen;
            length_us   = lus;
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

    integer snap_chip, snap_sym, snap_done, snap_ur;
    task automatic snap_counters;
        begin
            snap_chip = chip_valid_cnt;
            snap_sym  = symbol_valid_cnt;
            snap_done = tx_done_cnt;
            snap_ur   = underrun_cnt;
        end
    endtask

    task automatic wait_done(input integer timeout_ns, output bit done_seen);
        integer t_end;
        integer start_done;
        begin
            done_seen  = 1'b0;
            start_done = tx_done_cnt;
            t_end      = $time + timeout_ns;
            while ($time < t_end && !done_seen) begin
                @(posedge clk_mcu);
                if (tx_done_cnt != start_done) done_seen = 1'b1;
            end
            #(T_BCHIP * 4);
        end
    endtask

    initial begin
        bit done;
        $display("============================================================");
        $display(" tb_top_flat : end-to-end smoke test (flattened RTL)");
        $display("============================================================");

        // ---- T_A1 1 Mbps DBPSK, payload_len = 4 ----
        $display("\n--- T_A1 DBPSK 1 Mbps, payload=4 ---");
        do_reset();
        configure(4'b0000, 16'd4, 16'd0);
        write_bytes(4, 8'hA0);
        snap_counters();
        pulse_tx_enable();
        wait_done(3_000_000, done);
        chk    ("T_A1 tx_done pulsed", done);
        chk_eq ("T_A1 chip_valid count",  chip_valid_cnt   - snap_chip,
                2112 + (8*4+32)*11);        // 2816
        chk_eq ("T_A1 symbol_valid silent", symbol_valid_cnt - snap_sym, 0);
        chk_eq ("T_A1 no underrun",       underrun_cnt - snap_ur, 0);
        chk    ("T_A1 invalid_mode clear", !invalid_mode);

        // ---- T_B1 QPSK, payload_len = 4 ----
        $display("\n--- T_B1 QPSK, payload=4 ---");
        do_reset();
        configure(4'b1001, 16'd4, 16'd0);
        write_bytes(4, 8'hB0);
        snap_counters();
        pulse_tx_enable();
        wait_done(200_000, done);
        chk    ("T_B1 tx_done pulsed", done);
        // total bits = preamble(32) + payload(32) + fcs(32) = 96.  96/2 = 48 syms.
        chk_eq ("T_B1 symbol_valid count", symbol_valid_cnt - snap_sym, 48);
        chk_eq ("T_B1 chip_valid silent",  chip_valid_cnt   - snap_chip, 0);
        chk_eq ("T_B1 no underrun",        underrun_cnt     - snap_ur,   0);
        chk    ("T_B1 invalid_mode clear", !invalid_mode);

        // ---- T_C1 illegal mod_config 0111 ----
        $display("\n--- T_C1 illegal mod_config ---");
        do_reset();
        configure(4'b0111, 16'd4, 16'd0);
        snap_counters();
        pulse_tx_enable();
        #(T_MCU * 10);
        chk    ("T_C1 invalid_mode latched",      invalid_mode);
        chk    ("T_C1 tx_busy stayed low",       !tx_busy);
        chk_eq ("T_C1 no tx_done fired",         tx_done_cnt      - snap_done, 0);
        chk_eq ("T_C1 no chip_valid pulses",     chip_valid_cnt   - snap_chip, 0);
        chk_eq ("T_C1 no symbol_valid pulses",   symbol_valid_cnt - snap_sym,  0);

        $display("------------------------------------------------------------");
        $display(" total=%0d  failed=%0d  result=%s", total, fails,
                 (fails == 0) ? "*** PASS ***" : "*** FAIL ***");
        $display("============================================================");
        $finish;
    end

    initial begin
        #50_000_000;
        $display("[TB-FATAL] top_flat timeout");
        $fatal(1, "timeout");
    end

endmodule
