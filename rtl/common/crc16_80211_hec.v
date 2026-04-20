// =============================================================================
// crc16_80211_hec : IEEE 802.11 PLCP Header Error Check.
//
//   Polynomial : x^16 + x^12 + x^5 + 1       (= 0x1021, canonical CCITT)
//   Init       : 0xFFFF
//   RefIn      : false  (register shifts LEFT; feedback = state[15] ^ bit)
//   RefOut     : false
//   XorOut     : 0xFFFF
//
// Interface:
//   - Assert `init` for one cycle before the first data bit to pre-load
//     the register to 0xFFFF.
//   - `data_valid` high on each clock edge where `data_bit` should be
//     consumed.  The 802.11 convention is to feed PLCP header bits in the
//     same LSB-first-within-octet order in which they are transmitted;
//     callers must match that ordering.
//   - After the last header bit has been consumed, `crc_out` holds the
//     finalized (XorOut-applied) CRC.  Per IEEE 802.11-2016 sec 15.2.3.7
//     the HEC is transmitted with the coefficient of the highest-order
//     term first, i.e. `crc_out[15]` first.
// =============================================================================
module crc16_80211_hec (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        init,        // Synchronous init pulse: load state to 1s.
    input  wire        data_valid,  // One data_bit consumed per asserted cycle.
    input  wire        data_bit,    // Next header bit.
    output wire [15:0] crc_out      // Finalized HEC (already XOR-ed with 1s).
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
