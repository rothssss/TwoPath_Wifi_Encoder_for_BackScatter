// =============================================================================
// phy_dsss_80211b : 802.11b PHY -- Barker spreading + DBPSK, clk_b_chip
// (11 MHz) domain.
//
// Barker sequence (per MAS sec 4 Block B):
//   For input bit 1 : emit `10110111000` (MSB-first -> chip 0 is '1').
//   For input bit 0 : emit the inverse `01001000111`.
//
// DBPSK mapping (per MAS sec 4 Block B):
//   current_phase <= prev_phase XOR incoming_chip
//
// Reset behaviour (ASSUMPTION Q7):
//   prev_phase is reset to 0 on rst_n, and is ALSO reset at each packet
//   start (when bit_valid_chip rises from 0 to 1).  If you would rather
//   preserve phase across packets, set RESET_DBPSK_PER_PACKET = 0.
//
// Output:
//   path_a_symbol_valid : asserted each chip cycle when a new DBPSK chip
//                         is on the bus.
//   path_a_symbol[0]    : the DBPSK-modulated chip.
//   path_a_symbol[7:1]  : 0 (per MAS sec 4 Block B).
// =============================================================================
module phy_dsss_80211b #(
    parameter [10:0] BARKER_PATTERN       = 11'b10110111000,
    parameter        RESET_DBPSK_PER_PACKET = 1
) (
    input  wire clk_b_chip,
    input  wire rst_n,

    // From bit_to_chip_handshake
    input  wire       bit_in_chip,
    input  wire       bit_valid_chip,
    input  wire [3:0] chip_cnt,
    input  wire       bit_window_start,

    output reg  [7:0] path_a_symbol,
    output reg        path_a_symbol_valid
);

    // Barker chip for the current bit:
    //   raw = BARKER_PATTERN[10 - chip_cnt]  if bit_in_chip == 1
    //         ~BARKER_PATTERN[10 - chip_cnt] otherwise
    // chip_cnt 0 emits the leftmost bit first (MSB of the constant).
    wire barker_chip_one  = BARKER_PATTERN[10 - chip_cnt[3:0]];
    wire barker_chip      = bit_in_chip ? barker_chip_one : ~barker_chip_one;

    // DBPSK state.
    reg prev_phase;
    wire current_phase = prev_phase ^ barker_chip;

    // Detect rising edge of bit_valid_chip for per-packet DBPSK reset.
    reg bit_valid_chip_q;
    wire valid_rising = bit_valid_chip & ~bit_valid_chip_q;

    always @(posedge clk_b_chip or negedge rst_n) begin
        if (!rst_n) begin
            prev_phase          <= 1'b0;
            bit_valid_chip_q    <= 1'b0;
            path_a_symbol       <= 8'd0;
            path_a_symbol_valid <= 1'b0;
        end else begin
            bit_valid_chip_q <= bit_valid_chip;

            if (RESET_DBPSK_PER_PACKET && valid_rising) begin
                prev_phase <= 1'b0;
            end

            if (bit_valid_chip) begin
                prev_phase          <= current_phase;
                path_a_symbol       <= {7'b0, current_phase};
                path_a_symbol_valid <= 1'b1;
            end else begin
                path_a_symbol_valid <= 1'b0;
            end
        end
    end

    // Silence unused-signals lint.
    wire _unused = &{1'b0, bit_window_start};

endmodule
