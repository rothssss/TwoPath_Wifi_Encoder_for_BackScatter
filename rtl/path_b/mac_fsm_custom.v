// =============================================================================
// mac_fsm_custom : Custom (Path B) MAC engine running on clk_custom (up to
// 100 MHz).  Produces one scrambled information bit per `bit_valid` cycle;
// the PHY S2P grouper accumulates these bits into QAM symbols.
//
// Packet format (spec questions Q9, Q10):
//   CUSTOM_PREAMBLE : CUSTOM_PREAMBLE_LEN bits of CUSTOM_PREAMBLE_PAT
//                     (LSB-first), RAW (not scrambled, not CRC-fed).  Used
//                     by the receiver for AGC and symbol-timing recovery.
//   PAYLOAD         : payload_len bytes, LSB-first, scrambled, CRC-fed.
//   FCS             : 32-bit finalized CRC-32, LSB-first, scrambled, NOT
//                     CRC-fed.
//
// The CRC and scrambler are fresh instances (separate from Path A), per MAS
// sec 4 Block C.  They are reset/reseeded on every `start_pulse`.
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

    // FWFT FIFO read port
    output reg         fifo_rd_en,
    input  wire        fifo_empty,
    input  wire [7:0]  fifo_rd_data,
    output reg         underrun_flag,

    // One bit per `bit_valid` cycle (scrambled from HEADER onwards).
    output reg         bit_valid,
    output reg         bit_out
);

    // -----------------------------------------------------------------------
    // State
    // -----------------------------------------------------------------------
    localparam [2:0]
        S_IDLE           = 3'd0,
        S_PREAMBLE       = 3'd1,
        S_PAYLOAD        = 3'd2,
        S_FCS            = 3'd3,
        S_DONE           = 3'd4;

    reg [2:0] state, state_next;

    reg [15:0] preamble_cnt;    // must cover CUSTOM_PREAMBLE_LEN (<=65535).
    reg [7:0]  fcs_cnt;         // 0..31 for FCS.
    reg [15:0] byte_cnt;
    reg [2:0]  bit_in_byte;
    reg [15:0] payload_len_q;
    reg [7:0]  byte_sr;
    reg [31:0] preamble_sr;     // only low CUSTOM_PREAMBLE_LEN bits used.
    reg [31:0] fcs_sr;

    // -----------------------------------------------------------------------
    // Combinational "next bit"
    // -----------------------------------------------------------------------
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

    // -----------------------------------------------------------------------
    // CRC instance
    // -----------------------------------------------------------------------
    reg crc_init;
    crc32_80211 u_crc (
        .clk        (clk),
        .rst_n      (rst_n),
        .init       (crc_init),
        .data_valid (valid_c & feed_crc_c),
        .data_bit   (raw_bit_c),
        .crc_out    (crc_out)
    );

    // -----------------------------------------------------------------------
    // Scrambler LFSR (advanced on scrambled bits)
    // -----------------------------------------------------------------------
    reg  [6:0] lfsr;
    wire       lfsr_feedback = lfsr[6] ^ lfsr[3];
    wire       scrambled_bit = raw_bit_c ^ lfsr[6];

    // -----------------------------------------------------------------------
    // Next-state
    // -----------------------------------------------------------------------
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

    // -----------------------------------------------------------------------
    // Sequential
    // -----------------------------------------------------------------------
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
