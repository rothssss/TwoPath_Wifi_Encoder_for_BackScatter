// =============================================================================
// multi_mode_tx_baseband : 802.11b backscatter TX baseband.
//
// Supported PSDU rates (all on chip_i / chip_q at 11 Mchip/s):
//   mod_config = 4'b0000 : 1   Mbps DBPSK + 11-chip Barker (chip computes)
//   mod_config = 4'b0001 : 2   Mbps DQPSK + 11-chip Barker (chip computes)
//   mod_config = 4'b0010 : 5.5 Mbps CCK   (MCU pre-computes; chip streams)
//   mod_config = 4'b0011 : 11  Mbps CCK   (MCU pre-computes; chip streams)
//
// All other mod_config values are illegal, refused at start, and latched
// into invalid_mode.
//
// MCU offload contract for CCK:
//   For mod_config = 4'b001x the MCU is responsible for self-synchronous
//   scrambling, CRC-32, 8-chip CCK encoding (incl. odd-symbol +pi and
//   chip-3/chip-6 hardwired +pi), the LENGTH and SERVICE field values, and
//   the cck_symbol_count for the PLCP PSDU+FCS region.  See
//   rtl/path_a/mac_fsm_80211b.v header for the per-symbol packing format
//   on the FIFO write port.
//
// Interface notes:
//   * length_field replaces the previously-deprecated length_us port and is
//     used at every rate (Barker rates set it to LENGTH = 8 * N_octets for
//     1 Mbps or 4 * N_octets for 2 Mbps).
//   * service_field is a per-packet 8-bit input, replacing the old
//     compile-time SERVICE_FIELD_A parameter.  This lets the MCU set
//     LENGTH_EXTENSION (bit 7) and LOCKED_CLOCKS (bit 2) per packet.
//   * cck_symbol_count is read only by CCK rates; it is ignored otherwise.
//   * clk_custom, symbol_out, and symbol_valid are still retained as ports
//     for wrapper-pinout stability and remain unused.
//   * The FIFO read side is always clk_b_chip.
// =============================================================================
module multi_mode_tx_baseband #(
    parameter integer PREAMBLE_SYNC_LEN_A = 128,
    parameter [15:0]  SFD_PATTERN_A       = 16'hF3A0,
    parameter [6:0]   SCRAMBLER_SEED_A    = 7'h6D,
    parameter [10:0]  BARKER_PATTERN      = 11'b10110111000,
    parameter integer FIFO_DEPTH          = 16,
    parameter integer FIFO_ADDR_W         = 4
) (
    input  wire        clk_b_chip,
    input  wire        clk_custom,
    input  wire        clk_mcu,
    input  wire        rst_n,

    input  wire        tx_enable,
    input  wire [3:0]  mod_config,
    input  wire [15:0] payload_len,
    input  wire [15:0] length_field,
    input  wire [7:0]  service_field,
    input  wire [15:0] cck_symbol_count,

    input  wire [7:0]  payload_in,
    input  wire        payload_write,

    output wire        tx_busy,
    output wire        fifo_full,
    output wire        underrun,
    output wire        invalid_mode,
    output wire        tx_done,

    output wire [7:0]  symbol_out,
    output wire        symbol_valid,
    output wire        chip_i,
    output wire        chip_q,
    output wire        chip_valid
);

    // =======================================================================
    // Reset synchronizers
    // =======================================================================
    wire rst_n_mcu_s;
    wire rst_n_b_chip_s;

    reset_sync u_rs_mcu   (.clk(clk_mcu),    .async_rst_n(rst_n), .sync_rst_n(rst_n_mcu_s));
    reset_sync u_rs_bchip (.clk(clk_b_chip), .async_rst_n(rst_n), .sync_rst_n(rst_n_b_chip_s));

    // =======================================================================
    // Mode decode
    //   Legal: 0000, 0001, 0010, 0011.
    // =======================================================================
    reg mod_valid_c;
    always @(*) begin
        mod_valid_c = (mod_config[3:2] == 2'b00);
    end
    wire       mod_valid = mod_valid_c;
    wire [1:0] rate_mode = mod_config[1:0];

    // =======================================================================
    // tx_enable edge detect in clk_mcu
    // =======================================================================
    reg tx_enable_q;
    always @(posedge clk_mcu or negedge rst_n_mcu_s) begin
        if (!rst_n_mcu_s) tx_enable_q <= 1'b0;
        else              tx_enable_q <= tx_enable;
    end
    wire tx_enable_pulse_mcu = tx_enable & ~tx_enable_q;

    // Sticky invalid-mode flag
    reg invalid_mode_r;
    always @(posedge clk_mcu or negedge rst_n_mcu_s) begin
        if (!rst_n_mcu_s)                           invalid_mode_r <= 1'b0;
        else if (tx_enable_pulse_mcu && !mod_valid) invalid_mode_r <= 1'b1;
    end
    assign invalid_mode = invalid_mode_r;

    // Legal starts only
    wire start_mcu_a = tx_enable_pulse_mcu & mod_valid;
    wire start_pulse_a;
    pulse_sync u_ps_a (
        .src_clk(clk_mcu),    .src_rst_n(rst_n_mcu_s),    .src_pulse(start_mcu_a),
        .dst_clk(clk_b_chip), .dst_rst_n(rst_n_b_chip_s), .dst_pulse(start_pulse_a)
    );

    // =======================================================================
    // Async FIFO (MCU -> clk_b_chip only)
    // =======================================================================
    wire       fifo_rd_en;
    wire       fifo_empty;
    wire [7:0] fifo_rd_data;

    async_fifo #(
        .DATA_W(8), .DEPTH(FIFO_DEPTH), .ADDR_W(FIFO_ADDR_W)
    ) u_fifo (
        .wclk   (clk_mcu),
        .wrst_n (rst_n_mcu_s),
        .wr_en  (payload_write),
        .wr_data(payload_in),
        .full   (fifo_full),
        .rclk   (clk_b_chip),
        .rrst_n (rst_n_b_chip_s),
        .rd_en  (fifo_rd_en),
        .rd_data(fifo_rd_data),
        .empty  (fifo_empty)
    );

    // =======================================================================
    // Path A only: 802.11b 1/2/5.5/11 Mbps Long PLCP + rotator
    // =======================================================================
    wire       a_fifo_rd_en;
    wire       a_busy;
    wire       a_done;
    wire       a_underrun;
    wire [1:0] a_base_phase;
    wire [1:0] a_delta_phi1;
    wire       a_update_phi1;
    wire       a_chip_valid_to_phy;
    wire       a_chip_i;
    wire       a_chip_q;
    wire       a_chip_valid_out;

    mac_fsm_80211b #(
        .PREAMBLE_SYNC_LEN(PREAMBLE_SYNC_LEN_A),
        .SFD_PATTERN     (SFD_PATTERN_A),
        .SCRAMBLER_SEED  (SCRAMBLER_SEED_A),
        .BARKER_PATTERN  (BARKER_PATTERN)
    ) u_mac_a (
        .clk             (clk_b_chip),
        .rst_n           (rst_n_b_chip_s),
        .start_pulse     (start_pulse_a),
        .rate_mode       (rate_mode),
        .payload_len     (payload_len),
        .length_field    (length_field),
        .service_field   (service_field),
        .cck_symbol_count(cck_symbol_count),
        .busy            (a_busy),
        .done_pulse      (a_done),
        .fifo_rd_en      (a_fifo_rd_en),
        .fifo_empty      (fifo_empty),
        .fifo_rd_data    (fifo_rd_data),
        .underrun_flag   (a_underrun),
        .base_phase      (a_base_phase),
        .delta_phi1      (a_delta_phi1),
        .update_phi1     (a_update_phi1),
        .chip_valid      (a_chip_valid_to_phy)
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

    assign fifo_rd_en   = a_fifo_rd_en;
    assign chip_i       = a_chip_i;
    assign chip_q       = a_chip_q;
    assign chip_valid   = a_chip_valid_out;
    assign symbol_out   = 8'd0;
    assign symbol_valid = 1'b0;

    // =======================================================================
    // tx_busy / tx_done / underrun back to clk_mcu
    // =======================================================================
    sync_2ff #(.WIDTH(1), .RESET_VAL(1'b0)) u_busy_sync (
        .clk(clk_mcu), .rst_n(rst_n_mcu_s),
        .d_in(a_busy), .d_out(tx_busy)
    );

    wire done_a_mcu;
    pulse_sync u_done_a (
        .src_clk(clk_b_chip), .src_rst_n(rst_n_b_chip_s), .src_pulse(a_done),
        .dst_clk(clk_mcu),    .dst_rst_n(rst_n_mcu_s),    .dst_pulse(done_a_mcu)
    );
    assign tx_done = done_a_mcu;

    wire a_ur_mcu;
    sync_2ff #(.WIDTH(1), .RESET_VAL(1'b0)) u_ur_a_sync (
        .clk(clk_mcu), .rst_n(rst_n_mcu_s),
        .d_in(a_underrun), .d_out(a_ur_mcu)
    );
    assign underrun = a_ur_mcu;

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
