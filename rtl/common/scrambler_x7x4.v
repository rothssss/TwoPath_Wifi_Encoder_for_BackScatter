// =============================================================================
// scrambler_x7x4 : 7-bit LFSR side-stream scrambler.
//   Polynomial : x^7 + x^4 + 1   (as specified in the MAS).
//   Equivalent feedback taps     : state[6] XOR state[3].
//   Shift direction              : feedback inserted at state[0] on each tick.
//
// Assumptions (see spec Q5):
//   - Default seed 7'h5D (0b1011101) loaded on packet start via `seed_load`.
//   - Scrambling gate: only when `data_valid` asserts, so the LFSR does not
//     advance on idle cycles.  Output bit = data_in XOR state[6].
// =============================================================================
module scrambler_x7x4 #(
    parameter [6:0] DEFAULT_SEED = 7'h5D
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       seed_load,   // Synchronous: reload DEFAULT_SEED.
    input  wire       data_valid,  // Advance and scramble one bit.
    input  wire       data_in,     // Raw input bit.
    output wire       data_out     // Scrambled bit (combinational w.r.t. state).
);

    reg [6:0] lfsr;
    wire feedback = lfsr[6] ^ lfsr[3];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)             lfsr <= DEFAULT_SEED;
        else if (seed_load)     lfsr <= DEFAULT_SEED;
        else if (data_valid)    lfsr <= {lfsr[5:0], feedback};
    end

    assign data_out = data_in ^ lfsr[6];

endmodule
