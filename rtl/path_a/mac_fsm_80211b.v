// =============================================================================
// mac_fsm_80211b : 802.11b Long PLCP MAC/PLCP engine for all four rates.
//
//   mod_config[1:0]
//     00 : 1 Mbps DBPSK + Barker (11 chips/sym, 1 bit/sym)
//     01 : 2 Mbps DQPSK + Barker (11 chips/sym, 2 bit/sym)
//     10 : 5.5 Mbps CCK          ( 8 chips/sym, 4 data bits/sym)
//     11 : 11 Mbps CCK           ( 8 chips/sym, 8 data bits/sym)
//
// Clock domain: `clk_b_chip` (11 MHz) -- the MAC now runs in the chip
// domain, emits one chip's worth of `base_phase` / `delta_phi1` /
// `update_phi1` to the rotator PHY every 11 MHz cycle, and tracks a
// per-state chip counter (0..10 for Barker, 0..7 for CCK).
//
// Scrambler / CRC strategy:
//
//   - SCRAMBLER, CRC-16 HEC and CRC-32 FCS run on chip for 1/2 Mbps.
//     Scrambler is initialized at packet start; all 192 preamble+header
//     bits are scrambled; continues into PSDU/FCS for 1/2 Mbps.
//   - For CCK PSDU (5.5 / 11 Mbps), the MCU has already applied
//     scrambler + FCS off-chip and pre-encoded each CCK symbol as a
//     16-bit word { c6, c5, c4, c3, c2, c1, c0, delta_phi1 } (little-
//     endian across two FIFO bytes).  The chip-side scrambler/CRC are
//     held idle during S_PSDU_CCK; the MCU is responsible for starting
//     its own scrambler from the deterministic state reached at end of
//     header (seed + 192 advances).
//
// PLCP framing (Long PLCP, 802.11-2016 sec 16.2.2):
//   SYNC(128) | SFD(16) | SIGNAL(8) | SERVICE(8) | LENGTH(16) | HEC(16) | PSDU+FCS
//   - Preamble + header are ALWAYS 1 Mbps DBPSK + Barker.
//   - PSDU portion's PHY encoding depends on mod_config.
// =============================================================================
module mac_fsm_80211b #(
    parameter integer PREAMBLE_SYNC_LEN = 128,
    parameter [15:0]  SFD_PATTERN       = 16'hF3A0,
    parameter [7:0]   SERVICE_FIELD     = 8'h00,      // bit[2] advertises locked clocks
    parameter [6:0]   SCRAMBLER_SEED    = 7'h6D,
    parameter [10:0]  BARKER_PATTERN    = 11'b10110111000
) (
    input  wire        clk,                          // clk_b_chip
    input  wire        rst_n,

    input  wire        start_pulse,
    input  wire [1:0]  rate,                         // mod_config[1:0]
    input  wire [15:0] payload_len,                  // PSDU octets (excl FCS)
    input  wire [15:0] length_us,                    // MCU-computed LENGTH field

    output reg         busy,
    output reg         done_pulse,

    // FIFO read port
    output reg         fifo_rd_en,
    input  wire        fifo_empty,
    input  wire [7:0]  fifo_rd_data,
    output reg         underrun_flag,

    // To PHY rotator
    output reg  [1:0]  base_phase,
    output reg  [1:0]  delta_phi1,
    output reg         update_phi1,
    output reg         chip_valid
);

    // ------------------------------------------------------------------
    // SIGNAL byte lookup (802.11-2016 sec 16.2.3.4)
    // ------------------------------------------------------------------
    function [7:0] signal_byte_for_rate;
        input [1:0] r;
        case (r)
            2'b00  : signal_byte_for_rate = 8'h0A;   // 1 Mbps DBPSK
            2'b01  : signal_byte_for_rate = 8'h14;   // 2 Mbps DQPSK
            2'b10  : signal_byte_for_rate = 8'h37;   // 5.5 Mbps CCK
            2'b11  : signal_byte_for_rate = 8'h6E;   // 11 Mbps CCK
            default: signal_byte_for_rate = 8'h0A;
        endcase
    endfunction

    // ------------------------------------------------------------------
    // States
    // ------------------------------------------------------------------
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

    // Chip-within-symbol counter and its max (10 for Barker, 7 for CCK).
    reg  [3:0] chip_cnt;
    wire [3:0] chip_cnt_max = (state == S_PSDU_CCK) ? 4'd7 : 4'd10;
    wire       symbol_start = (chip_cnt == 4'd0);
    wire       symbol_end   = (chip_cnt == chip_cnt_max);

    // Symbol-level bookkeeping
    reg [15:0] payload_len_q;
    reg [15:0] length_us_q;
    reg [7:0]  sym_cnt;        // covers up to 128 (SYNC)
    reg [15:0] byte_cnt;
    reg [2:0]  bit_in_byte;
    reg [15:0] cck_sym_total;  // total CCK symbols for PSDU+FCS
    reg [15:0] cck_sym_cnt;

    // Per-state shift registers
    reg [7:0]  byte_sr;
    reg [31:0] header_sr;
    reg [15:0] sfd_sr;
    reg [15:0] hec_sr;
    reg [31:0] fcs_sr;

    // CCK symbol word latched from 2 FIFO bytes: {c6,c5,c4,c3,c2,c1,c0,delta_phi1}
    reg [15:0] cck_word;

    // ------------------------------------------------------------------
    // CRCs (only valid for 1/2 Mbps; idle for CCK)
    // ------------------------------------------------------------------
    reg         crc_init;
    wire [15:0] hec_out;
    wire [31:0] fcs_out;

    // ------------------------------------------------------------------
    // Combinational per-symbol "what raw bit(s) are we emitting?"
    // ------------------------------------------------------------------
    reg        raw_bit_c;         // first/only bit of the symbol (for DBPSK, SYNC, SFD, HEAD, HEC, FCS)
    reg        raw_bit2_c;        // second bit of the symbol (DQPSK only)
    reg        scramble_c;        // XOR with LFSR before using
    reg        two_bit_sym_c;     // DQPSK: symbol has 2 data bits
    reg        feed_hec_c;        // this symbol's raw bit feeds HEC CRC
    reg        feed_fcs_c;        // this symbol's raw bit feeds FCS CRC
    reg        cck_mode_c;        // CCK PSDU: use cck_word, not Barker
    reg        emit_chip_c;       // there is a valid chip to emit this cycle

    // First-cycle detection for loading CRC output into the shift reg.
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
                raw_bit_c   = sfd_sr[15];        // MSB first
                scramble_c  = 1'b1;
                emit_chip_c = 1'b1;
            end
            S_HEAD: begin
                raw_bit_c   = header_sr[0];      // LSB first per octet
                scramble_c  = 1'b1;
                feed_hec_c  = 1'b1;
                emit_chip_c = 1'b1;
            end
            S_HEC: begin
                raw_bit_c   = hec_source[15];    // MSB first
                scramble_c  = 1'b1;
                emit_chip_c = 1'b1;
            end
            S_PSDU_BARKER: begin
                raw_bit_c     = byte_sr[0];
                raw_bit2_c    = byte_sr[1];
                scramble_c    = 1'b1;
                two_bit_sym_c = (rate_q == 2'b01);  // DQPSK takes 2 bits
                feed_fcs_c    = 1'b1;
                emit_chip_c   = 1'b1;
            end
            S_FCS_BARKER: begin
                raw_bit_c     = fcs_source[0];     // LSB first
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

    // ------------------------------------------------------------------
    // Self-synchronous scrambler state (x^7 + x^4 + 1).  Advances at
    // symbol_start for states where scramble_c is asserted, by 1 step
    // (DBPSK-like) or 2 serialized steps (DQPSK) per symbol.  Idle
    // during S_PSDU_CCK because the MCU precomputes the CCK payload path.
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

    // delta_phi1 for Barker-based symbols.
    // DBPSK (1 bit):  0 -> +0 (phase delta 0),    1 -> +pi (phase delta 2)
    // DQPSK (dibit): IEEE 802.11b Table 11, with s0 transmitted first:
    //   s0 s1 = 00 -> 0, 01 -> +pi/2, 11 -> +pi, 10 -> +3pi/2.
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

    // Barker base phase for chip_cnt: '1'-chip -> phase 0, '0'-chip -> phase 2.
    wire barker_chip_bit = BARKER_PATTERN[10 - chip_cnt[3:0]];
    wire [1:0] base_phase_barker = barker_chip_bit ? 2'b00 : 2'b10;

    // CCK: base_phase = c_k from the latched cck_word; c7 is always 0.
    //   c0 is bits [3:2], c1 [5:4], ... c6 [15:14].
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
            3'd7: base_phase_cck = 2'b00;        // c7 = 0 by construction
            default: base_phase_cck = 2'b00;
        endcase
    end

    // CCK delta_phi1 at symbol_start comes from the low 2 bits of cck_word.
    wire [1:0] delta_phi1_cck = cck_word[1:0];

    // ------------------------------------------------------------------
    // HEC / FCS instances
    // ------------------------------------------------------------------
    crc16_80211_hec u_hec (
        .clk(clk), .rst_n(rst_n), .init(crc_init),
        .data_valid(symbol_start & feed_hec_c),
        .data_bit  (raw_bit_c),
        .crc_out   (hec_out)
    );

    // CRC-32 FCS: for DQPSK we feed 2 bits per symbol; need to advance twice.
    // Easiest: feed s0 at symbol_start and s1 on the next cycle when two_bit_sym_c.
    // Implemented with a 1-shot delayed valid signal.
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

    // ------------------------------------------------------------------
    // Header-field load value (LSB-first byte order)
    // ------------------------------------------------------------------
    function service_length_ext_bit;
        input [1:0]  r;
        input [15:0] payload_octets;
        input [15:0] tx_length_us;
        reg   [16:0] total_octets;
        reg   [20:0] rx_octets_no_ext;
        begin
            if (r == 2'b11) begin
                total_octets     = {1'b0, payload_octets} + 17'd4;
                rx_octets_no_ext = ({5'd0, tx_length_us} * 5'd11) >> 3;
                service_length_ext_bit = (rx_octets_no_ext > total_octets);
            end else begin
                service_length_ext_bit = 1'b0;
            end
        end
    endfunction
    wire [7:0]  signal_byte_c  = signal_byte_for_rate(rate);
    wire [7:0]  service_byte_c =
        { service_length_ext_bit(rate, payload_len, length_us),
          3'b000,
          1'b0,
          SERVICE_FIELD[2],
          2'b00 };
    wire [31:0] header_load    = { length_us[15:8], length_us[7:0], service_byte_c, signal_byte_c };

    // ------------------------------------------------------------------
    // Total CCK symbol count for PSDU+FCS.
    //   CCK-11: (payload_len*8 + 32) / 8 = payload_len + 4
    //   CCK-5.5:(payload_len*8 + 32) / 4 = 2*payload_len + 8
    // ------------------------------------------------------------------
    wire [15:0] cck_sym_total_load =
        (rate == 2'b11) ? (payload_len + 16'd4)
                        : ({payload_len, 1'b0} + 16'd8);  // 2*payload_len + 8

    // ------------------------------------------------------------------
    // Next-state logic
    // ------------------------------------------------------------------
    always @(*) begin
        state_next = state;
        case (state)
            S_IDLE: if (start_pulse) state_next = S_SYNC;
            S_SYNC: if (symbol_end && sym_cnt == PREAMBLE_SYNC_LEN - 1) state_next = S_SFD;
            S_SFD : if (symbol_end && sym_cnt == 8'd15)                 state_next = S_HEAD;
            S_HEAD: if (symbol_end && sym_cnt == 8'd31)                 state_next = S_HEC;
            S_HEC : if (symbol_end && sym_cnt == 8'd15) begin
                if (rate_q[1])  // CCK rates
                    state_next = S_PSDU_CCK;
                else if (payload_len_q == 16'd0)
                    state_next = S_FCS_BARKER;
                else
                    state_next = S_PSDU_BARKER;
            end
            S_PSDU_BARKER: begin
                // DBPSK: 8 bits per byte, DQPSK: 4 dibits per byte.
                if (symbol_end && byte_cnt == payload_len_q - 16'd1) begin
                    if ((rate_q == 2'b00 && bit_in_byte == 3'd7) ||
                        (rate_q == 2'b01 && bit_in_byte == 3'd6))
                        state_next = S_FCS_BARKER;
                end
            end
            S_FCS_BARKER: begin
                // DBPSK: 32 symbols; DQPSK: 16 symbols.
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

    // ------------------------------------------------------------------
    // Sequential update
    // ------------------------------------------------------------------
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

            // ----- Per-chip PHY drive -----
            base_phase <= cck_mode_c ? base_phase_cck : base_phase_barker;
            if (symbol_start && emit_chip_c) begin
                update_phi1 <= 1'b1;
                delta_phi1  <= cck_mode_c ? delta_phi1_cck : delta_phi1_barker;
            end

            // ----- Scrambler advance at symbol_start (Barker states only) -----
            if (symbol_start && scramble_c) begin
                lfsr <= two_bit_sym_c ? lfsr_advance2 : lfsr_advance1;
            end

            // ----- Chip counter -----
            if (symbol_end) chip_cnt <= 4'd0;
            else            chip_cnt <= chip_cnt + 4'd1;

            // ----- State-specific bookkeeping (only at symbol_end, when we
            //       advance to the next symbol, do we update sym_cnt et al) -----
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
                                fifo_rd_en    <= 1'b1;   // advance to the first symbol's high byte
                            end else begin
                                underrun_flag <= 1'b1;
                            end
                        end
                    end
                end

                S_PSDU_BARKER: begin
                    if (symbol_end) begin
                        // sym_cnt tracks symbols within S_PSDU_BARKER for
                        // diagnostic purposes; more importantly, reset to 0
                        // on the final PSDU symbol so `S_FCS_BARKER` enters
                        // with sym_cnt == 0 (first_fcs_cycle detection).
                        if ((rate_q == 2'b00 && byte_cnt == payload_len_q - 16'd1 && bit_in_byte == 3'd7) ||
                            (rate_q == 2'b01 && byte_cnt == payload_len_q - 16'd1 && bit_in_byte == 3'd6))
                            sym_cnt <= 8'd0;
                        else
                            sym_cnt <= sym_cnt + 8'd1;

                        if (rate_q == 2'b00) begin
                            // DBPSK: 1 bit per symbol, 8 bits per byte.
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
                            // DQPSK: 2 bits per symbol, 4 dibits per byte.
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
                            // DQPSK consumes 2 bits per symbol.
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
                                fifo_rd_en    <= 1'b1;  // advance next symbol low -> high
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
