// =============================================================================
// mac_fsm_80211b : 802.11b Long PLCP MAC/PLCP engine for 1, 2, 5.5, and 11
// Mbps.  CCK rates use an MCU offload contract: the MCU pre-computes the
// 8-chip CCK symbol pattern in software and ships it as 4 packed FIFO bytes
// per symbol, which this MAC streams straight to phy_a_rotator.
//
//   rate_mode = 2'b00 : 1   Mbps DBPSK + 11-chip Barker (chip computes everything)
//   rate_mode = 2'b01 : 2   Mbps DQPSK + 11-chip Barker (chip computes everything)
//   rate_mode = 2'b10 : 5.5 Mbps CCK   (MCU pre-computes; chip streams)
//   rate_mode = 2'b11 : 11  Mbps CCK   (MCU pre-computes; chip streams)
//
// PLCP framing (always Long preamble per IEEE 802.11-2016 sec 16.2.3):
//   SYNC(128) | SFD(16) | SIGNAL(8) | SERVICE(8) | LENGTH(16) | HEC(16) | PSDU | FCS
//
// SYNC/SFD/SIGNAL/SERVICE/LENGTH/HEC are always 1 Mbps DBPSK + Barker.
// That matches what a commercial 802.11b Long-PLCP receiver expects to
// see for every PSDU rate.
//
// MCU contract for CCK rates:
//   The MCU is responsible for performing, in software:
//     - self-synchronous scrambling (sec 16.2.4) of the payload bitstream;
//     - CRC-32 (sec 16.2.3.6) over the scrambled payload;
//     - 8-chip CCK encoding (sec 16.4.6) of the scrambled-payload + FCS bits;
//     - the sec 16.4.6.3 odd-symbol +pi correction, folded into delta_phi1;
//     - the sec 16.4.6 chip-3 / chip-6 hard-wired +pi, folded into c_k.
//   The chip side never touches scrambler / CRC / Barker for CCK PSDU+FCS;
//   it only replays the QPSK chip phases through phy_a_rotator.
//
// CCK symbol packing (LSB-first across 4 FIFO bytes per CCK symbol):
//   bits[1:0]    = delta_phi1[1:0]    (DQPSK delta for d1, with the
//                                      sec 16.4.6.3 odd-symbol +pi already
//                                      folded in)
//   bits[3:2]    = c_k0[1:0]
//   bits[5:4]    = c_k1[1:0]
//   bits[7:6]    = c_k2[1:0]
//   bits[9:8]    = c_k3[1:0]          (c_k3 already includes +pi)
//   bits[11:10]  = c_k4[1:0]
//   bits[13:12]  = c_k5[1:0]
//   bits[15:14]  = c_k6[1:0]          (c_k6 already includes +pi)
//   bits[17:16]  = c_k7[1:0]
//   bits[31:18]  = reserved (MCU writes 0)
//
//   FIFO bytes consumed per CCK packet = 4 * cck_symbol_count.
//
// MCU-supplied per-packet inputs:
//   length_field    : 16-bit LENGTH for the PLCP header (sec 16.2.3.5).
//                     Used at every rate.
//   service_field   : 8-bit SERVICE byte (sec 16.2.3.4), with LENGTH_EXTENSION
//                     in bit 7 and LOCKED_CLOCKS in bit 2.  Used at every rate.
//   cck_symbol_count: number of 8-chip CCK symbols making up PSDU+FCS.
//                     Used only for CCK rates; ignored for Barker rates.
//
// For Barker rates, payload_len is the raw-payload byte count and the chip
// computes the scrambler / CRC-32 / Barker chip stream on its own.
// =============================================================================
module mac_fsm_80211b #(
    parameter integer PREAMBLE_SYNC_LEN = 128,
    parameter [15:0]  SFD_PATTERN       = 16'hF3A0,
    parameter [6:0]   SCRAMBLER_SEED    = 7'h6D,
    parameter [10:0]  BARKER_PATTERN    = 11'b10110111000
) (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        start_pulse,
    input  wire [1:0]  rate_mode,
    input  wire [15:0] payload_len,
    input  wire [15:0] length_field,
    input  wire [7:0]  service_field,
    input  wire [15:0] cck_symbol_count,

    output reg         busy,
    output reg         done_pulse,

    output wire        fifo_rd_en,
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
        begin
            case (r)
                2'b00:   signal_byte_for_rate = 8'h0A; // 1   Mbps
                2'b01:   signal_byte_for_rate = 8'h14; // 2   Mbps
                2'b10:   signal_byte_for_rate = 8'h37; // 5.5 Mbps
                2'b11:   signal_byte_for_rate = 8'h6E; // 11  Mbps
                default: signal_byte_for_rate = 8'h0A;
            endcase
        end
    endfunction

    localparam [3:0]
        S_IDLE        = 4'd0,
        S_SYNC        = 4'd1,
        S_SFD         = 4'd2,
        S_HEAD        = 4'd3,
        S_HEC         = 4'd4,
        S_PSDU_BARKER = 4'd5,
        S_FCS_BARKER  = 4'd6,
        S_PSDU_CCK    = 4'd7,
        S_DONE        = 4'd8;

    reg [3:0] state, state_next;
    reg [1:0] rate_mode_q;
    wire      cck_active = rate_mode_q[1];

    reg  [3:0] chip_cnt;
    wire [3:0] chip_max     = (state == S_PSDU_CCK) ? 4'd7 : 4'd10;
    wire       symbol_start = (chip_cnt == 4'd0);
    wire       symbol_end   = (chip_cnt == chip_max);

    reg  [15:0] payload_len_q;
    reg  [15:0] cck_sym_count_q;
    reg  [7:0]  sym_cnt;
    reg  [15:0] byte_cnt;
    reg  [15:0] cck_sym_cnt;
    reg  [2:0]  bit_in_byte;

    reg  [7:0]  byte_sr;
    reg  [31:0] header_sr;
    reg  [15:0] sfd_sr;
    reg  [15:0] hec_sr;
    reg  [31:0] fcs_sr;

    // CCK symbol streamer: cck_word_curr feeds the 8 chips of the symbol
    // currently emitting; cck_word_next buffers the next symbol's 4 bytes
    // while the current symbol is still on the wire.
    reg  [31:0] cck_word_curr;
    reg  [31:0] cck_word_next;

    reg         crc_init;

    reg         raw_bit_c;
    reg         raw_bit2_c;
    reg         scramble_c;
    reg         two_bit_sym_c;
    reg         feed_hec_c;
    reg         feed_fcs_c;
    reg         emit_chip_c;

    wire [15:0] hec_out;
    wire [31:0] fcs_out;

    wire [15:0] hec_source = (state == S_HEC        && sym_cnt == 8'd0) ? hec_out : hec_sr;
    wire [31:0] fcs_source = (state == S_FCS_BARKER && sym_cnt == 8'd0) ? fcs_out : fcs_sr;

    always @(*) begin
        raw_bit_c     = 1'b0;
        raw_bit2_c    = 1'b0;
        scramble_c    = 1'b0;
        two_bit_sym_c = 1'b0;
        feed_hec_c    = 1'b0;
        feed_fcs_c    = 1'b0;
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
                two_bit_sym_c = rate_mode_q[0];
                feed_fcs_c    = 1'b1;
                emit_chip_c   = 1'b1;
            end
            S_FCS_BARKER: begin
                raw_bit_c     = fcs_source[0];
                raw_bit2_c    = fcs_source[1];
                scramble_c    = 1'b1;
                two_bit_sym_c = rate_mode_q[0];
                emit_chip_c   = 1'b1;
            end
            S_PSDU_CCK: begin
                // Chip pattern is replayed straight from cck_word_curr; no
                // chip-side scrambler / Barker / CRC engagement.
                emit_chip_c   = 1'b1;
            end
            default: ;
        endcase
    end

    // ------------------------------------------------------------------
    // Self-synchronous scrambler (Barker rates only)
    // ------------------------------------------------------------------
    reg  [6:0] lfsr;
    function scramble_bit_ss;
        input [6:0] state_in;
        input       raw_bit;
        begin
            scramble_bit_ss = raw_bit ^ state_in[6] ^ state_in[3];
        end
    endfunction
    function [6:0] scramble_state_ss;
        input [6:0] state_in;
        input       raw_bit;
        reg         scrambled;
        begin
            scrambled = scramble_bit_ss(state_in, raw_bit);
            scramble_state_ss = {scrambled, state_in[6:1]};
        end
    endfunction

    wire       s0            = scramble_bit_ss(lfsr, raw_bit_c);
    wire [6:0] lfsr_advance1 = scramble_state_ss(lfsr, raw_bit_c);
    wire       s1            = scramble_bit_ss(lfsr_advance1, raw_bit2_c);
    wire [6:0] lfsr_advance2 = scramble_state_ss(lfsr_advance1, raw_bit2_c);

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

    wire barker_chip_bit       = BARKER_PATTERN[10 - chip_cnt[3:0]];
    wire [1:0] base_phase_barker = barker_chip_bit ? 2'b00 : 2'b10;

    // CCK chip-phase mux: pick c_k[chip_cnt] from cck_word_curr.
    // Layout (LSB-first): [delta=1:0][c0=3:2][c1=5:4]...[c7=17:16].
    // Indexed part-select keeps this one expression and avoids the
    // always_comb / case event-ordering ambiguity the earlier version had.
    wire [1:0] cck_chip_phase = cck_word_curr[2 + (chip_cnt[2:0] << 1) +: 2];
    wire [1:0] cck_delta_phi1 = cck_word_curr[1:0];

    // -----------------------------------------------------------------------
    // Combinational FIFO read-enable.
    //
    // fifo_rd_en MUST be combinational so the async FWFT FIFO can advance
    // its rptr on the SAME edge the MAC captures the byte, not a cycle
    // later.  When fifo_rd_en was driven NBA inside the seq always, the
    // FIFO saw the request one cycle late and CCK's 4-consecutive-cycle
    // prefetch ended up reading byte 0 twice and dropping byte 3.
    // -----------------------------------------------------------------------
    wire cck_active_in = rate_mode_q[1];

    wire fifo_rd_en_barker_hec_end =
        (state == S_HEC) && !cck_active_in &&
        (sym_cnt == 8'd15) && symbol_end &&
        (payload_len_q != 16'd0) && (payload_len_q > 16'd1);

    wire fifo_rd_en_barker_psdu =
        (state == S_PSDU_BARKER) && symbol_end &&
        (((!rate_mode_q[0]) && (bit_in_byte == 3'd7)) ||
         (( rate_mode_q[0]) && (bit_in_byte == 3'd6))) &&
        (byte_cnt != payload_len_q - 16'd1) &&
        (byte_cnt != payload_len_q - 16'd2);

    wire fifo_rd_en_cck_hec_pre =
        (state == S_HEC) && cck_active_in &&
        (sym_cnt == 8'd15) &&
        (chip_cnt >= 4'd4) && (chip_cnt <= 4'd7) &&
        (cck_sym_count_q != 16'd0);

    wire fifo_rd_en_cck_psdu_pre =
        (state == S_PSDU_CCK) &&
        (cck_sym_cnt < cck_sym_count_q - 16'd1) &&
        (chip_cnt <= 4'd3);

    assign fifo_rd_en = !fifo_empty &&
                        (fifo_rd_en_barker_hec_end |
                         fifo_rd_en_barker_psdu    |
                         fifo_rd_en_cck_hec_pre    |
                         fifo_rd_en_cck_psdu_pre);

    crc16_80211_hec u_hec (
        .clk       (clk),
        .rst_n     (rst_n),
        .init      (crc_init),
        .data_valid(symbol_start & feed_hec_c),
        .data_bit  (raw_bit_c),
        .crc_out   (hec_out)
    );

    reg fcs_feed_second_cycle;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)                          fcs_feed_second_cycle <= 1'b0;
        else if (symbol_start & feed_fcs_c & two_bit_sym_c)
                                             fcs_feed_second_cycle <= 1'b1;
        else                                 fcs_feed_second_cycle <= 1'b0;
    end

    crc32_80211 u_fcs (
        .clk       (clk),
        .rst_n     (rst_n),
        .init      (crc_init),
        .data_valid((symbol_start & feed_fcs_c) | fcs_feed_second_cycle),
        .data_bit  (fcs_feed_second_cycle ? raw_bit2_c : raw_bit_c),
        .crc_out   (fcs_out)
    );

    // Header is loaded from MCU-supplied LENGTH and SERVICE for all rates.
    wire [31:0] header_load = {
        length_field[15:8],
        length_field[7:0],
        service_field,
        signal_byte_for_rate(rate_mode)
    };

    always @(*) begin
        state_next = state;
        case (state)
            S_IDLE       : if (start_pulse) state_next = S_SYNC;
            S_SYNC       : if (symbol_end && sym_cnt == PREAMBLE_SYNC_LEN - 1) state_next = S_SFD;
            S_SFD        : if (symbol_end && sym_cnt == 8'd15)                 state_next = S_HEAD;
            S_HEAD       : if (symbol_end && sym_cnt == 8'd31)                 state_next = S_HEC;
            S_HEC        : if (symbol_end && sym_cnt == 8'd15) begin
                if (cck_active) begin
                    state_next = (cck_sym_count_q == 16'd0) ? S_DONE : S_PSDU_CCK;
                end else begin
                    state_next = (payload_len_q == 16'd0) ? S_FCS_BARKER : S_PSDU_BARKER;
                end
            end
            S_PSDU_BARKER: begin
                if (symbol_end && byte_cnt == payload_len_q - 16'd1) begin
                    if ((!rate_mode_q[0] && bit_in_byte == 3'd7) ||
                        ( rate_mode_q[0] && bit_in_byte == 3'd6))
                        state_next = S_FCS_BARKER;
                end
            end
            S_FCS_BARKER : begin
                if (symbol_end) begin
                    if ((!rate_mode_q[0] && sym_cnt == 8'd31) ||
                        ( rate_mode_q[0] && sym_cnt == 8'd15))
                        state_next = S_DONE;
                end
            end
            S_PSDU_CCK   : begin
                if (symbol_end && cck_sym_cnt == cck_sym_count_q - 16'd1)
                    state_next = S_DONE;
            end
            S_DONE       : state_next = S_IDLE;
            default      : state_next = S_IDLE;
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state              <= S_IDLE;
            rate_mode_q        <= 2'd0;
            chip_cnt           <= 4'd0;
            sym_cnt            <= 8'd0;
            byte_cnt           <= 16'd0;
            cck_sym_cnt        <= 16'd0;
            bit_in_byte        <= 3'd0;
            payload_len_q      <= 16'd0;
            cck_sym_count_q    <= 16'd0;
            byte_sr            <= 8'd0;
            header_sr          <= 32'd0;
            sfd_sr             <= 16'd0;
            hec_sr             <= 16'd0;
            fcs_sr             <= 32'd0;
            cck_word_curr      <= 32'd0;
            cck_word_next      <= 32'd0;
            lfsr               <= SCRAMBLER_SEED;
            crc_init           <= 1'b0;
            underrun_flag      <= 1'b0;
            base_phase         <= 2'd0;
            delta_phi1         <= 2'd0;
            update_phi1        <= 1'b0;
            chip_valid         <= 1'b0;
            busy               <= 1'b0;
            done_pulse         <= 1'b0;
        end else begin
            state       <= state_next;
            crc_init    <= 1'b0;
            done_pulse  <= 1'b0;
            update_phi1 <= 1'b0;
            chip_valid  <= emit_chip_c;

            // Drive base_phase / delta_phi1 from the rate-appropriate source.
            base_phase  <= (state == S_PSDU_CCK) ? cck_chip_phase : base_phase_barker;
            if (symbol_start && emit_chip_c) begin
                update_phi1 <= 1'b1;
                delta_phi1  <= (state == S_PSDU_CCK) ? cck_delta_phi1 : delta_phi1_barker;
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
                        rate_mode_q     <= rate_mode;
                        payload_len_q   <= payload_len;
                        cck_sym_count_q <= cck_symbol_count;
                        sym_cnt         <= 8'd0;
                        byte_cnt        <= 16'd0;
                        cck_sym_cnt     <= 16'd0;
                        bit_in_byte     <= 3'd0;
                        chip_cnt        <= 4'd0;
                        sfd_sr          <= SFD_PATTERN;
                        header_sr       <= header_load;
                        cck_word_curr   <= 32'd0;
                        cck_word_next   <= 32'd0;
                        lfsr            <= SCRAMBLER_SEED;
                        crc_init        <= 1'b1;
                        underrun_flag   <= 1'b0;
                        busy            <= 1'b1;
                    end
                end

                S_SYNC: begin
                    if (symbol_end) begin
                        sym_cnt <= (sym_cnt == PREAMBLE_SYNC_LEN - 1) ? 8'd0 : sym_cnt + 8'd1;
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
                    // CCK preload: during the LAST HEC symbol's chips 4..7,
                    // pull 4 bytes from the FIFO into cck_word_next so that
                    // chip 0 of S_PSDU_CCK can emit with no bubble.
                    if (cck_active && sym_cnt == 8'd15 &&
                        chip_cnt >= 4'd4 && chip_cnt <= 4'd7 &&
                        cck_sym_count_q != 16'd0) begin
                        if (!fifo_empty) begin
                            case (chip_cnt[1:0])
                                2'd0: cck_word_next[7:0]   <= fifo_rd_data;
                                2'd1: cck_word_next[15:8]  <= fifo_rd_data;
                                2'd2: cck_word_next[23:16] <= fifo_rd_data;
                                2'd3: cck_word_next[31:24] <= fifo_rd_data;
                            endcase
                        end else begin
                            underrun_flag <= 1'b1;
                        end
                    end

                    if (symbol_end) begin
                        if (sym_cnt == 8'd0) hec_sr <= {hec_out[14:0], 1'b0};
                        else                 hec_sr <= {hec_sr[14:0], 1'b0};
                        sym_cnt <= (sym_cnt == 8'd15) ? 8'd0 : sym_cnt + 8'd1;

                        if (sym_cnt == 8'd15) begin
                            if (cck_active) begin
                                cck_word_curr <= cck_word_next;
                                cck_sym_cnt   <= 16'd0;
                            end else if (payload_len_q != 16'd0) begin
                                if (!fifo_empty) begin
                                    byte_sr <= fifo_rd_data;
                                end else begin
                                    underrun_flag <= 1'b1;
                                end
                            end
                        end
                    end
                end

                S_PSDU_BARKER: begin
                    if (symbol_end) begin
                        if ((!rate_mode_q[0] && byte_cnt == payload_len_q - 16'd1 && bit_in_byte == 3'd7) ||
                            ( rate_mode_q[0] && byte_cnt == payload_len_q - 16'd1 && bit_in_byte == 3'd6))
                            sym_cnt <= 8'd0;
                        else
                            sym_cnt <= sym_cnt + 8'd1;

                        if (!rate_mode_q[0]) begin
                            byte_sr     <= {1'b0, byte_sr[7:1]};
                            bit_in_byte <= bit_in_byte + 3'd1;
                            if (bit_in_byte == 3'd7) begin
                                byte_cnt <= byte_cnt + 16'd1;
                                if (byte_cnt != payload_len_q - 16'd1) begin
                                    if (!fifo_empty) begin
                                        byte_sr <= fifo_rd_data;
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
                        if (!rate_mode_q[0]) begin
                            if (sym_cnt == 8'd0) fcs_sr <= {1'b0, fcs_out[31:1]};
                            else                 fcs_sr <= {1'b0, fcs_sr[31:1]};
                        end else begin
                            if (sym_cnt == 8'd0) fcs_sr <= {2'b00, fcs_out[31:2]};
                            else                 fcs_sr <= {2'b00, fcs_sr[31:2]};
                        end
                    end
                end

                S_PSDU_CCK: begin
                    // Concurrent prefetch: while chips 0..3 of the CURRENT
                    // symbol emit, pull bytes 0..3 of the NEXT symbol from
                    // the FIFO.  Skip on the final symbol.
                    if (cck_sym_cnt < cck_sym_count_q - 16'd1 && chip_cnt <= 4'd3) begin
                        if (!fifo_empty) begin
                            case (chip_cnt[1:0])
                                2'd0: cck_word_next[7:0]   <= fifo_rd_data;
                                2'd1: cck_word_next[15:8]  <= fifo_rd_data;
                                2'd2: cck_word_next[23:16] <= fifo_rd_data;
                                2'd3: cck_word_next[31:24] <= fifo_rd_data;
                            endcase
                        end else begin
                            underrun_flag <= 1'b1;
                        end
                    end

                    if (symbol_end) begin
                        if (cck_sym_cnt < cck_sym_count_q - 16'd1) begin
                            cck_word_curr <= cck_word_next;
                            cck_sym_cnt   <= cck_sym_cnt + 16'd1;
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
