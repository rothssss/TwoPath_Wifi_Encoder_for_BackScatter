// =============================================================================
// mac_fsm_80211b : 802.11b Long PLCP MAC/PLCP engine for 1 and 2 Mbps only.
//
//   rate = 1'b0 : 1 Mbps DBPSK + 11-chip Barker
//   rate = 1'b1 : 2 Mbps DQPSK + 11-chip Barker
//
// The cut-down Wi-Fi-only variant removes:
//   * 5.5 / 11 Mbps CCK support
//   * the off-chip CCK payload contract
//   * external LENGTH-field input for higher-rate rounding
//
// PLCP framing remains standards-facing for the retained rates:
//   SYNC(128) | SFD(16) | SIGNAL(8) | SERVICE(8) | LENGTH(16) | HEC(16) | PSDU | FCS
//
// Preamble + header are always scrambled and transmitted as DBPSK+Barker.
// PSDU and FCS are scrambled and CRC-32 protected on chip.
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
    input  wire        rate,
    input  wire [15:0] payload_len,

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
        input r;
        begin
            signal_byte_for_rate = r ? 8'h14 : 8'h0A;
        end
    endfunction

    localparam [2:0]
        S_IDLE        = 3'd0,
        S_SYNC        = 3'd1,
        S_SFD         = 3'd2,
        S_HEAD        = 3'd3,
        S_HEC         = 3'd4,
        S_PSDU_BARKER = 3'd5,
        S_FCS_BARKER  = 3'd6,
        S_DONE        = 3'd7;

    reg [2:0] state, state_next;
    reg       rate_q;

    reg  [3:0] chip_cnt;
    wire       symbol_start = (chip_cnt == 4'd0);
    wire       symbol_end   = (chip_cnt == 4'd10);

    reg  [15:0] payload_len_q;
    reg  [7:0]  sym_cnt;
    reg  [15:0] byte_cnt;
    reg  [2:0]  bit_in_byte;

    reg  [7:0]  byte_sr;
    reg  [31:0] header_sr;
    reg  [15:0] sfd_sr;
    reg  [15:0] hec_sr;
    reg  [31:0] fcs_sr;

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
                two_bit_sym_c = rate_q;
                feed_fcs_c    = 1'b1;
                emit_chip_c   = 1'b1;
            end
            S_FCS_BARKER: begin
                raw_bit_c     = fcs_source[0];
                raw_bit2_c    = fcs_source[1];
                scramble_c    = 1'b1;
                two_bit_sym_c = rate_q;
                emit_chip_c   = 1'b1;
            end
            default: ;
        endcase
    end

    // ------------------------------------------------------------------
    // Self-synchronous scrambler
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

    wire barker_chip_bit = BARKER_PATTERN[10 - chip_cnt[3:0]];
    wire [1:0] base_phase_barker = barker_chip_bit ? 2'b00 : 2'b10;

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

    // LENGTH is cheap again for the retained rates:
    //   1 Mbps -> 8 * payload_len us
    //   2 Mbps -> 4 * payload_len us
    wire [15:0] length_field_c = rate ? (payload_len << 2) : (payload_len << 3);
    wire [31:0] header_load = {
        length_field_c[15:8],
        length_field_c[7:0],
        SERVICE_FIELD,
        signal_byte_for_rate(rate)
    };

    always @(*) begin
        state_next = state;
        case (state)
            S_IDLE       : if (start_pulse) state_next = S_SYNC;
            S_SYNC       : if (symbol_end && sym_cnt == PREAMBLE_SYNC_LEN - 1) state_next = S_SFD;
            S_SFD        : if (symbol_end && sym_cnt == 8'd15)                 state_next = S_HEAD;
            S_HEAD       : if (symbol_end && sym_cnt == 8'd31)                 state_next = S_HEC;
            S_HEC        : if (symbol_end && sym_cnt == 8'd15)
                               state_next = (payload_len_q == 16'd0) ? S_FCS_BARKER : S_PSDU_BARKER;
            S_PSDU_BARKER: begin
                if (symbol_end && byte_cnt == payload_len_q - 16'd1) begin
                    if ((!rate_q && bit_in_byte == 3'd7) ||
                        ( rate_q && bit_in_byte == 3'd6))
                        state_next = S_FCS_BARKER;
                end
            end
            S_FCS_BARKER : begin
                if (symbol_end) begin
                    if ((!rate_q && sym_cnt == 8'd31) ||
                        ( rate_q && sym_cnt == 8'd15))
                        state_next = S_DONE;
                end
            end
            S_DONE       : state_next = S_IDLE;
            default      : state_next = S_IDLE;
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state              <= S_IDLE;
            rate_q             <= 1'b0;
            chip_cnt           <= 4'd0;
            sym_cnt            <= 8'd0;
            byte_cnt           <= 16'd0;
            bit_in_byte        <= 3'd0;
            payload_len_q      <= 16'd0;
            byte_sr            <= 8'd0;
            header_sr          <= 32'd0;
            sfd_sr             <= 16'd0;
            hec_sr             <= 16'd0;
            fcs_sr             <= 32'd0;
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

            base_phase <= base_phase_barker;
            if (symbol_start && emit_chip_c) begin
                update_phi1 <= 1'b1;
                delta_phi1  <= delta_phi1_barker;
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
                        rate_q        <= rate;
                        payload_len_q <= payload_len;
                        sym_cnt       <= 8'd0;
                        byte_cnt      <= 16'd0;
                        bit_in_byte   <= 3'd0;
                        chip_cnt      <= 4'd0;
                        sfd_sr        <= SFD_PATTERN;
                        header_sr     <= header_load;
                        lfsr          <= SCRAMBLER_SEED;
                        crc_init      <= 1'b1;
                        underrun_flag <= 1'b0;
                        busy          <= 1'b1;
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
                    if (symbol_end) begin
                        if (sym_cnt == 8'd0) hec_sr <= {hec_out[14:0], 1'b0};
                        else                 hec_sr <= {hec_sr[14:0], 1'b0};
                        sym_cnt <= (sym_cnt == 8'd15) ? 8'd0 : sym_cnt + 8'd1;

                        if (sym_cnt == 8'd15 && payload_len_q != 16'd0) begin
                            if (!fifo_empty) begin
                                byte_sr <= fifo_rd_data;
                                if (payload_len_q > 16'd1) fifo_rd_en <= 1'b1;
                            end else begin
                                underrun_flag <= 1'b1;
                            end
                        end
                    end
                end

                S_PSDU_BARKER: begin
                    if (symbol_end) begin
                        if ((!rate_q && byte_cnt == payload_len_q - 16'd1 && bit_in_byte == 3'd7) ||
                            ( rate_q && byte_cnt == payload_len_q - 16'd1 && bit_in_byte == 3'd6))
                            sym_cnt <= 8'd0;
                        else
                            sym_cnt <= sym_cnt + 8'd1;

                        if (!rate_q) begin
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
                        if (!rate_q) begin
                            if (sym_cnt == 8'd0) fcs_sr <= {1'b0, fcs_out[31:1]};
                            else                 fcs_sr <= {1'b0, fcs_sr[31:1]};
                        end else begin
                            if (sym_cnt == 8'd0) fcs_sr <= {2'b00, fcs_out[31:2]};
                            else                 fcs_sr <= {2'b00, fcs_sr[31:2]};
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
