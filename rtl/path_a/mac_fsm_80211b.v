// =============================================================================
// mac_fsm_80211b : 802.11b (Path A) MAC engine running on clk_b_data (1 MHz).
//
// Emits exactly one scrambled information bit per `bit_valid` cycle.  The
// downstream phase-aligned handshake forwards this bit to the 11 MHz chip-
// rate Barker spreader (11 chips per bit).
//
// Packet format (spec Q1-Q6, all tunable by parameter):
//   PREAMBLE_SYNC  : PREAMBLE_SYNC_LEN bits of 1, RAW (no scramble)      [Q2]
//   PREAMBLE_SFD   : 16 bits of SFD_PATTERN, LSB-first, RAW              [Q2]
//   HEADER         : HEADER_LEN bits of HEADER_CONST, LSB-first,
//                    scrambled, fed into CRC                             [Q1,Q6]
//   PAYLOAD        : payload_len bytes, LSB-first within each byte,
//                    scrambled, fed into CRC                             [Q3]
//   FCS            : 32-bit finalized CRC-32 (after XorOut), LSB-first,
//                    scrambled, NOT CRC-fed                              [Q4]
//
// Outputs are registered one cycle after the combinational compute.
// =============================================================================
module mac_fsm_80211b #(
    parameter integer PREAMBLE_SYNC_LEN = 128,
    parameter integer HEADER_LEN        = 48,
    parameter [15:0]  SFD_PATTERN       = 16'hF3A0,
    parameter [47:0]  HEADER_CONST      = 48'h000000000000,
    parameter [6:0]   SCRAMBLER_SEED    = 7'h5D
) (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        start_pulse,
    input  wire [15:0] payload_len,
    output reg         busy,
    output reg         done_pulse,

    // FWFT FIFO read port (rd_data shows current word; rd_en advances).
    output reg         fifo_rd_en,
    input  wire        fifo_empty,
    input  wire [7:0]  fifo_rd_data,
    output reg         underrun_flag,

    // Scrambled output bit stream.
    output reg         bit_valid,
    output reg         bit_out
);

    // -----------------------------------------------------------------------
    // State encoding
    // -----------------------------------------------------------------------
    localparam [2:0]
        S_IDLE          = 3'd0,
        S_PREAMBLE_SYNC = 3'd1,
        S_PREAMBLE_SFD  = 3'd2,
        S_HEADER        = 3'd3,
        S_PAYLOAD       = 3'd4,
        S_FCS           = 3'd5,
        S_DONE          = 3'd6;

    reg [2:0] state, state_next;

    reg [7:0]  bit_cnt;       // covers PREAMBLE_SYNC_LEN (up to 255).
    reg [15:0] byte_cnt;
    reg [2:0]  bit_in_byte;
    reg [15:0] payload_len_q;
    reg [7:0]  byte_sr;
    reg [47:0] header_sr;
    reg [15:0] sfd_sr;
    reg [31:0] fcs_sr;

    // -----------------------------------------------------------------------
    // CRC
    // -----------------------------------------------------------------------
    reg         crc_init;
    wire [31:0] crc_out;

    // -----------------------------------------------------------------------
    // Combinational "next bit" datapath
    // -----------------------------------------------------------------------
    reg  raw_bit_c;
    reg  scramble_c;
    reg  feed_crc_c;
    reg  valid_c;

    // On the FIRST cycle of S_FCS, the fcs_sr has not yet been loaded (it is
    // loaded from crc_out on this same edge), so the bit we emit this cycle
    // must come directly from crc_out[0].  On subsequent cycles, the already
    // loaded/shifted fcs_sr is used.
    wire first_fcs_cycle = (state == S_FCS) && (bit_cnt == 8'd0);
    wire [31:0] fcs_source = first_fcs_cycle ? crc_out : fcs_sr;

    always @(*) begin
        raw_bit_c  = 1'b0;
        scramble_c = 1'b0;
        feed_crc_c = 1'b0;
        valid_c    = 1'b0;
        case (state)
            S_PREAMBLE_SYNC: begin
                raw_bit_c = 1'b1;
                valid_c   = 1'b1;
            end
            S_PREAMBLE_SFD: begin
                raw_bit_c = sfd_sr[0];
                valid_c   = 1'b1;
            end
            S_HEADER: begin
                raw_bit_c  = header_sr[0];
                scramble_c = 1'b1;
                feed_crc_c = 1'b1;
                valid_c    = 1'b1;
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

    crc32_80211 u_crc (
        .clk        (clk),
        .rst_n      (rst_n),
        .init       (crc_init),
        .data_valid (valid_c & feed_crc_c),
        .data_bit   (raw_bit_c),
        .crc_out    (crc_out)
    );

    // -----------------------------------------------------------------------
    // Scrambler LFSR (x^7 + x^4 + 1) advanced on scrambled bits only [Q6].
    // -----------------------------------------------------------------------
    reg  [6:0] lfsr;
    wire       lfsr_feedback = lfsr[6] ^ lfsr[3];
    wire       scrambled_bit = raw_bit_c ^ lfsr[6];

    // -----------------------------------------------------------------------
    // Next-state logic
    // -----------------------------------------------------------------------
    always @(*) begin
        state_next = state;
        case (state)
            S_IDLE          : if (start_pulse)                          state_next = S_PREAMBLE_SYNC;
            S_PREAMBLE_SYNC : if (bit_cnt == PREAMBLE_SYNC_LEN - 1)     state_next = S_PREAMBLE_SFD;
            S_PREAMBLE_SFD  : if (bit_cnt == 16 - 1)                    state_next = S_HEADER;
            S_HEADER        : if (bit_cnt == HEADER_LEN - 1)
                                  state_next = (payload_len_q == 16'd0) ? S_FCS : S_PAYLOAD;
            S_PAYLOAD       : if ((byte_cnt == payload_len_q - 1) &&
                                  (bit_in_byte == 3'd7))                state_next = S_FCS;
            S_FCS           : if (bit_cnt == 32 - 1)                    state_next = S_DONE;
            S_DONE          :                                           state_next = S_IDLE;
            default         :                                           state_next = S_IDLE;
        endcase
    end

    // -----------------------------------------------------------------------
    // Sequential update
    // -----------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state         <= S_IDLE;
            bit_cnt       <= 8'd0;
            byte_cnt      <= 16'd0;
            bit_in_byte   <= 3'd0;
            payload_len_q <= 16'd0;
            byte_sr       <= 8'd0;
            header_sr     <= 48'd0;
            sfd_sr        <= 16'd0;
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

            // Default single-cycle strobes
            fifo_rd_en <= 1'b0;
            crc_init   <= 1'b0;
            done_pulse <= 1'b0;

            // Registered bit stream (1-cycle latency from combinational).
            bit_valid <= valid_c;
            bit_out   <= scramble_c ? scrambled_bit : raw_bit_c;

            // Scrambler advances only on cycles where a scrambled bit is
            // emitted (SYNC/SFD do not advance the LFSR) [Q6].
            if (valid_c && scramble_c) begin
                lfsr <= {lfsr[5:0], lfsr_feedback};
            end

            // -----------------------------------------------------------
            // Per-state bookkeeping
            // -----------------------------------------------------------
            case (state)
                S_IDLE: begin
                    busy <= 1'b0;
                    if (start_pulse) begin
                        payload_len_q <= payload_len;
                        bit_cnt       <= 8'd0;
                        byte_cnt      <= 16'd0;
                        bit_in_byte   <= 3'd0;
                        sfd_sr        <= SFD_PATTERN;
                        header_sr     <= HEADER_CONST;
                        lfsr          <= SCRAMBLER_SEED;
                        crc_init      <= 1'b1;
                        underrun_flag <= 1'b0;
                        busy          <= 1'b1;
                    end
                end

                S_PREAMBLE_SYNC: begin
                    bit_cnt <= (bit_cnt == PREAMBLE_SYNC_LEN - 1) ? 8'd0
                                                                  : bit_cnt + 1'b1;
                end

                S_PREAMBLE_SFD: begin
                    sfd_sr  <= {1'b0, sfd_sr[15:1]};
                    bit_cnt <= (bit_cnt == 16 - 1) ? 8'd0 : bit_cnt + 1'b1;
                end

                S_HEADER: begin
                    header_sr <= {1'b0, header_sr[47:1]};
                    bit_cnt   <= (bit_cnt == HEADER_LEN - 1) ? 8'd0
                                                             : bit_cnt + 1'b1;

                    // Prefetch first payload byte one cycle before PAYLOAD.
                    if ((bit_cnt == HEADER_LEN - 2) && (payload_len_q != 16'd0)) begin
                        if (!fifo_empty) fifo_rd_en    <= 1'b1;
                        else             underrun_flag <= 1'b1;
                    end
                    if ((bit_cnt == HEADER_LEN - 1) && (payload_len_q != 16'd0)) begin
                        byte_sr <= fifo_rd_data;
                    end
                end

                S_PAYLOAD: begin
                    byte_sr     <= {1'b0, byte_sr[7:1]};
                    bit_in_byte <= bit_in_byte + 1'b1;

                    if ((bit_in_byte == 3'd6) && (byte_cnt != payload_len_q - 1)) begin
                        if (!fifo_empty) fifo_rd_en    <= 1'b1;
                        else             underrun_flag <= 1'b1;
                    end
                    if (bit_in_byte == 3'd7) begin
                        byte_cnt <= byte_cnt + 1'b1;
                        if (byte_cnt != payload_len_q - 1) begin
                            byte_sr <= fifo_rd_data;
                        end
                    end
                end

                S_FCS: begin
                    // On the first FCS cycle, the raw bit on the wire
                    // (crc_out[0]) is already correct via fcs_source mux.
                    // We simultaneously latch the rest of crc_out into
                    // fcs_sr so subsequent cycles shift it out.
                    if (bit_cnt == 8'd0) fcs_sr <= {1'b0, crc_out[31:1]};
                    else                 fcs_sr <= {1'b0, fcs_sr[31:1]};
                    bit_cnt <= (bit_cnt == 32 - 1) ? 8'd0 : bit_cnt + 1'b1;
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
