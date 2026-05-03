# Design Notes — CCK re-add and prior-review corrections

This file replaces the earlier review notes. It captures (a) corrections to
claims in the previous version of this document, (b) the new CCK MCU-offload
contract, and (c) the open items that remain before tape-out.

---

## A. Corrections to the previous review

### A.1 Scrambler is multiplicative (correct), not additive

The earlier note claimed the on-chip scrambler was an additive (Fibonacci)
LFSR and would prevent commercial 802.11b receivers from locking onto the
SFD. On re-read of the actual RTL, that claim is **wrong** — both the
standalone module and the inline copy in the MAC are spec-compliant
self-synchronous (multiplicative) scramblers, matching IEEE 802.11-2016
sec 16.2.4 Fig. 16-6:

  - `rtl/common/scrambler_x7x4.v:25-30`:
    ```
    wire data_out_c = data_in ^ lfsr[6] ^ lfsr[3];
    ...
    else if (data_valid) lfsr <= {data_out_c, lfsr[6:1]};
    ```
  - `rtl/path_a/mac_fsm_80211b.v:scramble_bit_ss / scramble_state_ss`
    has the same form: `out = data ^ state[6] ^ state[3]`, state shift
    feeds the `scrambled` bit (not raw input) into the new state MSB.

The earlier note's `data_out = data_in ^ lfsr[6]` and
`lfsr <= {lfsr[5:0], lfsr[6]^lfsr[3]}` formulation is the broken additive
form, but it is not what is in the source tree.

**Action:** earlier note retracted; no change required to scrambler RTL.

### A.2 SERVICE LENGTH_EXTENSION (real issue, now fixed)

Previous note flagged that SERVICE was a compile-time `8'h00` constant and
therefore could not carry the LENGTH_EXTENSION bit (sec 16.2.3.4) needed
at CCK rates. **Fixed** in this revision: `service_field[7:0]` is now a
per-packet input on `multi_mode_tx_baseband`, used for every rate. The
MCU is responsible for setting bit 7 (LENGTH_EXTENSION) and bit 2
(LOCKED_CLOCKS) per packet.

### A.3 Invalid-mode sticky flag still does not auto-clear

Same as before. `invalid_mode_r` is set once and only cleared by reset.
Acceptable as a reset-level error indicator. If the MCU expects to clear
it by writing a valid `mod_config`, add a write-1-to-clear path. Not
addressed in this revision.

---

## B. CCK MCU-offload contract (new in this revision)

### B.1 Why offload

A full on-chip CCK encoder requires:

  - dibit-to-QPSK lookup tables for {phi2, phi3, phi4} (rate-dependent),
  - a phi1 accumulator with the per-symbol +pi odd/even toggle
    (sec 16.4.6.3),
  - eight per-chip phase adders combining (phi1, phi2, phi3, phi4) mod 4,
  - the hard-wired +pi on chips 3 and 6 (sec 16.4.6),
  - a CRC-32 path that runs over scrambled payload bits, even though the
    chip output is encoded symbols (not bits).

Together this is the single biggest non-Path-A area consumer in the
original multi-mode design. Mentor's constraint is area, so this revision
moves *all* of that work into firmware on the MCU and keeps only a
chip-side streamer.

### B.2 Division of labor

| Step                                     | Does the chip do it?              |
|------------------------------------------|-----------------------------------|
| PLCP SYNC / SFD / SIGNAL / SERVICE / LENGTH / HEC | yes (always 1 Mbps DBPSK + Barker) |
| Scrambling of CCK PSDU + FCS bits        | no (MCU)                          |
| CRC-32 of CCK PSDU                       | no (MCU)                          |
| 8-chip CCK encoding (phi1..phi4 + chip-3/6 +pi + odd-symbol +pi) | no (MCU)                |
| Per-chip QPSK rotation through `phy_a_rotator`                  | yes                     |
| Pre-fetch and stream symbol words from FIFO                     | yes                     |
| Compute LENGTH / SERVICE / cck_symbol_count                     | no (MCU)                |
| Scrambling / CRC-32 / Barker spreading for 1/2 Mbps             | yes (unchanged)         |

For 1 and 2 Mbps the chip-side path is unchanged: scrambler, CRC-32 and
Barker spreader still run on chip. Only CCK rates use the offload.

### B.3 New top-level ports

Added on `multi_mode_tx_baseband`:

  - `length_field[15:0]` — replaces the previously-deprecated `length_us`
    port. MCU writes the LENGTH for the PLCP header (sec 16.2.3.5) at
    every rate.
  - `service_field[7:0]` — MCU writes the SERVICE byte (sec 16.2.3.4)
    at every rate. Bit 7 = LENGTH_EXTENSION, bit 2 = LOCKED_CLOCKS.
  - `cck_symbol_count[15:0]` — number of 8-chip CCK symbols making up
    PSDU+FCS. Used only for CCK rates.

Unchanged ports retained for wrapper-pinout stability:
`clk_custom`, `symbol_out[7:0]`, `symbol_valid` (still tied to 0).

### B.4 mod_config map

  - `4'b0000` — 1   Mbps DBPSK + Barker (chip computes everything)
  - `4'b0001` — 2   Mbps DQPSK + Barker (chip computes everything)
  - `4'b0010` — 5.5 Mbps CCK   (MCU offload)
  - `4'b0011` — 11  Mbps CCK   (MCU offload)
  - all others — illegal, latches `invalid_mode`.

### B.5 FIFO contract (CCK)

Per CCK symbol the MCU pushes 4 bytes into the existing async FIFO.
Layout, LSB-first across the 4 bytes:

```
bits[1:0]    = delta_phi1[1:0]   (DQPSK delta for d1, with sec 16.4.6.3
                                  odd-symbol +pi already folded in)
bits[3:2]    = c_k0[1:0]
bits[5:4]    = c_k1[1:0]
bits[7:6]    = c_k2[1:0]
bits[9:8]    = c_k3[1:0]         (already includes the chip-3 +pi)
bits[11:10]  = c_k4[1:0]
bits[13:12]  = c_k5[1:0]
bits[15:14]  = c_k6[1:0]         (already includes the chip-6 +pi)
bits[17:16]  = c_k7[1:0]
bits[31:18]  = reserved (MCU writes 0)
```

MCU pushes those 4 bytes in normal byte order (byte 0 first) into the
existing FIFO, exactly the same write port and protocol used for raw
payload at 1/2 Mbps.

Total FIFO bytes per CCK packet = `4 * cck_symbol_count`.

### B.6 Sustained bandwidth

  - 5.5 Mbps and 11 Mbps both run at 1.375 Msym/s.
  - 4 bytes/sym -> **5.5 MB/s sustained** during a CCK packet.
  - At 50 MHz clk_mcu that is one byte every ~9 cycles, comfortable for
    DMA from a precomputed RAM buffer.
  - FIFO depth was bumped from 8 -> 16 bytes (`FIFO_ADDR_W` 3 -> 4) to
    give MCUs without strict-deadline DMA roughly 3 us of jitter
    headroom. Still tiny compared to the original 32-byte FIFO.

### B.7 Chip-side streamer mechanics

  - New FSM state `S_PSDU_CCK` in `mac_fsm_80211b`.
  - `chip_cnt` is reused but rolls 0..7 in `S_PSDU_CCK` (vs 0..10 for
    Barker).
  - Two 32-bit registers, `cck_word_curr` and `cck_word_next`, give a
    one-symbol prefetch buffer.
  - Pre-load of symbol 0 happens during chips 4..7 of the LAST HEC
    symbol (HEC has 16 bits = 176 chips, so we have lots of room).
    This avoids a chip-rate bubble at the HEC -> PSDU boundary.
  - Concurrent emit + prefetch in `S_PSDU_CCK`: while chips 0..3 of the
    current symbol emit, the FSM pulls bytes 0..3 of the next symbol
    from the FIFO.
  - `phy_a_rotator` is unchanged; its existing `base_phase` /
    `delta_phi1` / `update_phi1` interface was already CCK-aware.

### B.8 What still needs work for CCK

  - **No bit-level golden-vector regression yet.** The directed CCK tests
    in `tb/tb_multi_mode_tx_baseband.sv` (T_A3, T_A4) and in the synth
    bench check chip-stream geometry only (chip count, symbol count,
    underrun). A real golden-vector check requires a reference CCK
    encoder; recommended source is MATLAB
    `wlanWaveformGenerator(wlanNonHTConfig('Modulation','DSSS', ...))`
    or an equivalent ns-3 / GNURadio reference.
  - **MCU firmware is not in this repo.** A C reference for the
    scrambler + CRC-32 + CCK-encoder pipeline is the next deliverable
    and should live alongside the RTL once written.
  - **No spec-mask check.** `phy_to_iq` produces axis-rotated +/-1
    chips; the analog front end / DAC must shape these into something
    that meets the sec 16.3 spectral mask.

---

## C. FIFO design (unchanged from prior note)

The async FIFO is a Cummings dual-clock design with Gray-coded pointers
crossing through `sync_2ff` instances. Write side is `clk_mcu` (50 MHz);
read side is `clk_b_chip` (11 MHz). Underrun is asserted by the MAC FSM
on read-when-empty and surfaces back to the MCU through `sync_2ff`.

Sizing rationale:

| Path           | Peak FIFO byte rate | Notes                  |
|----------------|---------------------|------------------------|
| 1   Mbps DBPSK | ~11 kB/s            | one byte / 88 us       |
| 2   Mbps DQPSK | ~23 kB/s            | one byte / 44 us       |
| 5.5 Mbps CCK   | ~5.5 MB/s sustained | 4 bytes/sym, 1.375 Msym/s |
| 11  Mbps CCK   | ~5.5 MB/s sustained | same, double info bits |

The 16-byte FIFO holds ~3 us of CCK burst at peak; depth is a power of
two so the Gray-pointer math still works; address width 4 keeps the
synchronizer footprint small.

---

## D. Lint-level / toolchain observations carried forward

Items that do not break compliance but still want attention before sign-off:

  - No `default_nettype none` anywhere. Add to every file.
  - `async_fifo` read data is unregistered; consider a registered-output
    option if hold margin is tight.
  - `scrambler_x7x4_test` overrides `SCRAMBLER_SEED(7'h00)`, which is the
    one seed sec 16.2.4 forbids (degenerates the multiplicative LFSR).
    Add a non-zero-seed regression alongside.
  - `clock_mux_static` is no longer instantiated and can be deleted, or
    kept only as a library cell.

---

## E. Bottom-line compliance status (after this revision)

  - Scrambler: spec-compliant (verified).
  - SFD / Barker / DBPSK / DQPSK: spec-compliant (verified previously).
  - SERVICE byte: now per-packet, MCU-supplied; LENGTH_EXTENSION can
    be set correctly.
  - LENGTH field: now per-packet, MCU-supplied.
  - CCK chip stream: spec-compliant only if MCU firmware is correct;
    no chip-side check possible without the firmware reference.

A commercial 802.11b receiver should now be able to lock onto and decode
a 1 or 2 Mbps packet today, and 5.5 / 11 Mbps once the MCU CCK encoder is
written and validated against a golden vector.
