// =============================================================================
// multi_mode_tx_baseband : top-level backscatter TX baseband.
//
// Implements the Micro-Architecture Specification "Multi-Mode Backscatter
// Baseband", supporting two mutually-exclusive datapaths:
//
//   Path A : 802.11b (mod_config == 3'b000), DSSS + DBPSK at 1 Mbps.
//   Path B : Custom variable QAM (mod_config > 3'b000), OOK / QPSK /
//            16-/64-/256-QAM up to 100 Mbaud.
//
// File organisation:
//   rtl/cdc/        synchronizers, pulse-sync, async FIFO
//   rtl/common/     CRC-32, scrambler, clock mux
//   rtl/path_a/     802.11b MAC, 1->11 MHz handshake, DSSS PHY
//   rtl/path_b/     Custom MAC, variable S2P PHY
//
// See design-docs/Wifi Doc *.md for the MAS this module implements.
// =============================================================================
module multi_mode_tx_baseband #(
    // ---- 802.11b (Path A) tunables ----------------------------------------
    parameter integer PREAMBLE_SYNC_LEN_A = 128,
    parameter integer HEADER_LEN_A        = 48,
    parameter [15:0]  SFD_PATTERN_A       = 16'hF3A0,
    parameter [47:0]  HEADER_CONST_A      = 48'h000000000000,
    parameter [6:0]   SCRAMBLER_SEED_A    = 7'h5D,
    parameter [10:0]  BARKER_PATTERN      = 11'b10110111000,
    parameter         RESET_DBPSK_PER_PACKET = 1,
    // ---- Custom (Path B) tunables -----------------------------------------
    parameter integer CUSTOM_PREAMBLE_LEN = 32,
    parameter [31:0]  CUSTOM_PREAMBLE_PAT = 32'hAAAAAAAA,
    parameter [6:0]   SCRAMBLER_SEED_B    = 7'h5D,
    // ---- FIFO ----
    parameter integer FIFO_DEPTH          = 32,
    parameter integer FIFO_ADDR_W         = 5
) (
    // Clocks & reset
    input  wire        clk_b_data,   // 1   MHz
    input  wire        clk_b_chip,   // 11  MHz, phase-aligned to clk_b_data
    input  wire        clk_custom,   // up to 100 MHz
    input  wire        clk_mcu,
    input  wire        rst_n,        // async active-low

    // Control from MCU
    input  wire        tx_enable,    // synchronous to clk_mcu; rising edge triggers
    input  wire [2:0]  mod_config,   // 000=802.11b, 001=OOK, 010=QPSK, 011=16QAM, 100=64QAM, 101=256QAM
    input  wire [15:0] payload_len,

    // Payload ingress
    input  wire [7:0]  payload_in,
    input  wire        payload_write,

    // Status to MCU
    output wire        tx_busy,
    output wire        fifo_full,

    // Symbol egress (to external analog decoder)
    output wire [7:0]  symbol_out,
    output wire        symbol_valid
);

    // =======================================================================
    // Path-select signal (static).  Expected to be stable before tx_enable.
    // =======================================================================
    wire path_a_sel = (mod_config == 3'b000);

    // =======================================================================
    // tx_enable rising-edge detect in clk_mcu domain -> pulse sync to
    // the active datapath's MAC clock.
    // =======================================================================
    reg tx_enable_q;
    always @(posedge clk_mcu or negedge rst_n) begin
        if (!rst_n) tx_enable_q <= 1'b0;
        else        tx_enable_q <= tx_enable;
    end
    wire tx_enable_pulse_mcu = tx_enable & ~tx_enable_q;

    wire start_pulse_a, start_pulse_b;
    pulse_sync u_ps_a (
        .src_clk   (clk_mcu),    .src_rst_n(rst_n), .src_pulse(tx_enable_pulse_mcu & path_a_sel),
        .dst_clk   (clk_b_data), .dst_rst_n(rst_n), .dst_pulse(start_pulse_a)
    );
    pulse_sync u_ps_b (
        .src_clk   (clk_mcu),   .src_rst_n(rst_n), .src_pulse(tx_enable_pulse_mcu & ~path_a_sel),
        .dst_clk   (clk_custom), .dst_rst_n(rst_n), .dst_pulse(start_pulse_b)
    );

    // =======================================================================
    // Async input FIFO (Block A).  Write port on clk_mcu.  Read port on
    // the selected datapath clock (clk_b_data or clk_custom).
    // =======================================================================
    wire rclk_fifo;
    clock_mux_static u_rclk_mux (
        .sel(~path_a_sel),            // 0 => clk_b_data, 1 => clk_custom
        .clk0(clk_b_data),
        .clk1(clk_custom),
        .clk_out(rclk_fifo)
    );

    wire        fifo_rd_en;
    wire        fifo_empty;
    wire [7:0]  fifo_rd_data;

    // NOTE (Q11): the FIFO read side uses the top-level `rst_n` directly.
    // This is safe because rst_n is async-assert (the whole chip is held in
    // reset synchronously by the power-on reset generator external to this
    // block) and the async FIFO's own internal sync logic uses gray-code
    // pointers that can tolerate async reset without corrupting the write
    // side.  If a production reset controller wants synchronous de-assertion
    // in the read-clock domain, replace with a proper rst-sync wrapper.
    async_fifo #(
        .DATA_W(8),
        .DEPTH (FIFO_DEPTH),
        .ADDR_W(FIFO_ADDR_W)
    ) u_fifo (
        .wclk   (clk_mcu),
        .wrst_n (rst_n),
        .wr_en  (payload_write),
        .wr_data(payload_in),
        .full   (fifo_full),

        .rclk   (rclk_fifo),
        .rrst_n (rst_n),
        .rd_en  (fifo_rd_en),
        .rd_data(fifo_rd_data),
        .empty  (fifo_empty)
    );

    // =======================================================================
    // Path A : 802.11b
    // =======================================================================
    wire        a_fifo_rd_en;
    wire        a_bit_valid_data;
    wire        a_bit_out_data;
    wire        a_busy_data, a_done_data;
    wire        a_underrun;

    mac_fsm_80211b #(
        .PREAMBLE_SYNC_LEN(PREAMBLE_SYNC_LEN_A),
        .HEADER_LEN       (HEADER_LEN_A),
        .SFD_PATTERN      (SFD_PATTERN_A),
        .HEADER_CONST     (HEADER_CONST_A),
        .SCRAMBLER_SEED   (SCRAMBLER_SEED_A)
    ) u_mac_a (
        .clk          (clk_b_data),
        .rst_n        (rst_n),
        .start_pulse  (start_pulse_a),
        .payload_len  (payload_len),
        .busy         (a_busy_data),
        .done_pulse   (a_done_data),
        .fifo_rd_en   (a_fifo_rd_en),
        .fifo_empty   (fifo_empty),
        .fifo_rd_data (fifo_rd_data),
        .underrun_flag(a_underrun),
        .bit_valid    (a_bit_valid_data),
        .bit_out      (a_bit_out_data)
    );

    wire        a_bit_in_chip;
    wire        a_bit_valid_chip;
    wire [3:0]  a_chip_cnt;
    wire        a_bit_window_start;

    bit_to_chip_handshake u_a_hs (
        .clk_b_chip      (clk_b_chip),
        .rst_n           (rst_n),
        .bit_in          (a_bit_out_data),
        .bit_valid_in    (a_bit_valid_data),
        .bit_in_chip     (a_bit_in_chip),
        .bit_valid_chip  (a_bit_valid_chip),
        .chip_cnt        (a_chip_cnt),
        .bit_window_start(a_bit_window_start)
    );

    wire [7:0] path_a_symbol;
    wire       path_a_symbol_valid;

    phy_dsss_80211b #(
        .BARKER_PATTERN        (BARKER_PATTERN),
        .RESET_DBPSK_PER_PACKET(RESET_DBPSK_PER_PACKET)
    ) u_phy_a (
        .clk_b_chip         (clk_b_chip),
        .rst_n              (rst_n),
        .bit_in_chip        (a_bit_in_chip),
        .bit_valid_chip     (a_bit_valid_chip),
        .chip_cnt           (a_chip_cnt),
        .bit_window_start   (a_bit_window_start),
        .path_a_symbol      (path_a_symbol),
        .path_a_symbol_valid(path_a_symbol_valid)
    );

    // =======================================================================
    // Path B : Custom QAM
    // =======================================================================
    wire b_fifo_rd_en;
    wire b_bit_valid, b_bit_out;
    wire b_busy, b_done;
    wire b_underrun;

    mac_fsm_custom #(
        .CUSTOM_PREAMBLE_LEN(CUSTOM_PREAMBLE_LEN),
        .CUSTOM_PREAMBLE_PAT(CUSTOM_PREAMBLE_PAT),
        .SCRAMBLER_SEED     (SCRAMBLER_SEED_B)
    ) u_mac_b (
        .clk          (clk_custom),
        .rst_n        (rst_n),
        .start_pulse  (start_pulse_b),
        .payload_len  (payload_len),
        .busy         (b_busy),
        .done_pulse   (b_done),
        .fifo_rd_en   (b_fifo_rd_en),
        .fifo_empty   (fifo_empty),
        .fifo_rd_data (fifo_rd_data),
        .underrun_flag(b_underrun),
        .bit_valid    (b_bit_valid),
        .bit_out      (b_bit_out)
    );

    wire [7:0] path_b_symbol;
    wire       path_b_symbol_valid;
    wire       b_invalid_mode;

    phy_qam_custom u_phy_b (
        .clk                 (clk_custom),
        .rst_n               (rst_n),
        .mod_config          (mod_config),
        .bit_valid           (b_bit_valid),
        .bit_in              (b_bit_out),
        .invalid_mode        (b_invalid_mode),
        .path_b_symbol       (path_b_symbol),
        .path_b_symbol_valid (path_b_symbol_valid)
    );

    // =======================================================================
    // FIFO rd_en multiplexing (in rclk domain, purely combinational).
    // =======================================================================
    assign fifo_rd_en = path_a_sel ? a_fifo_rd_en : b_fifo_rd_en;

    // =======================================================================
    // Output mux (Block D).  Symbol output comes from the active path's PHY
    // and is driven synchronous to that path's clock.  Downstream analog
    // must sample on the correct clock (the other one is gated off).
    // =======================================================================
    assign symbol_out   = path_a_sel ? path_a_symbol       : path_b_symbol;
    assign symbol_valid = path_a_sel ? path_a_symbol_valid : path_b_symbol_valid;

    // =======================================================================
    // tx_busy back to clk_mcu.  OR of the two paths (only one is ever
    // running) synchronised through 2FF into clk_mcu.
    // =======================================================================
    wire busy_any = (path_a_sel ? a_busy_data : b_busy);
    sync_2ff #(.WIDTH(1), .RESET_VAL(1'b0)) u_busy_sync (
        .clk(clk_mcu), .rst_n(rst_n),
        .d_in(busy_any),
        .d_out(tx_busy)
    );

    // -----------------------------------------------------------------------
    // Unused / diagnostic signals (kept live to avoid removal by synthesis
    // in case a top-level wants to observe them).
    // -----------------------------------------------------------------------
    wire _unused = &{1'b0, a_done_data, b_done, a_underrun, b_underrun,
                     b_invalid_mode, path_a_symbol_valid};

endmodule
