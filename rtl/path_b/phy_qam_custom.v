// =============================================================================
// phy_qam_custom : Variable S2P grouper for Path B.  Collects a bit stream
// from the custom MAC and emits an N-bit parallel symbol where N is a
// function of `mod_config`:
//
//   mod_config  |  N (bits/symbol)  |  Output placement
//   ------------+-------------------+-------------------
//   000 (OOK)   |  1                |  path_b_symbol[0]
//   001 (QPSK)  |  2                |  path_b_symbol[1:0]
//   010 (16QAM) |  4                |  path_b_symbol[3:0]
//   011 (64QAM) |  6                |  path_b_symbol[5:0]
//   100 (256QAM)|  8                |  path_b_symbol[7:0]
//   other       |  (undefined)      |  all zero (idle)
//
// The encoding matches mod_config[2:0] as passed by the top level (see
// Multi-Mode_TX_Architecture.md §1).  mod_config[3]=1 selects Path B at
// the top; that bit is stripped before reaching this module.
//
// Accumulation convention: the first bit received lands in the symbol LSB;
// the Nth bit lands in bit N-1.  Upper bits above N-1 are hard-wired to 0
// per MAS sec 4 Block C ("Zero-Padding").
//
// Per-packet reset (fix for cross-packet bit spill-over):
//   `start_pulse` is asserted for one clk cycle at the start of each PPDU
//   (same pulse that starts the custom MAC).  It zeroes the accumulator
//   (`cnt`, `sr`) so the first bit of the new packet lands cleanly in the
//   LSB of the first symbol.  Without this reset, if a prior packet ended
//   mid-symbol (PREAMBLE_LEN + PSDU_BITS + 32 not a multiple of N), the
//   next packet's first symbol would mix leftover bits from the previous
//   packet with new preamble bits.  `end_pulse` flushes any residual bits as
//   one final zero-padded symbol so the trailing payload/FCS bits are not lost.
// =============================================================================
module phy_qam_custom (
    input  wire       clk,
    input  wire       rst_n,

    input  wire       start_pulse,     // sync reset of the S2P accumulator
    input  wire       end_pulse,       // flush a final partial symbol
    input  wire [2:0] mod_config,

    input  wire       bit_valid,
    input  wire       bit_in,

    // Signal to MAC/top that a mis-configured mode is selected.
    output wire       invalid_mode,

    output reg  [7:0] path_b_symbol,
    output reg        path_b_symbol_valid
);

    // Number of bits per symbol from mod_config.
    reg [3:0] bits_per_sym;
    always @(*) begin
        case (mod_config)
            3'b000 : bits_per_sym = 4'd1;  // OOK
            3'b001 : bits_per_sym = 4'd2;  // QPSK
            3'b010 : bits_per_sym = 4'd4;  // 16-QAM
            3'b011 : bits_per_sym = 4'd6;  // 64-QAM
            3'b100 : bits_per_sym = 4'd8;  // 256-QAM
            default: bits_per_sym = 4'd0;  // invalid
        endcase
    end

    assign invalid_mode = (bits_per_sym == 4'd0) && bit_valid;

    reg [7:0] sr;
    reg [3:0] cnt;

    // Incoming bit enters at the MSB so that after N shifts the first bit
    // lands at position (8-N) and the last lands at bit 7.  Reading
    // sr_next[7 : 8-N] then yields { last_received, ..., first_received },
    // which matches the "first bit at symbol LSB" convention.
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

            // Per-packet sync reset takes priority so a residual cnt/sr
            // from the previous packet cannot leak bits into this one.
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
