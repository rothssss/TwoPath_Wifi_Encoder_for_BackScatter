// =============================================================================
// bit_to_chip_handshake : cross a 1 Mbps bit stream from clk_b_data (1 MHz)
// into clk_b_chip (11 MHz).  Relies on the spec's guarantee that the two
// clocks are phase-aligned with an integer 1:11 ratio.
//
// Architecture:
//   - 2FF-synchronize `bit_in` and `bit_valid_in` into clk_b_chip.  Because
//     the source holds each bit stable for 11 chip cycles, a 2FF delay is
//     safely absorbed.
//   - A chip-rate counter (0..10) is maintained inside clk_b_chip.  It
//     starts counting once `bit_valid_sync` is observed high and rolls over
//     every 11 chip cycles.  Its phase is locked naturally by the first
//     valid edge; thereafter it free-runs in lockstep with the 1 MHz domain.
//   - `chip_cnt==0` marks the start of a new 1-bit window; the PHY should
//     use this to gate DBPSK state updates.
//
// Timing constraint (SDC): treat the bit_in/bit_valid_in crossing as an
// asynchronous path with a 2-cycle max delay (standard 2FF).  Alternatively,
// since the two clocks are phase-aligned (integer ratio), the crossing can
// be constrained as a multi-cycle path -- but the 2FF is included so
// verification remains safe if phase alignment is ever lost.
// =============================================================================
module bit_to_chip_handshake (
    input  wire clk_b_chip,
    input  wire rst_n,

    // From MAC (clk_b_data domain)
    input  wire bit_in,
    input  wire bit_valid_in,

    // To PHY (clk_b_chip domain)
    output wire bit_in_chip,          // Synchronized data bit.
    output wire bit_valid_chip,       // Synchronized valid (level).
    output reg  [3:0] chip_cnt,       // 0..10, rolls over.
    output wire bit_window_start      // 1 cycle when chip_cnt rolls to 0.
);

    // 2FF sync
    sync_2ff #(.WIDTH(1)) u_sync_bit (
        .clk(clk_b_chip), .rst_n(rst_n),
        .d_in(bit_in),    .d_out(bit_in_chip)
    );
    sync_2ff #(.WIDTH(1)) u_sync_valid (
        .clk(clk_b_chip), .rst_n(rst_n),
        .d_in(bit_valid_in), .d_out(bit_valid_chip)
    );

    // Chip-rate counter.  Resets to 0 when valid is low, counts 0..10 when
    // valid is high, wraps to 0.
    reg running;
    always @(posedge clk_b_chip or negedge rst_n) begin
        if (!rst_n) begin
            chip_cnt <= 4'd0;
            running  <= 1'b0;
        end else if (!bit_valid_chip) begin
            chip_cnt <= 4'd0;
            running  <= 1'b0;
        end else begin
            running  <= 1'b1;
            chip_cnt <= (chip_cnt == 4'd10) ? 4'd0 : chip_cnt + 1'b1;
        end
    end

    // Pulse on the cycle chip_cnt transitions to 0 (i.e., start of bit).
    reg chip_cnt_was_10;
    always @(posedge clk_b_chip or negedge rst_n) begin
        if (!rst_n)                  chip_cnt_was_10 <= 1'b0;
        else if (!bit_valid_chip)    chip_cnt_was_10 <= 1'b0;
        else                         chip_cnt_was_10 <= (chip_cnt == 4'd10);
    end

    // On the first valid cycle OR immediately after chip_cnt wraps.
    assign bit_window_start = bit_valid_chip && (running ? chip_cnt_was_10 : 1'b1);

endmodule
