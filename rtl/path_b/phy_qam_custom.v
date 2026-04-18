// =============================================================================
// phy_qam_custom : Variable S2P grouper for Path B.  Collects a bit stream
// from the custom MAC and emits an N-bit parallel symbol where N is a
// function of `mod_config`:
//
//   mod_config  |  N (bits/symbol)  |  Output placement
//   ------------+-------------------+-------------------
//   001 (OOK)   |  1                |  path_b_symbol[0]
//   010 (QPSK)  |  2                |  path_b_symbol[1:0]
//   011 (16QAM) |  4                |  path_b_symbol[3:0]
//   100 (64QAM) |  6                |  path_b_symbol[5:0]
//   101 (256QAM)|  8                |  path_b_symbol[7:0]
//   other       |  (undefined)      |  all zero (idle)
//
// Accumulation convention (ASSUMPTION Q8): the first bit received is placed
// into the LSB of the symbol; the Nth bit into bit N-1.  (Equivalent to a
// right-shifting register where the incoming bit enters at bit N-1 and the
// LSB is emitted after N shifts.)  Upper bits above N-1 are hard-wired to 0
// per MAS sec 4 Block C ("Zero-Padding").
//
// `path_b_symbol_valid` pulses for exactly one clk_custom cycle whenever a
// new symbol is produced, i.e. after every N valid input bits.
// =============================================================================
module phy_qam_custom (
    input  wire       clk,
    input  wire       rst_n,

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
            3'b001 : bits_per_sym = 4'd1;  // OOK
            3'b010 : bits_per_sym = 4'd2;  // QPSK
            3'b011 : bits_per_sym = 4'd4;  // 16-QAM
            3'b100 : bits_per_sym = 4'd6;  // 64-QAM
            3'b101 : bits_per_sym = 4'd8;  // 256-QAM
            default: bits_per_sym = 4'd0;  // invalid / Path A
        endcase
    end

    assign invalid_mode = (bits_per_sym == 4'd0) && bit_valid;

    reg [7:0] sr;
    reg [3:0] cnt;

    // New bits enter at the MSB of the shift register so that after N shifts
    // the first received bit lands at position (8-N) and the last lands at
    // bit 7.  Reading sr_next[7 : 8-N] therefore yields
    //   { last_received, ..., first_received }
    // which matches the convention: first bit at symbol LSB, last at MSB.
    wire [7:0] sr_next = {bit_in, sr[7:1]};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sr                  <= 8'd0;
            cnt                 <= 4'd0;
            path_b_symbol       <= 8'd0;
            path_b_symbol_valid <= 1'b0;
        end else begin
            path_b_symbol_valid <= 1'b0;
            if (bit_valid && bits_per_sym != 4'd0) begin
                sr  <= sr_next;
                if (cnt + 1'b1 == bits_per_sym) begin
                    cnt <= 4'd0;
                    case (bits_per_sym)
                        4'd1: path_b_symbol <= {7'd0, sr_next[7]};
                        4'd2: path_b_symbol <= {6'd0, sr_next[7:6]};
                        4'd4: path_b_symbol <= {4'd0, sr_next[7:4]};
                        4'd6: path_b_symbol <= {2'd0, sr_next[7:2]};
                        4'd8: path_b_symbol <=        sr_next[7:0];
                        default: path_b_symbol <= 8'd0;
                    endcase
                    path_b_symbol_valid <= 1'b1;
                end else begin
                    cnt <= cnt + 1'b1;
                end
            end
        end
    end

endmodule
