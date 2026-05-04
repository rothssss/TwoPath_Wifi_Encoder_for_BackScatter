// Global default timescale for every module in the filelist that does not
// declare its own.  1 ns / 1 ps is plenty of resolution for this block.
`timescale 1ns/1ps


// =============================================================================
// sync_2ff : two-flop synchronizer for single-bit control / slow-changing data.
//
// Use ONLY for single-bit signals or multi-bit signals whose bits are guaranteed
// never to change on the same cycle (e.g. gray-coded pointers).
// For arbitrary multi-bit data crossings, use async_fifo or a handshake.
//
// Reset is asynchronous active-low, consistent with the global rst_n strategy.
// =============================================================================
module sync_2ff #(
    parameter WIDTH      = 1,
    parameter RESET_VAL  = 1'b0
) (
    input  wire               clk,
    input  wire               rst_n,
    input  wire [WIDTH-1:0]   d_in,
    output wire [WIDTH-1:0]   d_out
);

    reg [WIDTH-1:0] meta_q;
    reg [WIDTH-1:0] sync_q;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            meta_q <= {WIDTH{RESET_VAL}};
            sync_q <= {WIDTH{RESET_VAL}};
        end else begin
            meta_q <= d_in;
            sync_q <= meta_q;
        end
    end

    assign d_out = sync_q;

endmodule


// =============================================================================
// pulse_sync : cross a 1-cycle pulse from src_clk to dst_clk domains.
//
// Mechanism:
//   - Source pulse toggles a level on src_clk.
//   - Level is 2FF-synchronized into dst_clk.
//   - Edge detector in dst_clk regenerates a single-cycle pulse.
//
// Requirement: src_pulse must not assert faster than dst_clk / 3, otherwise
// toggles can be missed. For tx_enable (rising-edge event) this is fine.
// =============================================================================
module pulse_sync (
    input  wire src_clk,
    input  wire src_rst_n,
    input  wire src_pulse,

    input  wire dst_clk,
    input  wire dst_rst_n,
    output wire dst_pulse
);

    reg toggle_src;
    always @(posedge src_clk or negedge src_rst_n) begin
        if (!src_rst_n)      toggle_src <= 1'b0;
        else if (src_pulse)  toggle_src <= ~toggle_src;
    end

    wire toggle_dst;
    sync_2ff #(.WIDTH(1), .RESET_VAL(1'b0)) u_sync (
        .clk   (dst_clk),
        .rst_n (dst_rst_n),
        .d_in  (toggle_src),
        .d_out (toggle_dst)
    );

    reg toggle_dst_q;
    always @(posedge dst_clk or negedge dst_rst_n) begin
        if (!dst_rst_n) toggle_dst_q <= 1'b0;
        else            toggle_dst_q <= toggle_dst;
    end

    assign dst_pulse = toggle_dst ^ toggle_dst_q;

endmodule


// =============================================================================
// reset_sync : async-assert, sync-deassert reset synchronizer.
//
// The input `async_rst_n` is the chip-level asynchronous reset (typically
// POR + pin).  It is immediately asserted (flush the domain) but is
// re-released synchronously with `clk`, so no flop in the domain can see
// a reset-release edge violating its recovery/removal window.
//
// Instantiate ONE per clock domain that needs synchronous de-assertion
// (i.e., every functional clock in the design).
//
// SDC handling: declare async_rst_n as an async reset.  The recovery/removal
// arcs from the second stage are valid sync paths to all loads.
// =============================================================================
module reset_sync (
    input  wire clk,
    input  wire async_rst_n,
    output wire sync_rst_n
);

    reg meta_q;
    reg sync_q;

    always @(posedge clk or negedge async_rst_n) begin
        if (!async_rst_n) begin
            meta_q <= 1'b0;
            sync_q <= 1'b0;
        end else begin
            meta_q <= 1'b1;
            sync_q <= meta_q;
        end
    end

    assign sync_rst_n = sync_q;

endmodule


// =============================================================================
// async_fifo : dual-clock asynchronous FIFO using Gray-coded pointers.
//
// Depth must be a power of two. Default 32 x 8 per spec (Block A).
//
// Pointers:
//   - Write pointer is (ADDR_W+1) bits: the top bit is the wrap flag for
//     full detection; lower ADDR_W bits index the memory.
//   - Same for read pointer.
//   - Gray-coded copies of the pointers are crossed through 2FF synchronizers
//     into the opposite clock domain to generate full/empty.
//
// full  = (wptr_gray == {~rptr_gray_sync[ADDR_W:ADDR_W-1], rptr_gray_sync[ADDR_W-2:0]})
// empty = (rptr_gray == wptr_gray_sync)
//
// Reset is active-low asynchronous; synchronously released in each domain by
// 2FF-synchronizing rst_n in the top-level (not done inside this block).
// =============================================================================
module async_fifo #(
    parameter DATA_W = 8,
    parameter DEPTH  = 32,
    parameter ADDR_W = 5   // = $clog2(DEPTH); must match DEPTH.
) (
    // Write side
    input  wire              wclk,
    input  wire              wrst_n,
    input  wire              wr_en,
    input  wire [DATA_W-1:0] wr_data,
    output wire              full,

    // Read side
    input  wire              rclk,
    input  wire              rrst_n,
    input  wire              rd_en,
    output wire [DATA_W-1:0] rd_data,
    output wire              empty
);

    // ---- Memory (inferred RAM) ------------------------------------------
    reg [DATA_W-1:0] mem [0:DEPTH-1];

    // ---- Write domain ----------------------------------------------------
    reg  [ADDR_W:0] wptr_bin;
    reg  [ADDR_W:0] wptr_gray;
    wire [ADDR_W:0] wptr_bin_next  = wptr_bin + {{ADDR_W{1'b0}}, (wr_en & ~full)};
    wire [ADDR_W:0] wptr_gray_next = (wptr_bin_next >> 1) ^ wptr_bin_next;

    always @(posedge wclk or negedge wrst_n) begin
        if (!wrst_n) begin
            wptr_bin  <= {ADDR_W+1{1'b0}};
            wptr_gray <= {ADDR_W+1{1'b0}};
        end else begin
            wptr_bin  <= wptr_bin_next;
            wptr_gray <= wptr_gray_next;
        end
    end

    always @(posedge wclk) begin
        if (wr_en && !full) mem[wptr_bin[ADDR_W-1:0]] <= wr_data;
    end

    // ---- Read domain -----------------------------------------------------
    // Declare the read-domain pointer regs up front so the r2w synchronizer
    // below can reference `rptr_gray` without creating an implicit wire
    // (strict LRM; Xcelium rejects the later reg redeclaration).
    reg  [ADDR_W:0] rptr_bin;
    reg  [ADDR_W:0] rptr_gray;
    wire [ADDR_W:0] rptr_bin_next  = rptr_bin + {{ADDR_W{1'b0}}, (rd_en & ~empty)};
    wire [ADDR_W:0] rptr_gray_next = (rptr_bin_next >> 1) ^ rptr_bin_next;

    // Sync read-pointer (gray) into write domain
    wire [ADDR_W:0] rptr_gray_at_w;
    sync_2ff #(.WIDTH(ADDR_W+1), .RESET_VAL(1'b0)) u_sync_r2w (
        .clk(wclk), .rst_n(wrst_n),
        .d_in (rptr_gray),
        .d_out(rptr_gray_at_w)
    );

    // Full when wptr_gray equals read-pointer-gray with the upper two bits
    // inverted (classic Cummings async-FIFO formulation).
    assign full = (wptr_gray == {~rptr_gray_at_w[ADDR_W:ADDR_W-1],
                                  rptr_gray_at_w[ADDR_W-2:0]});

    always @(posedge rclk or negedge rrst_n) begin
        if (!rrst_n) begin
            rptr_bin  <= {ADDR_W+1{1'b0}};
            rptr_gray <= {ADDR_W+1{1'b0}};
        end else begin
            rptr_bin  <= rptr_bin_next;
            rptr_gray <= rptr_gray_next;
        end
    end

    // Sync write-pointer (gray) into read domain
    wire [ADDR_W:0] wptr_gray_at_r;
    sync_2ff #(.WIDTH(ADDR_W+1), .RESET_VAL(1'b0)) u_sync_w2r (
        .clk(rclk), .rst_n(rrst_n),
        .d_in (wptr_gray),
        .d_out(wptr_gray_at_r)
    );

    assign empty = (rptr_gray == wptr_gray_at_r);

    // Read data is combinational from memory at the current read address.
    // Downstream should register it if synchronous read is desired.
    assign rd_data = mem[rptr_bin[ADDR_W-1:0]];

endmodule


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

// =============================================================================
// mac_fsm_80211b : 802.11b Long PLCP MAC/PLCP engine for 1, 2, 5.5, and 11
// Mbps.  CCK rates use an MCU offload contract: the MCU pre-computes the
// 8-chip CCK symbol pattern in software and ships it as 4 packed FIFO bytes
// per symbol, which this MAC streams straight to phy_a_rotator.
//
//   rate_mode = 2'b00 : 1   Mbps DBPSK + 11-chip Barker (chip computes everything)
//   rate_mode = 2'b01 : 2   Mbps DQPSK + 11-chip Barker (chip computes everything)
//   rate_mode = 2'b10 : 5.5 Mbps CCK   (MCU pre-computes; chip streams)
//   rate_mode = 2'b11 : 11  Mbps CCK   (MCU pre-computes; chip streams)
//
// PLCP framing (always Long preamble per IEEE 802.11-2016 sec 16.2.3):
//   SYNC(128) | SFD(16) | SIGNAL(8) | SERVICE(8) | LENGTH(16) | HEC(16) | PSDU | FCS
//
// SYNC/SFD/SIGNAL/SERVICE/LENGTH/HEC are always 1 Mbps DBPSK + Barker.
// That matches what a commercial 802.11b Long-PLCP receiver expects to
// see for every PSDU rate.
//
// MCU contract for CCK rates:
//   The MCU is responsible for performing, in software:
//     - self-synchronous scrambling (sec 16.2.4) of the payload bitstream;
//     - CRC-32 (sec 16.2.3.6) over the scrambled payload;
//     - 8-chip CCK encoding (sec 16.4.6) of the scrambled-payload + FCS bits;
//     - the sec 16.4.6.3 odd-symbol +pi correction, folded into delta_phi1;
//     - the sec 16.4.6 chip-3 / chip-6 hard-wired +pi, folded into c_k.
//   The chip side never touches scrambler / CRC / Barker for CCK PSDU+FCS;
//   it only replays the QPSK chip phases through phy_a_rotator.
//
// CCK symbol packing (LSB-first across 4 FIFO bytes per CCK symbol):
//   bits[1:0]    = delta_phi1[1:0]    (DQPSK delta for d1, with the
//                                      sec 16.4.6.3 odd-symbol +pi already
//                                      folded in)
//   bits[3:2]    = c_k0[1:0]
//   bits[5:4]    = c_k1[1:0]
//   bits[7:6]    = c_k2[1:0]
//   bits[9:8]    = c_k3[1:0]          (c_k3 already includes +pi)
//   bits[11:10]  = c_k4[1:0]
//   bits[13:12]  = c_k5[1:0]
//   bits[15:14]  = c_k6[1:0]          (c_k6 already includes +pi)
//   bits[17:16]  = c_k7[1:0]
//   bits[31:18]  = reserved (MCU writes 0)
//
//   FIFO bytes consumed per CCK packet = 4 * cck_symbol_count.
//
// MCU-supplied per-packet inputs:
//   length_field    : 16-bit LENGTH for the PLCP header (sec 16.2.3.5).
//                     Used at every rate.
//   service_field   : 8-bit SERVICE byte (sec 16.2.3.4), with LENGTH_EXTENSION
//                     in bit 7 and LOCKED_CLOCKS in bit 2.  Used at every rate.
//   cck_symbol_count: number of 8-chip CCK symbols making up PSDU+FCS.
//                     Used only for CCK rates; ignored for Barker rates.
//
// For Barker rates, payload_len is the raw-payload byte count and the chip
// computes the scrambler / CRC-32 / Barker chip stream on its own.
// =============================================================================
module mac_fsm_80211b #(
    parameter integer PREAMBLE_SYNC_LEN = 128,
    parameter [15:0]  SFD_PATTERN       = 16'hF3A0,
    parameter [6:0]   SCRAMBLER_SEED    = 7'h6D,
    parameter [10:0]  BARKER_PATTERN    = 11'b10110111000
) (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        start_pulse,
    input  wire [1:0]  rate_mode,
    input  wire [15:0] payload_len,
    input  wire [15:0] length_field,
    input  wire [7:0]  service_field,
    input  wire [15:0] cck_symbol_count,

    output reg         busy,
    output reg         done_pulse,

    output wire        fifo_rd_en,
    input  wire        fifo_empty,
    input  wire [7:0]  fifo_rd_data,
    output reg         underrun_flag,

    output reg  [1:0]  base_phase,
    output reg  [1:0]  delta_phi1,
    output reg         update_phi1,
    output reg         chip_valid
);

    function [7:0] signal_byte_for_rate;
        input [1:0] r;
        begin
            case (r)
                2'b00:   signal_byte_for_rate = 8'h0A; // 1   Mbps
                2'b01:   signal_byte_for_rate = 8'h14; // 2   Mbps
                2'b10:   signal_byte_for_rate = 8'h37; // 5.5 Mbps
                2'b11:   signal_byte_for_rate = 8'h6E; // 11  Mbps
                default: signal_byte_for_rate = 8'h0A;
            endcase
        end
    endfunction

    localparam [3:0]
        S_IDLE        = 4'd0,
        S_SYNC        = 4'd1,
        S_SFD         = 4'd2,
        S_HEAD        = 4'd3,
        S_HEC         = 4'd4,
        S_PSDU_BARKER = 4'd5,
        S_FCS_BARKER  = 4'd6,
        S_PSDU_CCK    = 4'd7,
        S_DONE        = 4'd8;

    reg [3:0] state, state_next;
    reg [1:0] rate_mode_q;
    wire      cck_active = rate_mode_q[1];

    reg  [3:0] chip_cnt;
    wire [3:0] chip_max     = (state == S_PSDU_CCK) ? 4'd7 : 4'd10;
    wire       symbol_start = (chip_cnt == 4'd0);
    wire       symbol_end   = (chip_cnt == chip_max);

    reg  [15:0] payload_len_q;
    reg  [15:0] cck_sym_count_q;
    reg  [7:0]  sym_cnt;
    reg  [15:0] byte_cnt;
    reg  [15:0] cck_sym_cnt;
    reg  [2:0]  bit_in_byte;

    reg  [7:0]  byte_sr;
    reg  [31:0] header_sr;
    reg  [15:0] sfd_sr;
    reg  [15:0] hec_sr;
    reg  [31:0] fcs_sr;

    // CCK symbol streamer: cck_word_curr feeds the 8 chips of the symbol
    // currently emitting; cck_word_next buffers the next symbol's 4 bytes
    // while the current symbol is still on the wire.
    reg  [31:0] cck_word_curr;
    reg  [31:0] cck_word_next;

    reg         crc_init;

    reg         raw_bit_c;
    reg         raw_bit2_c;
    reg         scramble_c;
    reg         two_bit_sym_c;
    reg         feed_hec_c;
    reg         feed_fcs_c;
    reg         emit_chip_c;

    wire [15:0] hec_out;
    wire [31:0] fcs_out;

    wire [15:0] hec_source = (state == S_HEC        && sym_cnt == 8'd0) ? hec_out : hec_sr;
    wire [31:0] fcs_source = (state == S_FCS_BARKER && sym_cnt == 8'd0) ? fcs_out : fcs_sr;

    always @(*) begin
        raw_bit_c     = 1'b0;
        raw_bit2_c    = 1'b0;
        scramble_c    = 1'b0;
        two_bit_sym_c = 1'b0;
        feed_hec_c    = 1'b0;
        feed_fcs_c    = 1'b0;
        emit_chip_c   = 1'b0;

        case (state)
            S_SYNC: begin
                raw_bit_c   = 1'b1;
                scramble_c  = 1'b1;
                emit_chip_c = 1'b1;
            end
            S_SFD: begin
                raw_bit_c   = sfd_sr[15];
                scramble_c  = 1'b1;
                emit_chip_c = 1'b1;
            end
            S_HEAD: begin
                raw_bit_c   = header_sr[0];
                scramble_c  = 1'b1;
                feed_hec_c  = 1'b1;
                emit_chip_c = 1'b1;
            end
            S_HEC: begin
                raw_bit_c   = hec_source[15];
                scramble_c  = 1'b1;
                emit_chip_c = 1'b1;
            end
            S_PSDU_BARKER: begin
                raw_bit_c     = byte_sr[0];
                raw_bit2_c    = byte_sr[1];
                scramble_c    = 1'b1;
                two_bit_sym_c = rate_mode_q[0];
                feed_fcs_c    = 1'b1;
                emit_chip_c   = 1'b1;
            end
            S_FCS_BARKER: begin
                raw_bit_c     = fcs_source[0];
                raw_bit2_c    = fcs_source[1];
                scramble_c    = 1'b1;
                two_bit_sym_c = rate_mode_q[0];
                emit_chip_c   = 1'b1;
            end
            S_PSDU_CCK: begin
                // Chip pattern is replayed straight from cck_word_curr; no
                // chip-side scrambler / Barker / CRC engagement.
                emit_chip_c   = 1'b1;
            end
            default: ;
        endcase
    end

    // ------------------------------------------------------------------
    // Self-synchronous scrambler (Barker rates only)
    // ------------------------------------------------------------------
    reg  [6:0] lfsr;
    function scramble_bit_ss;
        input [6:0] state_in;
        input       raw_bit;
        begin
            scramble_bit_ss = raw_bit ^ state_in[6] ^ state_in[3];
        end
    endfunction
    function [6:0] scramble_state_ss;
        input [6:0] state_in;
        input       raw_bit;
        reg         scrambled;
        begin
            scrambled = scramble_bit_ss(state_in, raw_bit);
            scramble_state_ss = {scrambled, state_in[6:1]};
        end
    endfunction

    wire       s0            = scramble_bit_ss(lfsr, raw_bit_c);
    wire [6:0] lfsr_advance1 = scramble_state_ss(lfsr, raw_bit_c);
    wire       s1            = scramble_bit_ss(lfsr_advance1, raw_bit2_c);
    wire [6:0] lfsr_advance2 = scramble_state_ss(lfsr_advance1, raw_bit2_c);

    function [1:0] dqpsk_delta_from_bits;
        input bit0;
        input bit1;
        begin
            case ({bit1, bit0})
                2'b00 : dqpsk_delta_from_bits = 2'd0;
                2'b10 : dqpsk_delta_from_bits = 2'd1;
                2'b11 : dqpsk_delta_from_bits = 2'd2;
                2'b01 : dqpsk_delta_from_bits = 2'd3;
                default: dqpsk_delta_from_bits = 2'd0;
            endcase
        end
    endfunction

    wire [1:0] delta_phi1_barker =
        two_bit_sym_c ? dqpsk_delta_from_bits(s0, s1) : {s0, 1'b0};

    wire barker_chip_bit       = BARKER_PATTERN[10 - chip_cnt[3:0]];
    wire [1:0] base_phase_barker = barker_chip_bit ? 2'b00 : 2'b10;

    // CCK chip-phase mux: pick c_k[chip_cnt] from cck_word_curr.
    // Layout (LSB-first): [delta=1:0][c0=3:2][c1=5:4]...[c7=17:16].
    // Indexed part-select keeps this one expression and avoids the
    // always_comb / case event-ordering ambiguity the earlier version had.
    wire [1:0] cck_chip_phase = cck_word_curr[2 + (chip_cnt[2:0] << 1) +: 2];
    wire [1:0] cck_delta_phi1 = cck_word_curr[1:0];

    // -----------------------------------------------------------------------
    // Combinational FIFO read-enable.
    //
    // fifo_rd_en MUST be combinational so the async FWFT FIFO can advance
    // its rptr on the SAME edge the MAC captures the byte, not a cycle
    // later.  When fifo_rd_en was driven NBA inside the seq always, the
    // FIFO saw the request one cycle late and CCK's 4-consecutive-cycle
    // prefetch ended up reading byte 0 twice and dropping byte 3.
    // -----------------------------------------------------------------------
    wire cck_active_in = rate_mode_q[1];

    wire fifo_rd_en_barker_hec_end =
        (state == S_HEC) && !cck_active_in &&
        (sym_cnt == 8'd15) && symbol_end &&
        (payload_len_q != 16'd0) && (payload_len_q > 16'd1);

    wire fifo_rd_en_barker_psdu =
        (state == S_PSDU_BARKER) && symbol_end &&
        (((!rate_mode_q[0]) && (bit_in_byte == 3'd7)) ||
         (( rate_mode_q[0]) && (bit_in_byte == 3'd6))) &&
        (byte_cnt != payload_len_q - 16'd1) &&
        (byte_cnt != payload_len_q - 16'd2);

    wire fifo_rd_en_cck_hec_pre =
        (state == S_HEC) && cck_active_in &&
        (sym_cnt == 8'd15) &&
        (chip_cnt >= 4'd4) && (chip_cnt <= 4'd7) &&
        (cck_sym_count_q != 16'd0);

    wire fifo_rd_en_cck_psdu_pre =
        (state == S_PSDU_CCK) &&
        (cck_sym_cnt < cck_sym_count_q - 16'd1) &&
        (chip_cnt <= 4'd3);

    assign fifo_rd_en = !fifo_empty &&
                        (fifo_rd_en_barker_hec_end |
                         fifo_rd_en_barker_psdu    |
                         fifo_rd_en_cck_hec_pre    |
                         fifo_rd_en_cck_psdu_pre);

    crc16_80211_hec u_hec (
        .clk       (clk),
        .rst_n     (rst_n),
        .init      (crc_init),
        .data_valid(symbol_start & feed_hec_c),
        .data_bit  (raw_bit_c),
        .crc_out   (hec_out)
    );

    reg fcs_feed_second_cycle;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)                          fcs_feed_second_cycle <= 1'b0;
        else if (symbol_start & feed_fcs_c & two_bit_sym_c)
                                             fcs_feed_second_cycle <= 1'b1;
        else                                 fcs_feed_second_cycle <= 1'b0;
    end

    crc32_80211 u_fcs (
        .clk       (clk),
        .rst_n     (rst_n),
        .init      (crc_init),
        .data_valid((symbol_start & feed_fcs_c) | fcs_feed_second_cycle),
        .data_bit  (fcs_feed_second_cycle ? raw_bit2_c : raw_bit_c),
        .crc_out   (fcs_out)
    );

    // Header is loaded from MCU-supplied LENGTH and SERVICE for all rates.
    wire [31:0] header_load = {
        length_field[15:8],
        length_field[7:0],
        service_field,
        signal_byte_for_rate(rate_mode)
    };

    always @(*) begin
        state_next = state;
        case (state)
            S_IDLE       : if (start_pulse) state_next = S_SYNC;
            S_SYNC       : if (symbol_end && sym_cnt == PREAMBLE_SYNC_LEN - 1) state_next = S_SFD;
            S_SFD        : if (symbol_end && sym_cnt == 8'd15)                 state_next = S_HEAD;
            S_HEAD       : if (symbol_end && sym_cnt == 8'd31)                 state_next = S_HEC;
            S_HEC        : if (symbol_end && sym_cnt == 8'd15) begin
                if (cck_active) begin
                    state_next = (cck_sym_count_q == 16'd0) ? S_DONE : S_PSDU_CCK;
                end else begin
                    state_next = (payload_len_q == 16'd0) ? S_FCS_BARKER : S_PSDU_BARKER;
                end
            end
            S_PSDU_BARKER: begin
                if (symbol_end && byte_cnt == payload_len_q - 16'd1) begin
                    if ((!rate_mode_q[0] && bit_in_byte == 3'd7) ||
                        ( rate_mode_q[0] && bit_in_byte == 3'd6))
                        state_next = S_FCS_BARKER;
                end
            end
            S_FCS_BARKER : begin
                if (symbol_end) begin
                    if ((!rate_mode_q[0] && sym_cnt == 8'd31) ||
                        ( rate_mode_q[0] && sym_cnt == 8'd15))
                        state_next = S_DONE;
                end
            end
            S_PSDU_CCK   : begin
                if (symbol_end && cck_sym_cnt == cck_sym_count_q - 16'd1)
                    state_next = S_DONE;
            end
            S_DONE       : state_next = S_IDLE;
            default      : state_next = S_IDLE;
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state              <= S_IDLE;
            rate_mode_q        <= 2'd0;
            chip_cnt           <= 4'd0;
            sym_cnt            <= 8'd0;
            byte_cnt           <= 16'd0;
            cck_sym_cnt        <= 16'd0;
            bit_in_byte        <= 3'd0;
            payload_len_q      <= 16'd0;
            cck_sym_count_q    <= 16'd0;
            byte_sr            <= 8'd0;
            header_sr          <= 32'd0;
            sfd_sr             <= 16'd0;
            hec_sr             <= 16'd0;
            fcs_sr             <= 32'd0;
            cck_word_curr      <= 32'd0;
            cck_word_next      <= 32'd0;
            lfsr               <= SCRAMBLER_SEED;
            crc_init           <= 1'b0;
            underrun_flag      <= 1'b0;
            base_phase         <= 2'd0;
            delta_phi1         <= 2'd0;
            update_phi1        <= 1'b0;
            chip_valid         <= 1'b0;
            busy               <= 1'b0;
            done_pulse         <= 1'b0;
        end else begin
            state       <= state_next;
            crc_init    <= 1'b0;
            done_pulse  <= 1'b0;
            update_phi1 <= 1'b0;
            chip_valid  <= emit_chip_c;

            // Drive base_phase / delta_phi1 from the rate-appropriate source.
            base_phase  <= (state == S_PSDU_CCK) ? cck_chip_phase : base_phase_barker;
            if (symbol_start && emit_chip_c) begin
                update_phi1 <= 1'b1;
                delta_phi1  <= (state == S_PSDU_CCK) ? cck_delta_phi1 : delta_phi1_barker;
            end

            if (symbol_start && scramble_c) begin
                lfsr <= two_bit_sym_c ? lfsr_advance2 : lfsr_advance1;
            end

            if (symbol_end) chip_cnt <= 4'd0;
            else            chip_cnt <= chip_cnt + 4'd1;

            case (state)
                S_IDLE: begin
                    busy <= 1'b0;
                    if (start_pulse) begin
                        rate_mode_q     <= rate_mode;
                        payload_len_q   <= payload_len;
                        cck_sym_count_q <= cck_symbol_count;
                        sym_cnt         <= 8'd0;
                        byte_cnt        <= 16'd0;
                        cck_sym_cnt     <= 16'd0;
                        bit_in_byte     <= 3'd0;
                        chip_cnt        <= 4'd0;
                        sfd_sr          <= SFD_PATTERN;
                        header_sr       <= header_load;
                        cck_word_curr   <= 32'd0;
                        cck_word_next   <= 32'd0;
                        lfsr            <= SCRAMBLER_SEED;
                        crc_init        <= 1'b1;
                        underrun_flag   <= 1'b0;
                        busy            <= 1'b1;
                    end
                end

                S_SYNC: begin
                    if (symbol_end) begin
                        sym_cnt <= (sym_cnt == PREAMBLE_SYNC_LEN - 1) ? 8'd0 : sym_cnt + 8'd1;
                    end
                end

                S_SFD: begin
                    if (symbol_end) begin
                        sfd_sr  <= {sfd_sr[14:0], 1'b0};
                        sym_cnt <= (sym_cnt == 8'd15) ? 8'd0 : sym_cnt + 8'd1;
                    end
                end

                S_HEAD: begin
                    if (symbol_end) begin
                        header_sr <= {1'b0, header_sr[31:1]};
                        sym_cnt   <= (sym_cnt == 8'd31) ? 8'd0 : sym_cnt + 8'd1;
                    end
                end

                S_HEC: begin
                    // CCK preload: during the LAST HEC symbol's chips 4..7,
                    // pull 4 bytes from the FIFO into cck_word_next so that
                    // chip 0 of S_PSDU_CCK can emit with no bubble.
                    if (cck_active && sym_cnt == 8'd15 &&
                        chip_cnt >= 4'd4 && chip_cnt <= 4'd7 &&
                        cck_sym_count_q != 16'd0) begin
                        if (!fifo_empty) begin
                            case (chip_cnt[1:0])
                                2'd0: cck_word_next[7:0]   <= fifo_rd_data;
                                2'd1: cck_word_next[15:8]  <= fifo_rd_data;
                                2'd2: cck_word_next[23:16] <= fifo_rd_data;
                                2'd3: cck_word_next[31:24] <= fifo_rd_data;
                            endcase
                        end else begin
                            underrun_flag <= 1'b1;
                        end
                    end

                    if (symbol_end) begin
                        if (sym_cnt == 8'd0) hec_sr <= {hec_out[14:0], 1'b0};
                        else                 hec_sr <= {hec_sr[14:0], 1'b0};
                        sym_cnt <= (sym_cnt == 8'd15) ? 8'd0 : sym_cnt + 8'd1;

                        if (sym_cnt == 8'd15) begin
                            if (cck_active) begin
                                cck_word_curr <= cck_word_next;
                                cck_sym_cnt   <= 16'd0;
                            end else if (payload_len_q != 16'd0) begin
                                if (!fifo_empty) begin
                                    byte_sr <= fifo_rd_data;
                                end else begin
                                    underrun_flag <= 1'b1;
                                end
                            end
                        end
                    end
                end

                S_PSDU_BARKER: begin
                    if (symbol_end) begin
                        if ((!rate_mode_q[0] && byte_cnt == payload_len_q - 16'd1 && bit_in_byte == 3'd7) ||
                            ( rate_mode_q[0] && byte_cnt == payload_len_q - 16'd1 && bit_in_byte == 3'd6))
                            sym_cnt <= 8'd0;
                        else
                            sym_cnt <= sym_cnt + 8'd1;

                        if (!rate_mode_q[0]) begin
                            byte_sr     <= {1'b0, byte_sr[7:1]};
                            bit_in_byte <= bit_in_byte + 3'd1;
                            if (bit_in_byte == 3'd7) begin
                                byte_cnt <= byte_cnt + 16'd1;
                                if (byte_cnt != payload_len_q - 16'd1) begin
                                    if (!fifo_empty) begin
                                        byte_sr <= fifo_rd_data;
                                    end else begin
                                        underrun_flag <= 1'b1;
                                    end
                                end
                            end
                        end else begin
                            byte_sr     <= {2'b00, byte_sr[7:2]};
                            bit_in_byte <= bit_in_byte + 3'd2;
                            if (bit_in_byte == 3'd6) begin
                                byte_cnt <= byte_cnt + 16'd1;
                                if (byte_cnt != payload_len_q - 16'd1) begin
                                    if (!fifo_empty) begin
                                        byte_sr <= fifo_rd_data;
                                    end else begin
                                        underrun_flag <= 1'b1;
                                    end
                                end
                            end
                        end
                    end
                end

                S_FCS_BARKER: begin
                    if (symbol_end) begin
                        sym_cnt <= sym_cnt + 8'd1;
                        if (!rate_mode_q[0]) begin
                            if (sym_cnt == 8'd0) fcs_sr <= {1'b0, fcs_out[31:1]};
                            else                 fcs_sr <= {1'b0, fcs_sr[31:1]};
                        end else begin
                            if (sym_cnt == 8'd0) fcs_sr <= {2'b00, fcs_out[31:2]};
                            else                 fcs_sr <= {2'b00, fcs_sr[31:2]};
                        end
                    end
                end

                S_PSDU_CCK: begin
                    // Concurrent prefetch: while chips 0..3 of the CURRENT
                    // symbol emit, pull bytes 0..3 of the NEXT symbol from
                    // the FIFO.  Skip on the final symbol.
                    if (cck_sym_cnt < cck_sym_count_q - 16'd1 && chip_cnt <= 4'd3) begin
                        if (!fifo_empty) begin
                            case (chip_cnt[1:0])
                                2'd0: cck_word_next[7:0]   <= fifo_rd_data;
                                2'd1: cck_word_next[15:8]  <= fifo_rd_data;
                                2'd2: cck_word_next[23:16] <= fifo_rd_data;
                                2'd3: cck_word_next[31:24] <= fifo_rd_data;
                            endcase
                        end else begin
                            underrun_flag <= 1'b1;
                        end
                    end

                    if (symbol_end) begin
                        if (cck_sym_cnt < cck_sym_count_q - 16'd1) begin
                            cck_word_curr <= cck_word_next;
                            cck_sym_cnt   <= cck_sym_cnt + 16'd1;
                        end
                    end
                end

                S_DONE: begin
                    busy       <= 1'b0;
                    done_pulse <= 1'b1;
                end

                default: ;
            endcase
        end
    end

endmodule


// =============================================================================
// multi_mode_tx_baseband : 802.11b backscatter TX baseband.
//
// Supported PSDU rates (all on chip_i / chip_q at 11 Mchip/s):
//   mod_config = 4'b0000 : 1   Mbps DBPSK + 11-chip Barker (chip computes)
//   mod_config = 4'b0001 : 2   Mbps DQPSK + 11-chip Barker (chip computes)
//   mod_config = 4'b0010 : 5.5 Mbps CCK   (MCU pre-computes; chip streams)
//   mod_config = 4'b0011 : 11  Mbps CCK   (MCU pre-computes; chip streams)
//
// All other mod_config values are illegal, refused at start, and latched
// into invalid_mode.
//
// MCU offload contract for CCK:
//   For mod_config = 4'b001x the MCU is responsible for self-synchronous
//   scrambling, CRC-32, 8-chip CCK encoding (incl. odd-symbol +pi and
//   chip-3/chip-6 hardwired +pi), the LENGTH and SERVICE field values, and
//   the cck_symbol_count for the PLCP PSDU+FCS region.  See
//   rtl/path_a/mac_fsm_80211b.v header for the per-symbol packing format
//   on the FIFO write port.
//
// Interface notes:
//   * length_field replaces the previously-deprecated length_us port and is
//     used at every rate (Barker rates set it to LENGTH = 8 * N_octets for
//     1 Mbps or 4 * N_octets for 2 Mbps).
//   * service_field is a per-packet 8-bit input, replacing the old
//     compile-time SERVICE_FIELD_A parameter.  This lets the MCU set
//     LENGTH_EXTENSION (bit 7) and LOCKED_CLOCKS (bit 2) per packet.
//   * cck_symbol_count is read only by CCK rates; it is ignored otherwise.
//   * clk_custom, symbol_out, and symbol_valid are still retained as ports
//     for wrapper-pinout stability and remain unused.
//   * The FIFO read side is always clk_b_chip.
// =============================================================================
module multi_mode_tx_baseband #(
    parameter integer PREAMBLE_SYNC_LEN_A = 128,
    parameter [15:0]  SFD_PATTERN_A       = 16'hF3A0,
    parameter [6:0]   SCRAMBLER_SEED_A    = 7'h6D,
    parameter [10:0]  BARKER_PATTERN      = 11'b10110111000,
    parameter integer FIFO_DEPTH          = 16,
    parameter integer FIFO_ADDR_W         = 4
) (
    input  wire        clk_b_chip,
    input  wire        clk_custom,
    input  wire        clk_mcu,
    input  wire        rst_n,

    input  wire        tx_enable,
    input  wire [3:0]  mod_config,
    input  wire [15:0] payload_len,
    input  wire [15:0] length_field,
    input  wire [7:0]  service_field,
    input  wire [15:0] cck_symbol_count,

    input  wire [7:0]  payload_in,
    input  wire        payload_write,

    output wire        tx_busy,
    output wire        fifo_full,
    output wire        underrun,
    output wire        invalid_mode,
    output wire        tx_done,

    output wire [7:0]  symbol_out,
    output wire        symbol_valid,
    output wire        chip_i,
    output wire        chip_q,
    output wire        chip_valid
);

    // =======================================================================
    // Reset synchronizers
    // =======================================================================
    wire rst_n_mcu_s;
    wire rst_n_b_chip_s;

    reset_sync u_rs_mcu   (.clk(clk_mcu),    .async_rst_n(rst_n), .sync_rst_n(rst_n_mcu_s));
    reset_sync u_rs_bchip (.clk(clk_b_chip), .async_rst_n(rst_n), .sync_rst_n(rst_n_b_chip_s));

    // =======================================================================
    // Mode decode
    //   Legal: 0000, 0001, 0010, 0011.
    // =======================================================================
    reg mod_valid_c;
    always @(*) begin
        mod_valid_c = (mod_config[3:2] == 2'b00);
    end
    wire       mod_valid = mod_valid_c;
    wire [1:0] rate_mode = mod_config[1:0];

    // =======================================================================
    // tx_enable edge detect in clk_mcu
    // =======================================================================
    reg tx_enable_q;
    always @(posedge clk_mcu or negedge rst_n_mcu_s) begin
        if (!rst_n_mcu_s) tx_enable_q <= 1'b0;
        else              tx_enable_q <= tx_enable;
    end
    wire tx_enable_pulse_mcu = tx_enable & ~tx_enable_q;

    // Sticky invalid-mode flag
    reg invalid_mode_r;
    always @(posedge clk_mcu or negedge rst_n_mcu_s) begin
        if (!rst_n_mcu_s)                           invalid_mode_r <= 1'b0;
        else if (tx_enable_pulse_mcu && !mod_valid) invalid_mode_r <= 1'b1;
    end
    assign invalid_mode = invalid_mode_r;

    // Legal starts only
    wire start_mcu_a = tx_enable_pulse_mcu & mod_valid;
    wire start_pulse_a;
    pulse_sync u_ps_a (
        .src_clk(clk_mcu),    .src_rst_n(rst_n_mcu_s),    .src_pulse(start_mcu_a),
        .dst_clk(clk_b_chip), .dst_rst_n(rst_n_b_chip_s), .dst_pulse(start_pulse_a)
    );

    // =======================================================================
    // Async FIFO (MCU -> clk_b_chip only)
    // =======================================================================
    wire       fifo_rd_en;
    wire       fifo_empty;
    wire [7:0] fifo_rd_data;

    async_fifo #(
        .DATA_W(8), .DEPTH(FIFO_DEPTH), .ADDR_W(FIFO_ADDR_W)
    ) u_fifo (
        .wclk   (clk_mcu),
        .wrst_n (rst_n_mcu_s),
        .wr_en  (payload_write),
        .wr_data(payload_in),
        .full   (fifo_full),
        .rclk   (clk_b_chip),
        .rrst_n (rst_n_b_chip_s),
        .rd_en  (fifo_rd_en),
        .rd_data(fifo_rd_data),
        .empty  (fifo_empty)
    );

    // =======================================================================
    // Path A only: 802.11b 1/2/5.5/11 Mbps Long PLCP + rotator
    // =======================================================================
    wire       a_fifo_rd_en;
    wire       a_busy;
    wire       a_done;
    wire       a_underrun;
    wire [1:0] a_base_phase;
    wire [1:0] a_delta_phi1;
    wire       a_update_phi1;
    wire       a_chip_valid_to_phy;
    wire       a_chip_i;
    wire       a_chip_q;
    wire       a_chip_valid_out;

    mac_fsm_80211b #(
        .PREAMBLE_SYNC_LEN(PREAMBLE_SYNC_LEN_A),
        .SFD_PATTERN     (SFD_PATTERN_A),
        .SCRAMBLER_SEED  (SCRAMBLER_SEED_A),
        .BARKER_PATTERN  (BARKER_PATTERN)
    ) u_mac_a (
        .clk             (clk_b_chip),
        .rst_n           (rst_n_b_chip_s),
        .start_pulse     (start_pulse_a),
        .rate_mode       (rate_mode),
        .payload_len     (payload_len),
        .length_field    (length_field),
        .service_field   (service_field),
        .cck_symbol_count(cck_symbol_count),
        .busy            (a_busy),
        .done_pulse      (a_done),
        .fifo_rd_en      (a_fifo_rd_en),
        .fifo_empty      (fifo_empty),
        .fifo_rd_data    (fifo_rd_data),
        .underrun_flag   (a_underrun),
        .base_phase      (a_base_phase),
        .delta_phi1      (a_delta_phi1),
        .update_phi1     (a_update_phi1),
        .chip_valid      (a_chip_valid_to_phy)
    );

    phy_a_rotator u_phy_a (
        .clk        (clk_b_chip),
        .rst_n      (rst_n_b_chip_s),
        .start_pulse(start_pulse_a),
        .base_phase (a_base_phase),
        .delta_phi1 (a_delta_phi1),
        .update_phi1(a_update_phi1),
        .valid_chip (a_chip_valid_to_phy),
        .chip_i     (a_chip_i),
        .chip_q     (a_chip_q),
        .chip_valid (a_chip_valid_out)
    );

    assign fifo_rd_en   = a_fifo_rd_en;
    assign chip_i       = a_chip_i;
    assign chip_q       = a_chip_q;
    assign chip_valid   = a_chip_valid_out;
    assign symbol_out   = 8'd0;
    assign symbol_valid = 1'b0;

    // =======================================================================
    // tx_busy / tx_done / underrun back to clk_mcu
    // =======================================================================
    sync_2ff #(.WIDTH(1), .RESET_VAL(1'b0)) u_busy_sync (
        .clk(clk_mcu), .rst_n(rst_n_mcu_s),
        .d_in(a_busy), .d_out(tx_busy)
    );

    wire done_a_mcu;
    pulse_sync u_done_a (
        .src_clk(clk_b_chip), .src_rst_n(rst_n_b_chip_s), .src_pulse(a_done),
        .dst_clk(clk_mcu),    .dst_rst_n(rst_n_mcu_s),    .dst_pulse(done_a_mcu)
    );
    assign tx_done = done_a_mcu;

    wire a_ur_mcu;
    sync_2ff #(.WIDTH(1), .RESET_VAL(1'b0)) u_ur_a_sync (
        .clk(clk_mcu), .rst_n(rst_n_mcu_s),
        .d_in(a_underrun), .d_out(a_ur_mcu)
    );
    assign underrun = a_ur_mcu;

    // =======================================================================
    // SVA (sim-only).  Enable with +define+ASSERT_ON.
    // =======================================================================
`ifdef ASSERT_ON
    property p_mod_config_stable;
        @(posedge clk_mcu) disable iff (!rst_n_mcu_s)
            tx_busy |-> $stable(mod_config);
    endproperty
    a_mod_config_stable : assert property (p_mod_config_stable)
        else $error("mod_config changed while tx_busy was high");

    property p_payload_len_stable;
        @(posedge clk_mcu) disable iff (!rst_n_mcu_s)
            tx_busy |-> $stable(payload_len);
    endproperty
    a_payload_len_stable : assert property (p_payload_len_stable)
        else $error("payload_len changed while tx_busy was high");

    property p_tx_enable_no_overlap;
        @(posedge clk_mcu) disable iff (!rst_n_mcu_s)
            (tx_enable & ~tx_enable_q) |-> !tx_busy;
    endproperty
    a_tx_enable_no_overlap : assert property (p_tx_enable_no_overlap)
        else $error("tx_enable rising edge while tx_busy still high");

    property p_invalid_mode_latched;
        @(posedge clk_mcu) disable iff (!rst_n_mcu_s)
            (tx_enable_pulse_mcu && !mod_valid) |-> ##[0:1] invalid_mode;
    endproperty
    a_invalid_mode_latched : assert property (p_invalid_mode_latched)
        else $error("illegal mod_config was not latched into invalid_mode");
`endif

endmodule
