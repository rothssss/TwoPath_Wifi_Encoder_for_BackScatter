// =============================================================================
// phy_a_rotator : Path A QPSK rotator.  One block serves all four 802.11b
// rates.
//
// Interface:
//   - `base_phase` [1:0]  : base QPSK phase for the current chip.  For
//                           Barker-based rates (1/2 Mbps) the MAC sets
//                           this to 0 for a '+1' Barker chip or 2 (pi)
//                           for a '-1' Barker chip.  For CCK rates the
//                           MAC forwards the c_k field received from
//                           the MCU (the base-phase table already
//                           accounts for d2/d3/d4 dibits and, for
//                           chips 3 and 6, the hard-wired +pi).
//   - `delta_phi1` [1:0]  : phi1 accumulator update for the current
//                           symbol.  Valid when `update_phi1` pulses.
//                           For 1 Mbps DBPSK this is {data_bit, 1'b0}
//                           (0 or 2).  For 2 Mbps DQPSK it is the Gray-
//                           coded dibit phase delta.  For CCK rates it
//                           is the MCU-supplied field, which already
//                           folds in the odd/even-symbol pi correction
//                           called out in 802.11-2016 sec 16.4.6.3.
//   - `update_phi1`       : pulses for exactly one clk cycle at the
//                           start of each symbol (chip_cnt == 0).  The
//                           accumulator absorbs `delta_phi1` on that
//                           edge so chips within the symbol see the
//                           freshly-updated phase.
//   - `valid_chip`        : asserts each cycle that a valid chip is on
//                           the bus.
//
// Output is registered (1 cycle latency from inputs).
// =============================================================================
module phy_a_rotator (
    input  wire       clk,
    input  wire       rst_n,

    input  wire       start_pulse,      // Zero phi1 at packet start.
    input  wire [1:0] base_phase,
    input  wire [1:0] delta_phi1,
    input  wire       update_phi1,
    input  wire       valid_chip,

    output reg        chip_i,
    output reg        chip_q,
    output reg        chip_valid
);

    reg [1:0] phi1_acc;

    // Next-cycle phase accumulator value.
    wire [1:0] phi1_next = phi1_acc + delta_phi1;

    // Current-cycle chip phase to transmit.  When `update_phi1` fires on
    // the first chip of a new symbol, the chip uses the FRESHLY-UPDATED
    // accumulator (phi1_next) so that chip 0 already sees the new phase.
    wire [1:0] phi1_eff = update_phi1 ? phi1_next : phi1_acc;
    wire [1:0] chip_phase = base_phase + phi1_eff;

    wire       chip_i_c;
    wire       chip_q_c;
    phase_to_iq u_p2iq (.phase(chip_phase), .chip_i(chip_i_c), .chip_q(chip_q_c));

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            phi1_acc   <= 2'd0;
            chip_i     <= 1'b0;
            chip_q     <= 1'b0;
            chip_valid <= 1'b0;
        end else begin
            if (start_pulse)        phi1_acc <= 2'd0;
            else if (update_phi1)   phi1_acc <= phi1_next;

            if (valid_chip) begin
                chip_i     <= chip_i_c;
                chip_q     <= chip_q_c;
                chip_valid <= 1'b1;
            end else begin
                chip_valid <= 1'b0;
            end
        end
    end

endmodule
