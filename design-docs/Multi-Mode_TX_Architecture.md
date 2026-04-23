# Multi-Mode Backscatter TX Baseband — Architecture & Dataflow

This document describes the current architecture of `multi_mode_tx_baseband`
after the multi-rate refactor and supersedes the original `Wifi Doc` MAS for
the digital block.  The high-level product intent is unchanged: an
ultra-low-power backscatter transmitter that retrieves payload bytes from an
MCU over a parallel interface and emits logical baseband symbols to an
external analog combinational decoder.

## 1. Two datapaths, one chip

The datapath is selected by `mod_config[3]`:

| `mod_config[3]` | `mod_config[2:0]` | Mode                             | Chip output           |
|-----------------|-------------------|----------------------------------|-----------------------|
| 0               | 000               | 802.11b 1 Mbps DBPSK + Barker    | `chip_i` / `chip_q`   |
| 0               | 001               | 802.11b 2 Mbps DQPSK + Barker    | `chip_i` / `chip_q`   |
| 0               | 010               | 802.11b 5.5 Mbps CCK             | `chip_i` / `chip_q`   |
| 0               | 011               | 802.11b 11 Mbps CCK              | `chip_i` / `chip_q`   |
| 1               | 000               | Custom OOK                       | `symbol_out[7:0]`     |
| 1               | 001               | Custom QPSK                      | `symbol_out[7:0]`     |
| 1               | 010               | Custom 16-QAM                    | `symbol_out[7:0]`     |
| 1               | 011               | Custom 64-QAM                    | `symbol_out[7:0]`     |
| 1               | 100               | Custom 256-QAM                   | `symbol_out[7:0]`     |

Path A targets **full IEEE 802.11-2016 Long PLCP compliance** so the
transmission is decodable by commercial 802.11b receivers.  Path B is our
companion-RX-only link.

Any other `mod_config` value is illegal; the chip refuses to start and
latches `invalid_mode` sticky.

## 2. Clocks, resets, pins

| Clock        | Rate            | Purpose                                        |
|--------------|-----------------|------------------------------------------------|
| `clk_mcu`    | MCU-defined     | MCU interface, FIFO write, tx_busy/tx_done sync |
| `clk_b_chip` | 11 MHz          | **Root clock for all of Path A** (MAC + PHY)    |
| `clk_custom` | up to 100 MHz   | Path B                                         |

The legacy 1 MHz `clk_b_data` input has been retired; the 1 Mbps bit cadence
is now generated internally by counting chip-within-symbol on `clk_b_chip`.

`rst_n` is asynchronous-assert at the chip boundary; each clock domain
gets its own `reset_sync` wrapper so the de-assertion is synchronous.

Output pins for the baseband symbol:
- **Path A**: `chip_i`, `chip_q`, `chip_valid` — registered in `clk_b_chip`.
  During DBPSK (1 Mbps) `chip_q` tracks `chip_i`; the analog side is
  expected to gate Q based on `mod_config`.
- **Path B**: `symbol_out[7:0]`, `symbol_valid` — in `clk_custom`.

Status pins: `tx_busy`, `tx_done`, `fifo_full`, `underrun`,
`invalid_mode`.  All are in `clk_mcu` and may be read directly by the MCU.

## 3. Path A — 802.11b Long PLCP

### 3.1 PPDU structure

```
 128 bits        16 bits   8       8         16        16        variable        32
+-----------+  +-------+  +------+---------+---------+--------+  +-----------+  +-----+
|  SYNC     |  |  SFD  |  |SIGNAL|SERVICE  |LENGTH   | HEC    |  |   PSDU    |  | FCS |
|  (scr 1's)|  | F3A0  |  | rate | dyn/CCK | tx time |CRC-16  |  |  payload  |  |CRC32|
+-----------+  +-------+  +------+---------+---------+--------+  +-----------+  +-----+
 <-- 1 Mbps DBPSK + Barker, scrambled throughout, HEC on 32 header bits -->  <-- rate-dependent -->
```

Preamble + header are **always** transmitted at 1 Mbps DBPSK + Barker,
regardless of PSDU rate (this is the Long PLCP choice over Short PLCP; the
Short variant would have run the header at 2 Mbps and is intentionally not
supported here).

### 3.2 Chip-domain state machine (`mac_fsm_80211b`)

One FSM on `clk_b_chip` drives everything:

```
S_IDLE → S_SYNC → S_SFD → S_HEAD → S_HEC
                                      ↓
                          rate 1/2 Mbps → S_PSDU_BARKER → S_FCS_BARKER → S_DONE
                          rate 5.5/11 Mbps → S_PSDU_CCK → S_DONE
```

Chip counter `chip_cnt` tracks chip-within-symbol:
- 0..10 for Barker-based states (11 chips per symbol)
- 0..7 for `S_PSDU_CCK` (8 chips per CCK symbol)

Per-symbol bookkeeping happens at `chip_cnt == chip_cnt_max` (symbol_end)
so new symbols load cleanly on the following `chip_cnt == 0`.

### 3.3 On-chip components used for Path A

- **Scrambler** (self-synchronous, x⁷ + x⁴ + 1): reset to `SCRAMBLER_SEED`
  at packet start; each scrambled bit is formed as `data ^ state[6] ^ state[3]`
  and shifted back into the state. Path A advances one step per DBPSK-style
  bit, two serialized steps per DQPSK symbol, and 0 steps during S_PSDU_CCK.
- **HEC** (`crc16_80211_hec`, CRC-16-CCITT-FALSE, init 0xFFFF, XorOut
  0xFFFF): covers the 32 SIGNAL+SERVICE+LENGTH bits.  Transmitted MSB-first.
- **FCS** (`crc32_80211`, init 0xFFFFFFFF, reflected I/O, XorOut): covers
  the PSDU for 1/2 Mbps rates only.  Transmitted LSB-first.
- **Phase rotator** (`phy_a_rotator`): single 2-bit DQPSK accumulator that
  drives chip-level I/Q.  Zeroed at `start_pulse`; updated per symbol by
  `delta_phi1`.

### 3.4 CCK rates — MCU-side pre-encoding

The mentor-directed philosophy: keep only "adder rotation" on chip; push
the CCK codeword computation off die.  The MCU takes responsibility for:

1. Running the scrambler forward 192 steps from `SCRAMBLER_SEED` to reach
   the state the chip's scrambler lands on at end-of-header.  (192 steps
   because the chip scrambles all 128 SYNC + 16 SFD + 48 header bits,
   including the HEC bits it computes.)
2. Scrambling the PSDU bytes + FCS using that post-header scrambler state.
3. Computing the CCK base codeword's seven non-zero chip phases from the
   scrambled dibits per 802.11-2016 sec 16.4.6.3 — specifically
   `c0..c6` = {φ₂+φ₃+φ₄, φ₃+φ₄, φ₂+φ₄, φ₄+π, φ₂+φ₃, φ₃, φ₂+π} (c7 ≡ 0,
   implicit).
4. Computing `delta_phi1` = the DQPSK phase step for this CCK symbol,
   including the even/odd-symbol π correction called out in sec 16.4.6.3.
5. Packing each CCK symbol into one 16-bit word:

   ```
        bit    15 14 13 12 11 10  9  8  7  6  5  4  3  2  1  0
              +--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+
              | c6   | c5   | c4   | c3   | c2   | c1   | c0   | Δφ1 |
              +--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+--+
   ```

   and streaming it to the chip as two FIFO bytes, low byte first.

Symbol count per packet (PSDU+FCS, where FCS is also pre-encoded by MCU):
- 11 Mbps CCK: `payload_len + 4` symbols → `2 × (payload_len + 4)` bytes.
- 5.5 Mbps CCK: `2 × (payload_len + 4)` symbols → `4 × (payload_len + 4)` bytes.

The MCU also supplies `length_us` (the LENGTH field value in µs) because
the spec formulas for 5.5/11 Mbps require a ceil-by-11 division that
would be expensive in silicon at low Vdd. The chip derives SERVICE bit b7
from `length_us` for 11 Mbps CCK and uses `SERVICE_FIELD[2]` to advertise
the optional locked-clocks bit.

### 3.5 Path A per-chip dataflow

```
  MAC FSM (clk_b_chip)                      phy_a_rotator (clk_b_chip)
  ────────────────────                      ──────────────────────────
  base_phase[1:0]  ───────────────────────► base phase
  delta_phi1[1:0]  ──────────────────────── φ1 accumulator delta
  update_phi1      ───────────────────────► (pulse at chip_cnt==0)
                                            ↓
                                            phi1_acc += delta_phi1
                                            chip_phase = base_phase + phi1_acc
                                            ↓
                                           phase_to_iq
                                            ↓
                                           chip_i, chip_q (registered)
```

- For Barker-based states, `base_phase` is:
  - `2'b00` if `BARKER_PATTERN[10-chip_cnt] == 1` (chip +1)
  - `2'b10` otherwise (chip -1)
- For `S_PSDU_CCK`, `base_phase` is `c_k` (or `2'b00` when `chip_cnt == 7`).
- `delta_phi1` comes from:
  - Scrambled data bit for DBPSK: `{s0, 1'b0}` (0 or π)
  - Scrambled dibit for DQPSK: Table-11 mapping `00→0`, `01→π/2`, `11→π`, `10→3π/2`
  - MCU-supplied field for CCK: `cck_word[1:0]`
- `update_phi1` pulses one cycle per symbol (at `chip_cnt == 0`), so the
  rotator's accumulator is updated BEFORE the first chip of each symbol
  uses it (`phi1_eff = update_phi1 ? phi1_next : phi1_acc` in the rotator).

## 4. Path B — Custom QAM

Unchanged from the prior revision except for the fixes already landed:

- `mac_fsm_custom` (on `clk_custom`) emits 1 scrambled bit per cycle using
  a CRC-32 over the PSDU and a parameterized preamble pattern.
- `phy_qam_custom` accumulates bits into N-bit symbols per `mod_config[2:0]`
  (OOK=1, QPSK=2, 16-QAM=4, 64-QAM=6, 256-QAM=8), and is now reset per
  packet by `start_pulse` to prevent cross-packet bit spill-over.
- `symbol_out[7:0]` / `symbol_valid` in `clk_custom` drive the analog side.

The S2P grouper and bit-level scrambler are retained; we're not dropping
them at this round.

## 5. FIFO and MCU-side ingress

One async FIFO bridges `clk_mcu` to the active datapath's read clock.
Depth = 32 bytes by default.  Read clock is muxed between `clk_b_chip`
(Path A) and `clk_custom` (Path B) using `clock_mux_static`.

**TAPE-OUT REQUIREMENT**: `clock_mux_static` is a combinational MUX
placeholder.  It must be replaced with the PDK's glitch-free clock-mux
cell (e.g. CKMUX2D*) before GDS and declared as a clock in SDC.  The
integration contract is that `mod_config` is stable while any chip clock
is running.

Per-rate FIFO byte consumption:
| Rate                | Bytes per packet (exclusive of the 192 header bits) |
|---------------------|-----------------------------------------------------|
| 1 Mbps DBPSK        | `payload_len`                                       |
| 2 Mbps DQPSK        | `payload_len`                                       |
| 5.5 Mbps CCK        | `4 × (payload_len + 4)` (MCU pre-encoded)           |
| 11 Mbps CCK         | `2 × (payload_len + 4)` (MCU pre-encoded)           |
| Path B any mode     | `payload_len` (S2P grouper on-chip packs as before) |

## 6. Control and status interface

```
    MCU                                    chip
     │                                      │
     │ mod_config[3:0], payload_len[15:0]   │   (static through the packet)
     │ length_us[15:0]                      │
     │ tx_enable   ─────rising edge────────►│
     │                                      │
     │ payload_write + payload_in[7:0]     ─► FIFO
     │                                     ◄─ fifo_full
     │                                      │
     │                                     ◄─ tx_busy (level)
     │                                     ◄─ tx_done  (1-cycle pulse)
     │                                     ◄─ underrun (sticky)
     │                                     ◄─ invalid_mode (sticky)
     │                                     ◄─ chip_i / chip_q / chip_valid (Path A)
     │                                     ◄─ symbol_out / symbol_valid    (Path B)
```

SVA assertions (enable with `+define+ASSERT_ON`) flag violations of:
mod_config / payload_len / length_us stability during a packet, overlapping
tx_enable while busy, and failure to latch `invalid_mode`.

## 7. Key changes made in this conversation round

### Round 1 (review fixes + 802.11b Long PLCP for 1 Mbps)

1. **DBPSK per-packet phase reset fixed** — the late-winning non-blocking
   assignment that silently defeated `RESET_DBPSK_PER_PACKET` is gone.
2. **Path B S2P grouper resets per packet** — `phy_qam_custom.start_pulse`
   wired from top-level; fixes cross-packet bit spill-over.
3. **Error observability**: new top-level outputs `underrun`,
   `invalid_mode`, `tx_done`; illegal `mod_config` hard-gates the start.
4. **Per-domain `reset_sync`** for clean synchronous reset de-assertion.
5. **Full Long PLCP compliance for Path A at 1 Mbps**: scrambled SYNC/SFD,
   real CRC-16 HEC, CRC-32 FCS over PSDU only, correct bit orderings
   (MSB-first for SFD/HEC, LSB-first per octet for header/PSDU).
6. **Handshake SDC**: `bit_to_chip_handshake` switched from two independent
   2FFs to a single-FF capture under the divide-by-11 phase-alignment
   contract, eliminating the bit-vs-valid skew window.
7. **SVA assertions**: mod_config stable, tx_enable / payload_len
   constraints, invalid_mode latch.

### Round 2 (this round — multi-rate 802.11b)

1. **Rate matrix expanded** to all four 802.11b data rates (1/2/5.5/11 Mbps)
   via `mod_config[1:0]`; SIGNAL byte is rate-dependent and computed on chip.
2. **MAC moved to `clk_b_chip`** entirely.  The 1→11 MHz handshake
   (`bit_to_chip_handshake`) and the old DSSS PHY (`phy_dsss_80211b`) are
   deleted and replaced with a unified `phy_a_rotator`.
3. **Unified QPSK rotator** (`phy_a_rotator` + `phase_to_iq`) serves
   DBPSK, DQPSK, and CCK modes with a single 2-bit accumulator.  Reused
   instead of duplicated across rates.
4. **CCK moved off chip**: MCU pre-applies scrambler + FCS + CCK codeword
   computation.  Chip receives a packed 16-bit CCK symbol word per two
   FIFO bytes and applies only the φ₁ differential rotation.  No 1 Kb
   lookup table on die.
5. **New `crc16_80211_hec`** module used for the PLCP HEC (added Round 1,
   in active use after the multi-rate refactor).
6. **`mod_config` widened to 4 bits** to encode path select (bit 3) plus
   sub-mode (bits 2:0).  `invalid_mode` hard-gate adapted.
7. **Distinct `chip_i` / `chip_q` output pins** carry Path A chips.
   Path B keeps the 8-bit `symbol_out` bus.
8. **New `length_us[15:0]` input** — MCU supplies the PLCP LENGTH field
   directly (avoids an on-chip divide-by-11 for 5.5/11 Mbps).
9. **Removed files**: `path_a/bit_to_chip_handshake.v`,
   `path_a/phy_dsss_80211b.v` (replaced by rotator + merged MAC).
10. **`clk_b_data` pin retired**.  The MAC derives its 1 Mbps cadence from
    `chip_cnt` on `clk_b_chip`, so the pad is no longer needed; removed
    from the top-level port list and pad ring.

## 8. Outstanding items for tape-out

- Swap `clock_mux_static` for the PDK's glitch-free clock-mux cell.
- Confirm MCU firmware support for the new CCK packing format and the
  post-header scrambler-state replication.
- Decide whether Short PLCP is ever needed (currently not supported).
- Gate-level power estimation to confirm the CCK-rotator path meets the
  ULP budget; back-off options include dropping 5.5 Mbps (shares hardware
  with 11 Mbps so savings are small) or dropping CCK entirely and
  supporting only 1/2 Mbps.
