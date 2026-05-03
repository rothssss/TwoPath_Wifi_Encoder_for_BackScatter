# Wi-Fi TX Architecture (1/2 Mbps on chip + 5.5/11 Mbps via MCU offload)

This document describes the current architecture of `multi_mode_tx_baseband`
after re-adding 5.5 / 11 Mbps CCK with the MCU-offload contract.

## Supported modes

All four standards-compliant 802.11b PSDU rates are supported:

| `mod_config` | Mode                       | Computation split            |
|--------------|----------------------------|------------------------------|
| `4'b0000`    | 1   Mbps DBPSK + Barker    | chip computes everything     |
| `4'b0001`    | 2   Mbps DQPSK + Barker    | chip computes everything     |
| `4'b0010`    | 5.5 Mbps CCK               | MCU encodes; chip streams    |
| `4'b0011`    | 11  Mbps CCK               | MCU encodes; chip streams    |

All other `mod_config` values are illegal and latch `invalid_mode`.

The chip-side output is `chip_i / chip_q / chip_valid` at 11 Mchip/s for
every mode. The deprecated `symbol_out[7:0]` / `symbol_valid` pins are
retained for wrapper-pinout stability and remain tied to 0.

## Why offload CCK

A full on-chip CCK encoder would add the largest non-Path-A area in the
design: dibit-to-phase tables, a 4-input mod-4 phase adder per chip, a
per-symbol +pi accumulator (sec 16.4.6.3 odd-symbol correction), and the
hard-wired +pi on chips 3 and 6 (sec 16.4.6). Mentor's constraint is
chip area, so all of that math now lives in MCU firmware.

The chip-side cost of CCK in this architecture is roughly:

  - one new FSM state (`S_PSDU_CCK`),
  - two 32-bit prefetch registers (`cck_word_curr` / `cck_word_next`),
  - a 4:1 chip-phase mux,
  - the `length_field` / `service_field` / `cck_symbol_count` per-packet
    inputs.

`phy_a_rotator` is unchanged; its `base_phase` / `delta_phi1` interface
was always built CCK-aware.

## Datapath

```text
MCU payload bytes  (raw payload at 1/2 Mbps; precomputed CCK words at 5.5/11)
  -> async FIFO (clk_mcu -> clk_b_chip)
  -> mac_fsm_80211b
  -> phy_a_rotator
  -> chip_i / chip_q / chip_valid
```

There is exactly one active transmit path. The FIFO read side is
hard-wired to `clk_b_chip`.

## PLCP framing (Long preamble, all rates)

```text
SYNC(128) | SFD(16) | SIGNAL(8) | SERVICE(8) | LENGTH(16) | HEC(16) | PSDU | FCS
```

Preamble + header are always 1 Mbps DBPSK + Barker. The MCU controls
the SIGNAL byte (selected by `rate_mode`), SERVICE byte
(`service_field`, including LENGTH_EXTENSION bit 7 and LOCKED_CLOCKS
bit 2) and LENGTH field (`length_field`).

## Path A internals (1 / 2 Mbps)

For `rate_mode = 2'b00` or `2'b01` the chip-side path is unchanged:

  - self-synchronous scrambler (sec 16.2.4, multiplicative form),
  - on-chip CRC-16 HEC and CRC-32 FCS,
  - DBPSK / DQPSK differential phase mapping,
  - 11-chip Barker spreading,
  - chip-domain phase rotator.

The MCU pushes raw payload bytes into the FIFO and supplies
`payload_len` (raw payload byte count), `length_field`
(`8 * payload_len` for 1 Mbps, `4 * payload_len` for 2 Mbps), and
`service_field`. `cck_symbol_count` is unused.

## Path A internals (5.5 / 11 Mbps CCK)

For `rate_mode = 2'b1x` the MCU performs the heavy work:

  - scramble payload + FCS bits per sec 16.2.4,
  - compute CRC-32 over the scrambled payload (sec 16.2.3.6),
  - CCK-encode the bitstream into 8-chip QPSK symbols per sec 16.4.6,
  - fold the chip-3 / chip-6 +pi into each `c_k`,
  - fold the odd-symbol +pi into `delta_phi1` per sec 16.4.6.3,
  - compute LENGTH (`length_field`), SERVICE (`service_field`,
    incl. LENGTH_EXTENSION rule from sec 16.2.3.4), and the count of
    8-chip symbols (`cck_symbol_count`).

The chip-side does only:

  - generate SYNC / SFD / SIGNAL / SERVICE / LENGTH / HEC at 1 Mbps
    DBPSK + Barker,
  - prefetch the first CCK symbol's 4 bytes during HEC's last symbol,
  - in `S_PSDU_CCK`, replay 8 QPSK chips per CCK symbol from
    `cck_word_curr`, while concurrently prefetching the next symbol's
    4 bytes during chips 0..3,
  - drive `chip_valid` for `cck_symbol_count * 8` chips,
  - assert `tx_done` at packet end.

## CCK FIFO packing (per symbol)

4 bytes per CCK symbol, LSB-first across the 4 bytes:

```
bits[1:0]    = delta_phi1[1:0]
bits[3:2]    = c_k0[1:0]
bits[5:4]    = c_k1[1:0]
bits[7:6]    = c_k2[1:0]
bits[9:8]    = c_k3[1:0]   (already includes the chip-3 +pi)
bits[11:10]  = c_k4[1:0]
bits[13:12]  = c_k5[1:0]
bits[15:14]  = c_k6[1:0]   (already includes the chip-6 +pi)
bits[17:16]  = c_k7[1:0]
bits[31:18]  = reserved (MCU writes 0)
```

Sustained FIFO bandwidth in CCK = `4 bytes/sym * 1.375 Msym/s = 5.5 MB/s`.

## FIFO contract

  - Default depth: `16` bytes (`FIFO_ADDR_W = 4`). Holds ~3 us of CCK
    burst at peak; very generous for 1/2 Mbps. Bumped from 8 because
    CCK's 5.5 MB/s sustained rate eats the previous buffer in ~1 us.
  - Write port is `clk_mcu`, read port is `clk_b_chip`.
  - Standard back-pressure via `fifo_full`; underrun via `underrun`.

## On-chip blocks still present

  - self-synchronous scrambler (`scrambler_x7x4` and inline copy in
    `mac_fsm_80211b`)
  - CRC-16 HEC for the PLCP header
  - CRC-32 FCS for the PSDU (Barker rates only; idle in CCK)
  - DBPSK / DQPSK differential phase mapping
  - 11-chip Barker spreader
  - chip-domain QPSK phase rotator (`phy_a_rotator`)
  - new CCK symbol streamer + prefetch buffer

## Verification scope

Active testbenches now cover:

  - illegal-mode rejection
  - 1 Mbps DBPSK packet flow
  - 2 Mbps DQPSK packet flow
  - 5.5 Mbps CCK chip-count geometry (stub, all-zero MCU words)
  - 11 Mbps CCK chip-count geometry (stub, all-zero MCU words)
  - FIFO byte alignment (Barker)
  - DQPSK differential mapping
  - on-chip header construction (Barker)
  - back-to-back packet cleanup

Bit-level golden-vector validation of the CCK chip stream against an
802.11-compliant reference encoder is the next verification deliverable
and is **not yet present** in this repo.

## Synthesis handoff

  - Hierarchical: `rtl/multi_mode_tx_baseband.v` and submodules.
  - Single-module flattened: `synth/rtl_flat/multi_mode_tx_baseband_flat.v`,
    auto-regenerated from `multi_mode_tx_baseband_flat_multimodule.v` by
    `synth/rtl_flat/gen_single_module_flat.py` (the original
    PowerShell script `gen_single_module_flat.ps1` is preserved
    alongside).
