# Wi-Fi TX Change Log

This note records the architectural cuts made to reduce area while
preserving commercial-`802.11b` compatibility, and the subsequent
re-add of CCK rates via an MCU-offload contract.

## Revision 2 — CCK re-added with MCU offload

### New supported PSDU rates

1. `4'b0010` -> 5.5 Mbps CCK
2. `4'b0011` -> 11  Mbps CCK

The 1 Mbps DBPSK and 2 Mbps DQPSK paths are unchanged from revision 1.

### Computation split for CCK

The MCU performs in firmware:

  - scrambling of the payload + FCS bitstream (sec 16.2.4),
  - CRC-32 over the scrambled payload (sec 16.2.3.6),
  - 8-chip CCK encoding (sec 16.4.6), including the chip-3 and chip-6
    hard-wired +pi and the odd-symbol +pi correction of sec 16.4.6.3,
  - LENGTH and SERVICE field values per sec 16.2.3.4 / 16.2.3.5,
  - the symbol count for the PSDU+FCS region.

The chip performs:

  - PLCP preamble + header generation (always 1 Mbps DBPSK + Barker),
  - prefetch and replay of MCU-supplied CCK symbol words through
    `phy_a_rotator`,
  - tx_done / underrun signaling.

### New top-level ports

1. `length_field[15:0]` — replaces the previously-deprecated
   `length_us` port. MCU-supplied LENGTH for the PLCP header.
2. `service_field[7:0]` — MCU-supplied SERVICE byte. Replaces the old
   compile-time `SERVICE_FIELD_A` parameter.
3. `cck_symbol_count[15:0]` — number of 8-chip CCK symbols making up
   PSDU+FCS. Used only for CCK rates.

Removed inputs: none. The port `length_us` is renamed to `length_field`;
its semantics are now well-defined for every rate (raw 16-bit LENGTH).

### CCK FIFO packing

4 bytes per CCK symbol, LSB-first across the 4 FIFO bytes:

  - bits[1:0]   = delta_phi1
  - bits[17:2]  = c_k0..c_k7 (2 bits each)
  - bits[31:18] = reserved (zero)

See `design-docs/Multi-Mode_TX_Architecture.md` and the header of
`rtl/path_a/mac_fsm_80211b.v` for the full bit layout.

### MAC FSM additions

1. New state `S_PSDU_CCK`.
2. New registers `cck_word_curr[31:0]` and `cck_word_next[31:0]` — a
   one-symbol prefetch buffer.
3. CCK preload during chips 4..7 of the last HEC symbol, so that
   `S_PSDU_CCK` can emit chip 0 with no chip-rate bubble.
4. Concurrent emit + prefetch in `S_PSDU_CCK`: chips 0..3 of the
   current symbol emit while bytes 0..3 of the next symbol load.
5. `rate` (1 bit) widened to `rate_mode` (2 bits): `00`=1M, `01`=2M,
   `10`=5.5M CCK, `11`=11M CCK.
6. SIGNAL byte function extended for the two new rates: `0x37` for
   5.5 Mbps and `0x6E` for 11 Mbps.

### FIFO sizing change

  - Default depth: 8 -> 16 bytes.
  - Default address width: 3 -> 4.
  - Rationale: CCK's 5.5 MB/s sustained byte rate would exhaust an
    8-byte buffer in ~1.4 us, leaving no MCU jitter headroom. 16 bytes
    gives ~3 us of headroom, still well below the original 32-byte
    depth.

### Verification changes

1. Top-level TB renamed `length_us` regs to `length_field`, added regs
   for `service_field` and `cck_symbol_count`, and adjusted the
   illegal-mode test (5.5 / 11 Mbps codes are no longer illegal).
2. Added directed CCK tests (T_A3, T_A4) that stream all-zero stub
   symbols and check chip-count geometry. Bit-level validation against
   a golden CCK reference is a TODO.
3. `tb_mac_fsm_80211b_checks.sv` updated to drive `length_field` and
   `service_field` directly (was relying on chip-side computation).
4. `tb_top_flat.sv` rewritten to exercise the flattened RTL with the
   same Barker + CCK + invalid-mode coverage.

### Documentation updates

  - `synth/rtl_flat/new_problems.md` rewritten:
    retracts the (incorrect) prior claim that the on-chip scrambler is
    additive; documents the CCK contract; confirms the SERVICE
    LENGTH_EXTENSION fix.
  - `design-docs/Multi-Mode_TX_Architecture.md` updated for the four
    supported PSDU rates and the CCK FIFO contract.

### Synthesis handoff

  - `synth/rtl_flat/multi_mode_tx_baseband_flat_multimodule.v`
    rebuilt.
  - `synth/rtl_flat/multi_mode_tx_baseband_flat.v` rebuilt.
  - Added `synth/rtl_flat/gen_single_module_flat.py` (Python port of
    the existing PowerShell flattener) so the flat file can be
    regenerated on Linux hosts.

---

## Revision 1 — Wi-Fi-only area cut (recorded for history)

### Functional cuts

1. Removed the custom non-Wi-Fi Path B from the active top-level RTL.
2. Removed `5.5 Mbps` CCK support. *(Re-added in revision 2.)*
3. Removed `11 Mbps` CCK support. *(Re-added in revision 2.)*
4. Reduced the legal `mod_config` set to `4'b0000` and `4'b0001`.
   *(Extended back to `0010` and `0011` in revision 2.)*
5. Rejected all other mode codes through the existing `invalid_mode`
   latch. *(Still applies; only the legal set has expanded.)*

### Top-level simplifications

1. Deleted the FIFO read-clock mux. The FIFO now always reads on
   `clk_b_chip`.
2. Removed Path B busy/done/underrun CDC plumbing.
3. Tied `symbol_out` to zero and `symbol_valid` low.
4. Kept `clk_custom`, `symbol_out`, `symbol_valid` ports for wrapper
   stability. (`length_us` repurposed to `length_field` in revision 2.)

### Path A simplifications (revision 1)

1. Removed all CCK state, counters, and symbol-word handling from
   `mac_fsm_80211b`. *(Re-added in revision 2 with the offload
   contract.)*
2. Removed the MCU-side CCK payload contract from the active design.
   *(Replaced in revision 2 by the new MCU-offload CCK contract.)*
3. Replaced external LENGTH input usage with on-chip LENGTH generation.
   *(Reverted in revision 2: LENGTH is now MCU-supplied
   (`length_field`).)*
4. Kept on-chip scrambler, HEC, FCS, Barker spreading, and
   DBPSK / DQPSK mapping.

### FIFO sizing (revision 1)

1. Changed default FIFO depth from 32 -> 8 bytes.
2. Changed default FIFO address width from 5 -> 3.

*(Bumped to 16 / 4 in revision 2 to give MCU jitter headroom for CCK.)*

### Compatibility impact (after revision 2)

What stays compatible:

  - Long PLCP framing for all four 802.11b PSDU rates.
  - DBPSK / DQPSK differential mapping (chip-side).
  - 11-chip Barker spreading (chip-side, 1/2 Mbps).
  - CCK 8-chip codeword stream on-air (correctness depends on MCU
    firmware).
  - Commercial 802.11b receiver targeting for all four rates, assuming
    the MCU CCK encoder is correct.

What is no longer supported:

  - Any custom QAM / non-Wi-Fi transmit mode (Path B is still gone).
