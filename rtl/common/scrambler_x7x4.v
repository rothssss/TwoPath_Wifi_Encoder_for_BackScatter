// =============================================================================
// scrambler_x7x4 : 7-bit self-synchronous scrambler.
//   Polynomial : x^7 + x^4 + 1.
//   Per-bit operation:
//     scrambled  = data_in XOR state[6] XOR state[3]
//     state_next = {scrambled, state[6:1]}
//
// Assumptions:
//   - Default seed 7'h5D (0b1011101) loaded on packet start via `seed_load`.
//   - Scrambling gate: only when `data_valid` asserts, so the LFSR does not
//     advance on idle cycles.
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
    wire data_out_c = data_in ^ lfsr[6] ^ lfsr[3];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)             lfsr <= DEFAULT_SEED;
        else if (seed_load)     lfsr <= DEFAULT_SEED;
        else if (data_valid)    lfsr <= {data_out_c, lfsr[6:1]};
    end

    assign data_out = data_out_c;

endmodule
