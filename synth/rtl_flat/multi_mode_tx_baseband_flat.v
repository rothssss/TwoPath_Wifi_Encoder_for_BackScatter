// =============================================================================
// multi_mode_tx_baseband_flat.v
//
// Single-module flattened top-level RTL for synthesis handoff / export.
// The helper instances from the original hierarchical design are inlined into
// the top module below. The hierarchical multi-module stitch-up is preserved in
// multi_mode_tx_baseband_flat_multimodule.v for module-level benches.
// =============================================================================
`timescale 1ns/1ps

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

function [7:0] multi_mode_tx_baseband__u_mac_a__signal_byte_for_rate;
        input [1:0] r;
        begin
            case (r)
                2'b00:   multi_mode_tx_baseband__u_mac_a__signal_byte_for_rate = 8'h0A; // 1   Mbps
                2'b01:   multi_mode_tx_baseband__u_mac_a__signal_byte_for_rate = 8'h14; // 2   Mbps
                2'b10:   multi_mode_tx_baseband__u_mac_a__signal_byte_for_rate = 8'h37; // 5.5 Mbps
                2'b11:   multi_mode_tx_baseband__u_mac_a__signal_byte_for_rate = 8'h6E; // 11  Mbps
                default: multi_mode_tx_baseband__u_mac_a__signal_byte_for_rate = 8'h0A;
            endcase
        end
    endfunction

    function multi_mode_tx_baseband__u_mac_a__scramble_bit_ss;
        input [6:0] state_in;
        input       raw_bit;
        begin
            multi_mode_tx_baseband__u_mac_a__scramble_bit_ss = raw_bit ^ state_in[6] ^ state_in[3];
        end
    endfunction


    function [1:0] multi_mode_tx_baseband__u_mac_a__dqpsk_delta_from_bits;
        input bit0;
        input bit1;
        begin
            case ({bit1, bit0})
                2'b00 : multi_mode_tx_baseband__u_mac_a__dqpsk_delta_from_bits = 2'd0;
                2'b10 : multi_mode_tx_baseband__u_mac_a__dqpsk_delta_from_bits = 2'd1;
                2'b11 : multi_mode_tx_baseband__u_mac_a__dqpsk_delta_from_bits = 2'd2;
                2'b01 : multi_mode_tx_baseband__u_mac_a__dqpsk_delta_from_bits = 2'd3;
                default: multi_mode_tx_baseband__u_mac_a__dqpsk_delta_from_bits = 2'd0;
            endcase
        end
    endfunction

// =======================================================================
    // Reset synchronizers
    // =======================================================================
    wire rst_n_mcu_s;
    wire rst_n_b_chip_s;
// ---------------------------------------------------------------------------
// Inlined reset_sync instance: multi_mode_tx_baseband__u_rs_mcu
// ---------------------------------------------------------------------------
reg multi_mode_tx_baseband__u_rs_mcu__meta_q;
    reg multi_mode_tx_baseband__u_rs_mcu__sync_q;

    always @(posedge clk_mcu or negedge rst_n) begin
        if (!rst_n) begin
            multi_mode_tx_baseband__u_rs_mcu__meta_q <= 1'b0;
            multi_mode_tx_baseband__u_rs_mcu__sync_q <= 1'b0;
        end else begin
            multi_mode_tx_baseband__u_rs_mcu__meta_q <= 1'b1;
            multi_mode_tx_baseband__u_rs_mcu__sync_q <= multi_mode_tx_baseband__u_rs_mcu__meta_q;
        end
    end

    assign rst_n_mcu_s = multi_mode_tx_baseband__u_rs_mcu__sync_q;
// ---------------------------------------------------------------------------
// Inlined reset_sync instance: multi_mode_tx_baseband__u_rs_bchip
// ---------------------------------------------------------------------------
reg multi_mode_tx_baseband__u_rs_bchip__meta_q;
    reg multi_mode_tx_baseband__u_rs_bchip__sync_q;

    always @(posedge clk_b_chip or negedge rst_n) begin
        if (!rst_n) begin
            multi_mode_tx_baseband__u_rs_bchip__meta_q <= 1'b0;
            multi_mode_tx_baseband__u_rs_bchip__sync_q <= 1'b0;
        end else begin
            multi_mode_tx_baseband__u_rs_bchip__meta_q <= 1'b1;
            multi_mode_tx_baseband__u_rs_bchip__sync_q <= multi_mode_tx_baseband__u_rs_bchip__meta_q;
        end
    end

    assign rst_n_b_chip_s = multi_mode_tx_baseband__u_rs_bchip__sync_q;

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
// ---------------------------------------------------------------------------
// Inlined pulse_sync instance: multi_mode_tx_baseband__u_ps_a
// ---------------------------------------------------------------------------
reg multi_mode_tx_baseband__u_ps_a__toggle_src;
    always @(posedge clk_mcu or negedge rst_n_mcu_s) begin
        if (!rst_n_mcu_s)      multi_mode_tx_baseband__u_ps_a__toggle_src <= 1'b0;
        else if (start_mcu_a)  multi_mode_tx_baseband__u_ps_a__toggle_src <= ~multi_mode_tx_baseband__u_ps_a__toggle_src;
    end

    wire multi_mode_tx_baseband__u_ps_a__toggle_dst;
// ---------------------------------------------------------------------------
// Inlined sync_2ff instance: multi_mode_tx_baseband__u_ps_a__u_sync
// ---------------------------------------------------------------------------
reg [1-1:0] multi_mode_tx_baseband__u_ps_a__u_sync__meta_q;
    reg [1-1:0] multi_mode_tx_baseband__u_ps_a__u_sync__sync_q;

    always @(posedge clk_b_chip or negedge rst_n_b_chip_s) begin
        if (!rst_n_b_chip_s) begin
            multi_mode_tx_baseband__u_ps_a__u_sync__meta_q <= {1{1'b0}};
            multi_mode_tx_baseband__u_ps_a__u_sync__sync_q <= {1{1'b0}};
        end else begin
            multi_mode_tx_baseband__u_ps_a__u_sync__meta_q <= multi_mode_tx_baseband__u_ps_a__toggle_src;
            multi_mode_tx_baseband__u_ps_a__u_sync__sync_q <= multi_mode_tx_baseband__u_ps_a__u_sync__meta_q;
        end
    end

    assign multi_mode_tx_baseband__u_ps_a__toggle_dst = multi_mode_tx_baseband__u_ps_a__u_sync__sync_q;

    reg multi_mode_tx_baseband__u_ps_a__toggle_dst_q;
    always @(posedge clk_b_chip or negedge rst_n_b_chip_s) begin
        if (!rst_n_b_chip_s) multi_mode_tx_baseband__u_ps_a__toggle_dst_q <= 1'b0;
        else            multi_mode_tx_baseband__u_ps_a__toggle_dst_q <= multi_mode_tx_baseband__u_ps_a__toggle_dst;
    end

    assign start_pulse_a = multi_mode_tx_baseband__u_ps_a__toggle_dst ^ multi_mode_tx_baseband__u_ps_a__toggle_dst_q;

    // =======================================================================
    // Async FIFO (MCU -> clk_b_chip only)
    // =======================================================================
    wire       fifo_rd_en;
    wire       fifo_empty;
    wire [7:0] fifo_rd_data;
// ---------------------------------------------------------------------------
// Inlined async_fifo instance: multi_mode_tx_baseband__u_fifo
// ---------------------------------------------------------------------------
// ---- Memory (inferred RAM) ------------------------------------------
    reg [8-1:0] multi_mode_tx_baseband__u_fifo__mem [0:FIFO_DEPTH-1];

    // ---- Write domain ----------------------------------------------------
    reg  [FIFO_ADDR_W:0] multi_mode_tx_baseband__u_fifo__wptr_bin;
    reg  [FIFO_ADDR_W:0] multi_mode_tx_baseband__u_fifo__wptr_gray;
    wire [FIFO_ADDR_W:0] multi_mode_tx_baseband__u_fifo__wptr_bin_next  = multi_mode_tx_baseband__u_fifo__wptr_bin + {{FIFO_ADDR_W{1'b0}}, (payload_write & ~fifo_full)};
    wire [FIFO_ADDR_W:0] multi_mode_tx_baseband__u_fifo__wptr_gray_next = (multi_mode_tx_baseband__u_fifo__wptr_bin_next >> 1) ^ multi_mode_tx_baseband__u_fifo__wptr_bin_next;

    always @(posedge clk_mcu or negedge rst_n_mcu_s) begin
        if (!rst_n_mcu_s) begin
            multi_mode_tx_baseband__u_fifo__wptr_bin  <= {FIFO_ADDR_W+1{1'b0}};
            multi_mode_tx_baseband__u_fifo__wptr_gray <= {FIFO_ADDR_W+1{1'b0}};
        end else begin
            multi_mode_tx_baseband__u_fifo__wptr_bin  <= multi_mode_tx_baseband__u_fifo__wptr_bin_next;
            multi_mode_tx_baseband__u_fifo__wptr_gray <= multi_mode_tx_baseband__u_fifo__wptr_gray_next;
        end
    end

    always @(posedge clk_mcu) begin
        if (payload_write && !fifo_full) multi_mode_tx_baseband__u_fifo__mem[multi_mode_tx_baseband__u_fifo__wptr_bin[FIFO_ADDR_W-1:0]] <= payload_in;
    end

    // ---- Read domain -----------------------------------------------------
    // Declare the read-domain pointer regs up front so the r2w synchronizer
    // below can reference `multi_mode_tx_baseband__u_fifo__rptr_gray` without creating an implicit wire
    // (strict LRM; Xcelium rejects the later reg redeclaration).
    reg  [FIFO_ADDR_W:0] multi_mode_tx_baseband__u_fifo__rptr_bin;
    reg  [FIFO_ADDR_W:0] multi_mode_tx_baseband__u_fifo__rptr_gray;
    wire [FIFO_ADDR_W:0] multi_mode_tx_baseband__u_fifo__rptr_bin_next  = multi_mode_tx_baseband__u_fifo__rptr_bin + {{FIFO_ADDR_W{1'b0}}, (fifo_rd_en & ~fifo_empty)};
    wire [FIFO_ADDR_W:0] multi_mode_tx_baseband__u_fifo__rptr_gray_next = (multi_mode_tx_baseband__u_fifo__rptr_bin_next >> 1) ^ multi_mode_tx_baseband__u_fifo__rptr_bin_next;

    // Sync read-pointer (gray) into write domain
    wire [FIFO_ADDR_W:0] multi_mode_tx_baseband__u_fifo__rptr_gray_at_w;
// ---------------------------------------------------------------------------
// Inlined sync_2ff instance: multi_mode_tx_baseband__u_fifo__u_sync_r2w
// ---------------------------------------------------------------------------
reg [FIFO_ADDR_W+1-1:0] multi_mode_tx_baseband__u_fifo__u_sync_r2w__meta_q;
    reg [FIFO_ADDR_W+1-1:0] multi_mode_tx_baseband__u_fifo__u_sync_r2w__sync_q;

    always @(posedge clk_mcu or negedge rst_n_mcu_s) begin
        if (!rst_n_mcu_s) begin
            multi_mode_tx_baseband__u_fifo__u_sync_r2w__meta_q <= {FIFO_ADDR_W+1{1'b0}};
            multi_mode_tx_baseband__u_fifo__u_sync_r2w__sync_q <= {FIFO_ADDR_W+1{1'b0}};
        end else begin
            multi_mode_tx_baseband__u_fifo__u_sync_r2w__meta_q <= multi_mode_tx_baseband__u_fifo__rptr_gray;
            multi_mode_tx_baseband__u_fifo__u_sync_r2w__sync_q <= multi_mode_tx_baseband__u_fifo__u_sync_r2w__meta_q;
        end
    end

    assign multi_mode_tx_baseband__u_fifo__rptr_gray_at_w = multi_mode_tx_baseband__u_fifo__u_sync_r2w__sync_q;

    // Full when multi_mode_tx_baseband__u_fifo__wptr_gray equals read-pointer-gray with the upper two bits
    // inverted (classic Cummings async-FIFO formulation).
    assign fifo_full = (multi_mode_tx_baseband__u_fifo__wptr_gray == {~multi_mode_tx_baseband__u_fifo__rptr_gray_at_w[FIFO_ADDR_W:FIFO_ADDR_W-1],
                                  multi_mode_tx_baseband__u_fifo__rptr_gray_at_w[FIFO_ADDR_W-2:0]});

    always @(posedge clk_b_chip or negedge rst_n_b_chip_s) begin
        if (!rst_n_b_chip_s) begin
            multi_mode_tx_baseband__u_fifo__rptr_bin  <= {FIFO_ADDR_W+1{1'b0}};
            multi_mode_tx_baseband__u_fifo__rptr_gray <= {FIFO_ADDR_W+1{1'b0}};
        end else begin
            multi_mode_tx_baseband__u_fifo__rptr_bin  <= multi_mode_tx_baseband__u_fifo__rptr_bin_next;
            multi_mode_tx_baseband__u_fifo__rptr_gray <= multi_mode_tx_baseband__u_fifo__rptr_gray_next;
        end
    end

    // Sync write-pointer (gray) into read domain
    wire [FIFO_ADDR_W:0] multi_mode_tx_baseband__u_fifo__wptr_gray_at_r;
// ---------------------------------------------------------------------------
// Inlined sync_2ff instance: multi_mode_tx_baseband__u_fifo__u_sync_w2r
// ---------------------------------------------------------------------------
reg [FIFO_ADDR_W+1-1:0] multi_mode_tx_baseband__u_fifo__u_sync_w2r__meta_q;
    reg [FIFO_ADDR_W+1-1:0] multi_mode_tx_baseband__u_fifo__u_sync_w2r__sync_q;

    always @(posedge clk_b_chip or negedge rst_n_b_chip_s) begin
        if (!rst_n_b_chip_s) begin
            multi_mode_tx_baseband__u_fifo__u_sync_w2r__meta_q <= {FIFO_ADDR_W+1{1'b0}};
            multi_mode_tx_baseband__u_fifo__u_sync_w2r__sync_q <= {FIFO_ADDR_W+1{1'b0}};
        end else begin
            multi_mode_tx_baseband__u_fifo__u_sync_w2r__meta_q <= multi_mode_tx_baseband__u_fifo__wptr_gray;
            multi_mode_tx_baseband__u_fifo__u_sync_w2r__sync_q <= multi_mode_tx_baseband__u_fifo__u_sync_w2r__meta_q;
        end
    end

    assign multi_mode_tx_baseband__u_fifo__wptr_gray_at_r = multi_mode_tx_baseband__u_fifo__u_sync_w2r__sync_q;

    assign fifo_empty = (multi_mode_tx_baseband__u_fifo__rptr_gray == multi_mode_tx_baseband__u_fifo__wptr_gray_at_r);

    // Read data is combinational from memory at the current read address.
    // Downstream should register it if synchronous read is desired.
    assign fifo_rd_data = multi_mode_tx_baseband__u_fifo__mem[multi_mode_tx_baseband__u_fifo__rptr_bin[FIFO_ADDR_W-1:0]];

    // =======================================================================
    // Path A only: 802.11b 1/2/5.5/11 Mbps Long PLCP + rotator
    // =======================================================================
    reg         a_fifo_rd_en;
    reg         a_busy;
    reg         a_done;
    reg         a_underrun;
    reg  [1:0]  a_base_phase;
    reg  [1:0]  a_delta_phi1;
    reg         a_update_phi1;
    reg         a_chip_valid_to_phy;
    reg         a_chip_i;
    reg         a_chip_q;
    reg         a_chip_valid_out;
// ---------------------------------------------------------------------------
// Inlined mac_fsm_80211b instance: multi_mode_tx_baseband__u_mac_a
// ---------------------------------------------------------------------------
localparam [3:0]
        multi_mode_tx_baseband__u_mac_a__S_IDLE        = 4'd0,
        multi_mode_tx_baseband__u_mac_a__S_SYNC        = 4'd1,
        multi_mode_tx_baseband__u_mac_a__S_SFD         = 4'd2,
        multi_mode_tx_baseband__u_mac_a__S_HEAD        = 4'd3,
        multi_mode_tx_baseband__u_mac_a__S_HEC         = 4'd4,
        multi_mode_tx_baseband__u_mac_a__S_PSDU_BARKER = 4'd5,
        multi_mode_tx_baseband__u_mac_a__S_FCS_BARKER  = 4'd6,
        multi_mode_tx_baseband__u_mac_a__S_PSDU_CCK    = 4'd7,
        multi_mode_tx_baseband__u_mac_a__S_DONE        = 4'd8;

    reg [3:0] multi_mode_tx_baseband__u_mac_a__state, multi_mode_tx_baseband__u_mac_a__state_next;
    reg [1:0] multi_mode_tx_baseband__u_mac_a__rate_mode_q;
    wire      multi_mode_tx_baseband__u_mac_a__cck_active = multi_mode_tx_baseband__u_mac_a__rate_mode_q[1];

    reg  [3:0] multi_mode_tx_baseband__u_mac_a__chip_cnt;
    wire [3:0] multi_mode_tx_baseband__u_mac_a__chip_max     = (multi_mode_tx_baseband__u_mac_a__state == multi_mode_tx_baseband__u_mac_a__S_PSDU_CCK) ? 4'd7 : 4'd10;
    wire       multi_mode_tx_baseband__u_mac_a__symbol_start = (multi_mode_tx_baseband__u_mac_a__chip_cnt == 4'd0);
    wire       multi_mode_tx_baseband__u_mac_a__symbol_end   = (multi_mode_tx_baseband__u_mac_a__chip_cnt == multi_mode_tx_baseband__u_mac_a__chip_max);

    reg  [15:0] multi_mode_tx_baseband__u_mac_a__payload_len_q;
    reg  [15:0] multi_mode_tx_baseband__u_mac_a__cck_sym_count_q;
    reg  [7:0]  multi_mode_tx_baseband__u_mac_a__sym_cnt;
    reg  [15:0] multi_mode_tx_baseband__u_mac_a__byte_cnt;
    reg  [15:0] multi_mode_tx_baseband__u_mac_a__cck_sym_cnt;
    reg  [2:0]  multi_mode_tx_baseband__u_mac_a__bit_in_byte;

    reg  [7:0]  multi_mode_tx_baseband__u_mac_a__byte_sr;
    reg  [31:0] multi_mode_tx_baseband__u_mac_a__header_sr;
    reg  [15:0] multi_mode_tx_baseband__u_mac_a__sfd_sr;
    reg  [15:0] multi_mode_tx_baseband__u_mac_a__hec_sr;
    reg  [31:0] multi_mode_tx_baseband__u_mac_a__fcs_sr;

    // CCK symbol streamer: multi_mode_tx_baseband__u_mac_a__cck_word_curr feeds the 8 chips of the symbol
    // currently emitting; multi_mode_tx_baseband__u_mac_a__cck_word_next buffers the next symbol's 4 bytes
    // while the current symbol is still on the wire.
    reg  [31:0] multi_mode_tx_baseband__u_mac_a__cck_word_curr;
    reg  [31:0] multi_mode_tx_baseband__u_mac_a__cck_word_next;

    reg         multi_mode_tx_baseband__u_mac_a__crc_init;

    reg         multi_mode_tx_baseband__u_mac_a__raw_bit_c;
    reg         multi_mode_tx_baseband__u_mac_a__raw_bit2_c;
    reg         multi_mode_tx_baseband__u_mac_a__scramble_c;
    reg         multi_mode_tx_baseband__u_mac_a__two_bit_sym_c;
    reg         multi_mode_tx_baseband__u_mac_a__feed_hec_c;
    reg         multi_mode_tx_baseband__u_mac_a__feed_fcs_c;
    reg         multi_mode_tx_baseband__u_mac_a__emit_chip_c;

    wire [15:0] multi_mode_tx_baseband__u_mac_a__hec_out;
    wire [31:0] multi_mode_tx_baseband__u_mac_a__fcs_out;

    wire [15:0] multi_mode_tx_baseband__u_mac_a__hec_source = (multi_mode_tx_baseband__u_mac_a__state == multi_mode_tx_baseband__u_mac_a__S_HEC        && multi_mode_tx_baseband__u_mac_a__sym_cnt == 8'd0) ? multi_mode_tx_baseband__u_mac_a__hec_out : multi_mode_tx_baseband__u_mac_a__hec_sr;
    wire [31:0] multi_mode_tx_baseband__u_mac_a__fcs_source = (multi_mode_tx_baseband__u_mac_a__state == multi_mode_tx_baseband__u_mac_a__S_FCS_BARKER && multi_mode_tx_baseband__u_mac_a__sym_cnt == 8'd0) ? multi_mode_tx_baseband__u_mac_a__fcs_out : multi_mode_tx_baseband__u_mac_a__fcs_sr;

    always @(*) begin
        multi_mode_tx_baseband__u_mac_a__raw_bit_c     = 1'b0;
        multi_mode_tx_baseband__u_mac_a__raw_bit2_c    = 1'b0;
        multi_mode_tx_baseband__u_mac_a__scramble_c    = 1'b0;
        multi_mode_tx_baseband__u_mac_a__two_bit_sym_c = 1'b0;
        multi_mode_tx_baseband__u_mac_a__feed_hec_c    = 1'b0;
        multi_mode_tx_baseband__u_mac_a__feed_fcs_c    = 1'b0;
        multi_mode_tx_baseband__u_mac_a__emit_chip_c   = 1'b0;

        case (multi_mode_tx_baseband__u_mac_a__state)
            multi_mode_tx_baseband__u_mac_a__S_SYNC: begin
                multi_mode_tx_baseband__u_mac_a__raw_bit_c   = 1'b1;
                multi_mode_tx_baseband__u_mac_a__scramble_c  = 1'b1;
                multi_mode_tx_baseband__u_mac_a__emit_chip_c = 1'b1;
            end
            multi_mode_tx_baseband__u_mac_a__S_SFD: begin
                multi_mode_tx_baseband__u_mac_a__raw_bit_c   = multi_mode_tx_baseband__u_mac_a__sfd_sr[15];
                multi_mode_tx_baseband__u_mac_a__scramble_c  = 1'b1;
                multi_mode_tx_baseband__u_mac_a__emit_chip_c = 1'b1;
            end
            multi_mode_tx_baseband__u_mac_a__S_HEAD: begin
                multi_mode_tx_baseband__u_mac_a__raw_bit_c   = multi_mode_tx_baseband__u_mac_a__header_sr[0];
                multi_mode_tx_baseband__u_mac_a__scramble_c  = 1'b1;
                multi_mode_tx_baseband__u_mac_a__feed_hec_c  = 1'b1;
                multi_mode_tx_baseband__u_mac_a__emit_chip_c = 1'b1;
            end
            multi_mode_tx_baseband__u_mac_a__S_HEC: begin
                multi_mode_tx_baseband__u_mac_a__raw_bit_c   = multi_mode_tx_baseband__u_mac_a__hec_source[15];
                multi_mode_tx_baseband__u_mac_a__scramble_c  = 1'b1;
                multi_mode_tx_baseband__u_mac_a__emit_chip_c = 1'b1;
            end
            multi_mode_tx_baseband__u_mac_a__S_PSDU_BARKER: begin
                multi_mode_tx_baseband__u_mac_a__raw_bit_c     = multi_mode_tx_baseband__u_mac_a__byte_sr[0];
                multi_mode_tx_baseband__u_mac_a__raw_bit2_c    = multi_mode_tx_baseband__u_mac_a__byte_sr[1];
                multi_mode_tx_baseband__u_mac_a__scramble_c    = 1'b1;
                multi_mode_tx_baseband__u_mac_a__two_bit_sym_c = multi_mode_tx_baseband__u_mac_a__rate_mode_q[0];
                multi_mode_tx_baseband__u_mac_a__feed_fcs_c    = 1'b1;
                multi_mode_tx_baseband__u_mac_a__emit_chip_c   = 1'b1;
            end
            multi_mode_tx_baseband__u_mac_a__S_FCS_BARKER: begin
                multi_mode_tx_baseband__u_mac_a__raw_bit_c     = multi_mode_tx_baseband__u_mac_a__fcs_source[0];
                multi_mode_tx_baseband__u_mac_a__raw_bit2_c    = multi_mode_tx_baseband__u_mac_a__fcs_source[1];
                multi_mode_tx_baseband__u_mac_a__scramble_c    = 1'b1;
                multi_mode_tx_baseband__u_mac_a__two_bit_sym_c = multi_mode_tx_baseband__u_mac_a__rate_mode_q[0];
                multi_mode_tx_baseband__u_mac_a__emit_chip_c   = 1'b1;
            end
            multi_mode_tx_baseband__u_mac_a__S_PSDU_CCK: begin
                // Chip pattern is replayed straight from multi_mode_tx_baseband__u_mac_a__cck_word_curr; no
                // chip-side scrambler / Barker / CRC engagement.
                multi_mode_tx_baseband__u_mac_a__emit_chip_c   = 1'b1;
            end
            default: ;
        endcase
    end

    // ------------------------------------------------------------------
    // Self-synchronous scrambler (Barker rates only)
    // ------------------------------------------------------------------
    reg  [6:0] multi_mode_tx_baseband__u_mac_a__lfsr;
function [6:0] multi_mode_tx_baseband__u_mac_a__scramble_state_ss;
        input [6:0] state_in;
        input       raw_bit;
        reg         multi_mode_tx_baseband__u_mac_a__scrambled;
        begin
            multi_mode_tx_baseband__u_mac_a__scrambled = multi_mode_tx_baseband__u_mac_a__scramble_bit_ss(state_in, raw_bit);
            multi_mode_tx_baseband__u_mac_a__scramble_state_ss = {multi_mode_tx_baseband__u_mac_a__scrambled, state_in[6:1]};
        end
    endfunction

    wire       multi_mode_tx_baseband__u_mac_a__s0            = multi_mode_tx_baseband__u_mac_a__scramble_bit_ss(multi_mode_tx_baseband__u_mac_a__lfsr, multi_mode_tx_baseband__u_mac_a__raw_bit_c);
    wire [6:0] multi_mode_tx_baseband__u_mac_a__lfsr_advance1 = multi_mode_tx_baseband__u_mac_a__scramble_state_ss(multi_mode_tx_baseband__u_mac_a__lfsr, multi_mode_tx_baseband__u_mac_a__raw_bit_c);
    wire       multi_mode_tx_baseband__u_mac_a__s1            = multi_mode_tx_baseband__u_mac_a__scramble_bit_ss(multi_mode_tx_baseband__u_mac_a__lfsr_advance1, multi_mode_tx_baseband__u_mac_a__raw_bit2_c);
    wire [6:0] multi_mode_tx_baseband__u_mac_a__lfsr_advance2 = multi_mode_tx_baseband__u_mac_a__scramble_state_ss(multi_mode_tx_baseband__u_mac_a__lfsr_advance1, multi_mode_tx_baseband__u_mac_a__raw_bit2_c);
wire [1:0] multi_mode_tx_baseband__u_mac_a__delta_phi1_barker =
        multi_mode_tx_baseband__u_mac_a__two_bit_sym_c ? multi_mode_tx_baseband__u_mac_a__dqpsk_delta_from_bits(multi_mode_tx_baseband__u_mac_a__s0, multi_mode_tx_baseband__u_mac_a__s1) : {multi_mode_tx_baseband__u_mac_a__s0, 1'b0};

    wire multi_mode_tx_baseband__u_mac_a__barker_chip_bit       = BARKER_PATTERN[10 - multi_mode_tx_baseband__u_mac_a__chip_cnt[3:0]];
    wire [1:0] multi_mode_tx_baseband__u_mac_a__base_phase_barker = multi_mode_tx_baseband__u_mac_a__barker_chip_bit ? 2'b00 : 2'b10;

    // CCK chip-phase mux: pick c_k[multi_mode_tx_baseband__u_mac_a__chip_cnt] from multi_mode_tx_baseband__u_mac_a__cck_word_curr.
    // Layout (LSB-first): [delta=1:0][c0=3:2][c1=5:4]...[c7=17:16].
    // Indexed part-select keeps this one expression and avoids the
    // always_comb / case event-ordering ambiguity the earlier version had.
    wire [1:0] multi_mode_tx_baseband__u_mac_a__cck_chip_phase = multi_mode_tx_baseband__u_mac_a__cck_word_curr[2 + (multi_mode_tx_baseband__u_mac_a__chip_cnt[2:0] << 1) +: 2];
    wire [1:0] multi_mode_tx_baseband__u_mac_a__cck_delta_phi1 = multi_mode_tx_baseband__u_mac_a__cck_word_curr[1:0];

    // -----------------------------------------------------------------------
    // Combinational FIFO read-enable.
    //
    // a_fifo_rd_en MUST be combinational so the async FWFT FIFO can advance
    // its rptr on the SAME edge the MAC captures the byte, not a cycle
    // later.  When a_fifo_rd_en was driven NBA inside the seq always, the
    // FIFO saw the request one cycle late and CCK's 4-consecutive-cycle
    // prefetch ended up reading byte 0 twice and dropping byte 3.
    // -----------------------------------------------------------------------
    wire multi_mode_tx_baseband__u_mac_a__cck_active_in = multi_mode_tx_baseband__u_mac_a__rate_mode_q[1];

    wire multi_mode_tx_baseband__u_mac_a__fifo_rd_en_barker_hec_end =
        (multi_mode_tx_baseband__u_mac_a__state == multi_mode_tx_baseband__u_mac_a__S_HEC) && !multi_mode_tx_baseband__u_mac_a__cck_active_in &&
        (multi_mode_tx_baseband__u_mac_a__sym_cnt == 8'd15) && multi_mode_tx_baseband__u_mac_a__symbol_end &&
        (multi_mode_tx_baseband__u_mac_a__payload_len_q != 16'd0) && (multi_mode_tx_baseband__u_mac_a__payload_len_q > 16'd1);

    wire multi_mode_tx_baseband__u_mac_a__fifo_rd_en_barker_psdu =
        (multi_mode_tx_baseband__u_mac_a__state == multi_mode_tx_baseband__u_mac_a__S_PSDU_BARKER) && multi_mode_tx_baseband__u_mac_a__symbol_end &&
        (((!multi_mode_tx_baseband__u_mac_a__rate_mode_q[0]) && (multi_mode_tx_baseband__u_mac_a__bit_in_byte == 3'd7)) ||
         (( multi_mode_tx_baseband__u_mac_a__rate_mode_q[0]) && (multi_mode_tx_baseband__u_mac_a__bit_in_byte == 3'd6))) &&
        (multi_mode_tx_baseband__u_mac_a__byte_cnt != multi_mode_tx_baseband__u_mac_a__payload_len_q - 16'd1) &&
        (multi_mode_tx_baseband__u_mac_a__byte_cnt != multi_mode_tx_baseband__u_mac_a__payload_len_q - 16'd2);

    wire multi_mode_tx_baseband__u_mac_a__fifo_rd_en_cck_hec_pre =
        (multi_mode_tx_baseband__u_mac_a__state == multi_mode_tx_baseband__u_mac_a__S_HEC) && multi_mode_tx_baseband__u_mac_a__cck_active_in &&
        (multi_mode_tx_baseband__u_mac_a__sym_cnt == 8'd15) &&
        (multi_mode_tx_baseband__u_mac_a__chip_cnt >= 4'd4) && (multi_mode_tx_baseband__u_mac_a__chip_cnt <= 4'd7) &&
        (multi_mode_tx_baseband__u_mac_a__cck_sym_count_q != 16'd0);

    wire multi_mode_tx_baseband__u_mac_a__fifo_rd_en_cck_psdu_pre =
        (multi_mode_tx_baseband__u_mac_a__state == multi_mode_tx_baseband__u_mac_a__S_PSDU_CCK) &&
        (multi_mode_tx_baseband__u_mac_a__cck_sym_cnt < multi_mode_tx_baseband__u_mac_a__cck_sym_count_q - 16'd1) &&
        (multi_mode_tx_baseband__u_mac_a__chip_cnt <= 4'd3);

    assign a_fifo_rd_en = !fifo_empty &&
                        (multi_mode_tx_baseband__u_mac_a__fifo_rd_en_barker_hec_end |
                         multi_mode_tx_baseband__u_mac_a__fifo_rd_en_barker_psdu    |
                         multi_mode_tx_baseband__u_mac_a__fifo_rd_en_cck_hec_pre    |
                         multi_mode_tx_baseband__u_mac_a__fifo_rd_en_cck_psdu_pre);
// ---------------------------------------------------------------------------
// Inlined crc16_80211_hec instance: multi_mode_tx_baseband__u_mac_a__u_hec
// ---------------------------------------------------------------------------
reg [15:0] multi_mode_tx_baseband__u_mac_a__u_hec__state;

    wire        multi_mode_tx_baseband__u_mac_a__u_hec__fb         = multi_mode_tx_baseband__u_mac_a__u_hec__state[15] ^ multi_mode_tx_baseband__u_mac_a__raw_bit_c;
    wire [15:0] multi_mode_tx_baseband__u_mac_a__u_hec__state_next = {multi_mode_tx_baseband__u_mac_a__u_hec__state[14:0], 1'b0} ^ (multi_mode_tx_baseband__u_mac_a__u_hec__fb ? 16'h1021 : 16'h0000);

    always @(posedge clk_b_chip or negedge rst_n_b_chip_s) begin
        if (!rst_n_b_chip_s)           multi_mode_tx_baseband__u_mac_a__u_hec__state <= 16'hFFFF;
        else if (multi_mode_tx_baseband__u_mac_a__crc_init)        multi_mode_tx_baseband__u_mac_a__u_hec__state <= 16'hFFFF;
        else if (multi_mode_tx_baseband__u_mac_a__symbol_start & multi_mode_tx_baseband__u_mac_a__feed_hec_c)  multi_mode_tx_baseband__u_mac_a__u_hec__state <= multi_mode_tx_baseband__u_mac_a__u_hec__state_next;
    end

    assign multi_mode_tx_baseband__u_mac_a__hec_out = multi_mode_tx_baseband__u_mac_a__u_hec__state ^ 16'hFFFF;

    reg multi_mode_tx_baseband__u_mac_a__fcs_feed_second_cycle;
    always @(posedge clk_b_chip or negedge rst_n_b_chip_s) begin
        if (!rst_n_b_chip_s)                          multi_mode_tx_baseband__u_mac_a__fcs_feed_second_cycle <= 1'b0;
        else if (multi_mode_tx_baseband__u_mac_a__symbol_start & multi_mode_tx_baseband__u_mac_a__feed_fcs_c & multi_mode_tx_baseband__u_mac_a__two_bit_sym_c)
                                             multi_mode_tx_baseband__u_mac_a__fcs_feed_second_cycle <= 1'b1;
        else                                 multi_mode_tx_baseband__u_mac_a__fcs_feed_second_cycle <= 1'b0;
    end
// ---------------------------------------------------------------------------
// Inlined crc32_80211 instance: multi_mode_tx_baseband__u_mac_a__u_fcs
// ---------------------------------------------------------------------------
reg [31:0] multi_mode_tx_baseband__u_mac_a__u_fcs__state;

    // Next-multi_mode_tx_baseband__u_mac_a__u_fcs__state logic: reflected CRC-32 update.
    //   x = multi_mode_tx_baseband__u_mac_a__u_fcs__state[0] XOR multi_mode_tx_baseband__u_mac_a__fcs_feed_second_cycle ? multi_mode_tx_baseband__u_mac_a__raw_bit2_c : multi_mode_tx_baseband__u_mac_a__raw_bit_c
    //   state_next = (multi_mode_tx_baseband__u_mac_a__u_fcs__state >> 1) XOR (x ? 0xEDB88320 : 0)
    wire        multi_mode_tx_baseband__u_mac_a__u_fcs__fb = multi_mode_tx_baseband__u_mac_a__u_fcs__state[0] ^ multi_mode_tx_baseband__u_mac_a__fcs_feed_second_cycle ? multi_mode_tx_baseband__u_mac_a__raw_bit2_c : multi_mode_tx_baseband__u_mac_a__raw_bit_c;
    wire [31:0] multi_mode_tx_baseband__u_mac_a__u_fcs__state_next_data = (multi_mode_tx_baseband__u_mac_a__u_fcs__state >> 1) ^ (multi_mode_tx_baseband__u_mac_a__u_fcs__fb ? 32'hEDB88320 : 32'h00000000);

    always @(posedge clk_b_chip or negedge rst_n_b_chip_s) begin
        if (!rst_n_b_chip_s)           multi_mode_tx_baseband__u_mac_a__u_fcs__state <= 32'hFFFFFFFF;
        else if (multi_mode_tx_baseband__u_mac_a__crc_init)        multi_mode_tx_baseband__u_mac_a__u_fcs__state <= 32'hFFFFFFFF;
        else if ((multi_mode_tx_baseband__u_mac_a__symbol_start & multi_mode_tx_baseband__u_mac_a__feed_fcs_c) | multi_mode_tx_baseband__u_mac_a__fcs_feed_second_cycle)  multi_mode_tx_baseband__u_mac_a__u_fcs__state <= multi_mode_tx_baseband__u_mac_a__u_fcs__state_next_data;
    end

    assign multi_mode_tx_baseband__u_mac_a__fcs_out = multi_mode_tx_baseband__u_mac_a__u_fcs__state ^ 32'hFFFFFFFF;

    // Header is loaded from MCU-supplied LENGTH and SERVICE for all rates.
    wire [31:0] multi_mode_tx_baseband__u_mac_a__header_load = {
        length_field[15:8],
        length_field[7:0],
        service_field,
        multi_mode_tx_baseband__u_mac_a__signal_byte_for_rate(rate_mode)
    };

    always @(*) begin
        multi_mode_tx_baseband__u_mac_a__state_next = multi_mode_tx_baseband__u_mac_a__state;
        case (multi_mode_tx_baseband__u_mac_a__state)
            multi_mode_tx_baseband__u_mac_a__S_IDLE       : if (start_pulse_a) multi_mode_tx_baseband__u_mac_a__state_next = multi_mode_tx_baseband__u_mac_a__S_SYNC;
            multi_mode_tx_baseband__u_mac_a__S_SYNC       : if (multi_mode_tx_baseband__u_mac_a__symbol_end && multi_mode_tx_baseband__u_mac_a__sym_cnt == PREAMBLE_SYNC_LEN_A - 1) multi_mode_tx_baseband__u_mac_a__state_next = multi_mode_tx_baseband__u_mac_a__S_SFD;
            multi_mode_tx_baseband__u_mac_a__S_SFD        : if (multi_mode_tx_baseband__u_mac_a__symbol_end && multi_mode_tx_baseband__u_mac_a__sym_cnt == 8'd15)                 multi_mode_tx_baseband__u_mac_a__state_next = multi_mode_tx_baseband__u_mac_a__S_HEAD;
            multi_mode_tx_baseband__u_mac_a__S_HEAD       : if (multi_mode_tx_baseband__u_mac_a__symbol_end && multi_mode_tx_baseband__u_mac_a__sym_cnt == 8'd31)                 multi_mode_tx_baseband__u_mac_a__state_next = multi_mode_tx_baseband__u_mac_a__S_HEC;
            multi_mode_tx_baseband__u_mac_a__S_HEC        : if (multi_mode_tx_baseband__u_mac_a__symbol_end && multi_mode_tx_baseband__u_mac_a__sym_cnt == 8'd15) begin
                if (multi_mode_tx_baseband__u_mac_a__cck_active) begin
                    multi_mode_tx_baseband__u_mac_a__state_next = (multi_mode_tx_baseband__u_mac_a__cck_sym_count_q == 16'd0) ? multi_mode_tx_baseband__u_mac_a__S_DONE : multi_mode_tx_baseband__u_mac_a__S_PSDU_CCK;
                end else begin
                    multi_mode_tx_baseband__u_mac_a__state_next = (multi_mode_tx_baseband__u_mac_a__payload_len_q == 16'd0) ? multi_mode_tx_baseband__u_mac_a__S_FCS_BARKER : multi_mode_tx_baseband__u_mac_a__S_PSDU_BARKER;
                end
            end
            multi_mode_tx_baseband__u_mac_a__S_PSDU_BARKER: begin
                if (multi_mode_tx_baseband__u_mac_a__symbol_end && multi_mode_tx_baseband__u_mac_a__byte_cnt == multi_mode_tx_baseband__u_mac_a__payload_len_q - 16'd1) begin
                    if ((!multi_mode_tx_baseband__u_mac_a__rate_mode_q[0] && multi_mode_tx_baseband__u_mac_a__bit_in_byte == 3'd7) ||
                        ( multi_mode_tx_baseband__u_mac_a__rate_mode_q[0] && multi_mode_tx_baseband__u_mac_a__bit_in_byte == 3'd6))
                        multi_mode_tx_baseband__u_mac_a__state_next = multi_mode_tx_baseband__u_mac_a__S_FCS_BARKER;
                end
            end
            multi_mode_tx_baseband__u_mac_a__S_FCS_BARKER : begin
                if (multi_mode_tx_baseband__u_mac_a__symbol_end) begin
                    if ((!multi_mode_tx_baseband__u_mac_a__rate_mode_q[0] && multi_mode_tx_baseband__u_mac_a__sym_cnt == 8'd31) ||
                        ( multi_mode_tx_baseband__u_mac_a__rate_mode_q[0] && multi_mode_tx_baseband__u_mac_a__sym_cnt == 8'd15))
                        multi_mode_tx_baseband__u_mac_a__state_next = multi_mode_tx_baseband__u_mac_a__S_DONE;
                end
            end
            multi_mode_tx_baseband__u_mac_a__S_PSDU_CCK   : begin
                if (multi_mode_tx_baseband__u_mac_a__symbol_end && multi_mode_tx_baseband__u_mac_a__cck_sym_cnt == multi_mode_tx_baseband__u_mac_a__cck_sym_count_q - 16'd1)
                    multi_mode_tx_baseband__u_mac_a__state_next = multi_mode_tx_baseband__u_mac_a__S_DONE;
            end
            multi_mode_tx_baseband__u_mac_a__S_DONE       : multi_mode_tx_baseband__u_mac_a__state_next = multi_mode_tx_baseband__u_mac_a__S_IDLE;
            default      : multi_mode_tx_baseband__u_mac_a__state_next = multi_mode_tx_baseband__u_mac_a__S_IDLE;
        endcase
    end

    always @(posedge clk_b_chip or negedge rst_n_b_chip_s) begin
        if (!rst_n_b_chip_s) begin
            multi_mode_tx_baseband__u_mac_a__state              <= multi_mode_tx_baseband__u_mac_a__S_IDLE;
            multi_mode_tx_baseband__u_mac_a__rate_mode_q        <= 2'd0;
            multi_mode_tx_baseband__u_mac_a__chip_cnt           <= 4'd0;
            multi_mode_tx_baseband__u_mac_a__sym_cnt            <= 8'd0;
            multi_mode_tx_baseband__u_mac_a__byte_cnt           <= 16'd0;
            multi_mode_tx_baseband__u_mac_a__cck_sym_cnt        <= 16'd0;
            multi_mode_tx_baseband__u_mac_a__bit_in_byte        <= 3'd0;
            multi_mode_tx_baseband__u_mac_a__payload_len_q      <= 16'd0;
            multi_mode_tx_baseband__u_mac_a__cck_sym_count_q    <= 16'd0;
            multi_mode_tx_baseband__u_mac_a__byte_sr            <= 8'd0;
            multi_mode_tx_baseband__u_mac_a__header_sr          <= 32'd0;
            multi_mode_tx_baseband__u_mac_a__sfd_sr             <= 16'd0;
            multi_mode_tx_baseband__u_mac_a__hec_sr             <= 16'd0;
            multi_mode_tx_baseband__u_mac_a__fcs_sr             <= 32'd0;
            multi_mode_tx_baseband__u_mac_a__cck_word_curr      <= 32'd0;
            multi_mode_tx_baseband__u_mac_a__cck_word_next      <= 32'd0;
            multi_mode_tx_baseband__u_mac_a__lfsr               <= SCRAMBLER_SEED_A;
            multi_mode_tx_baseband__u_mac_a__crc_init           <= 1'b0;
            a_underrun      <= 1'b0;
            a_base_phase         <= 2'd0;
            a_delta_phi1         <= 2'd0;
            a_update_phi1        <= 1'b0;
            a_chip_valid_to_phy         <= 1'b0;
            a_busy               <= 1'b0;
            a_done         <= 1'b0;
        end else begin
            multi_mode_tx_baseband__u_mac_a__state       <= multi_mode_tx_baseband__u_mac_a__state_next;
            multi_mode_tx_baseband__u_mac_a__crc_init    <= 1'b0;
            a_done  <= 1'b0;
            a_update_phi1 <= 1'b0;
            a_chip_valid_to_phy  <= multi_mode_tx_baseband__u_mac_a__emit_chip_c;

            // Drive a_base_phase / a_delta_phi1 from the rate-appropriate source.
            a_base_phase  <= (multi_mode_tx_baseband__u_mac_a__state == multi_mode_tx_baseband__u_mac_a__S_PSDU_CCK) ? multi_mode_tx_baseband__u_mac_a__cck_chip_phase : multi_mode_tx_baseband__u_mac_a__base_phase_barker;
            if (multi_mode_tx_baseband__u_mac_a__symbol_start && multi_mode_tx_baseband__u_mac_a__emit_chip_c) begin
                a_update_phi1 <= 1'b1;
                a_delta_phi1  <= (multi_mode_tx_baseband__u_mac_a__state == multi_mode_tx_baseband__u_mac_a__S_PSDU_CCK) ? multi_mode_tx_baseband__u_mac_a__cck_delta_phi1 : multi_mode_tx_baseband__u_mac_a__delta_phi1_barker;
            end

            if (multi_mode_tx_baseband__u_mac_a__symbol_start && multi_mode_tx_baseband__u_mac_a__scramble_c) begin
                multi_mode_tx_baseband__u_mac_a__lfsr <= multi_mode_tx_baseband__u_mac_a__two_bit_sym_c ? multi_mode_tx_baseband__u_mac_a__lfsr_advance2 : multi_mode_tx_baseband__u_mac_a__lfsr_advance1;
            end

            if (multi_mode_tx_baseband__u_mac_a__symbol_end) multi_mode_tx_baseband__u_mac_a__chip_cnt <= 4'd0;
            else            multi_mode_tx_baseband__u_mac_a__chip_cnt <= multi_mode_tx_baseband__u_mac_a__chip_cnt + 4'd1;

            case (multi_mode_tx_baseband__u_mac_a__state)
                multi_mode_tx_baseband__u_mac_a__S_IDLE: begin
                    a_busy <= 1'b0;
                    if (start_pulse_a) begin
                        multi_mode_tx_baseband__u_mac_a__rate_mode_q     <= rate_mode;
                        multi_mode_tx_baseband__u_mac_a__payload_len_q   <= payload_len;
                        multi_mode_tx_baseband__u_mac_a__cck_sym_count_q <= cck_symbol_count;
                        multi_mode_tx_baseband__u_mac_a__sym_cnt         <= 8'd0;
                        multi_mode_tx_baseband__u_mac_a__byte_cnt        <= 16'd0;
                        multi_mode_tx_baseband__u_mac_a__cck_sym_cnt     <= 16'd0;
                        multi_mode_tx_baseband__u_mac_a__bit_in_byte     <= 3'd0;
                        multi_mode_tx_baseband__u_mac_a__chip_cnt        <= 4'd0;
                        multi_mode_tx_baseband__u_mac_a__sfd_sr          <= SFD_PATTERN_A;
                        multi_mode_tx_baseband__u_mac_a__header_sr       <= multi_mode_tx_baseband__u_mac_a__header_load;
                        multi_mode_tx_baseband__u_mac_a__cck_word_curr   <= 32'd0;
                        multi_mode_tx_baseband__u_mac_a__cck_word_next   <= 32'd0;
                        multi_mode_tx_baseband__u_mac_a__lfsr            <= SCRAMBLER_SEED_A;
                        multi_mode_tx_baseband__u_mac_a__crc_init        <= 1'b1;
                        a_underrun   <= 1'b0;
                        a_busy            <= 1'b1;
                    end
                end

                multi_mode_tx_baseband__u_mac_a__S_SYNC: begin
                    if (multi_mode_tx_baseband__u_mac_a__symbol_end) begin
                        multi_mode_tx_baseband__u_mac_a__sym_cnt <= (multi_mode_tx_baseband__u_mac_a__sym_cnt == PREAMBLE_SYNC_LEN_A - 1) ? 8'd0 : multi_mode_tx_baseband__u_mac_a__sym_cnt + 8'd1;
                    end
                end

                multi_mode_tx_baseband__u_mac_a__S_SFD: begin
                    if (multi_mode_tx_baseband__u_mac_a__symbol_end) begin
                        multi_mode_tx_baseband__u_mac_a__sfd_sr  <= {multi_mode_tx_baseband__u_mac_a__sfd_sr[14:0], 1'b0};
                        multi_mode_tx_baseband__u_mac_a__sym_cnt <= (multi_mode_tx_baseband__u_mac_a__sym_cnt == 8'd15) ? 8'd0 : multi_mode_tx_baseband__u_mac_a__sym_cnt + 8'd1;
                    end
                end

                multi_mode_tx_baseband__u_mac_a__S_HEAD: begin
                    if (multi_mode_tx_baseband__u_mac_a__symbol_end) begin
                        multi_mode_tx_baseband__u_mac_a__header_sr <= {1'b0, multi_mode_tx_baseband__u_mac_a__header_sr[31:1]};
                        multi_mode_tx_baseband__u_mac_a__sym_cnt   <= (multi_mode_tx_baseband__u_mac_a__sym_cnt == 8'd31) ? 8'd0 : multi_mode_tx_baseband__u_mac_a__sym_cnt + 8'd1;
                    end
                end

                multi_mode_tx_baseband__u_mac_a__S_HEC: begin
                    // CCK preload: during the LAST HEC symbol's chips 4..7,
                    // pull 4 bytes from the FIFO into multi_mode_tx_baseband__u_mac_a__cck_word_next so that
                    // chip 0 of multi_mode_tx_baseband__u_mac_a__S_PSDU_CCK can emit with no bubble.
                    if (multi_mode_tx_baseband__u_mac_a__cck_active && multi_mode_tx_baseband__u_mac_a__sym_cnt == 8'd15 &&
                        multi_mode_tx_baseband__u_mac_a__chip_cnt >= 4'd4 && multi_mode_tx_baseband__u_mac_a__chip_cnt <= 4'd7 &&
                        multi_mode_tx_baseband__u_mac_a__cck_sym_count_q != 16'd0) begin
                        if (!fifo_empty) begin
                            case (multi_mode_tx_baseband__u_mac_a__chip_cnt[1:0])
                                2'd0: multi_mode_tx_baseband__u_mac_a__cck_word_next[7:0]   <= fifo_rd_data;
                                2'd1: multi_mode_tx_baseband__u_mac_a__cck_word_next[15:8]  <= fifo_rd_data;
                                2'd2: multi_mode_tx_baseband__u_mac_a__cck_word_next[23:16] <= fifo_rd_data;
                                2'd3: multi_mode_tx_baseband__u_mac_a__cck_word_next[31:24] <= fifo_rd_data;
                            endcase
                        end else begin
                            a_underrun <= 1'b1;
                        end
                    end

                    if (multi_mode_tx_baseband__u_mac_a__symbol_end) begin
                        if (multi_mode_tx_baseband__u_mac_a__sym_cnt == 8'd0) multi_mode_tx_baseband__u_mac_a__hec_sr <= {multi_mode_tx_baseband__u_mac_a__hec_out[14:0], 1'b0};
                        else                 multi_mode_tx_baseband__u_mac_a__hec_sr <= {multi_mode_tx_baseband__u_mac_a__hec_sr[14:0], 1'b0};
                        multi_mode_tx_baseband__u_mac_a__sym_cnt <= (multi_mode_tx_baseband__u_mac_a__sym_cnt == 8'd15) ? 8'd0 : multi_mode_tx_baseband__u_mac_a__sym_cnt + 8'd1;

                        if (multi_mode_tx_baseband__u_mac_a__sym_cnt == 8'd15) begin
                            if (multi_mode_tx_baseband__u_mac_a__cck_active) begin
                                multi_mode_tx_baseband__u_mac_a__cck_word_curr <= multi_mode_tx_baseband__u_mac_a__cck_word_next;
                                multi_mode_tx_baseband__u_mac_a__cck_sym_cnt   <= 16'd0;
                            end else if (multi_mode_tx_baseband__u_mac_a__payload_len_q != 16'd0) begin
                                if (!fifo_empty) begin
                                    multi_mode_tx_baseband__u_mac_a__byte_sr <= fifo_rd_data;
                                end else begin
                                    a_underrun <= 1'b1;
                                end
                            end
                        end
                    end
                end

                multi_mode_tx_baseband__u_mac_a__S_PSDU_BARKER: begin
                    if (multi_mode_tx_baseband__u_mac_a__symbol_end) begin
                        if ((!multi_mode_tx_baseband__u_mac_a__rate_mode_q[0] && multi_mode_tx_baseband__u_mac_a__byte_cnt == multi_mode_tx_baseband__u_mac_a__payload_len_q - 16'd1 && multi_mode_tx_baseband__u_mac_a__bit_in_byte == 3'd7) ||
                            ( multi_mode_tx_baseband__u_mac_a__rate_mode_q[0] && multi_mode_tx_baseband__u_mac_a__byte_cnt == multi_mode_tx_baseband__u_mac_a__payload_len_q - 16'd1 && multi_mode_tx_baseband__u_mac_a__bit_in_byte == 3'd6))
                            multi_mode_tx_baseband__u_mac_a__sym_cnt <= 8'd0;
                        else
                            multi_mode_tx_baseband__u_mac_a__sym_cnt <= multi_mode_tx_baseband__u_mac_a__sym_cnt + 8'd1;

                        if (!multi_mode_tx_baseband__u_mac_a__rate_mode_q[0]) begin
                            multi_mode_tx_baseband__u_mac_a__byte_sr     <= {1'b0, multi_mode_tx_baseband__u_mac_a__byte_sr[7:1]};
                            multi_mode_tx_baseband__u_mac_a__bit_in_byte <= multi_mode_tx_baseband__u_mac_a__bit_in_byte + 3'd1;
                            if (multi_mode_tx_baseband__u_mac_a__bit_in_byte == 3'd7) begin
                                multi_mode_tx_baseband__u_mac_a__byte_cnt <= multi_mode_tx_baseband__u_mac_a__byte_cnt + 16'd1;
                                if (multi_mode_tx_baseband__u_mac_a__byte_cnt != multi_mode_tx_baseband__u_mac_a__payload_len_q - 16'd1) begin
                                    if (!fifo_empty) begin
                                        multi_mode_tx_baseband__u_mac_a__byte_sr <= fifo_rd_data;
                                    end else begin
                                        a_underrun <= 1'b1;
                                    end
                                end
                            end
                        end else begin
                            multi_mode_tx_baseband__u_mac_a__byte_sr     <= {2'b00, multi_mode_tx_baseband__u_mac_a__byte_sr[7:2]};
                            multi_mode_tx_baseband__u_mac_a__bit_in_byte <= multi_mode_tx_baseband__u_mac_a__bit_in_byte + 3'd2;
                            if (multi_mode_tx_baseband__u_mac_a__bit_in_byte == 3'd6) begin
                                multi_mode_tx_baseband__u_mac_a__byte_cnt <= multi_mode_tx_baseband__u_mac_a__byte_cnt + 16'd1;
                                if (multi_mode_tx_baseband__u_mac_a__byte_cnt != multi_mode_tx_baseband__u_mac_a__payload_len_q - 16'd1) begin
                                    if (!fifo_empty) begin
                                        multi_mode_tx_baseband__u_mac_a__byte_sr <= fifo_rd_data;
                                    end else begin
                                        a_underrun <= 1'b1;
                                    end
                                end
                            end
                        end
                    end
                end

                multi_mode_tx_baseband__u_mac_a__S_FCS_BARKER: begin
                    if (multi_mode_tx_baseband__u_mac_a__symbol_end) begin
                        multi_mode_tx_baseband__u_mac_a__sym_cnt <= multi_mode_tx_baseband__u_mac_a__sym_cnt + 8'd1;
                        if (!multi_mode_tx_baseband__u_mac_a__rate_mode_q[0]) begin
                            if (multi_mode_tx_baseband__u_mac_a__sym_cnt == 8'd0) multi_mode_tx_baseband__u_mac_a__fcs_sr <= {1'b0, multi_mode_tx_baseband__u_mac_a__fcs_out[31:1]};
                            else                 multi_mode_tx_baseband__u_mac_a__fcs_sr <= {1'b0, multi_mode_tx_baseband__u_mac_a__fcs_sr[31:1]};
                        end else begin
                            if (multi_mode_tx_baseband__u_mac_a__sym_cnt == 8'd0) multi_mode_tx_baseband__u_mac_a__fcs_sr <= {2'b00, multi_mode_tx_baseband__u_mac_a__fcs_out[31:2]};
                            else                 multi_mode_tx_baseband__u_mac_a__fcs_sr <= {2'b00, multi_mode_tx_baseband__u_mac_a__fcs_sr[31:2]};
                        end
                    end
                end

                multi_mode_tx_baseband__u_mac_a__S_PSDU_CCK: begin
                    // Concurrent prefetch: while chips 0..3 of the CURRENT
                    // symbol emit, pull bytes 0..3 of the NEXT symbol from
                    // the FIFO.  Skip on the final symbol.
                    if (multi_mode_tx_baseband__u_mac_a__cck_sym_cnt < multi_mode_tx_baseband__u_mac_a__cck_sym_count_q - 16'd1 && multi_mode_tx_baseband__u_mac_a__chip_cnt <= 4'd3) begin
                        if (!fifo_empty) begin
                            case (multi_mode_tx_baseband__u_mac_a__chip_cnt[1:0])
                                2'd0: multi_mode_tx_baseband__u_mac_a__cck_word_next[7:0]   <= fifo_rd_data;
                                2'd1: multi_mode_tx_baseband__u_mac_a__cck_word_next[15:8]  <= fifo_rd_data;
                                2'd2: multi_mode_tx_baseband__u_mac_a__cck_word_next[23:16] <= fifo_rd_data;
                                2'd3: multi_mode_tx_baseband__u_mac_a__cck_word_next[31:24] <= fifo_rd_data;
                            endcase
                        end else begin
                            a_underrun <= 1'b1;
                        end
                    end

                    if (multi_mode_tx_baseband__u_mac_a__symbol_end) begin
                        if (multi_mode_tx_baseband__u_mac_a__cck_sym_cnt < multi_mode_tx_baseband__u_mac_a__cck_sym_count_q - 16'd1) begin
                            multi_mode_tx_baseband__u_mac_a__cck_word_curr <= multi_mode_tx_baseband__u_mac_a__cck_word_next;
                            multi_mode_tx_baseband__u_mac_a__cck_sym_cnt   <= multi_mode_tx_baseband__u_mac_a__cck_sym_cnt + 16'd1;
                        end
                    end
                end

                multi_mode_tx_baseband__u_mac_a__S_DONE: begin
                    a_busy       <= 1'b0;
                    a_done <= 1'b1;
                end

                default: ;
            endcase
        end
    end
// ---------------------------------------------------------------------------
// Inlined phy_a_rotator instance: multi_mode_tx_baseband__u_phy_a
// ---------------------------------------------------------------------------
reg [1:0] multi_mode_tx_baseband__u_phy_a__phi1_acc;

    // Next-cycle phase accumulator value.
    wire [1:0] multi_mode_tx_baseband__u_phy_a__phi1_next = multi_mode_tx_baseband__u_phy_a__phi1_acc + a_delta_phi1;

    // Current-cycle chip phase to transmit.  When `a_update_phi1` fires on
    // the first chip of a new symbol, the chip uses the FRESHLY-UPDATED
    // accumulator (multi_mode_tx_baseband__u_phy_a__phi1_next) so that chip 0 already sees the new phase.
    wire [1:0] multi_mode_tx_baseband__u_phy_a__phi1_eff = a_update_phi1 ? multi_mode_tx_baseband__u_phy_a__phi1_next : multi_mode_tx_baseband__u_phy_a__phi1_acc;
    wire [1:0] multi_mode_tx_baseband__u_phy_a__chip_phase = a_base_phase + multi_mode_tx_baseband__u_phy_a__phi1_eff;

    wire       multi_mode_tx_baseband__u_phy_a__chip_i_c;
    wire       multi_mode_tx_baseband__u_phy_a__chip_q_c;
// ---------------------------------------------------------------------------
// Inlined phase_to_iq instance: multi_mode_tx_baseband__u_phy_a__u_p2iq
// ---------------------------------------------------------------------------
assign multi_mode_tx_baseband__u_phy_a__chip_i_c = ~multi_mode_tx_baseband__u_phy_a__chip_phase[0];        // multi_mode_tx_baseband__u_phy_a__chip_phase[0]=0 -> +1, multi_mode_tx_baseband__u_phy_a__chip_phase[0]=1 -> -1
    assign multi_mode_tx_baseband__u_phy_a__chip_q_c = ~multi_mode_tx_baseband__u_phy_a__chip_phase[1];        // multi_mode_tx_baseband__u_phy_a__chip_phase[1]=0 -> +1, multi_mode_tx_baseband__u_phy_a__chip_phase[1]=1 -> -1

    always @(posedge clk_b_chip or negedge rst_n_b_chip_s) begin
        if (!rst_n_b_chip_s) begin
            multi_mode_tx_baseband__u_phy_a__phi1_acc   <= 2'd0;
            a_chip_i     <= 1'b0;
            a_chip_q     <= 1'b0;
            a_chip_valid_out <= 1'b0;
        end else begin
            if (start_pulse_a)        multi_mode_tx_baseband__u_phy_a__phi1_acc <= 2'd0;
            else if (a_update_phi1)   multi_mode_tx_baseband__u_phy_a__phi1_acc <= multi_mode_tx_baseband__u_phy_a__phi1_next;

            if (a_chip_valid_to_phy) begin
                a_chip_i     <= multi_mode_tx_baseband__u_phy_a__chip_i_c;
                a_chip_q     <= multi_mode_tx_baseband__u_phy_a__chip_q_c;
                a_chip_valid_out <= 1'b1;
            end else begin
                a_chip_valid_out <= 1'b0;
            end
        end
    end

    assign fifo_rd_en   = a_fifo_rd_en;
    assign chip_i       = a_chip_i;
    assign chip_q       = a_chip_q;
    assign chip_valid   = a_chip_valid_out;
    assign symbol_out   = 8'd0;
    assign symbol_valid = 1'b0;

    // =======================================================================
    // tx_busy / tx_done / underrun back to clk_mcu
    // =======================================================================
// ---------------------------------------------------------------------------
// Inlined sync_2ff instance: multi_mode_tx_baseband__u_busy_sync
// ---------------------------------------------------------------------------
reg [1-1:0] multi_mode_tx_baseband__u_busy_sync__meta_q;
    reg [1-1:0] multi_mode_tx_baseband__u_busy_sync__sync_q;

    always @(posedge clk_mcu or negedge rst_n_mcu_s) begin
        if (!rst_n_mcu_s) begin
            multi_mode_tx_baseband__u_busy_sync__meta_q <= {1{1'b0}};
            multi_mode_tx_baseband__u_busy_sync__sync_q <= {1{1'b0}};
        end else begin
            multi_mode_tx_baseband__u_busy_sync__meta_q <= a_busy;
            multi_mode_tx_baseband__u_busy_sync__sync_q <= multi_mode_tx_baseband__u_busy_sync__meta_q;
        end
    end

    assign tx_busy = multi_mode_tx_baseband__u_busy_sync__sync_q;

    wire done_a_mcu;
// ---------------------------------------------------------------------------
// Inlined pulse_sync instance: multi_mode_tx_baseband__u_done_a
// ---------------------------------------------------------------------------
reg multi_mode_tx_baseband__u_done_a__toggle_src;
    always @(posedge clk_b_chip or negedge rst_n_b_chip_s) begin
        if (!rst_n_b_chip_s)      multi_mode_tx_baseband__u_done_a__toggle_src <= 1'b0;
        else if (a_done)  multi_mode_tx_baseband__u_done_a__toggle_src <= ~multi_mode_tx_baseband__u_done_a__toggle_src;
    end

    wire multi_mode_tx_baseband__u_done_a__toggle_dst;
// ---------------------------------------------------------------------------
// Inlined sync_2ff instance: multi_mode_tx_baseband__u_done_a__u_sync
// ---------------------------------------------------------------------------
reg [1-1:0] multi_mode_tx_baseband__u_done_a__u_sync__meta_q;
    reg [1-1:0] multi_mode_tx_baseband__u_done_a__u_sync__sync_q;

    always @(posedge clk_mcu or negedge rst_n_mcu_s) begin
        if (!rst_n_mcu_s) begin
            multi_mode_tx_baseband__u_done_a__u_sync__meta_q <= {1{1'b0}};
            multi_mode_tx_baseband__u_done_a__u_sync__sync_q <= {1{1'b0}};
        end else begin
            multi_mode_tx_baseband__u_done_a__u_sync__meta_q <= multi_mode_tx_baseband__u_done_a__toggle_src;
            multi_mode_tx_baseband__u_done_a__u_sync__sync_q <= multi_mode_tx_baseband__u_done_a__u_sync__meta_q;
        end
    end

    assign multi_mode_tx_baseband__u_done_a__toggle_dst = multi_mode_tx_baseband__u_done_a__u_sync__sync_q;

    reg multi_mode_tx_baseband__u_done_a__toggle_dst_q;
    always @(posedge clk_mcu or negedge rst_n_mcu_s) begin
        if (!rst_n_mcu_s) multi_mode_tx_baseband__u_done_a__toggle_dst_q <= 1'b0;
        else            multi_mode_tx_baseband__u_done_a__toggle_dst_q <= multi_mode_tx_baseband__u_done_a__toggle_dst;
    end

    assign done_a_mcu = multi_mode_tx_baseband__u_done_a__toggle_dst ^ multi_mode_tx_baseband__u_done_a__toggle_dst_q;

    assign tx_done = done_a_mcu;

    wire a_ur_mcu;
// ---------------------------------------------------------------------------
// Inlined sync_2ff instance: multi_mode_tx_baseband__u_ur_a_sync
// ---------------------------------------------------------------------------
reg [1-1:0] multi_mode_tx_baseband__u_ur_a_sync__meta_q;
    reg [1-1:0] multi_mode_tx_baseband__u_ur_a_sync__sync_q;

    always @(posedge clk_mcu or negedge rst_n_mcu_s) begin
        if (!rst_n_mcu_s) begin
            multi_mode_tx_baseband__u_ur_a_sync__meta_q <= {1{1'b0}};
            multi_mode_tx_baseband__u_ur_a_sync__sync_q <= {1{1'b0}};
        end else begin
            multi_mode_tx_baseband__u_ur_a_sync__meta_q <= a_underrun;
            multi_mode_tx_baseband__u_ur_a_sync__sync_q <= multi_mode_tx_baseband__u_ur_a_sync__meta_q;
        end
    end

    assign a_ur_mcu = multi_mode_tx_baseband__u_ur_a_sync__sync_q;

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
