// =============================================================================
// phase_to_iq : 2-bit QPSK phase -> (chip_i, chip_q) Gray mapping.
//
//   phase  angle   chip_i   chip_q
//   -----  ------  ------   ------
//    00    +pi/4     1         1
//    01   +3pi/4     0         1
//    11    -3pi/4    0         0
//    10    -pi/4     1         0
//
// Encoding chosen so that differential DQPSK phase add (mod 4) commutes with
// the usual Barker / CCK conventions: phase 00 is the "reference" (+I,+Q);
// phase 10 (i.e. bit 1 flipped) corresponds to a 90-deg rotation; etc.
//
// For DBPSK operation the MAC drives only phases 00 / 11; chip_q tracks
// chip_i and the analog side is free to gate Q based on mod_config.
// =============================================================================
module phase_to_iq (
    input  wire [1:0] phase,
    output wire       chip_i,
    output wire       chip_q
);
    assign chip_i = ~phase[0];        // phase[0]=0 -> +1, phase[0]=1 -> -1
    assign chip_q = ~phase[1];        // phase[1]=0 -> +1, phase[1]=1 -> -1
endmodule
