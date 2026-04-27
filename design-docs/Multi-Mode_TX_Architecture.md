# Wi-Fi-Only TX Architecture

This document describes the current architecture of `multi_mode_tx_baseband`
after the Wi-Fi-only area-reduction cut.

## Supported modes

Only two commercial-`802.11b`-facing modes remain:

| `mod_config` | Mode                          | Output pins              |
|--------------|-------------------------------|--------------------------|
| `4'b0000`    | `1 Mbps` DBPSK + Barker       | `chip_i`, `chip_q`       |
| `4'b0001`    | `2 Mbps` DQPSK + Barker       | `chip_i`, `chip_q`       |

All other `mod_config` values are illegal. The chip refuses to start and
latches `invalid_mode`.

## What was removed

The cut intentionally removes the largest nonessential blocks while keeping the
retained modes standards-facing:

- custom Path B modulation
- `5.5 Mbps` CCK
- `11 Mbps` CCK
- the read-clock mux
- the MCU-supplied `length_us` dependency
- all CCK symbol packing and off-chip CCK precompute logic

Deprecated top-level pins are still present only to avoid a wrapper-level
pinout break:

- `clk_custom`
- `length_us`
- `symbol_out[7:0]`
- `symbol_valid`

They no longer affect the synthesized logic.

## Current datapath

```text
MCU payload bytes
  -> async FIFO (clk_mcu -> clk_b_chip)
  -> mac_fsm_80211b
  -> phy_a_rotator
  -> chip_i / chip_q / chip_valid
```

There is now exactly one active transmit path.

## Path A framing

The transmitter still emits Long PLCP framing:

```text
SYNC(128) | SFD(16) | SIGNAL(8) | SERVICE(8) | LENGTH(16) | HEC(16) | PSDU | FCS(32)
```

Preamble and header are always `1 Mbps` DBPSK + Barker, which matches the
commercial `802.11b` receive expectation for Long PLCP.

For the retained modes:

- `1 Mbps`: PSDU and FCS use DBPSK + Barker
- `2 Mbps`: PSDU and FCS use DQPSK + Barker

## On-chip functions still present

To keep the retained modes self-contained and standards-facing, these blocks
remain on chip:

- self-synchronous scrambler
- CRC-16 HEC for the PLCP header
- CRC-32 FCS for the PSDU
- DQPSK differential phase mapping
- Barker spreading
- chip-domain phase rotator

## LENGTH field generation

Because only `1 Mbps` and `2 Mbps` remain, LENGTH is cheap to compute on chip:

- `1 Mbps`: `LENGTH = 8 * payload_len`
- `2 Mbps`: `LENGTH = 4 * payload_len`

This removes the previous need for MCU-supplied `length_us`.

## FIFO contract

The FIFO is now smaller by default:

- old default: `32` bytes
- new default: `8` bytes

The FIFO still bridges `clk_mcu` to `clk_b_chip`, so the MCU must keep up with
the selected on-air rate or the design can still assert `underrun`.

## Verification scope

The active benches now cover:

- illegal-mode rejection
- `1 Mbps` DBPSK packet flow
- `2 Mbps` DQPSK packet flow
- FIFO byte alignment
- DQPSK differential mapping
- on-chip LENGTH-field generation

Legacy Path B and CCK collateral is retained only as historical reference and
is no longer part of the active top-level architecture.
