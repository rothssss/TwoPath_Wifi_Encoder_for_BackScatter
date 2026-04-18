// =============================================================================
// crc32_80211 : bit-serial IEEE 802.11 FCS CRC-32.
//
// Standard parameters (verify against spec question Q4 before tape-out):
//   Polynomial : 0x04C11DB7
//   Init       : 0xFFFFFFFF
//   RefIn      : true  (LSB-first bit order)
//   RefOut     : true
//   XorOut     : 0xFFFFFFFF
//
// Equivalent reflected polynomial used internally : 0xEDB88320.
//
// Interface:
//   - Assert `init` for one cycle before the first data bit to load 0xFFFFFFFF.
//   - `data_valid` high on each clock edge where `data_bit` should be consumed.
//     (LSB-first: call with bit 0 of byte first, then bit 1, ... up to bit 7.)
//   - After the last data bit, `crc_out` holds the 32-bit reflected remainder
//     XOR-ed with 0xFFFFFFFF, i.e. the value that should be transmitted on
//     the wire LSB-first per IEEE 802.11 section 9.2.4.6.
// =============================================================================
module crc32_80211 (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        init,        // Synchronous init pulse: load state to 1s.
    input  wire        data_valid,  // One data_bit consumed per asserted cycle.
    input  wire        data_bit,    // LSB-first bit stream.
    output wire [31:0] crc_out      // Finalized FCS (already XOR-ed with 1s).
);

    reg [31:0] state;

    // Next-state logic: reflected CRC-32 update.
    //   x = state[0] XOR data_bit
    //   state_next = (state >> 1) XOR (x ? 0xEDB88320 : 0)
    wire        fb = state[0] ^ data_bit;
    wire [31:0] state_next_data = (state >> 1) ^ (fb ? 32'hEDB88320 : 32'h00000000);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)           state <= 32'hFFFFFFFF;
        else if (init)        state <= 32'hFFFFFFFF;
        else if (data_valid)  state <= state_next_data;
    end

    assign crc_out = state ^ 32'hFFFFFFFF;

endmodule
