// =============================================================================
// multi_mode_tx_baseband_flat.v
//
// Single-file flattened RTL for synthesis of the Two-Path WiFi Encoder /
// backscatter TX baseband.  Every module from rtl/cdc, rtl/common,
// rtl/path_a, rtl/path_b, and the top-level rtl/multi_mode_tx_baseband.v is
// inlined below in bottom-up dependency order, with full behavior preserved:
//
//   Leaf / utility modules
//     sync_2ff            two-flop synchronizer
//     reset_sync          async-assert / sync-deassert reset
//     pulse_sync          single-cycle pulse CDC
//     async_fifo          dual-clock Gray-coded FIFO
//     clock_mux_static    2:1 static clock mux (placeholder)
//     scrambler_x7x4      x^7 + x^4 + 1 side-stream scrambler
//     crc16_80211_hec     CCITT-like HEC, init/xor = 0xFFFF
//     crc32_80211         reflected CRC-32 (0xEDB88320)
//     phase_to_iq         Gray QPSK phase -> (I,Q)
//
//   Path A (802.11b Long PLCP, 1/2/5.5/11 Mbps)
//     phy_a_rotator
//     mac_fsm_80211b
//
//   Path B (custom QAM: OOK / QPSK / 16QAM / 64QAM / 256QAM)
//     mac_fsm_custom
//     phy_qam_custom
//
//   Top: multi_mode_tx_baseband
//
// This file is intended for logic synthesis: compile as one source, pass
// `multi_mode_tx_baseband` as the top.  Sim-only SystemVerilog assertions in
// the top module remain guarded by `ifdef ASSERT_ON so they are ignored in
// synthesis.
//
// NOTE: clock_mux_static is a behavioural MUX placeholder.  Replace with the
// foundry's glitch-free clock mux cell before GDS.
// =============================================================================
`timescale 1ns/1ps

// =============================================================================
// sync_2ff : two-flop synchronizer
// =============================================================================
module sync_2ff #(
    parameter WIDTH      = 1,
    parameter RESET_VAL  = 1'b0
) (
    input  wire               clk,
    input  wire               rst_n,
    input  wire [WIDTH-1:0]   d_in,
    output wire [WIDTH-1:0]   d_out
);

    reg [WIDTH-1:0] meta_q;
    reg [WIDTH-1:0] sync_q;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            meta_q <= {WIDTH{RESET_VAL}};
            sync_q <= {WIDTH{RESET_VAL}};
        end else begin
            meta_q <= d_in;
            sync_q <= meta_q;
        end
    end

    assign d_out = sync_q;

endmodule

// =============================================================================
// reset_sync : async-assert, sync-deassert reset synchronizer
// =============================================================================
module reset_sync (
    input  wire clk,
    input  wire async_rst_n,
    output wire sync_rst_n
);

    reg meta_q;
    reg sync_q;

    always @(posedge clk or negedge async_rst_n) begin
        if (!async_rst_n) begin
            meta_q <= 1'b0;
            sync_q <= 1'b0;
        end else begin
            meta_q <= 1'b1;
            sync_q <= meta_q;
        end
    end

    assign sync_rst_n = sync_q;

endmodule

// =============================================================================
// pulse_sync : cross a 1-cycle pulse between clock domains
// =============================================================================
module pulse_sync (
    input  wire src_clk,
    input  wire src_rst_n,
    input  wire src_pulse,

    input  wire dst_clk,
    input  wire dst_rst_n,
    output wire dst_pulse
);

    reg toggle_src;
    always @(posedge src_clk or negedge src_rst_n) begin
        if (!src_rst_n)      toggle_src <= 1'b0;
        else if (src_pulse)  toggle_src <= ~toggle_src;
    end

    wire toggle_dst;
    sync_2ff #(.WIDTH(1), .RESET_VAL(1'b0)) u_sync (
        .clk   (dst_clk),
        .rst_n (dst_rst_n),
        .d_in  (toggle_src),
        .d_out (toggle_dst)
    );

    reg toggle_dst_q;
    always @(posedge dst_clk or negedge dst_rst_n) begin
        if (!dst_rst_n) toggle_dst_q <= 1'b0;
        else            toggle_dst_q <= toggle_dst;
    end

    assign dst_pulse = toggle_dst ^ toggle_dst_q;

endmodule

// =============================================================================
// async_fifo : dual-clock Gray-coded asynchronous FIFO (power-of-2 depth)
// =============================================================================
module async_fifo #(
    parameter DATA_W = 8,
    parameter DEPTH  = 32,
    parameter ADDR_W = 5
) (
    input  wire              wclk,
    input  wire              wrst_n,
    input  wire              wr_en,
    input  wire [DATA_W-1:0] wr_data,
    output wire              full,

    input  wire              rclk,
    input  wire              rrst_n,
    input  wire              rd_en,
    output wire [DATA_W-1:0] rd_data,
    output wire              empty
);

    reg [DATA_W-1:0] mem [0:DEPTH-1];

    // ---- Write domain ----------------------------------------------------
    reg  [ADDR_W:0] wptr_bin;
    reg  [ADDR_W:0] wptr_gray;
    wire [ADDR_W:0] wptr_bin_next  = wptr_bin + {{ADDR_W{1'b0}}, (wr_en & ~full)};
    wire [ADDR_W:0] wptr_gray_next = (wptr_bin_next >> 1) ^ wptr_bin_next;

    always @(posedge wclk or negedge wrst_n) begin
        if (!wrst_n) begin
            wptr_bin  <= {ADDR_W+1{1'b0}};
            wptr_gray <= {ADDR_W+1{1'b0}};
        end else begin
            wptr_bin  <= wptr_bin_next;
            wptr_gray <= wptr_gray_next;
        end
    end

    always @(posedge wclk) begin
        if (wr_en && !full) mem[wptr_bin[ADDR_W-1:0]] <= wr_data;
    end

    // ---- Read domain -----------------------------------------------------
    reg  [ADDR_W:0] rptr_bin;
    reg  [ADDR_W:0] rptr_gray;
    wire [ADDR_W:0] rptr_bin_next  = rptr_bin + {{ADDR_W{1'b0}}, (rd_en & ~empty)};
    wire [ADDR_W:0] rptr_gray_next = (rptr_bin_next >> 1) ^ rptr_bin_next;

    wire [ADDR_W:0] rptr_gray_at_w;
    sync_2ff #(.WIDTH(ADDR_W+1), .RESET_VAL(1'b0)) u_sync_r2w (
        .clk(wclk), .rst_n(wrst_n),
        .d_in (rptr_gray),
        .d_out(rptr_gray_at_w)
    );

    assign full = (wptr_gray == {~rptr_gray_at_w[ADDR_W:ADDR_W-1],
                                  rptr_gray_at_w[ADDR_W-2:0]});

    always @(posedge rclk or negedge rrst_n) begin
        if (!rrst_n) begin
            rptr_bin  <= {ADDR_W+1{1'b0}};
            rptr_gray <= {ADDR_W+1{1'b0}};
        end else begin
            rptr_bin  <= rptr_bin_next;
            rptr_gray <= rptr_gray_next;
        end
    end

    wire [ADDR_W:0] wptr_gray_at_r;
    sync_2ff #(.WIDTH(ADDR_W+1), .RESET_VAL(1'b0)) u_sync_w2r (
        .clk(rclk), .rst_n(rrst_n),
        .d_in (wptr_gray),
        .d_out(wptr_gray_at_r)
    );

    assign empty   = (rptr_gray == wptr_gray_at_r);
    assign rd_data = mem[rptr_bin[ADDR_W-1:0]];

endmodule

// =============================================================================
// clock_mux_static : 2:1 static-select clock mux (placeholder; swap for
// foundry glitch-free cell before GDS)
// =============================================================================
module clock_mux_static (
    input  wire sel,
    input  wire clk0,
    input  wire clk1,
    output wire clk_out
);
    assign clk_out = sel ? clk1 : clk0;
endmodule

// =============================================================================
// scrambler_x7x4 : 7-bit side-stream scrambler (x^7 + x^4 + 1)
// =============================================================================
module scrambler_x7x4 #(
    parameter [6:0] DEFAULT_SEED = 7'h5D
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       seed_load,
    input  wire       data_valid,
    input  wire       data_in,
    output wire       data_out
);

    reg [6:0] lfsr;
    wire feedback = lfsr[6] ^ lfsr[3];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)             lfsr <= DEFAULT_SEED;
        else if (seed_load)     lfsr <= DEFAULT_SEED;
        else if (data_valid)    lfsr <= {lfsr[5:0], feedback};
    end

    assign data_out = data_in ^ lfsr[6];

endmodule

// =============================================================================
// crc16_80211_hec : IEEE 802.11 PLCP Header Error Check
//   Poly 0x1021, Init 0xFFFF, RefIn/Out=false, XorOut 0xFFFF
// =============================================================================
module crc16_80211_hec (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        init,
    input  wire        data_valid,
    input  wire        data_bit,
    output wire [15:0] crc_out
);

    reg [15:0] state;

    wire        fb         = state[15] ^ data_bit;
    wire [15:0] state_next = {state[14:0], 1'b0} ^ (fb ? 16'h1021 : 16'h0000);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)           state <= 16'hFFFF;
        else if (init)        state <= 16'hFFFF;
        else if (data_valid)  state <= state_next;
    end

    assign crc_out = state ^ 16'hFFFF;

endmodule

// =============================================================================
// crc32_80211 : reflected CRC-32 (poly 0x04C11DB7, reflected = 0xEDB88320)
// =============================================================================
module crc32_80211 (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        init,
    input  wire        data_valid,
    input  wire        data_bit,
    output wire [31:0] crc_out
);

    reg [31:0] state;

    wire        fb = state[0] ^ data_bit;
    wire [31:0] state_next_data = (state >> 1) ^ (fb ? 32'hEDB88320 : 32'h00000000);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)           state <= 32'hFFFFFFFF;
        else if (init)        state <= 32'hFFFFFFFF;
        else if (data_valid)  state <= state_next_data;
    end

    assign crc_out = state ^ 32'hFFFFFFFF;

endmodule

// =============================================================================
// phase_to_iq : Gray QPSK phase -> (chip_i, chip_q)
//   00 -> (+I,+Q)   01 -> (-I,+Q)   11 -> (-I,-Q)   10 -> (+I,-Q)
// =============================================================================
module phase_to_iq (
    input  wire [1:0] phase,
    output wire       chip_i,
    output wire       chip_q
);
    assign chip_i = ~phase[0];
    assign chip_q = ~phase[1];
endmodule

// =============================================================================
// phy_a_rotator : Path A QPSK rotator (serves all four 802.11b rates)
// =============================================================================
module phy_a_rotator (
    input  wire       clk,
    input  wire       rst_n,

    input  wire       start_pulse,
    input  wire [1:0] base_phase,
    input  wire [1:0] delta_phi1,
    input  wire       update_phi1,
    input  wire       valid_chip,

    output reg        chip_i,
    output reg        chip_q,
    output reg        chip_valid
);

    reg [1:0] phi1_acc;

    wire [1:0] phi1_next  = phi1_acc + delta_phi1;
    wire [1:0] phi1_eff   = update_phi1 ? phi1_next : phi1_acc;
    wire [1:0] chip_phase = base_phase + phi1_eff;

    wire       chip_i_c;
    wire       chip_q_c;
    phase_to_iq u_p2iq (.phase(chip_phase), .chip_i(chip_i_c), .chip_q(chip_q_c));

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            phi1_acc   <= 2'd0;
            chip_i     <= 1'b0;
            chip_q     <= 1'b0;
            chip_valid <= 1'b0;
        end else begin
            if (start_pulse)        phi1_acc <= 2'd0;
            else if (update_phi1)   phi1_acc <= phi1_next;

            if (valid_chip) begin
                chip_i     <= chip_i_c;
                chip_q     <= chip_q_c;
                chip_valid <= 1'b1;
            end else begin
                chip_valid <= 1'b0;
            end
        end
    end

endmodule

// =============================================================================
// mac_fsm_80211b : 802.11b Long PLCP MAC/PLCP for 1 / 2 / 5.5 / 11 Mbps
// =============================================================================
module mac_fsm_80211b #(
    parameter integer PREAMBLE_SYNC_LEN = 128,
    parameter [15:0]  SFD_PATTERN       = 16'hF3A0,
    parameter [7:0]   SERVICE_FIELD     = 8'h00,
    parameter [6:0]   SCRAMBLER_SEED    = 7'h6D,
    parameter [10:0]  BARKER_PATTERN    = 11'b10110111000
) (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        start_pulse,
    input  wire [1:0]  rate,
    input  wire [15:0] payload_len,
    input  wire [15:0] length_us,

    output reg         busy,
    output reg         done_pulse,

    output reg         fifo_rd_en,
    input  wire        fifo_empty,
    input  wire [7:0]  fifo_rd_data,
    output reg         underrun_flag,

    output reg  [1:0]  base_phase,
    output reg  [1:0]  delta_phi1,
    output reg         update_phi1,
    output reg         chip_valid
);

    function [7:0] signal_byte_for_rate;
        input [1:0] r;
        case (r)
            2'b00  : signal_byte_for_rate = 8'h0A;
            2'b01  : signal_byte_for_rate = 8'h14;
            2'b10  : signal_byte_for_rate = 8'h37;
            2'b11  : signal_byte_for_rate = 8'h6E;
            default: signal_byte_for_rate = 8'h0A;
        endcase
    endfunction

    localparam [3:0]
        S_IDLE         = 4'd0,
        S_SYNC         = 4'd1,
        S_SFD          = 4'd2,
        S_HEAD         = 4'd3,
        S_HEC          = 4'd4,
        S_PSDU_BARKER  = 4'd5,
        S_FCS_BARKER   = 4'd6,
        S_PSDU_CCK     = 4'd7,
        S_DONE         = 4'd8;

    reg [3:0] state, state_next;
    reg [1:0] rate_q;

    reg  [3:0] chip_cnt;
    wire [3:0] chip_cnt_max = (state == S_PSDU_CCK) ? 4'd7 : 4'd10;
    wire       symbol_start = (chip_cnt == 4'd0);
    wire       symbol_end   = (chip_cnt == chip_cnt_max);

    reg [15:0] payload_len_q;
    reg [15:0] length_us_q;
    reg [7:0]  sym_cnt;
    reg [15:0] byte_cnt;
    reg [2:0]  bit_in_byte;
    reg [15:0] cck_sym_total;
    reg [15:0] cck_sym_cnt;

    reg [7:0]  byte_sr;
    reg [31:0] header_sr;
    reg [15:0] sfd_sr;
    reg [15:0] hec_sr;
    reg [31:0] fcs_sr;

    reg [15:0] cck_word;

    reg         crc_init;
    wire [15:0] hec_out;
    wire [31:0] fcs_out;

    reg        raw_bit_c;
    reg        raw_bit2_c;
    reg        scramble_c;
    reg        two_bit_sym_c;
    reg        feed_hec_c;
    reg        feed_fcs_c;
    reg        cck_mode_c;
    reg        emit_chip_c;

    wire first_hec_cycle = (state == S_HEC)        && (sym_cnt == 8'd0) && symbol_start;
    wire first_fcs_cycle = (state == S_FCS_BARKER) && (sym_cnt == 8'd0) && symbol_start;
    wire [15:0] hec_source = (state == S_HEC        && sym_cnt == 8'd0) ? hec_out : hec_sr;
    wire [31:0] fcs_source = (state == S_FCS_BARKER && sym_cnt == 8'd0) ? fcs_out : fcs_sr;

    always @(*) begin
        raw_bit_c     = 1'b0;
        raw_bit2_c    = 1'b0;
        scramble_c    = 1'b0;
        two_bit_sym_c = 1'b0;
        feed_hec_c    = 1'b0;
        feed_fcs_c    = 1'b0;
        cck_mode_c    = 1'b0;
        emit_chip_c   = 1'b0;

        case (state)
            S_SYNC: begin
                raw_bit_c   = 1'b1;
                scramble_c  = 1'b1;
                emit_chip_c = 1'b1;
            end
            S_SFD: begin
                raw_bit_c   = sfd_sr[15];
                scramble_c  = 1'b1;
                emit_chip_c = 1'b1;
            end
            S_HEAD: begin
                raw_bit_c   = header_sr[0];
                scramble_c  = 1'b1;
                feed_hec_c  = 1'b1;
                emit_chip_c = 1'b1;
            end
            S_HEC: begin
                raw_bit_c   = hec_source[15];
                scramble_c  = 1'b1;
                emit_chip_c = 1'b1;
            end
            S_PSDU_BARKER: begin
                raw_bit_c     = byte_sr[0];
                raw_bit2_c    = byte_sr[1];
                scramble_c    = 1'b1;
                two_bit_sym_c = (rate_q == 2'b01);
                feed_fcs_c    = 1'b1;
                emit_chip_c   = 1'b1;
            end
            S_FCS_BARKER: begin
                raw_bit_c     = fcs_source[0];
                raw_bit2_c    = fcs_source[1];
                scramble_c    = 1'b1;
                two_bit_sym_c = (rate_q == 2'b01);
                emit_chip_c   = 1'b1;
            end
            S_PSDU_CCK: begin
                cck_mode_c  = 1'b1;
                emit_chip_c = 1'b1;
            end
            default: ;
        endcase
    end

    reg  [6:0] lfsr;
    wire       fb_a          = lfsr[6] ^ lfsr[3];
    wire [6:0] lfsr_advance1 = {lfsr[5:0], fb_a};
    wire       fb_b          = lfsr_advance1[6] ^ lfsr_advance1[3];
    wire [6:0] lfsr_advance2 = {lfsr_advance1[5:0], fb_b};

    wire s0 = raw_bit_c  ^ lfsr[6];
    wire s1 = raw_bit2_c ^ lfsr_advance1[6];

    function [1:0] dqpsk_delta_from_bits;
        input bit0;
        input bit1;
        begin
            case ({bit1, bit0})
                2'b00 : dqpsk_delta_from_bits = 2'd0;
                2'b10 : dqpsk_delta_from_bits = 2'd1;
                2'b11 : dqpsk_delta_from_bits = 2'd2;
                2'b01 : dqpsk_delta_from_bits = 2'd3;
                default: dqpsk_delta_from_bits = 2'd0;
            endcase
        end
    endfunction
    wire [1:0] delta_phi1_barker =
        two_bit_sym_c ? dqpsk_delta_from_bits(s0, s1) : {s0, 1'b0};

    wire barker_chip_bit = BARKER_PATTERN[10 - chip_cnt[3:0]];
    wire [1:0] base_phase_barker = barker_chip_bit ? 2'b00 : 2'b10;

    reg [1:0] base_phase_cck;
    always @(*) begin
        case (chip_cnt[2:0])
            3'd0: base_phase_cck = cck_word[3:2];
            3'd1: base_phase_cck = cck_word[5:4];
            3'd2: base_phase_cck = cck_word[7:6];
            3'd3: base_phase_cck = cck_word[9:8];
            3'd4: base_phase_cck = cck_word[11:10];
            3'd5: base_phase_cck = cck_word[13:12];
            3'd6: base_phase_cck = cck_word[15:14];
            3'd7: base_phase_cck = 2'b00;
            default: base_phase_cck = 2'b00;
        endcase
    end

    wire [1:0] delta_phi1_cck = cck_word[1:0];

    crc16_80211_hec u_hec (
        .clk(clk), .rst_n(rst_n), .init(crc_init),
        .data_valid(symbol_start & feed_hec_c),
        .data_bit  (raw_bit_c),
        .crc_out   (hec_out)
    );

    reg        fcs_feed_second_cycle;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)                          fcs_feed_second_cycle <= 1'b0;
        else if (symbol_start & feed_fcs_c & two_bit_sym_c)
                                             fcs_feed_second_cycle <= 1'b1;
        else                                 fcs_feed_second_cycle <= 1'b0;
    end
    crc32_80211 u_fcs (
        .clk(clk), .rst_n(rst_n), .init(crc_init),
        .data_valid((symbol_start & feed_fcs_c) | fcs_feed_second_cycle),
        .data_bit  (fcs_feed_second_cycle ? raw_bit2_c : raw_bit_c),
        .crc_out   (fcs_out)
    );

    wire [7:0]  signal_byte_c = signal_byte_for_rate(rate);
    wire [31:0] header_load   = { length_us[15:8], length_us[7:0], SERVICE_FIELD, signal_byte_c };

    wire [15:0] cck_sym_total_load =
        (rate == 2'b11) ? (payload_len + 16'd4)
                        : ({payload_len, 1'b0} + 16'd8);

    always @(*) begin
        state_next = state;
        case (state)
            S_IDLE: if (start_pulse) state_next = S_SYNC;
            S_SYNC: if (symbol_end && sym_cnt == PREAMBLE_SYNC_LEN - 1) state_next = S_SFD;
            S_SFD : if (symbol_end && sym_cnt == 8'd15)                 state_next = S_HEAD;
            S_HEAD: if (symbol_end && sym_cnt == 8'd31)                 state_next = S_HEC;
            S_HEC : if (symbol_end && sym_cnt == 8'd15) begin
                if (rate_q[1])
                    state_next = S_PSDU_CCK;
                else if (payload_len_q == 16'd0)
                    state_next = S_FCS_BARKER;
                else
                    state_next = S_PSDU_BARKER;
            end
            S_PSDU_BARKER: begin
                if (symbol_end && byte_cnt == payload_len_q - 16'd1) begin
                    if ((rate_q == 2'b00 && bit_in_byte == 3'd7) ||
                        (rate_q == 2'b01 && bit_in_byte == 3'd6))
                        state_next = S_FCS_BARKER;
                end
            end
            S_FCS_BARKER: begin
                if (symbol_end) begin
                    if ((rate_q == 2'b00 && sym_cnt == 8'd31) ||
                        (rate_q == 2'b01 && sym_cnt == 8'd15))
                        state_next = S_DONE;
                end
            end
            S_PSDU_CCK: begin
                if (symbol_end && cck_sym_cnt == cck_sym_total - 16'd1)
                    state_next = S_DONE;
            end
            S_DONE: state_next = S_IDLE;
            default: state_next = S_IDLE;
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state              <= S_IDLE;
            rate_q             <= 2'd0;
            chip_cnt           <= 4'd0;
            sym_cnt            <= 8'd0;
            byte_cnt           <= 16'd0;
            bit_in_byte        <= 3'd0;
            payload_len_q      <= 16'd0;
            length_us_q        <= 16'd0;
            cck_sym_total      <= 16'd0;
            cck_sym_cnt        <= 16'd0;
            byte_sr            <= 8'd0;
            header_sr          <= 32'd0;
            sfd_sr             <= 16'd0;
            hec_sr             <= 16'd0;
            fcs_sr             <= 32'd0;
            cck_word           <= 16'd0;
            lfsr               <= SCRAMBLER_SEED;
            crc_init           <= 1'b0;
            fifo_rd_en         <= 1'b0;
            underrun_flag      <= 1'b0;
            base_phase         <= 2'd0;
            delta_phi1         <= 2'd0;
            update_phi1        <= 1'b0;
            chip_valid         <= 1'b0;
            busy               <= 1'b0;
            done_pulse         <= 1'b0;
        end else begin
            state       <= state_next;
            fifo_rd_en  <= 1'b0;
            crc_init    <= 1'b0;
            done_pulse  <= 1'b0;
            update_phi1 <= 1'b0;
            chip_valid  <= emit_chip_c;

            base_phase <= cck_mode_c ? base_phase_cck : base_phase_barker;
            if (symbol_start && emit_chip_c) begin
                update_phi1 <= 1'b1;
                delta_phi1  <= cck_mode_c ? delta_phi1_cck : delta_phi1_barker;
            end

            if (symbol_start && scramble_c) begin
                lfsr <= two_bit_sym_c ? lfsr_advance2 : lfsr_advance1;
            end

            if (symbol_end) chip_cnt <= 4'd0;
            else            chip_cnt <= chip_cnt + 4'd1;

            case (state)
                S_IDLE: begin
                    busy <= 1'b0;
                    if (start_pulse) begin
                        rate_q          <= rate;
                        payload_len_q   <= payload_len;
                        length_us_q     <= length_us;
                        cck_sym_total   <= cck_sym_total_load;
                        sym_cnt         <= 8'd0;
                        byte_cnt        <= 16'd0;
                        bit_in_byte     <= 3'd0;
                        cck_sym_cnt     <= 16'd0;
                        chip_cnt        <= 4'd0;
                        sfd_sr          <= SFD_PATTERN;
                        header_sr       <= header_load;
                        lfsr            <= SCRAMBLER_SEED;
                        crc_init        <= 1'b1;
                        underrun_flag   <= 1'b0;
                        busy            <= 1'b1;
                    end
                end

                S_SYNC: begin
                    if (symbol_end) begin
                        sym_cnt <= (sym_cnt == PREAMBLE_SYNC_LEN - 1) ? 8'd0
                                                                      : sym_cnt + 8'd1;
                    end
                end

                S_SFD: begin
                    if (symbol_end) begin
                        sfd_sr  <= {sfd_sr[14:0], 1'b0};
                        sym_cnt <= (sym_cnt == 8'd15) ? 8'd0 : sym_cnt + 8'd1;
                    end
                end

                S_HEAD: begin
                    if (symbol_end) begin
                        header_sr <= {1'b0, header_sr[31:1]};
                        sym_cnt   <= (sym_cnt == 8'd31) ? 8'd0 : sym_cnt + 8'd1;
                    end
                end

                S_HEC: begin
                    if (symbol_end) begin
                        if (sym_cnt == 8'd0) hec_sr <= {hec_out[14:0], 1'b0};
                        else                 hec_sr <= {hec_sr[14:0], 1'b0};
                        sym_cnt <= (sym_cnt == 8'd15) ? 8'd0 : sym_cnt + 8'd1;

                        if (sym_cnt == 8'd15 && payload_len_q != 16'd0 && !rate_q[1]) begin
                            if (!fifo_empty) begin
                                byte_sr <= fifo_rd_data;
                                if (payload_len_q > 16'd1) fifo_rd_en <= 1'b1;
                            end else begin
                                underrun_flag <= 1'b1;
                            end
                        end
                        if (sym_cnt == 8'd15 && rate_q[1]) begin
                            if (!fifo_empty) begin
                                cck_word[7:0] <= fifo_rd_data;
                                fifo_rd_en    <= 1'b1;
                            end else begin
                                underrun_flag <= 1'b1;
                            end
                        end
                    end
                end

                S_PSDU_BARKER: begin
                    if (symbol_end) begin
                        if ((rate_q == 2'b00 && byte_cnt == payload_len_q - 16'd1 && bit_in_byte == 3'd7) ||
                            (rate_q == 2'b01 && byte_cnt == payload_len_q - 16'd1 && bit_in_byte == 3'd6))
                            sym_cnt <= 8'd0;
                        else
                            sym_cnt <= sym_cnt + 8'd1;

                        if (rate_q == 2'b00) begin
                            byte_sr     <= {1'b0, byte_sr[7:1]};
                            bit_in_byte <= bit_in_byte + 3'd1;
                            if (bit_in_byte == 3'd7) begin
                                byte_cnt <= byte_cnt + 16'd1;
                                if (byte_cnt != payload_len_q - 16'd1) begin
                                    if (!fifo_empty) begin
                                        byte_sr <= fifo_rd_data;
                                        if (byte_cnt != payload_len_q - 16'd2)
                                            fifo_rd_en <= 1'b1;
                                    end else begin
                                        underrun_flag <= 1'b1;
                                    end
                                end
                            end
                        end else begin
                            byte_sr     <= {2'b00, byte_sr[7:2]};
                            bit_in_byte <= bit_in_byte + 3'd2;
                            if (bit_in_byte == 3'd6) begin
                                byte_cnt <= byte_cnt + 16'd1;
                                if (byte_cnt != payload_len_q - 16'd1) begin
                                    if (!fifo_empty) begin
                                        byte_sr <= fifo_rd_data;
                                        if (byte_cnt != payload_len_q - 16'd2)
                                            fifo_rd_en <= 1'b1;
                                    end else begin
                                        underrun_flag <= 1'b1;
                                    end
                                end
                            end
                        end
                    end
                end

                S_FCS_BARKER: begin
                    if (symbol_end) begin
                        sym_cnt <= sym_cnt + 8'd1;
                        if (rate_q == 2'b00) begin
                            if (sym_cnt == 8'd0) fcs_sr <= {1'b0, fcs_out[31:1]};
                            else                 fcs_sr <= {1'b0, fcs_sr[31:1]};
                        end else begin
                            if (sym_cnt == 8'd0) fcs_sr <= {2'b00, fcs_out[31:2]};
                            else                 fcs_sr <= {2'b00, fcs_sr[31:2]};
                        end
                    end
                end

                S_PSDU_CCK: begin
                    if (symbol_end) begin
                        cck_sym_cnt <= cck_sym_cnt + 16'd1;
                        if (cck_sym_cnt != cck_sym_total - 16'd1) begin
                            if (!fifo_empty) begin
                                cck_word[7:0] <= fifo_rd_data;
                                fifo_rd_en    <= 1'b1;
                            end else begin
                                underrun_flag <= 1'b1;
                            end
                        end
                    end
                    if (chip_cnt == 4'd1) begin
                        cck_word[15:8] <= fifo_rd_data;
                        if (cck_sym_cnt != cck_sym_total - 16'd1) begin
                            if (!fifo_empty) fifo_rd_en    <= 1'b1;
                            else             underrun_flag <= 1'b1;
                        end
                    end
                end

                S_DONE: begin
                    busy       <= 1'b0;
                    done_pulse <= 1'b1;
                end

                default: ;
            endcase
        end
    end

endmodule

// =============================================================================
// mac_fsm_custom : custom (Path B) bit-stream MAC with CRC-32 FCS + scrambler
// =============================================================================
module mac_fsm_custom #(
    parameter integer CUSTOM_PREAMBLE_LEN  = 32,
    parameter [31:0]  CUSTOM_PREAMBLE_PAT  = 32'hAAAAAAAA,
    parameter [6:0]   SCRAMBLER_SEED       = 7'h5D
) (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        start_pulse,
    input  wire [15:0] payload_len,
    output reg         busy,
    output reg         done_pulse,

    output reg         fifo_rd_en,
    input  wire        fifo_empty,
    input  wire [7:0]  fifo_rd_data,
    output reg         underrun_flag,

    output reg         bit_valid,
    output reg         bit_out
);

    localparam [2:0]
        S_IDLE           = 3'd0,
        S_PREAMBLE       = 3'd1,
        S_PAYLOAD        = 3'd2,
        S_FCS            = 3'd3,
        S_DONE           = 3'd4;

    reg [2:0] state, state_next;

    reg [15:0] preamble_cnt;
    reg [7:0]  fcs_cnt;
    reg [15:0] byte_cnt;
    reg [2:0]  bit_in_byte;
    reg [15:0] payload_len_q;
    reg [7:0]  byte_sr;
    reg [31:0] preamble_sr;
    reg [31:0] fcs_sr;

    reg raw_bit_c;
    reg scramble_c;
    reg feed_crc_c;
    reg valid_c;

    wire first_fcs_cycle = (state == S_FCS) && (fcs_cnt == 8'd0);
    wire [31:0] crc_out;
    wire [31:0] fcs_source = first_fcs_cycle ? crc_out : fcs_sr;

    always @(*) begin
        raw_bit_c  = 1'b0;
        scramble_c = 1'b0;
        feed_crc_c = 1'b0;
        valid_c    = 1'b0;
        case (state)
            S_PREAMBLE: begin
                raw_bit_c = preamble_sr[0];
                valid_c   = 1'b1;
            end
            S_PAYLOAD: begin
                raw_bit_c  = byte_sr[0];
                scramble_c = 1'b1;
                feed_crc_c = 1'b1;
                valid_c    = 1'b1;
            end
            S_FCS: begin
                raw_bit_c  = fcs_source[0];
                scramble_c = 1'b1;
                feed_crc_c = 1'b0;
                valid_c    = 1'b1;
            end
            default: ;
        endcase
    end

    reg crc_init;
    crc32_80211 u_crc (
        .clk        (clk),
        .rst_n      (rst_n),
        .init       (crc_init),
        .data_valid (valid_c & feed_crc_c),
        .data_bit   (raw_bit_c),
        .crc_out    (crc_out)
    );

    reg  [6:0] lfsr;
    wire       lfsr_feedback = lfsr[6] ^ lfsr[3];
    wire       scrambled_bit = raw_bit_c ^ lfsr[6];

    always @(*) begin
        state_next = state;
        case (state)
            S_IDLE     : if (start_pulse)                               state_next = S_PREAMBLE;
            S_PREAMBLE : if (preamble_cnt == CUSTOM_PREAMBLE_LEN - 1)
                             state_next = (payload_len_q == 16'd0) ? S_FCS : S_PAYLOAD;
            S_PAYLOAD  : if ((byte_cnt == payload_len_q - 1) &&
                             (bit_in_byte == 3'd7))                    state_next = S_FCS;
            S_FCS      : if (fcs_cnt == 8'd31)                          state_next = S_DONE;
            S_DONE     :                                                state_next = S_IDLE;
            default    :                                                state_next = S_IDLE;
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state         <= S_IDLE;
            preamble_cnt  <= 16'd0;
            fcs_cnt       <= 8'd0;
            byte_cnt      <= 16'd0;
            bit_in_byte   <= 3'd0;
            payload_len_q <= 16'd0;
            byte_sr       <= 8'd0;
            preamble_sr   <= 32'd0;
            fcs_sr        <= 32'd0;
            lfsr          <= SCRAMBLER_SEED;
            crc_init      <= 1'b0;
            fifo_rd_en    <= 1'b0;
            underrun_flag <= 1'b0;
            bit_valid     <= 1'b0;
            bit_out       <= 1'b0;
            busy          <= 1'b0;
            done_pulse    <= 1'b0;
        end else begin
            state      <= state_next;
            fifo_rd_en <= 1'b0;
            crc_init   <= 1'b0;
            done_pulse <= 1'b0;

            bit_valid <= valid_c;
            bit_out   <= scramble_c ? scrambled_bit : raw_bit_c;

            if (valid_c && scramble_c) begin
                lfsr <= {lfsr[5:0], lfsr_feedback};
            end

            case (state)
                S_IDLE: begin
                    busy <= 1'b0;
                    if (start_pulse) begin
                        payload_len_q <= payload_len;
                        preamble_cnt  <= 16'd0;
                        fcs_cnt       <= 8'd0;
                        byte_cnt      <= 16'd0;
                        bit_in_byte   <= 3'd0;
                        preamble_sr   <= CUSTOM_PREAMBLE_PAT;
                        lfsr          <= SCRAMBLER_SEED;
                        crc_init      <= 1'b1;
                        underrun_flag <= 1'b0;
                        busy          <= 1'b1;
                    end
                end

                S_PREAMBLE: begin
                    preamble_sr  <= {1'b0, preamble_sr[31:1]};
                    preamble_cnt <= preamble_cnt + 1'b1;

                    if ((preamble_cnt == CUSTOM_PREAMBLE_LEN - 1) &&
                        (payload_len_q != 16'd0)) begin
                        if (!fifo_empty) begin
                            byte_sr <= fifo_rd_data;
                            if (payload_len_q > 16'd1) fifo_rd_en <= 1'b1;
                        end else begin
                            underrun_flag <= 1'b1;
                        end
                    end
                end

                S_PAYLOAD: begin
                    byte_sr     <= {1'b0, byte_sr[7:1]};
                    bit_in_byte <= bit_in_byte + 1'b1;

                    if (bit_in_byte == 3'd7) begin
                        byte_cnt <= byte_cnt + 1'b1;
                        if (byte_cnt != payload_len_q - 1) begin
                            if (!fifo_empty) begin
                                byte_sr <= fifo_rd_data;
                                if (byte_cnt != payload_len_q - 16'd2)
                                    fifo_rd_en <= 1'b1;
                            end else begin
                                underrun_flag <= 1'b1;
                            end
                        end
                    end
                end

                S_FCS: begin
                    if (fcs_cnt == 8'd0) fcs_sr <= {1'b0, crc_out[31:1]};
                    else                 fcs_sr <= {1'b0, fcs_sr[31:1]};
                    fcs_cnt <= fcs_cnt + 1'b1;
                end

                S_DONE: begin
                    busy       <= 1'b0;
                    done_pulse <= 1'b1;
                end

                default: ;
            endcase
        end
    end

endmodule

// =============================================================================
// phy_qam_custom : serial-to-parallel grouper for Path B
// =============================================================================
module phy_qam_custom (
    input  wire       clk,
    input  wire       rst_n,

    input  wire       start_pulse,
    input  wire       end_pulse,
    input  wire [2:0] mod_config,

    input  wire       bit_valid,
    input  wire       bit_in,

    output wire       invalid_mode,

    output reg  [7:0] path_b_symbol,
    output reg        path_b_symbol_valid
);

    reg [3:0] bits_per_sym;
    always @(*) begin
        case (mod_config)
            3'b000 : bits_per_sym = 4'd1;
            3'b001 : bits_per_sym = 4'd2;
            3'b010 : bits_per_sym = 4'd4;
            3'b011 : bits_per_sym = 4'd6;
            3'b100 : bits_per_sym = 4'd8;
            default: bits_per_sym = 4'd0;
        endcase
    end

    assign invalid_mode = (bits_per_sym == 4'd0) && bit_valid;

    reg [7:0] sr;
    reg [3:0] cnt;

    wire [7:0] sr_next = {bit_in, sr[7:1]};

    function [7:0] pack_symbol;
        input [3:0] used_bits;
        input [7:0] shift_reg;
        begin
            case (used_bits)
                4'd1: pack_symbol = {7'd0, shift_reg[7]};
                4'd2: pack_symbol = {6'd0, shift_reg[7:6]};
                4'd3: pack_symbol = {5'd0, shift_reg[7:5]};
                4'd4: pack_symbol = {4'd0, shift_reg[7:4]};
                4'd5: pack_symbol = {3'd0, shift_reg[7:3]};
                4'd6: pack_symbol = {2'd0, shift_reg[7:2]};
                4'd7: pack_symbol = {1'd0, shift_reg[7:1]};
                4'd8: pack_symbol =        shift_reg[7:0];
                default: pack_symbol = 8'd0;
            endcase
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sr                  <= 8'd0;
            cnt                 <= 4'd0;
            path_b_symbol       <= 8'd0;
            path_b_symbol_valid <= 1'b0;
        end else begin
            path_b_symbol_valid <= 1'b0;

            if (start_pulse) begin
                sr  <= 8'd0;
                cnt <= 4'd0;
            end else if (bit_valid && bits_per_sym != 4'd0) begin
                sr  <= sr_next;
                if (cnt + 1'b1 == bits_per_sym) begin
                    cnt <= 4'd0;
                    path_b_symbol <= pack_symbol(bits_per_sym, sr_next);
                    path_b_symbol_valid <= 1'b1;
                end else begin
                    cnt <= cnt + 1'b1;
                end
            end else if (end_pulse && cnt != 4'd0) begin
                path_b_symbol       <= pack_symbol(cnt, sr);
                path_b_symbol_valid <= 1'b1;
                sr                  <= 8'd0;
                cnt                 <= 4'd0;
            end
        end
    end

endmodule

// =============================================================================
// multi_mode_tx_baseband : top-level (two-path TX baseband)
// =============================================================================
module multi_mode_tx_baseband #(
    parameter integer PREAMBLE_SYNC_LEN_A = 128,
    parameter [15:0]  SFD_PATTERN_A       = 16'hF3A0,
    parameter [7:0]   SERVICE_FIELD_A     = 8'h00,
    parameter [6:0]   SCRAMBLER_SEED_A    = 7'h6D,
    parameter [10:0]  BARKER_PATTERN      = 11'b10110111000,
    parameter integer CUSTOM_PREAMBLE_LEN = 32,
    parameter [31:0]  CUSTOM_PREAMBLE_PAT = 32'hAAAAAAAA,
    parameter [6:0]   SCRAMBLER_SEED_B    = 7'h6D,
    parameter integer FIFO_DEPTH          = 32,
    parameter integer FIFO_ADDR_W         = 5
) (
    input  wire        clk_b_chip,
    input  wire        clk_custom,
    input  wire        clk_mcu,
    input  wire        rst_n,

    input  wire        tx_enable,
    input  wire [3:0]  mod_config,
    input  wire [15:0] payload_len,
    input  wire [15:0] length_us,

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

    wire rst_n_mcu_s;
    wire rst_n_b_chip_s;
    wire rst_n_custom_s;

    reset_sync u_rs_mcu    (.clk(clk_mcu),    .async_rst_n(rst_n), .sync_rst_n(rst_n_mcu_s));
    reset_sync u_rs_bchip  (.clk(clk_b_chip), .async_rst_n(rst_n), .sync_rst_n(rst_n_b_chip_s));
    reset_sync u_rs_custom (.clk(clk_custom), .async_rst_n(rst_n), .sync_rst_n(rst_n_custom_s));

    wire path_a_sel = (mod_config[3] == 1'b0);
    reg  mod_valid_c;
    always @(*) begin
        if (path_a_sel)  mod_valid_c = (mod_config[2:0] <= 3'b011);
        else             mod_valid_c = (mod_config[2:0] <= 3'b100);
    end
    wire mod_valid = mod_valid_c;

    wire [1:0] path_a_rate = mod_config[1:0];

    reg tx_enable_q;
    always @(posedge clk_mcu or negedge rst_n_mcu_s) begin
        if (!rst_n_mcu_s) tx_enable_q <= 1'b0;
        else              tx_enable_q <= tx_enable;
    end
    wire tx_enable_pulse_mcu = tx_enable & ~tx_enable_q;

    reg invalid_mode_r;
    always @(posedge clk_mcu or negedge rst_n_mcu_s) begin
        if (!rst_n_mcu_s)                              invalid_mode_r <= 1'b0;
        else if (tx_enable_pulse_mcu && !mod_valid)    invalid_mode_r <= 1'b1;
    end
    assign invalid_mode = invalid_mode_r;

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

    wire rclk_fifo;
    clock_mux_static u_rclk_mux (
        .sel(~path_a_sel),
        .clk0(clk_b_chip),
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

    assign fifo_rd_en = path_a_sel ? a_fifo_rd_en : b_fifo_rd_en;

    assign symbol_out   = path_b_symbol;
    assign symbol_valid = path_a_sel ? 1'b0 : path_b_symbol_valid;
    assign chip_i       = a_chip_i;
    assign chip_q       = a_chip_q;
    assign chip_valid   = path_a_sel ? a_chip_valid_out : 1'b0;

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

    wire _unused = &{1'b0, b_invalid_mode};

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
