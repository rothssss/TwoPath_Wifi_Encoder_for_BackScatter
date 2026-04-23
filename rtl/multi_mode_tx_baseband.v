// =============================================================================
// multi_mode_tx_baseband : top-level backscatter TX baseband (multi-rate).
//
// Two mutually-exclusive datapaths selected by `mod_config[3]`:
//
//   mod_config[3] = 0 : Path A -- 802.11b Long PLCP, full compliance.
//       mod_config[2:0]:
//         000 : 1 Mbps   DBPSK + Barker
//         001 : 2 Mbps   DQPSK + Barker
//         010 : 5.5 Mbps CCK (MCU-pre-encoded)
//         011 : 11  Mbps CCK (MCU-pre-encoded)
//         others : invalid (latched into `invalid_mode`, tx refused)
//       Chip outputs: chip_i, chip_q at 11 Mchip/s on clk_b_chip.
//
//   mod_config[3] = 1 : Path B -- custom QAM (unchanged from prior rev).
//       mod_config[2:0]:
//         000 : OOK
//         001 : QPSK
//         010 : 16-QAM
//         011 : 64-QAM
//         100 : 256-QAM
//         others : invalid
//       Chip output: symbol_out[7:0] at clk_custom rate.
//
// Integration notes (see design-docs/Multi-Mode_TX_Architecture.md):
//   * Path A MAC runs entirely on clk_b_chip (11 MHz).  The legacy 1 MHz
//     clk_b_data pin has been retired -- the 1 Mbps bit rate is derived
//     internally by a chip-within-symbol counter.
//   * For CCK rates the MCU pre-applies scrambler + FCS + CCK codeword
//     computation and streams 16-bit CCK symbol words (little-endian two
//     FIFO bytes each) of the form { c6, c5, c4, c3, c2, c1, c0,
//     delta_phi1 }.  The MCU must also supply `length_us` for the LENGTH
//     field because its computation for 5.5/11 Mbps requires division by
//     11 that would be expensive on chip.
//   * The chip provides the PLCP preamble + header (always 1 Mbps DBPSK
//     Long PLCP) for all four rates.  HEC is computed on chip.
//   * clock_mux_static is still a placeholder; swap for the foundry's
//     glitch-free clock mux before GDS.
// =============================================================================
module multi_mode_tx_baseband #(
    // ---- 802.11b (Path A) tunables ----------------------------------------
    parameter integer PREAMBLE_SYNC_LEN_A = 128,
    parameter [15:0]  SFD_PATTERN_A       = 16'hF3A0,
    parameter [7:0]   SERVICE_FIELD_A     = 8'h00,    // bit[2] optionally advertises locked clocks
    parameter [6:0]   SCRAMBLER_SEED_A    = 7'h6D,
    parameter [10:0]  BARKER_PATTERN      = 11'b10110111000,
    // ---- Custom (Path B) tunables -----------------------------------------
    parameter integer CUSTOM_PREAMBLE_LEN = 32,
    parameter [31:0]  CUSTOM_PREAMBLE_PAT = 32'hAAAAAAAA,
    parameter [6:0]   SCRAMBLER_SEED_B    = 7'h6D,
    // ---- FIFO ----
    parameter integer FIFO_DEPTH          = 32,
    parameter integer FIFO_ADDR_W         = 5
) (
    // Clocks & reset
    input  wire        clk_b_chip,   // 11 MHz, root clock for Path A
    input  wire        clk_custom,   // up to 100 MHz
    input  wire        clk_mcu,
    input  wire        rst_n,

    // Control from MCU
    input  wire        tx_enable,
    input  wire [3:0]  mod_config,
    input  wire [15:0] payload_len,
    input  wire [15:0] length_us,    // MCU-supplied LENGTH field value

    // Payload ingress
    input  wire [7:0]  payload_in,
    input  wire        payload_write,

    // Status to MCU
    output wire        tx_busy,
    output wire        fifo_full,
    output wire        underrun,
    output wire        invalid_mode,
    output wire        tx_done,

    // Symbol egress
    output wire [7:0]  symbol_out,   // Path B
    output wire        symbol_valid, // Path B
    output wire        chip_i,       // Path A (valid at 11 Mchip/s)
    output wire        chip_q,       // Path A
    output wire        chip_valid    // Path A
);

    // =======================================================================
    // Reset synchronizers (one per functional clock)
    // =======================================================================
    wire rst_n_mcu_s;
    wire rst_n_b_chip_s;
    wire rst_n_custom_s;

    reset_sync u_rs_mcu    (.clk(clk_mcu),    .async_rst_n(rst_n), .sync_rst_n(rst_n_mcu_s));
    reset_sync u_rs_bchip  (.clk(clk_b_chip), .async_rst_n(rst_n), .sync_rst_n(rst_n_b_chip_s));
    reset_sync u_rs_custom (.clk(clk_custom), .async_rst_n(rst_n), .sync_rst_n(rst_n_custom_s));

    // =======================================================================
    // Mode decoding
    //   path_a_sel = 1 if Path A 802.11b; else Path B custom.
    //   mod_valid  flags legal mod_config encodings.
    // =======================================================================
    wire path_a_sel = (mod_config[3] == 1'b0);
    reg  mod_valid_c;
    always @(*) begin
        if (path_a_sel)  mod_valid_c = (mod_config[2:0] <= 3'b011);  // 1/2/5.5/11 Mbps
        else             mod_valid_c = (mod_config[2:0] <= 3'b100);  // OOK/QPSK/16/64/256
    end
    wire mod_valid = mod_valid_c;

    // Rate for Path A: low 2 bits of mod_config.
    wire [1:0] path_a_rate = mod_config[1:0];

    // =======================================================================
    // tx_enable rising-edge detect (clk_mcu)
    // =======================================================================
    reg tx_enable_q;
    always @(posedge clk_mcu or negedge rst_n_mcu_s) begin
        if (!rst_n_mcu_s) tx_enable_q <= 1'b0;
        else              tx_enable_q <= tx_enable;
    end
    wire tx_enable_pulse_mcu = tx_enable & ~tx_enable_q;

    // Sticky invalid-mode flag (clk_mcu domain)
    reg invalid_mode_r;
    always @(posedge clk_mcu or negedge rst_n_mcu_s) begin
        if (!rst_n_mcu_s)                              invalid_mode_r <= 1'b0;
        else if (tx_enable_pulse_mcu && !mod_valid)    invalid_mode_r <= 1'b1;
    end
    assign invalid_mode = invalid_mode_r;

    // Hard-gated start pulses: refuse to dispatch on illegal mod_config.
    wire start_mcu_a = tx_enable_pulse_mcu &  path_a_sel & mod_valid;
    wire start_mcu_b = tx_enable_pulse_mcu & ~path_a_sel & mod_valid;

    wire start_pulse_a, start_pulse_b;
    pulse_sync u_ps_a (
        .src_clk(clk_mcu),    .src_rst_n(rst_n_mcu_s),   .src_pulse(start_mcu_a),
        .dst_clk(clk_b_chip), .dst_rst_n(rst_n_b_chip_s),.dst_pulse(start_pulse_a)
    );
    pulse_sync u_ps_b (
        .src_clk(clk_mcu),    .src_rst_n(rst_n_mcu_s),    .src_pulse(start_mcu_b),
        .dst_clk(clk_custom), .dst_rst_n(rst_n_custom_s), .dst_pulse(start_pulse_b)
    );

    // =======================================================================
    // Async input FIFO
    // =======================================================================
    wire rclk_fifo;
    clock_mux_static u_rclk_mux (
        .sel(~path_a_sel),
        .clk0(clk_b_chip),   // Path A now reads from FIFO at the chip clock.
        .clk1(clk_custom),
        .clk_out(rclk_fifo)
    );

    wire rrst_n_fifo = path_a_sel ? rst_n_b_chip_s : rst_n_custom_s;

    wire        fifo_rd_en;
    wire        fifo_empty;
    wire [7:0]  fifo_rd_data;

    async_fifo #(
        .DATA_W(8), .DEPTH(FIFO_DEPTH), .ADDR_W(FIFO_ADDR_W)
    ) u_fifo (
        .wclk(clk_mcu), .wrst_n(rst_n_mcu_s), .wr_en(payload_write),
        .wr_data(payload_in), .full(fifo_full),
        .rclk(rclk_fifo),     .rrst_n(rrst_n_fifo), .rd_en(fifo_rd_en),
        .rd_data(fifo_rd_data), .empty(fifo_empty)
    );

    // =======================================================================
    // Path A : 802.11b multi-rate MAC + rotator
    // =======================================================================
    wire        a_fifo_rd_en;
    wire        a_busy, a_done;
    wire        a_underrun;
    wire [1:0]  a_base_phase;
    wire [1:0]  a_delta_phi1;
    wire        a_update_phi1;
    wire        a_chip_valid_to_phy;
    wire        a_chip_i, a_chip_q, a_chip_valid_out;

    mac_fsm_80211b #(
        .PREAMBLE_SYNC_LEN(PREAMBLE_SYNC_LEN_A),
        .SFD_PATTERN     (SFD_PATTERN_A),
        .SERVICE_FIELD   (SERVICE_FIELD_A),
        .SCRAMBLER_SEED  (SCRAMBLER_SEED_A),
        .BARKER_PATTERN  (BARKER_PATTERN)
    ) u_mac_a (
        .clk          (clk_b_chip),
        .rst_n        (rst_n_b_chip_s),
        .start_pulse  (start_pulse_a),
        .rate         (path_a_rate),
        .payload_len  (payload_len),
        .length_us    (length_us),
        .busy         (a_busy),
        .done_pulse   (a_done),
        .fifo_rd_en   (a_fifo_rd_en),
        .fifo_empty   (fifo_empty),
        .fifo_rd_data (fifo_rd_data),
        .underrun_flag(a_underrun),
        .base_phase   (a_base_phase),
        .delta_phi1   (a_delta_phi1),
        .update_phi1  (a_update_phi1),
        .chip_valid   (a_chip_valid_to_phy)
    );

    phy_a_rotator u_phy_a (
        .clk        (clk_b_chip),
        .rst_n      (rst_n_b_chip_s),
        .start_pulse(start_pulse_a),
        .base_phase (a_base_phase),
        .delta_phi1 (a_delta_phi1),
        .update_phi1(a_update_phi1),
        .valid_chip (a_chip_valid_to_phy),
        .chip_i     (a_chip_i),
        .chip_q     (a_chip_q),
        .chip_valid (a_chip_valid_out)
    );

    // =======================================================================
    // Path B : Custom QAM (unchanged from prior revision)
    // =======================================================================
    wire b_fifo_rd_en;
    wire b_bit_valid, b_bit_out;
    wire b_busy, b_done, b_underrun;

    mac_fsm_custom #(
        .CUSTOM_PREAMBLE_LEN(CUSTOM_PREAMBLE_LEN),
        .CUSTOM_PREAMBLE_PAT(CUSTOM_PREAMBLE_PAT),
        .SCRAMBLER_SEED     (SCRAMBLER_SEED_B)
    ) u_mac_b (
        .clk          (clk_custom),
        .rst_n        (rst_n_custom_s),
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
        .rst_n               (rst_n_custom_s),
        .start_pulse         (start_pulse_b),
        .end_pulse           (b_done),
        .mod_config          (mod_config[2:0]),
        .bit_valid           (b_bit_valid),
        .bit_in              (b_bit_out),
        .invalid_mode        (b_invalid_mode),
        .path_b_symbol       (path_b_symbol),
        .path_b_symbol_valid (path_b_symbol_valid)
    );

    // =======================================================================
    // FIFO rd_en mux and output routing
    // =======================================================================
    assign fifo_rd_en = path_a_sel ? a_fifo_rd_en : b_fifo_rd_en;

    assign symbol_out   = path_b_symbol;
    assign symbol_valid = path_a_sel ? 1'b0 : path_b_symbol_valid;
    assign chip_i       = a_chip_i;
    assign chip_q       = a_chip_q;
    assign chip_valid   = path_a_sel ? a_chip_valid_out : 1'b0;

    // =======================================================================
    // tx_busy / tx_done / underrun back to clk_mcu
    // =======================================================================
    wire busy_any = path_a_sel ? a_busy : b_busy;
    sync_2ff #(.WIDTH(1), .RESET_VAL(1'b0)) u_busy_sync (
        .clk(clk_mcu), .rst_n(rst_n_mcu_s),
        .d_in(busy_any), .d_out(tx_busy)
    );

    wire done_a_mcu, done_b_mcu;
    pulse_sync u_done_a (
        .src_clk(clk_b_chip), .src_rst_n(rst_n_b_chip_s), .src_pulse(a_done),
        .dst_clk(clk_mcu),    .dst_rst_n(rst_n_mcu_s),    .dst_pulse(done_a_mcu)
    );
    pulse_sync u_done_b (
        .src_clk(clk_custom), .src_rst_n(rst_n_custom_s), .src_pulse(b_done),
        .dst_clk(clk_mcu),    .dst_rst_n(rst_n_mcu_s),    .dst_pulse(done_b_mcu)
    );
    assign tx_done = done_a_mcu | done_b_mcu;

    wire a_ur_mcu, b_ur_mcu;
    sync_2ff #(.WIDTH(1), .RESET_VAL(1'b0)) u_ur_a_sync (
        .clk(clk_mcu), .rst_n(rst_n_mcu_s),
        .d_in(a_underrun), .d_out(a_ur_mcu)
    );
    sync_2ff #(.WIDTH(1), .RESET_VAL(1'b0)) u_ur_b_sync (
        .clk(clk_mcu), .rst_n(rst_n_mcu_s),
        .d_in(b_underrun), .d_out(b_ur_mcu)
    );
    assign underrun = a_ur_mcu | b_ur_mcu;

    // Diagnostic-only signal kept live.
    wire _unused = &{1'b0, b_invalid_mode};

    // =======================================================================
    // SVA (sim-only).  Enable with +define+ASSERT_ON.
    // =======================================================================
`ifdef ASSERT_ON
    property p_mod_config_stable;
        @(posedge clk_mcu) disable iff (!rst_n_mcu_s)
            tx_busy |-> $stable(mod_config);
    endproperty
    a_mod_config_stable : assert property (p_mod_config_stable)
        else $error("mod_config changed while tx_busy was high");

    property p_payload_len_stable;
        @(posedge clk_mcu) disable iff (!rst_n_mcu_s)
            tx_busy |-> $stable(payload_len);
    endproperty
    a_payload_len_stable : assert property (p_payload_len_stable)
        else $error("payload_len changed while tx_busy was high");

    property p_length_us_stable;
        @(posedge clk_mcu) disable iff (!rst_n_mcu_s)
            tx_busy |-> $stable(length_us);
    endproperty
    a_length_us_stable : assert property (p_length_us_stable)
        else $error("length_us changed while tx_busy was high");

    property p_tx_enable_no_overlap;
        @(posedge clk_mcu) disable iff (!rst_n_mcu_s)
            (tx_enable & ~tx_enable_q) |-> !tx_busy;
    endproperty
    a_tx_enable_no_overlap : assert property (p_tx_enable_no_overlap)
        else $error("tx_enable rising edge while tx_busy still high");

    property p_invalid_mode_latched;
        @(posedge clk_mcu) disable iff (!rst_n_mcu_s)
            (tx_enable_pulse_mcu && !mod_valid) |-> ##[0:1] invalid_mode;
    endproperty
    a_invalid_mode_latched : assert property (p_invalid_mode_latched)
        else $error("illegal mod_config was not latched into invalid_mode");
`endif

endmodule
