// =============================================================================
// multi_mode_tx_baseband_flat.v
//
// Single-file flattened RTL for synthesis of the Two-Path WiFi Encoder /
// backscatter TX baseband. Every module from rtl/cdc, rtl/common,
// rtl/path_a, rtl/path_b, and the top-level rtl/multi_mode_tx_baseband.v is
// inlined below in bottom-up dependency order, with full behavior preserved.
//
// NOTE: clock_mux_static is a behavioural MUX placeholder. Replace with the
// foundry's glitch-free clock mux cell before GDS.
// =============================================================================
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
// clock_mux_static : 2:1 clock mux intended for STATIC select only.
//
// USAGE CONSTRAINT (critical for tape-out):
//   `sel` must NOT change while either clk0 or clk1 is toggling.  The
//   project-level integration guarantees this because `mod_config` is a
//   static configuration register that is programmed BEFORE either of
//   clk_b_chip/clk_custom is un-gated.
//
// For production silicon, REPLACE this wrapper with the standard-cell
// library's glitch-free clock mux (e.g. CKMUX2D* in most foundry kits)
// and declare it as a clock in SDC.  Do not leave a generic MUX on a clock
// path in the final netlist.
// =============================================================================
module clock_mux_static (
    input  wire sel,       // 0 -> clk0, 1 -> clk1
    input  wire clk0,
    input  wire clk1,
    output wire clk_out
);
    assign clk_out = sel ? clk1 : clk0;
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
// mac_fsm_80211b : 802.11b Long PLCP MAC/PLCP engine for all four rates.
//
//   mod_config[1:0]
//     00 : 1 Mbps DBPSK + Barker (11 chips/sym, 1 bit/sym)
//     01 : 2 Mbps DQPSK + Barker (11 chips/sym, 2 bit/sym)
//     10 : 5.5 Mbps CCK          ( 8 chips/sym, 4 data bits/sym)
//     11 : 11 Mbps CCK           ( 8 chips/sym, 8 data bits/sym)
//
// Clock domain: `clk_b_chip` (11 MHz) -- the MAC now runs in the chip
// domain, emits one chip's worth of `base_phase` / `delta_phi1` /
// `update_phi1` to the rotator PHY every 11 MHz cycle, and tracks a
// per-state chip counter (0..10 for Barker, 0..7 for CCK).
//
// Scrambler / CRC strategy:
//
//   - SCRAMBLER, CRC-16 HEC and CRC-32 FCS run on chip for 1/2 Mbps.
//     Scrambler is initialized at packet start; all 192 preamble+header
//     bits are scrambled; continues into PSDU/FCS for 1/2 Mbps.
//   - For CCK PSDU (5.5 / 11 Mbps), the MCU has already applied
//     scrambler + FCS off-chip and pre-encoded each CCK symbol as a
//     16-bit word { c6, c5, c4, c3, c2, c1, c0, delta_phi1 } (little-
//     endian across two FIFO bytes).  The chip-side scrambler/CRC are
//     held idle during S_PSDU_CCK; the MCU is responsible for starting
//     its own scrambler from the deterministic state reached at end of
//     header (seed + 192 advances).
//
// PLCP framing (Long PLCP, 802.11-2016 sec 16.2.2):
//   SYNC(128) | SFD(16) | SIGNAL(8) | SERVICE(8) | LENGTH(16) | HEC(16) | PSDU+FCS
//   - Preamble + header are ALWAYS 1 Mbps DBPSK + Barker.
//   - PSDU portion's PHY encoding depends on mod_config.
// =============================================================================
module mac_fsm_80211b #(
    parameter integer PREAMBLE_SYNC_LEN = 128,
    parameter [15:0]  SFD_PATTERN       = 16'hF3A0,
    parameter [7:0]   SERVICE_FIELD     = 8'h00,      // bit[2] advertises locked clocks
    parameter [6:0]   SCRAMBLER_SEED    = 7'h6D,
    parameter [10:0]  BARKER_PATTERN    = 11'b10110111000
) (
    input  wire        clk,                          // clk_b_chip
    input  wire        rst_n,

    input  wire        start_pulse,
    input  wire [1:0]  rate,                         // mod_config[1:0]
    input  wire [15:0] payload_len,                  // PSDU octets (excl FCS)
    input  wire [15:0] length_us,                    // MCU-computed LENGTH field

    output reg         busy,
    output reg         done_pulse,

    // FIFO read port
    output reg         fifo_rd_en,
    input  wire        fifo_empty,
    input  wire [7:0]  fifo_rd_data,
    output reg         underrun_flag,

    // To PHY rotator
    output reg  [1:0]  base_phase,
    output reg  [1:0]  delta_phi1,
    output reg         update_phi1,
    output reg         chip_valid
);

    // ------------------------------------------------------------------
    // SIGNAL byte lookup (802.11-2016 sec 16.2.3.4)
    // ------------------------------------------------------------------
    function [7:0] signal_byte_for_rate;
        input [1:0] r;
        case (r)
            2'b00  : signal_byte_for_rate = 8'h0A;   // 1 Mbps DBPSK
            2'b01  : signal_byte_for_rate = 8'h14;   // 2 Mbps DQPSK
            2'b10  : signal_byte_for_rate = 8'h37;   // 5.5 Mbps CCK
            2'b11  : signal_byte_for_rate = 8'h6E;   // 11 Mbps CCK
            default: signal_byte_for_rate = 8'h0A;
        endcase
    endfunction

    // ------------------------------------------------------------------
    // States
    // ------------------------------------------------------------------
    localparam [3:0]
        S_IDLE         = 4'd0,
        S_SYNC         = 4'd1,
        S_SFD          = 4'd2,
        S_HEAD         = 4'd3,
        S_HEC          = 4'd4,
        S_PSDU_BARKER  = 4'd5,
        S_FCS_BARKER   = 4'd6,
        S_PSDU_CCK     = 4'd7,
        S_DONE         = 4'd8;

    reg [3:0] state, state_next;
    reg [1:0] rate_q;

    // Chip-within-symbol counter and its max (10 for Barker, 7 for CCK).
    reg  [3:0] chip_cnt;
    wire [3:0] chip_cnt_max = (state == S_PSDU_CCK) ? 4'd7 : 4'd10;
    wire       symbol_start = (chip_cnt == 4'd0);
    wire       symbol_end   = (chip_cnt == chip_cnt_max);

    // Symbol-level bookkeeping
    reg [15:0] payload_len_q;
    reg [15:0] length_us_q;
    reg [7:0]  sym_cnt;        // covers up to 128 (SYNC)
    reg [15:0] byte_cnt;
    reg [2:0]  bit_in_byte;
    reg [15:0] cck_sym_total;  // total CCK symbols for PSDU+FCS
    reg [15:0] cck_sym_cnt;

    // Per-state shift registers
    reg [7:0]  byte_sr;
    reg [31:0] header_sr;
    reg [15:0] sfd_sr;
    reg [15:0] hec_sr;
    reg [31:0] fcs_sr;

    // CCK symbol word latched from 2 FIFO bytes: {c6,c5,c4,c3,c2,c1,c0,delta_phi1}
    reg [15:0] cck_word;

    // ------------------------------------------------------------------
    // CRCs (only valid for 1/2 Mbps; idle for CCK)
    // ------------------------------------------------------------------
    reg         crc_init;
    wire [15:0] hec_out;
    wire [31:0] fcs_out;

    // ------------------------------------------------------------------
    // Combinational per-symbol "what raw bit(s) are we emitting?"
    // ------------------------------------------------------------------
    reg        raw_bit_c;         // first/only bit of the symbol (for DBPSK, SYNC, SFD, HEAD, HEC, FCS)
    reg        raw_bit2_c;        // second bit of the symbol (DQPSK only)
    reg        scramble_c;        // XOR with LFSR before using
    reg        two_bit_sym_c;     // DQPSK: symbol has 2 data bits
    reg        feed_hec_c;        // this symbol's raw bit feeds HEC CRC
    reg        feed_fcs_c;        // this symbol's raw bit feeds FCS CRC
    reg        cck_mode_c;        // CCK PSDU: use cck_word, not Barker
    reg        emit_chip_c;       // there is a valid chip to emit this cycle

    // First-cycle detection for loading CRC output into the shift reg.
    wire first_hec_cycle = (state == S_HEC)        && (sym_cnt == 8'd0) && symbol_start;
    wire first_fcs_cycle = (state == S_FCS_BARKER) && (sym_cnt == 8'd0) && symbol_start;
    wire [15:0] hec_source = (state == S_HEC        && sym_cnt == 8'd0) ? hec_out : hec_sr;
    wire [31:0] fcs_source = (state == S_FCS_BARKER && sym_cnt == 8'd0) ? fcs_out : fcs_sr;

    always @(*) begin
        raw_bit_c     = 1'b0;
        raw_bit2_c    = 1'b0;
        scramble_c    = 1'b0;
        two_bit_sym_c = 1'b0;
        feed_hec_c    = 1'b0;
        feed_fcs_c    = 1'b0;
        cck_mode_c    = 1'b0;
        emit_chip_c   = 1'b0;

        case (state)
            S_SYNC: begin
                raw_bit_c   = 1'b1;
                scramble_c  = 1'b1;
                emit_chip_c = 1'b1;
            end
            S_SFD: begin
                raw_bit_c   = sfd_sr[15];        // MSB first
                scramble_c  = 1'b1;
                emit_chip_c = 1'b1;
            end
            S_HEAD: begin
                raw_bit_c   = header_sr[0];      // LSB first per octet
                scramble_c  = 1'b1;
                feed_hec_c  = 1'b1;
                emit_chip_c = 1'b1;
            end
            S_HEC: begin
                raw_bit_c   = hec_source[15];    // MSB first
                scramble_c  = 1'b1;
                emit_chip_c = 1'b1;
            end
            S_PSDU_BARKER: begin
                raw_bit_c     = byte_sr[0];
                raw_bit2_c    = byte_sr[1];
                scramble_c    = 1'b1;
                two_bit_sym_c = (rate_q == 2'b01);  // DQPSK takes 2 bits
                feed_fcs_c    = 1'b1;
                emit_chip_c   = 1'b1;
            end
            S_FCS_BARKER: begin
                raw_bit_c     = fcs_source[0];     // LSB first
                raw_bit2_c    = fcs_source[1];
                scramble_c    = 1'b1;
                two_bit_sym_c = (rate_q == 2'b01);
                emit_chip_c   = 1'b1;
            end
            S_PSDU_CCK: begin
                cck_mode_c  = 1'b1;
                emit_chip_c = 1'b1;
            end
            default: ;
        endcase
    end

    // ------------------------------------------------------------------
    // Self-synchronous scrambler state (x^7 + x^4 + 1).  Advances at
    // symbol_start for states where scramble_c is asserted, by 1 step
    // (DBPSK-like) or 2 serialized steps (DQPSK) per symbol.  Idle
    // during S_PSDU_CCK because the MCU precomputes the CCK payload path.
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

    // delta_phi1 for Barker-based symbols.
    // DBPSK (1 bit):  0 -> +0 (phase delta 0),    1 -> +pi (phase delta 2)
    // DQPSK (dibit): IEEE 802.11b Table 11, with s0 transmitted first:
    //   s0 s1 = 00 -> 0, 01 -> +pi/2, 11 -> +pi, 10 -> +3pi/2.
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

    // Barker base phase for chip_cnt: '1'-chip -> phase 0, '0'-chip -> phase 2.
    wire barker_chip_bit = BARKER_PATTERN[10 - chip_cnt[3:0]];
    wire [1:0] base_phase_barker = barker_chip_bit ? 2'b00 : 2'b10;

    // CCK: base_phase = c_k from the latched cck_word; c7 is always 0.
    //   c0 is bits [3:2], c1 [5:4], ... c6 [15:14].
    reg [1:0] base_phase_cck;
    always @(*) begin
        case (chip_cnt[2:0])
            3'd0: base_phase_cck = cck_word[3:2];
            3'd1: base_phase_cck = cck_word[5:4];
            3'd2: base_phase_cck = cck_word[7:6];
            3'd3: base_phase_cck = cck_word[9:8];
            3'd4: base_phase_cck = cck_word[11:10];
            3'd5: base_phase_cck = cck_word[13:12];
            3'd6: base_phase_cck = cck_word[15:14];
            3'd7: base_phase_cck = 2'b00;        // c7 = 0 by construction
            default: base_phase_cck = 2'b00;
        endcase
    end

    // CCK delta_phi1 at symbol_start comes from the low 2 bits of cck_word.
    wire [1:0] delta_phi1_cck = cck_word[1:0];

    // ------------------------------------------------------------------
    // HEC / FCS instances
    // ------------------------------------------------------------------
    crc16_80211_hec u_hec (
        .clk(clk), .rst_n(rst_n), .init(crc_init),
        .data_valid(symbol_start & feed_hec_c),
        .data_bit  (raw_bit_c),
        .crc_out   (hec_out)
    );

    // CRC-32 FCS: for DQPSK we feed 2 bits per symbol; need to advance twice.
    // Easiest: feed s0 at symbol_start and s1 on the next cycle when two_bit_sym_c.
    // Implemented with a 1-shot delayed valid signal.
    reg        fcs_feed_second_cycle;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)                          fcs_feed_second_cycle <= 1'b0;
        else if (symbol_start & feed_fcs_c & two_bit_sym_c)
                                             fcs_feed_second_cycle <= 1'b1;
        else                                 fcs_feed_second_cycle <= 1'b0;
    end
    crc32_80211 u_fcs (
        .clk(clk), .rst_n(rst_n), .init(crc_init),
        .data_valid((symbol_start & feed_fcs_c) | fcs_feed_second_cycle),
        .data_bit  (fcs_feed_second_cycle ? raw_bit2_c : raw_bit_c),
        .crc_out   (fcs_out)
    );

    // ------------------------------------------------------------------
    // Header-field load value (LSB-first byte order)
    // ------------------------------------------------------------------
    function service_length_ext_bit;
        input [1:0]  r;
        input [15:0] payload_octets;
        input [15:0] tx_length_us;
        reg   [16:0] total_octets;
        reg   [20:0] rx_octets_no_ext;
        begin
            if (r == 2'b11) begin
                total_octets     = {1'b0, payload_octets} + 17'd4;
                rx_octets_no_ext = ({5'd0, tx_length_us} * 5'd11) >> 3;
                service_length_ext_bit = (rx_octets_no_ext > total_octets);
            end else begin
                service_length_ext_bit = 1'b0;
            end
        end
    endfunction
    wire [7:0]  signal_byte_c  = signal_byte_for_rate(rate);
    wire [7:0]  service_byte_c =
        { service_length_ext_bit(rate, payload_len, length_us),
          3'b000,
          1'b0,
          SERVICE_FIELD[2],
          2'b00 };
    wire [31:0] header_load    = { length_us[15:8], length_us[7:0], service_byte_c, signal_byte_c };

    // ------------------------------------------------------------------
    // Total CCK symbol count for PSDU+FCS.
    //   CCK-11: (payload_len*8 + 32) / 8 = payload_len + 4
    //   CCK-5.5:(payload_len*8 + 32) / 4 = 2*payload_len + 8
    // ------------------------------------------------------------------
    wire [15:0] cck_sym_total_load =
        (rate == 2'b11) ? (payload_len + 16'd4)
                        : ({payload_len, 1'b0} + 16'd8);  // 2*payload_len + 8

    // ------------------------------------------------------------------
    // Next-state logic
    // ------------------------------------------------------------------
    always @(*) begin
        state_next = state;
        case (state)
            S_IDLE: if (start_pulse) state_next = S_SYNC;
            S_SYNC: if (symbol_end && sym_cnt == PREAMBLE_SYNC_LEN - 1) state_next = S_SFD;
            S_SFD : if (symbol_end && sym_cnt == 8'd15)                 state_next = S_HEAD;
            S_HEAD: if (symbol_end && sym_cnt == 8'd31)                 state_next = S_HEC;
            S_HEC : if (symbol_end && sym_cnt == 8'd15) begin
                if (rate_q[1])  // CCK rates
                    state_next = S_PSDU_CCK;
                else if (payload_len_q == 16'd0)
                    state_next = S_FCS_BARKER;
                else
                    state_next = S_PSDU_BARKER;
            end
            S_PSDU_BARKER: begin
                // DBPSK: 8 bits per byte, DQPSK: 4 dibits per byte.
                if (symbol_end && byte_cnt == payload_len_q - 16'd1) begin
                    if ((rate_q == 2'b00 && bit_in_byte == 3'd7) ||
                        (rate_q == 2'b01 && bit_in_byte == 3'd6))
                        state_next = S_FCS_BARKER;
                end
            end
            S_FCS_BARKER: begin
                // DBPSK: 32 symbols; DQPSK: 16 symbols.
                if (symbol_end) begin
                    if ((rate_q == 2'b00 && sym_cnt == 8'd31) ||
                        (rate_q == 2'b01 && sym_cnt == 8'd15))
                        state_next = S_DONE;
                end
            end
            S_PSDU_CCK: begin
                if (symbol_end && cck_sym_cnt == cck_sym_total - 16'd1)
                    state_next = S_DONE;
            end
            S_DONE: state_next = S_IDLE;
            default: state_next = S_IDLE;
        endcase
    end

    // ------------------------------------------------------------------
    // Sequential update
    // ------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state              <= S_IDLE;
            rate_q             <= 2'd0;
            chip_cnt           <= 4'd0;
            sym_cnt            <= 8'd0;
            byte_cnt           <= 16'd0;
            bit_in_byte        <= 3'd0;
            payload_len_q      <= 16'd0;
            length_us_q        <= 16'd0;
            cck_sym_total      <= 16'd0;
            cck_sym_cnt        <= 16'd0;
            byte_sr            <= 8'd0;
            header_sr          <= 32'd0;
            sfd_sr             <= 16'd0;
            hec_sr             <= 16'd0;
            fcs_sr             <= 32'd0;
            cck_word           <= 16'd0;
            lfsr               <= SCRAMBLER_SEED;
            crc_init           <= 1'b0;
            fifo_rd_en         <= 1'b0;
            underrun_flag      <= 1'b0;
            base_phase         <= 2'd0;
            delta_phi1         <= 2'd0;
            update_phi1        <= 1'b0;
            chip_valid         <= 1'b0;
            busy               <= 1'b0;
            done_pulse         <= 1'b0;
        end else begin
            state       <= state_next;
            fifo_rd_en  <= 1'b0;
            crc_init    <= 1'b0;
            done_pulse  <= 1'b0;
            update_phi1 <= 1'b0;
            chip_valid  <= emit_chip_c;

            // ----- Per-chip PHY drive -----
            base_phase <= cck_mode_c ? base_phase_cck : base_phase_barker;
            if (symbol_start && emit_chip_c) begin
                update_phi1 <= 1'b1;
                delta_phi1  <= cck_mode_c ? delta_phi1_cck : delta_phi1_barker;
            end

            // ----- Scrambler advance at symbol_start (Barker states only) -----
            if (symbol_start && scramble_c) begin
                lfsr <= two_bit_sym_c ? lfsr_advance2 : lfsr_advance1;
            end

            // ----- Chip counter -----
            if (symbol_end) chip_cnt <= 4'd0;
            else            chip_cnt <= chip_cnt + 4'd1;

            // ----- State-specific bookkeeping (only at symbol_end, when we
            //       advance to the next symbol, do we update sym_cnt et al) -----
            case (state)
                S_IDLE: begin
                    busy <= 1'b0;
                    if (start_pulse) begin
                        rate_q          <= rate;
                        payload_len_q   <= payload_len;
                        length_us_q     <= length_us;
                        cck_sym_total   <= cck_sym_total_load;
                        sym_cnt         <= 8'd0;
                        byte_cnt        <= 16'd0;
                        bit_in_byte     <= 3'd0;
                        cck_sym_cnt     <= 16'd0;
                        chip_cnt        <= 4'd0;
                        sfd_sr          <= SFD_PATTERN;
                        header_sr       <= header_load;
                        lfsr            <= SCRAMBLER_SEED;
                        crc_init        <= 1'b1;
                        underrun_flag   <= 1'b0;
                        busy            <= 1'b1;
                    end
                end

                S_SYNC: begin
                    if (symbol_end) begin
                        sym_cnt <= (sym_cnt == PREAMBLE_SYNC_LEN - 1) ? 8'd0
                                                                      : sym_cnt + 8'd1;
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
                    if (symbol_end) begin
                        if (sym_cnt == 8'd0) hec_sr <= {hec_out[14:0], 1'b0};
                        else                 hec_sr <= {hec_sr[14:0], 1'b0};
                        sym_cnt <= (sym_cnt == 8'd15) ? 8'd0 : sym_cnt + 8'd1;

                        if (sym_cnt == 8'd15 && payload_len_q != 16'd0 && !rate_q[1]) begin
                            if (!fifo_empty) begin
                                byte_sr <= fifo_rd_data;
                                if (payload_len_q > 16'd1) fifo_rd_en <= 1'b1;
                            end else begin
                                underrun_flag <= 1'b1;
                            end
                        end
                        if (sym_cnt == 8'd15 && rate_q[1]) begin
                            if (!fifo_empty) begin
                                cck_word[7:0] <= fifo_rd_data;
                                fifo_rd_en    <= 1'b1;   // advance to the first symbol's high byte
                            end else begin
                                underrun_flag <= 1'b1;
                            end
                        end
                    end
                end

                S_PSDU_BARKER: begin
                    if (symbol_end) begin
                        // sym_cnt tracks symbols within S_PSDU_BARKER for
                        // diagnostic purposes; more importantly, reset to 0
                        // on the final PSDU symbol so `S_FCS_BARKER` enters
                        // with sym_cnt == 0 (first_fcs_cycle detection).
                        if ((rate_q == 2'b00 && byte_cnt == payload_len_q - 16'd1 && bit_in_byte == 3'd7) ||
                            (rate_q == 2'b01 && byte_cnt == payload_len_q - 16'd1 && bit_in_byte == 3'd6))
                            sym_cnt <= 8'd0;
                        else
                            sym_cnt <= sym_cnt + 8'd1;

                        if (rate_q == 2'b00) begin
                            // DBPSK: 1 bit per symbol, 8 bits per byte.
                            byte_sr     <= {1'b0, byte_sr[7:1]};
                            bit_in_byte <= bit_in_byte + 3'd1;
                            if (bit_in_byte == 3'd7) begin
                                byte_cnt <= byte_cnt + 16'd1;
                                if (byte_cnt != payload_len_q - 16'd1) begin
                                    if (!fifo_empty) begin
                                        byte_sr <= fifo_rd_data;
                                        if (byte_cnt != payload_len_q - 16'd2)
                                            fifo_rd_en <= 1'b1;
                                    end else begin
                                        underrun_flag <= 1'b1;
                                    end
                                end
                            end
                        end else begin
                            // DQPSK: 2 bits per symbol, 4 dibits per byte.
                            byte_sr     <= {2'b00, byte_sr[7:2]};
                            bit_in_byte <= bit_in_byte + 3'd2;
                            if (bit_in_byte == 3'd6) begin
                                byte_cnt <= byte_cnt + 16'd1;
                                if (byte_cnt != payload_len_q - 16'd1) begin
                                    if (!fifo_empty) begin
                                        byte_sr <= fifo_rd_data;
                                        if (byte_cnt != payload_len_q - 16'd2)
                                            fifo_rd_en <= 1'b1;
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
                        if (rate_q == 2'b00) begin
                            if (sym_cnt == 8'd0) fcs_sr <= {1'b0, fcs_out[31:1]};
                            else                 fcs_sr <= {1'b0, fcs_sr[31:1]};
                        end else begin
                            // DQPSK consumes 2 bits per symbol.
                            if (sym_cnt == 8'd0) fcs_sr <= {2'b00, fcs_out[31:2]};
                            else                 fcs_sr <= {2'b00, fcs_sr[31:2]};
                        end
                    end
                end

                S_PSDU_CCK: begin
                    if (symbol_end) begin
                        cck_sym_cnt <= cck_sym_cnt + 16'd1;
                        if (cck_sym_cnt != cck_sym_total - 16'd1) begin
                            if (!fifo_empty) begin
                                cck_word[7:0] <= fifo_rd_data;
                                fifo_rd_en    <= 1'b1;  // advance next symbol low -> high
                            end else begin
                                underrun_flag <= 1'b1;
                            end
                        end
                    end
                    if (chip_cnt == 4'd1) begin
                        cck_word[15:8] <= fifo_rd_data;
                        if (cck_sym_cnt != cck_sym_total - 16'd1) begin
                            if (!fifo_empty) fifo_rd_en    <= 1'b1;
                            else             underrun_flag <= 1'b1;
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
// mac_fsm_custom : Custom (Path B) MAC engine running on clk_custom (up to
// 100 MHz).  Produces one scrambled information bit per `bit_valid` cycle;
// the PHY S2P grouper accumulates these bits into QAM symbols.
//
// Packet format (spec questions Q9, Q10):
//   CUSTOM_PREAMBLE : CUSTOM_PREAMBLE_LEN bits of CUSTOM_PREAMBLE_PAT
//                     (LSB-first), RAW (not scrambled, not CRC-fed).  Used
//                     by the receiver for AGC and symbol-timing recovery.
//   PAYLOAD         : payload_len bytes, LSB-first, scrambled, CRC-fed.
//   FCS             : 32-bit finalized CRC-32, LSB-first, scrambled, NOT
//                     CRC-fed.
//
// The CRC and scrambler are fresh instances (separate from Path A), per MAS
// sec 4 Block C.  They are reset/reseeded on every `start_pulse`.
// =============================================================================
module mac_fsm_custom #(
    parameter integer CUSTOM_PREAMBLE_LEN  = 32,
    parameter [31:0]  CUSTOM_PREAMBLE_PAT  = 32'hAAAAAAAA,
    parameter [6:0]   SCRAMBLER_SEED       = 7'h5D
) (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        start_pulse,
    input  wire [15:0] payload_len,
    output reg         busy,
    output reg         done_pulse,

    // FWFT FIFO read port
    output reg         fifo_rd_en,
    input  wire        fifo_empty,
    input  wire [7:0]  fifo_rd_data,
    output reg         underrun_flag,

    // One bit per `bit_valid` cycle (scrambled from HEADER onwards).
    output reg         bit_valid,
    output reg         bit_out
);

    // -----------------------------------------------------------------------
    // State
    // -----------------------------------------------------------------------
    localparam [2:0]
        S_IDLE           = 3'd0,
        S_PREAMBLE       = 3'd1,
        S_PAYLOAD        = 3'd2,
        S_FCS            = 3'd3,
        S_DONE           = 3'd4;

    reg [2:0] state, state_next;

    reg [15:0] preamble_cnt;    // must cover CUSTOM_PREAMBLE_LEN (<=65535).
    reg [7:0]  fcs_cnt;         // 0..31 for FCS.
    reg [15:0] byte_cnt;
    reg [2:0]  bit_in_byte;
    reg [15:0] payload_len_q;
    reg [7:0]  byte_sr;
    reg [31:0] preamble_sr;     // only low CUSTOM_PREAMBLE_LEN bits used.
    reg [31:0] fcs_sr;

    // -----------------------------------------------------------------------
    // Combinational "next bit"
    // -----------------------------------------------------------------------
    reg raw_bit_c;
    reg scramble_c;
    reg feed_crc_c;
    reg valid_c;

    wire first_fcs_cycle = (state == S_FCS) && (fcs_cnt == 8'd0);
    wire [31:0] crc_out;
    wire [31:0] fcs_source = first_fcs_cycle ? crc_out : fcs_sr;

    always @(*) begin
        raw_bit_c  = 1'b0;
        scramble_c = 1'b0;
        feed_crc_c = 1'b0;
        valid_c    = 1'b0;
        case (state)
            S_PREAMBLE: begin
                raw_bit_c = preamble_sr[0];
                valid_c   = 1'b1;
            end
            S_PAYLOAD: begin
                raw_bit_c  = byte_sr[0];
                scramble_c = 1'b1;
                feed_crc_c = 1'b1;
                valid_c    = 1'b1;
            end
            S_FCS: begin
                raw_bit_c  = fcs_source[0];
                scramble_c = 1'b1;
                feed_crc_c = 1'b0;
                valid_c    = 1'b1;
            end
            default: ;
        endcase
    end

    // -----------------------------------------------------------------------
    // CRC instance
    // -----------------------------------------------------------------------
    reg crc_init;
    crc32_80211 u_crc (
        .clk        (clk),
        .rst_n      (rst_n),
        .init       (crc_init),
        .data_valid (valid_c & feed_crc_c),
        .data_bit   (raw_bit_c),
        .crc_out    (crc_out)
    );

    // -----------------------------------------------------------------------
    // Self-synchronous scrambler state (advanced on scrambled bits)
    // -----------------------------------------------------------------------
    reg  [6:0] lfsr;
    wire       scrambled_bit = raw_bit_c ^ lfsr[6] ^ lfsr[3];

    // -----------------------------------------------------------------------
    // Next-state
    // -----------------------------------------------------------------------
    always @(*) begin
        state_next = state;
        case (state)
            S_IDLE     : if (start_pulse)                               state_next = S_PREAMBLE;
            S_PREAMBLE : if (preamble_cnt == CUSTOM_PREAMBLE_LEN - 1)
                             state_next = (payload_len_q == 16'd0) ? S_FCS : S_PAYLOAD;
            S_PAYLOAD  : if ((byte_cnt == payload_len_q - 1) &&
                             (bit_in_byte == 3'd7))                    state_next = S_FCS;
            S_FCS      : if (fcs_cnt == 8'd31)                          state_next = S_DONE;
            S_DONE     :                                                state_next = S_IDLE;
            default    :                                                state_next = S_IDLE;
        endcase
    end

    // -----------------------------------------------------------------------
    // Sequential
    // -----------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state         <= S_IDLE;
            preamble_cnt  <= 16'd0;
            fcs_cnt       <= 8'd0;
            byte_cnt      <= 16'd0;
            bit_in_byte   <= 3'd0;
            payload_len_q <= 16'd0;
            byte_sr       <= 8'd0;
            preamble_sr   <= 32'd0;
            fcs_sr        <= 32'd0;
            lfsr          <= SCRAMBLER_SEED;
            crc_init      <= 1'b0;
            fifo_rd_en    <= 1'b0;
            underrun_flag <= 1'b0;
            bit_valid     <= 1'b0;
            bit_out       <= 1'b0;
            busy          <= 1'b0;
            done_pulse    <= 1'b0;
        end else begin
            state      <= state_next;
            fifo_rd_en <= 1'b0;
            crc_init   <= 1'b0;
            done_pulse <= 1'b0;

            bit_valid <= valid_c;
            bit_out   <= scramble_c ? scrambled_bit : raw_bit_c;

            if (valid_c && scramble_c) begin
                lfsr <= {scrambled_bit, lfsr[6:1]};
            end

            case (state)
                S_IDLE: begin
                    busy <= 1'b0;
                    if (start_pulse) begin
                        payload_len_q <= payload_len;
                        preamble_cnt  <= 16'd0;
                        fcs_cnt       <= 8'd0;
                        byte_cnt      <= 16'd0;
                        bit_in_byte   <= 3'd0;
                        preamble_sr   <= CUSTOM_PREAMBLE_PAT;
                        lfsr          <= SCRAMBLER_SEED;
                        crc_init      <= 1'b1;
                        underrun_flag <= 1'b0;
                        busy          <= 1'b1;
                    end
                end

                S_PREAMBLE: begin
                    preamble_sr  <= {1'b0, preamble_sr[31:1]};
                    preamble_cnt <= preamble_cnt + 1'b1;

                    if ((preamble_cnt == CUSTOM_PREAMBLE_LEN - 1) &&
                        (payload_len_q != 16'd0)) begin
                        if (!fifo_empty) begin
                            byte_sr <= fifo_rd_data;
                            if (payload_len_q > 16'd1) fifo_rd_en <= 1'b1;
                        end else begin
                            underrun_flag <= 1'b1;
                        end
                    end
                end

                S_PAYLOAD: begin
                    byte_sr     <= {1'b0, byte_sr[7:1]};
                    bit_in_byte <= bit_in_byte + 1'b1;

                    if (bit_in_byte == 3'd7) begin
                        byte_cnt <= byte_cnt + 1'b1;
                        if (byte_cnt != payload_len_q - 1) begin
                            if (!fifo_empty) begin
                                byte_sr <= fifo_rd_data;
                                if (byte_cnt != payload_len_q - 16'd2)
                                    fifo_rd_en <= 1'b1;
                            end else begin
                                underrun_flag <= 1'b1;
                            end
                        end
                    end
                end

                S_FCS: begin
                    if (fcs_cnt == 8'd0) fcs_sr <= {1'b0, crc_out[31:1]};
                    else                 fcs_sr <= {1'b0, fcs_sr[31:1]};
                    fcs_cnt <= fcs_cnt + 1'b1;
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
// phy_qam_custom : Variable S2P grouper for Path B.  Collects a bit stream
// from the custom MAC and emits an N-bit parallel symbol where N is a
// function of `mod_config`:
//
//   mod_config  |  N (bits/symbol)  |  Output placement
//   ------------+-------------------+-------------------
//   000 (OOK)   |  1                |  path_b_symbol[0]
//   001 (QPSK)  |  2                |  path_b_symbol[1:0]
//   010 (16QAM) |  4                |  path_b_symbol[3:0]
//   011 (64QAM) |  6                |  path_b_symbol[5:0]
//   100 (256QAM)|  8                |  path_b_symbol[7:0]
//   other       |  (undefined)      |  all zero (idle)
//
// The encoding matches mod_config[2:0] as passed by the top level (see
// Multi-Mode_TX_Architecture.md ??1).  mod_config[3]=1 selects Path B at
// the top; that bit is stripped before reaching this module.
//
// Accumulation convention: the first bit received lands in the symbol LSB;
// the Nth bit lands in bit N-1.  Upper bits above N-1 are hard-wired to 0
// per MAS sec 4 Block C ("Zero-Padding").
//
// Per-packet reset (fix for cross-packet bit spill-over):
//   `start_pulse` is asserted for one clk cycle at the start of each PPDU
//   (same pulse that starts the custom MAC).  It zeroes the accumulator
//   (`cnt`, `sr`) so the first bit of the new packet lands cleanly in the
//   LSB of the first symbol.  Without this reset, if a prior packet ended
//   mid-symbol (PREAMBLE_LEN + PSDU_BITS + 32 not a multiple of N), the
//   next packet's first symbol would mix leftover bits from the previous
//   packet with new preamble bits.  `end_pulse` flushes any residual bits as
//   one final zero-padded symbol so the trailing payload/FCS bits are not lost.
// =============================================================================
module phy_qam_custom (
    input  wire       clk,
    input  wire       rst_n,

    input  wire       start_pulse,     // sync reset of the S2P accumulator
    input  wire       end_pulse,       // flush a final partial symbol
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
            3'b000 : bits_per_sym = 4'd1;  // OOK
            3'b001 : bits_per_sym = 4'd2;  // QPSK
            3'b010 : bits_per_sym = 4'd4;  // 16-QAM
            3'b011 : bits_per_sym = 4'd6;  // 64-QAM
            3'b100 : bits_per_sym = 4'd8;  // 256-QAM
            default: bits_per_sym = 4'd0;  // invalid
        endcase
    end

    assign invalid_mode = (bits_per_sym == 4'd0) && bit_valid;

    reg [7:0] sr;
    reg [3:0] cnt;

    // Incoming bit enters at the MSB so that after N shifts the first bit
    // lands at position (8-N) and the last lands at bit 7.  Reading
    // sr_next[7 : 8-N] then yields { last_received, ..., first_received },
    // which matches the "first bit at symbol LSB" convention.
    wire [7:0] sr_next = {bit_in, sr[7:1]};

    function [7:0] pack_symbol;
        input [3:0] used_bits;
        input [7:0] shift_reg;
        begin
            case (used_bits)
                4'd1: pack_symbol = {7'd0, shift_reg[7]};
                4'd2: pack_symbol = {6'd0, shift_reg[7:6]};
                4'd3: pack_symbol = {5'd0, shift_reg[7:5]};
                4'd4: pack_symbol = {4'd0, shift_reg[7:4]};
                4'd5: pack_symbol = {3'd0, shift_reg[7:3]};
                4'd6: pack_symbol = {2'd0, shift_reg[7:2]};
                4'd7: pack_symbol = {1'd0, shift_reg[7:1]};
                4'd8: pack_symbol =        shift_reg[7:0];
                default: pack_symbol = 8'd0;
            endcase
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sr                  <= 8'd0;
            cnt                 <= 4'd0;
            path_b_symbol       <= 8'd0;
            path_b_symbol_valid <= 1'b0;
        end else begin
            path_b_symbol_valid <= 1'b0;

            // Per-packet sync reset takes priority so a residual cnt/sr
            // from the previous packet cannot leak bits into this one.
            if (start_pulse) begin
                sr  <= 8'd0;
                cnt <= 4'd0;
            end else if (bit_valid && bits_per_sym != 4'd0) begin
                sr  <= sr_next;
                if (cnt + 1'b1 == bits_per_sym) begin
                    cnt <= 4'd0;
                    path_b_symbol <= pack_symbol(bits_per_sym, sr_next);
                    path_b_symbol_valid <= 1'b1;
                end else begin
                    cnt <= cnt + 1'b1;
                end
            end else if (end_pulse && cnt != 4'd0) begin
                path_b_symbol       <= pack_symbol(cnt, sr);
                path_b_symbol_valid <= 1'b1;
                sr                  <= 8'd0;
                cnt                 <= 4'd0;
            end
        end
    end

endmodule



// =============================================================================
// multi_mode_tx_baseband : top-level backscatter TX baseband (multi-rate).
//
// Two mutually-exclusive datapaths selected by `mod_config[3]`:
//
//   mod_config[3] = 0 : Path A -- 802.11b Long PLCP, full compliance.
//       mod_config[2:0]:
//         000 : 1 Mbps   DBPSK + Barker
//         001 : 2 Mbps   DQPSK + Barker
//         010 : 5.5 Mbps CCK (MCU-pre-encoded)
//         011 : 11  Mbps CCK (MCU-pre-encoded)
//         others : invalid (latched into `invalid_mode`, tx refused)
//       Chip outputs: chip_i, chip_q at 11 Mchip/s on clk_b_chip.
//
//   mod_config[3] = 1 : Path B -- custom QAM (unchanged from prior rev).
//       mod_config[2:0]:
//         000 : OOK
//         001 : QPSK
//         010 : 16-QAM
//         011 : 64-QAM
//         100 : 256-QAM
//         others : invalid
//       Chip output: symbol_out[7:0] at clk_custom rate.
//
// Integration notes (see design-docs/Multi-Mode_TX_Architecture.md):
//   * Path A MAC runs entirely on clk_b_chip (11 MHz).  The legacy 1 MHz
//     clk_b_data pin has been retired -- the 1 Mbps bit rate is derived
//     internally by a chip-within-symbol counter.
//   * For CCK rates the MCU pre-applies scrambler + FCS + CCK codeword
//     computation and streams 16-bit CCK symbol words (little-endian two
//     FIFO bytes each) of the form { c6, c5, c4, c3, c2, c1, c0,
//     delta_phi1 }.  The MCU must also supply `length_us` for the LENGTH
//     field because its computation for 5.5/11 Mbps requires division by
//     11 that would be expensive on chip.
//   * The chip provides the PLCP preamble + header (always 1 Mbps DBPSK
//     Long PLCP) for all four rates.  HEC is computed on chip.
//   * clock_mux_static is still a placeholder; swap for the foundry's
//     glitch-free clock mux before GDS.
// =============================================================================
module multi_mode_tx_baseband #(
    // ---- 802.11b (Path A) tunables ----------------------------------------
    parameter integer PREAMBLE_SYNC_LEN_A = 128,
    parameter [15:0]  SFD_PATTERN_A       = 16'hF3A0,
    parameter [7:0]   SERVICE_FIELD_A     = 8'h00,    // bit[2] optionally advertises locked clocks
    parameter [6:0]   SCRAMBLER_SEED_A    = 7'h6D,
    parameter [10:0]  BARKER_PATTERN      = 11'b10110111000,
    // ---- Custom (Path B) tunables -----------------------------------------
    parameter integer CUSTOM_PREAMBLE_LEN = 32,
    parameter [31:0]  CUSTOM_PREAMBLE_PAT = 32'hAAAAAAAA,
    parameter [6:0]   SCRAMBLER_SEED_B    = 7'h6D,
    // ---- FIFO ----
    parameter integer FIFO_DEPTH          = 32,
    parameter integer FIFO_ADDR_W         = 5
) (
    // Clocks & reset
    input  wire        clk_b_chip,   // 11 MHz, root clock for Path A
    input  wire        clk_custom,   // up to 100 MHz
    input  wire        clk_mcu,
    input  wire        rst_n,

    // Control from MCU
    input  wire        tx_enable,
    input  wire [3:0]  mod_config,
    input  wire [15:0] payload_len,
    input  wire [15:0] length_us,    // MCU-supplied LENGTH field value

    // Payload ingress
    input  wire [7:0]  payload_in,
    input  wire        payload_write,

    // Status to MCU
    output wire        tx_busy,
    output wire        fifo_full,
    output wire        underrun,
    output wire        invalid_mode,
    output wire        tx_done,

    // Symbol egress
    output wire [7:0]  symbol_out,   // Path B
    output wire        symbol_valid, // Path B
    output wire        chip_i,       // Path A (valid at 11 Mchip/s)
    output wire        chip_q,       // Path A
    output wire        chip_valid    // Path A
);

    // =======================================================================
    // Reset synchronizers (one per functional clock)
    // =======================================================================
    wire rst_n_mcu_s;
    wire rst_n_b_chip_s;
    wire rst_n_custom_s;

    reset_sync u_rs_mcu    (.clk(clk_mcu),    .async_rst_n(rst_n), .sync_rst_n(rst_n_mcu_s));
    reset_sync u_rs_bchip  (.clk(clk_b_chip), .async_rst_n(rst_n), .sync_rst_n(rst_n_b_chip_s));
    reset_sync u_rs_custom (.clk(clk_custom), .async_rst_n(rst_n), .sync_rst_n(rst_n_custom_s));

    // =======================================================================
    // Mode decoding
    //   path_a_sel = 1 if Path A 802.11b; else Path B custom.
    //   mod_valid  flags legal mod_config encodings.
    // =======================================================================
    wire path_a_sel = (mod_config[3] == 1'b0);
    reg  mod_valid_c;
    always @(*) begin
        if (path_a_sel)  mod_valid_c = (mod_config[2:0] <= 3'b011);  // 1/2/5.5/11 Mbps
        else             mod_valid_c = (mod_config[2:0] <= 3'b100);  // OOK/QPSK/16/64/256
    end
    wire mod_valid = mod_valid_c;

    // Rate for Path A: low 2 bits of mod_config.
    wire [1:0] path_a_rate = mod_config[1:0];

    // =======================================================================
    // tx_enable rising-edge detect (clk_mcu)
    // =======================================================================
    reg tx_enable_q;
    always @(posedge clk_mcu or negedge rst_n_mcu_s) begin
        if (!rst_n_mcu_s) tx_enable_q <= 1'b0;
        else              tx_enable_q <= tx_enable;
    end
    wire tx_enable_pulse_mcu = tx_enable & ~tx_enable_q;

    // Sticky invalid-mode flag (clk_mcu domain)
    reg invalid_mode_r;
    always @(posedge clk_mcu or negedge rst_n_mcu_s) begin
        if (!rst_n_mcu_s)                              invalid_mode_r <= 1'b0;
        else if (tx_enable_pulse_mcu && !mod_valid)    invalid_mode_r <= 1'b1;
    end
    assign invalid_mode = invalid_mode_r;

    // Hard-gated start pulses: refuse to dispatch on illegal mod_config.
    wire start_mcu_a = tx_enable_pulse_mcu &  path_a_sel & mod_valid;
    wire start_mcu_b = tx_enable_pulse_mcu & ~path_a_sel & mod_valid;

    wire start_pulse_a, start_pulse_b;
    pulse_sync u_ps_a (
        .src_clk(clk_mcu),    .src_rst_n(rst_n_mcu_s),   .src_pulse(start_mcu_a),
        .dst_clk(clk_b_chip), .dst_rst_n(rst_n_b_chip_s),.dst_pulse(start_pulse_a)
    );
    pulse_sync u_ps_b (
        .src_clk(clk_mcu),    .src_rst_n(rst_n_mcu_s),    .src_pulse(start_mcu_b),
        .dst_clk(clk_custom), .dst_rst_n(rst_n_custom_s), .dst_pulse(start_pulse_b)
    );

    // =======================================================================
    // Async input FIFO
    // =======================================================================
    wire rclk_fifo;
    clock_mux_static u_rclk_mux (
        .sel(~path_a_sel),
        .clk0(clk_b_chip),   // Path A now reads from FIFO at the chip clock.
        .clk1(clk_custom),
        .clk_out(rclk_fifo)
    );

    wire rrst_n_fifo = path_a_sel ? rst_n_b_chip_s : rst_n_custom_s;

    wire        fifo_rd_en;
    wire        fifo_empty;
    wire [7:0]  fifo_rd_data;

    async_fifo #(
        .DATA_W(8), .DEPTH(FIFO_DEPTH), .ADDR_W(FIFO_ADDR_W)
    ) u_fifo (
        .wclk(clk_mcu), .wrst_n(rst_n_mcu_s), .wr_en(payload_write),
        .wr_data(payload_in), .full(fifo_full),
        .rclk(rclk_fifo),     .rrst_n(rrst_n_fifo), .rd_en(fifo_rd_en),
        .rd_data(fifo_rd_data), .empty(fifo_empty)
    );

    // =======================================================================
    // Path A : 802.11b multi-rate MAC + rotator
    // =======================================================================
    wire        a_fifo_rd_en;
    wire        a_busy, a_done;
    wire        a_underrun;
    wire [1:0]  a_base_phase;
    wire [1:0]  a_delta_phi1;
    wire        a_update_phi1;
    wire        a_chip_valid_to_phy;
    wire        a_chip_i, a_chip_q, a_chip_valid_out;

    mac_fsm_80211b #(
        .PREAMBLE_SYNC_LEN(PREAMBLE_SYNC_LEN_A),
        .SFD_PATTERN     (SFD_PATTERN_A),
        .SERVICE_FIELD   (SERVICE_FIELD_A),
        .SCRAMBLER_SEED  (SCRAMBLER_SEED_A),
        .BARKER_PATTERN  (BARKER_PATTERN)
    ) u_mac_a (
        .clk          (clk_b_chip),
        .rst_n        (rst_n_b_chip_s),
        .start_pulse  (start_pulse_a),
        .rate         (path_a_rate),
        .payload_len  (payload_len),
        .length_us    (length_us),
        .busy         (a_busy),
        .done_pulse   (a_done),
        .fifo_rd_en   (a_fifo_rd_en),
        .fifo_empty   (fifo_empty),
        .fifo_rd_data (fifo_rd_data),
        .underrun_flag(a_underrun),
        .base_phase   (a_base_phase),
        .delta_phi1   (a_delta_phi1),
        .update_phi1  (a_update_phi1),
        .chip_valid   (a_chip_valid_to_phy)
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

    // =======================================================================
    // Path B : Custom QAM (unchanged from prior revision)
    // =======================================================================
    wire b_fifo_rd_en;
    wire b_bit_valid, b_bit_out;
    wire b_busy, b_done, b_underrun;

    mac_fsm_custom #(
        .CUSTOM_PREAMBLE_LEN(CUSTOM_PREAMBLE_LEN),
        .CUSTOM_PREAMBLE_PAT(CUSTOM_PREAMBLE_PAT),
        .SCRAMBLER_SEED     (SCRAMBLER_SEED_B)
    ) u_mac_b (
        .clk          (clk_custom),
        .rst_n        (rst_n_custom_s),
        .start_pulse  (start_pulse_b),
        .payload_len  (payload_len),
        .busy         (b_busy),
        .done_pulse   (b_done),
        .fifo_rd_en   (b_fifo_rd_en),
        .fifo_empty   (fifo_empty),
        .fifo_rd_data (fifo_rd_data),
        .underrun_flag(b_underrun),
        .bit_valid    (b_bit_valid),
        .bit_out      (b_bit_out)
    );

    wire [7:0] path_b_symbol;
    wire       path_b_symbol_valid;
    wire       b_invalid_mode;

    phy_qam_custom u_phy_b (
        .clk                 (clk_custom),
        .rst_n               (rst_n_custom_s),
        .start_pulse         (start_pulse_b),
        .end_pulse           (b_done),
        .mod_config          (mod_config[2:0]),
        .bit_valid           (b_bit_valid),
        .bit_in              (b_bit_out),
        .invalid_mode        (b_invalid_mode),
        .path_b_symbol       (path_b_symbol),
        .path_b_symbol_valid (path_b_symbol_valid)
    );

    // =======================================================================
    // FIFO rd_en mux and output routing
    // =======================================================================
    assign fifo_rd_en = path_a_sel ? a_fifo_rd_en : b_fifo_rd_en;

    assign symbol_out   = path_b_symbol;
    assign symbol_valid = path_a_sel ? 1'b0 : path_b_symbol_valid;
    assign chip_i       = a_chip_i;
    assign chip_q       = a_chip_q;
    assign chip_valid   = path_a_sel ? a_chip_valid_out : 1'b0;

    // =======================================================================
    // tx_busy / tx_done / underrun back to clk_mcu
    // =======================================================================
    wire busy_any = path_a_sel ? a_busy : b_busy;
    sync_2ff #(.WIDTH(1), .RESET_VAL(1'b0)) u_busy_sync (
        .clk(clk_mcu), .rst_n(rst_n_mcu_s),
        .d_in(busy_any), .d_out(tx_busy)
    );

    wire done_a_mcu, done_b_mcu;
    pulse_sync u_done_a (
        .src_clk(clk_b_chip), .src_rst_n(rst_n_b_chip_s), .src_pulse(a_done),
        .dst_clk(clk_mcu),    .dst_rst_n(rst_n_mcu_s),    .dst_pulse(done_a_mcu)
    );
    pulse_sync u_done_b (
        .src_clk(clk_custom), .src_rst_n(rst_n_custom_s), .src_pulse(b_done),
        .dst_clk(clk_mcu),    .dst_rst_n(rst_n_mcu_s),    .dst_pulse(done_b_mcu)
    );
    assign tx_done = done_a_mcu | done_b_mcu;

    wire a_ur_mcu, b_ur_mcu;
    sync_2ff #(.WIDTH(1), .RESET_VAL(1'b0)) u_ur_a_sync (
        .clk(clk_mcu), .rst_n(rst_n_mcu_s),
        .d_in(a_underrun), .d_out(a_ur_mcu)
    );
    sync_2ff #(.WIDTH(1), .RESET_VAL(1'b0)) u_ur_b_sync (
        .clk(clk_mcu), .rst_n(rst_n_mcu_s),
        .d_in(b_underrun), .d_out(b_ur_mcu)
    );
    assign underrun = a_ur_mcu | b_ur_mcu;

    // Diagnostic-only signal kept live.
    wire _unused = &{1'b0, b_invalid_mode};

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

    property p_length_us_stable;
        @(posedge clk_mcu) disable iff (!rst_n_mcu_s)
            tx_busy |-> $stable(length_us);
    endproperty
    a_length_us_stable : assert property (p_length_us_stable)
        else $error("length_us changed while tx_busy was high");

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

