# Wi-Fi Lite Change Log

This note records the explicit architectural cuts made to reduce area while
preserving commercial-`802.11b` compatibility for `1 Mbps` and `2 Mbps`.

## Functional cuts

1. Removed the custom non-Wi-Fi Path B from the active top-level RTL.
2. Removed `5.5 Mbps` CCK support.
3. Removed `11 Mbps` CCK support.
4. Reduced the legal `mod_config` set to:
   - `4'b0000` -> `1 Mbps` DBPSK
   - `4'b0001` -> `2 Mbps` DQPSK
5. Rejected all other mode codes through the existing `invalid_mode` latch.

## Top-level simplifications

1. Deleted the FIFO read-clock mux. The FIFO now always reads on `clk_b_chip`.
2. Removed Path B busy/done/underrun CDC plumbing.
3. Tied `symbol_out` to zero and `symbol_valid` low.
4. Kept `clk_custom` and `length_us` ports only for integration stability.

## Path A simplifications

1. Removed all CCK state, counters, and symbol-word handling from
   `mac_fsm_80211b`.
2. Removed the MCU-side CCK payload contract from the active design.
3. Replaced external LENGTH input usage with on-chip LENGTH generation:
   - `1 Mbps`: `8 * payload_len`
   - `2 Mbps`: `4 * payload_len`
4. Kept on-chip scrambler, HEC, FCS, Barker spreading, and DQPSK mapping.

## FIFO sizing change

1. Changed default FIFO depth from `32` bytes to `8` bytes.
2. Changed default FIFO address width from `5` to `3`.

## Verification changes

1. Removed CCK and Path B top-level tests.
2. Kept top-level tests for:
   - invalid mode rejection
   - `1 Mbps` DBPSK
   - `2 Mbps` DQPSK
   - back-to-back packet cleanup
3. Replaced the old CCK-focused Path A checks with on-chip LENGTH-field checks
   for the retained rates.

## Compatibility impact

What stays compatible:

- Long PLCP framing for the retained `1 Mbps` and `2 Mbps` modes
- DBPSK and DQPSK differential mapping
- Barker spreading
- commercial `802.11b` receiver targeting for those two rates

What is no longer supported:

- CCK decode paths on commodity receivers
- any custom QAM / non-Wi-Fi transmit mode
