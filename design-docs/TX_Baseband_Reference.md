# TX Baseband Reference (final, pre-tape-out)

This document is the canonical reference for the `multi_mode_tx_baseband`
RTL.  It describes the design, data flow at every supported rate, the
MCU offload contract, and the verification procedure.  It is the
intended single point of truth for anyone bringing the chip up post-fab
or porting the firmware to a new MCU.

Companion docs:

  - `Multi-Mode_TX_Architecture.md`            -- short architecture summary.
  - `Wifi_Lite_Change_Log.md`                  -- revision history.
  - `synth/rtl_flat/new_problems.md`           -- compliance review and
                                                  pre-tape-out caveats.

---

## 1. What this block is

`multi_mode_tx_baseband` is the digital baseband portion of an
802.11b-class transmitter, intended for backscatter or low-power direct
emission.  It accepts payload bytes from an MCU over an asynchronous
FIFO, builds a Long-PLCP IEEE 802.11b frame around the payload, and
emits a single-bit complex chip stream `chip_i / chip_q` at 11 Mchip/s.

Four PSDU rates are supported:

  | `mod_config` | Rate         | Modulation        | Encoding owner |
  |--------------|--------------|-------------------|----------------|
  | `4'b0000`    | 1   Mbps     | DBPSK + 11-Barker | chip           |
  | `4'b0001`    | 2   Mbps     | DQPSK + 11-Barker | chip           |
  | `4'b0010`    | 5.5 Mbps     | 8-chip CCK        | MCU firmware   |
  | `4'b0011`    | 11  Mbps     | 8-chip CCK        | MCU firmware   |

Any other `mod_config` value latches `invalid_mode` and refuses to
start.

CCK rates use an MCU-offload contract: the MCU's firmware computes
the scrambling, CRC-32, and CCK encoding (sec 16.4.6) in software and
ships pre-computed 8-chip QPSK symbols to the chip via the FIFO.  The
chip-side blocks for CCK are intentionally minimal -- no chip-side
scrambler, CRC, Walsh table, or DQPSK accumulator math runs at CCK
rates.  See section 5 for the byte-level packing.

For 1 and 2 Mbps the chip is fully self-contained: scrambler, CRC-32
FCS, CRC-16 HEC, Barker spreader, and DBPSK / DQPSK mapper all run on
chip.

---

## 2. Top-level interface

### 2.1 Ports

```
input  wire        clk_b_chip     // 11 MHz chip clock; everything that
                                  //   produces chips runs on this.
input  wire        clk_custom     // deprecated; tied to whatever the
                                  //   wrapper supplies, not used inside.
input  wire        clk_mcu        // 50 MHz typical; FIFO write port +
                                  //   tx_enable / status pins.
input  wire        rst_n          // async-asserted active-low reset.

input  wire        tx_enable      // rising edge starts a packet.
input  wire [3:0]  mod_config     // see table above; legal range 0000..0011.
input  wire [15:0] payload_len    // raw payload bytes (Barker rates only).
input  wire [15:0] length_field   // PLCP LENGTH field, MCU-supplied.
input  wire [7:0]  service_field  // PLCP SERVICE byte, MCU-supplied.
input  wire [15:0] cck_symbol_count // CCK symbols in PSDU+FCS (CCK only).

input  wire [7:0]  payload_in     // FIFO write data byte.
input  wire        payload_write  // FIFO write strobe.

output wire        tx_busy        // high while a packet is on the air.
output wire        fifo_full      // back-pressure to the MCU.
output wire        underrun       // FIFO went empty mid-packet.
output wire        invalid_mode   // illegal mod_config was attempted.
output wire        tx_done        // single-cycle pulse on packet end.

output wire [7:0]  symbol_out     // tied 0; legacy port.
output wire        symbol_valid   // tied 0; legacy port.
output wire        chip_i         // I-axis chip output, 1-bit sign.
output wire        chip_q         // Q-axis chip output, 1-bit sign.
output wire        chip_valid     // high while chip_i / chip_q are valid.
```

### 2.2 Parameters (compile-time)

```
parameter integer PREAMBLE_SYNC_LEN_A = 128       // SYNC bit count (spec)
parameter [15:0]  SFD_PATTERN_A       = 16'hF3A0  // SFD (spec)
parameter [6:0]   SCRAMBLER_SEED_A    = 7'h6D     // scrambler seed
parameter [10:0]  BARKER_PATTERN      = 11'b10110111000  // 11-chip Barker
parameter integer FIFO_DEPTH          = 16        // FIFO bytes
parameter integer FIFO_ADDR_W         = 4         // ceil(log2(FIFO_DEPTH))
```

### 2.3 Clock domains

Two functional clocks:

  - `clk_mcu`     -- MCU side.  Drives FIFO writes, `tx_enable`,
                     `invalid_mode` latch, and back-pressure / status.
  - `clk_b_chip`  -- Chip side.  11 MHz.  Drives the FIFO read pointer,
                     the MAC FSM, all on-chip framing logic, and the
                     phase rotator.  All chip-domain signals are
                     synchronous to this clock.

Cross-domain handoffs are:

  - `start_pulse` -- `clk_mcu -> clk_b_chip`, via `pulse_sync` (toggle
                     plus 2-flop sync plus edge detect).
  - `tx_busy`     -- `clk_b_chip -> clk_mcu`, via `sync_2ff`.
  - `tx_done`     -- `clk_b_chip -> clk_mcu`, via `pulse_sync`.
  - `underrun`    -- `clk_b_chip -> clk_mcu`, via `sync_2ff`.
  - Payload data  -- `clk_mcu -> clk_b_chip`, via the dual-clock async
                     FIFO (Gray-code Cummings pointer crossing).

### 2.4 Reset

`rst_n` is the chip-level async reset.  It enters two `reset_sync`
instances (one per clock) which produce `rst_n_mcu_s` and
`rst_n_b_chip_s`.  These are async-asserted (immediately on `rst_n`
falling edge) and sync-deasserted (released two clock edges after
`rst_n` rises).  All sequential logic in the design uses the
sync-deasserted reset of its own clock domain.

---

## 3. Architecture

### 3.1 Block diagram

```
       MCU                         clk_mcu                             clk_b_chip
       ---                         -------                             ----------
                                                                                   
   payload_in[7:0]   ----+                                                          
   payload_write    ----->----> [ async_fifo ] -- fifo_rd_data --+                  
                                                                 |                  
   tx_enable     ---+                                            v                  
                    +-+                                  [ mac_fsm_80211b ]         
                      v                                          |                  
              [tx_enable_pulse]----->[pulse_sync]---->[start_pulse_a]              
                      |                                          |                  
                      v                                          v                  
              [invalid_mode]<------(mod_config range check)      |                  
                                                                 |                  
                                                       base_phase, delta_phi1,      
                                                       update_phi1, chip_valid      
                                                                 |                  
                                                                 v                  
                                                        [ phy_a_rotator ]           
                                                                 |                  
                                                                 v                  
                                                          chip_i, chip_q,           
                                                          chip_valid                
                                                                                   
   tx_busy   <----- sync_2ff <-------- a_busy                                       
   tx_done   <----- pulse_sync <------ a_done                                       
   underrun  <----- sync_2ff <-------- a_underrun                                   
```

### 3.2 Datapath at a glance

  - One transmit path, four PSDU rates, one rotator.
  - SYNC, SFD, SIGNAL, SERVICE, LENGTH, HEC are always emitted as
    1 Mbps DBPSK + Barker, regardless of PSDU rate (this is what
    Long-PLCP requires).
  - Only the PSDU+FCS region differs per rate:
      * Barker rates: chip-side scrambler + CRC + Barker + DBPSK/DQPSK.
      * CCK rates:    chip streams pre-computed CCK symbols from FIFO.
  - The phase rotator is shared.  For Barker chips, base_phase is the
    Barker chip polarity (0 = "+1", 2 = "-1") and delta_phi1 is the
    DBPSK or DQPSK symbol delta.  For CCK chips, base_phase is the
    pre-computed `c_k` value and delta_phi1 is the pre-computed
    DQPSK delta for `phi1` (with the sec 16.4.6.3 odd-symbol +pi
    correction already folded in).

### 3.3 FSM

`mac_fsm_80211b` runs on `clk_b_chip` and walks one packet through nine
states:

```
  S_IDLE  ---start_pulse--->  S_SYNC
  S_SYNC  ---SYNC done---> S_SFD
  S_SFD   ---SFD done---> S_HEAD
  S_HEAD  ---HEADER done---> S_HEC
  S_HEC   ---HEC done, CCK---> S_PSDU_CCK
  S_HEC   ---HEC done, Barker, payload != 0---> S_PSDU_BARKER
  S_HEC   ---HEC done, Barker, payload == 0---> S_FCS_BARKER
  S_PSDU_BARKER ---last payload bit---> S_FCS_BARKER
  S_FCS_BARKER  ---last FCS bit ---> S_DONE
  S_PSDU_CCK    ---last CCK symbol--->S_DONE
  S_DONE  ---one cycle---> S_IDLE   (and pulses tx_done)
```

`chip_cnt` counts chips inside the current symbol.  In Barker states it
runs 0..10; in `S_PSDU_CCK` it runs 0..7.  `sym_cnt` counts symbols
inside the current field (0..127 for SYNC, 0..15 for SFD/HEC, 0..31
for HEAD).  `byte_cnt` and `bit_in_byte` track the position inside
the PSDU at Barker rates; `cck_sym_cnt` tracks the CCK PSDU symbol
index.

---

## 4. Per-rate data flow

### 4.1 1 Mbps DBPSK + Barker (`mod_config = 4'b0000`)

On-chip pipeline:

```
  payload byte (FIFO) ---LSB-first---> bit ---> scrambler ---> CRC-32 feed
                                                                    |
                                                                    v
                       DBPSK delta = {scrambled_bit, 0}    (via dqpsk_delta_from_bits)
                                                                    |
                                                                    v
                            phy_a_rotator -- chip_i / chip_q, 11 chips per bit
```

  - One byte from the FIFO becomes 8 PSDU bits.  Each bit becomes one
    1 Mbps DBPSK symbol = 11 Barker chips.
  - DBPSK delta: scrambled bit s0 = 0 -> delta 0 (no rotation),
                 s0 = 1 -> delta 2 (180-degree rotation).
  - Barker chip polarity: BARKER_PATTERN[10 - chip_cnt].  base_phase is
    `2'b00` for "+1" Barker chip, `2'b10` for "-1" Barker chip.
  - At end of payload, the FSM emits the 32-bit CRC-32 FCS the same
    way (LSB-first, scrambled, Barker-spread, DBPSK).
  - Each packet emits `(SYNC + SFD + SIGNAL + SERVICE + LENGTH + HEC) +
    8 * payload_len + 32` symbols, all at 11 chips per symbol.
    With default SYNC=128, that's `2112 + 11 * (8N + 32)` chips.

### 4.2 2 Mbps DQPSK + Barker (`mod_config = 4'b0001`)

Same pipeline as 1 Mbps, with two changes:

  - PSDU bits are consumed in pairs.  Each dibit becomes one DQPSK
    symbol = 11 Barker chips.  `bit_in_byte` increments by 2 per
    symbol.
  - DQPSK delta is `dqpsk_delta_from_bits(s0, s1)` per Table 16-4
    (00 -> 0, 01 -> pi/2, 11 -> pi, 10 -> 3pi/2).

Each packet emits `2112 + 11 * (4N + 16)` chips with default SYNC.

### 4.3 5.5 Mbps CCK (`mod_config = 4'b0010`)

  - Preamble + header is still 1 Mbps DBPSK + Barker.
  - PSDU + FCS region is replayed from MCU-supplied 4-byte words (one
    word per 8-chip CCK symbol).
  - On-chip scrambler, CRC-32, Barker, and DQPSK math are quiescent.
  - Symbol count, scrambling, CRC, CCK encoding, chip-3/6 +pi, and
    odd-symbol +pi are all the MCU's responsibility.

Pre-tape-out item: the MCU firmware reference encoder is not in this
repo.  When it lands, validate against MATLAB
`wlanWaveformGenerator(wlanNonHTConfig('Modulation','DSSS', ...))`
or an equivalent reference.

### 4.4 11 Mbps CCK (`mod_config = 4'b0011`)

Identical chip-side path to 5.5 Mbps.  The MCU encodes twice as many
information bits per symbol but ships the same 4-byte format per
8-chip symbol.  Sustained FIFO throughput is ~5.5 MB/s either way.

---

## 5. FIFO contract

The FIFO is a Cummings-style dual-clock async FIFO with Gray-coded
pointer crossings, 16 bytes deep by default.

### 5.1 Write side (MCU domain)

  - `payload_write` strobes one byte from `payload_in` per cycle while
    `fifo_full` is low.  A write while `fifo_full` is high is silently
    dropped (the FSM's `wptr_bin` only advances when
    `payload_write & ~fifo_full`).  The MCU is expected to honour
    `fifo_full` as back-pressure.
  - All write-side state is in `clk_mcu`.

### 5.2 Read side (chip domain)

  - `fifo_rd_en` is COMBINATIONAL and driven by the MAC FSM.  This is
    deliberate: the FIFO advances `rptr` on the same edge the MAC
    captures the byte, so consecutive reads work without a one-cycle
    bubble.  (The earlier registered `fifo_rd_en` had a one-cycle lag
    that broke CCK's four-back-to-back reads.)
  - `fifo_rd_data` is the byte at the current `rptr`; combinational on
    the FIFO RAM.

### 5.3 Byte stream at 1 / 2 Mbps

  - Stream is the raw payload byte-by-byte, in the order the MCU
    writes them.  LSB of each byte is the first bit on the air.
  - Total bytes per packet = `payload_len`.

### 5.4 Symbol stream at 5.5 / 11 Mbps (4 bytes / CCK symbol)

Per CCK symbol the MCU writes one 32-bit packed word, byte 0 first
(LSB-byte first).  The bit layout inside the 32-bit word is:

```
  bits [ 1: 0]   delta_phi1  (DQPSK delta for d1, with sec 16.4.6.3
                              odd-symbol +pi already folded in)
  bits [ 3: 2]   c_k0
  bits [ 5: 4]   c_k1
  bits [ 7: 6]   c_k2
  bits [ 9: 8]   c_k3        (already includes the chip-3 +pi)
  bits [11:10]   c_k4
  bits [13:12]   c_k5
  bits [15:14]   c_k6        (already includes the chip-6 +pi)
  bits [17:16]   c_k7
  bits [31:18]   reserved (MCU writes 0)
```

Concretely, the MCU writes:

```
  byte 0 = { c_k2, c_k1, c_k0, delta_phi1 }   (LSB to MSB inside the byte)
  byte 1 = { c_k6, c_k5, c_k4, c_k3 }
  byte 2 = {  6'b0,                   c_k7 }
  byte 3 =   8'h00
```

Total bytes per packet = `4 * cck_symbol_count`.  Sustained MCU bus
rate during a packet = `4 * 1.375 MHz = 5.5 MB/s`.

### 5.5 Underrun

`underrun` is set in the chip domain and crossed back to the MCU via
`sync_2ff` when:

  - The MAC tries to read but `fifo_empty` is high (Barker mode), or
  - The CCK streamer's prefetch tries to read but `fifo_empty` is
    high.

Underrun does not abort the packet -- the state machine continues to
emit chips, but the data is whatever was last in the prefetch buffer.
The `underrun` flag is the MCU's signal that the packet is corrupted.
Typical recovery is to wait for `tx_done` then re-queue.

---

## 6. PLCP framing details

Long preamble layout (every PSDU rate):

```
  +------+------+------+------+------+------+------+----+
  | SYNC | SFD  |SIGNAL|SVC   |LENGTH| HEC  | PSDU |FCS |
  | 128  |  16  |  8   |  8   |  16  |  16  |  ... | 32 |
  +------+------+------+------+------+------+------+----+
  <----- emitted at 1 Mbps DBPSK + Barker ------>     emitted at PSDU rate
```

  - `SYNC`         128 scrambled 1's, DBPSK + Barker (per sec 16.2.3.2).
  - `SFD`          0xF3A0, MSB on the air first (sec 16.2.3.3).  Stored
                   as `sfd_sr` and shifted left so `sfd_sr[15]` is the
                   bit being transmitted.
  - `SIGNAL byte`  0x0A / 0x14 / 0x37 / 0x6E for 1 / 2 / 5.5 / 11 Mbps
                   (Table 16-1).  Bits transmitted LSB-first within
                   the byte.
  - `SERVICE`      MCU-supplied via `service_field`.  Bit 7 =
                   LENGTH_EXTENSION (sec 16.2.3.4); the MCU is
                   responsible for setting it correctly at 11 Mbps
                   based on `(8 * N) mod 11`.  Bit 2 = LOCKED_CLOCKS.
                   Other bits zero by default.
  - `LENGTH`       MCU-supplied via `length_field`.  16 bits, LSB octet
                   first on the air.  Standard rules:
                       1   Mbps:  LENGTH = 8 * N        (microseconds)
                       2   Mbps:  LENGTH = 4 * N
                       5.5 Mbps:  LENGTH = ceil(8N / 4)
                       11  Mbps:  LENGTH = ceil(8N / 11)  + LENGTH_EXT
  - `HEC`          16-bit CRC-16 (poly 0x1021, init 0xFFFF, no
                   reflection, XOR-out 0xFFFF) over the prior 48
                   header bits.  Transmitted MSB-first per spec
                   sec 16.2.3.7.
  - `PSDU`         payload, format depends on rate (see section 4).
  - `FCS`          32-bit CRC-32 over the PSDU.  Polynomial
                   0x04C11DB7, reflected representation 0xEDB88320,
                   init 0xFFFFFFFF, XOR-out 0xFFFFFFFF.  Transmitted
                   LSB-first on the air.  At CCK rates the MCU
                   computes and pre-encodes the FCS as part of the
                   CCK symbol stream.

---

## 7. Scrambler

Self-synchronous scrambler with polynomial `x^7 + x^4 + 1`
(sec 16.2.4, Figure 16-6):

```
  scrambled_out = data_in XOR state[6] XOR state[3]
  state_next    = { scrambled_out, state[6:1] }
```

  - The default seed is `7'h6D` (any non-zero seed satisfies the spec;
    0 is forbidden because the LFSR degenerates).
  - The seed is reloaded on every `start_pulse` so each packet starts
    from a known state.
  - Used at Barker rates.  At CCK rates the MCU is responsible for
    scrambling the bitstream before CCK encoding, so the chip-side
    scrambler is held off.

---

## 8. Phase rotator

`phy_a_rotator` is a 4-state QPSK accumulator:

```
  phi1_next  = phi1_acc + delta_phi1               (2-bit modular add)
  phi1_eff   = update_phi1 ? phi1_next : phi1_acc  (chip 0 of new sym)
  chip_phase = base_phase + phi1_eff               (2-bit modular add)
  chip_i     = ~chip_phase[0]
  chip_q     = ~chip_phase[1]
```

The 2-bit phase code maps to the four diagonal QPSK constellation
points (+/- pi/4, +/- 3pi/4).  This is a 45-degree axis rotation
relative to the standard 802.11 constellation diagram.  Receivers with
carrier recovery resolve this transparently; see
`synth/rtl_flat/new_problems.md` section C.1 for the spec impact.

---

## 9. Verification

Four testbenches must all pass before sign-off.  Each is run from the
project root.

### 9.1 Top-level functional bench

```sh
xrun -sv -f tb/filelist.f +define+ASSERT_ON \
     -top tb_multi_mode_tx_baseband
```

Covers (test list inside `tb/tb_multi_mode_tx_baseband.sv`):

  - `T_C1` -- illegal `mod_config` (`4'b0100`, `4'b1000`) latches
              `invalid_mode` and refuses to start.
  - `T_A1` -- 1 Mbps DBPSK packet with 4 payload bytes; expects
              2816 `chip_valid` pulses, single `tx_done`, no underrun.
  - `T_A2` -- 2 Mbps DQPSK packet with 4 bytes; expects 2464 chips.
  - `T_A3` -- 5.5 Mbps CCK stub with 2 CCK symbols (8 FIFO bytes);
              expects 2128 chips.
  - `T_A4` -- 11 Mbps CCK stub with 2 CCK symbols; expects 2128 chips.
  - `T_C2` -- two back-to-back DBPSK packets each emit cleanly with
              two `tx_done` pulses.

Append `+define+WAVES` for VCD dumping
(`tb_multi_mode_tx_baseband.vcd`).

Pass criterion: log ends with `*** ALL TESTS PASSED ***`.

### 9.2 Focused Path A regression

```sh
xrun -sv -f tb/filelist_mac_fsm_80211b_checks.f \
     -top tb_mac_fsm_80211b_checks
```

Covers internal Barker behaviour: payload byte alignment against the
FWFT FIFO, DQPSK phase mapping, on-chip header construction at 1 and
2 Mbps.  Drives `mac_fsm_80211b` directly with a behavioural FIFO.

Pass criterion: every `[PASS]`, no `[FAIL]`.

### 9.3 CCK golden-vector regression

```sh
xrun -sv -f tb/filelist_mac_fsm_80211b_cck_golden.f \
     -top tb_mac_fsm_80211b_cck_golden
```

Validates the MCU-offload streamer at the MAC -> rotator interface.
Four directed tests:

  - `test_uniform_and_mixed`   -- 4 symbols, all phase codes.
  - `test_single_symbol`       -- corner case `cck_symbol_count = 1`.
  - `test_prefetch_isolation`  -- two symbols with maximally different
                                  c_k patterns; catches cross-symbol
                                  leakage.
  - `test_eight_symbols`       -- 8 symbols, prefetch across all
                                  symbol boundaries.

For each chip the bench checks:

  - `base_phase` matches `cck_word[2 + (chip<<1) +: 2]`.
  - `update_phi1` pulses once per symbol on chip 0 and only there.
  - `delta_phi1` at that pulse matches `cck_word[1:0]`.
  - Total chip count = `HDR_CHIPS + 8 * cck_symbol_count`.
  - FIFO bytes consumed = `4 * cck_symbol_count`.
  - `done_pulse` fires exactly once.
  - `update_phi1` fires `cck_symbol_count` times inside `S_PSDU_CCK`.

If any test fails, the bench prints `dut.chip_cnt`,
`dut.cck_sym_cnt`, `dut.state`, `dut.cck_word_curr`, and
`dut.cck_word_next` for the failing chip so the cause is
inspectable from the log alone.

Pass criterion: tally line reads `total=40 failed=0 result=*** PASS ***`.

### 9.4 Flattened-RTL smoke test

```sh
xrun -sv -f synth/tb/filelist_tb_top_flat.f \
     -top tb_top_flat
```

End-to-end smoke against `synth/rtl_flat/multi_mode_tx_baseband_flat.v`
to confirm the flattened single-module file synthesises identically
in simulation.  Tests:

  - `T_A1` -- 1 Mbps DBPSK 4-byte packet; expects 2816 chips.
  - `T_A2` -- 11 Mbps CCK stub, 2 symbols; expects 2128 chips.
  - `T_C1` -- illegal `mod_config = 4'b0111`; latches `invalid_mode`.

This must be run AFTER any change to the hierarchical RTL or to
`gen_single_module_flat.py` (the flattener).  Regenerate the flat
files first:

```sh
python3 synth/rtl_flat/gen_single_module_flat.py
```

Pass criterion: tally line reads `*** PASS ***`.

### 9.5 Iteration order

Run the four benches in this order; smaller/faster first so a
regression is caught at the smallest blast radius:

```sh
cd /storage-home/l/lr60/ELEC422/wifi-chip/TwoPath_Wifi_Encoder_for_BackScatter

xrun -sv -f tb/filelist_mac_fsm_80211b_cck_golden.f \
     -top tb_mac_fsm_80211b_cck_golden -l logs/cck.log

xrun -sv -f tb/filelist_mac_fsm_80211b_checks.f \
     -top tb_mac_fsm_80211b_checks -l logs/mac_checks.log

xrun -sv -f tb/filelist.f +define+ASSERT_ON \
     -top tb_multi_mode_tx_baseband -l logs/top.log

xrun -sv -f synth/tb/filelist_tb_top_flat.f \
     -top tb_top_flat -l logs/flat.log

grep -E '\\*\\*\\*|FAIL' logs/*.log
```

Last grep should show four `*** PASS ***` lines and no `[FAIL]`.

---

## 10. Synthesis handoff

  - **Hierarchical sources** for tools that prefer them:
      `rtl/multi_mode_tx_baseband.v` and the modules under
      `rtl/cdc/`, `rtl/common/`, `rtl/path_a/`.

  - **Flattened single-module file** for tools that prefer flat:
      `synth/rtl_flat/multi_mode_tx_baseband_flat.v`.

  - **Filelists**:
      `tb/filelist.f`                       hierarchical RTL + top tb.
      `tb/filelist_mac_fsm_80211b_checks.f` Path A focused.
      `tb/filelist_mac_fsm_80211b_cck_golden.f` CCK golden.
      `synth/tb/filelist_tb_top_flat.f`     flat RTL + flat tb.
      `synth/tb/filelist_rtl_top_only.f`    flat RTL only (no tb).

  - **Regenerating the flat file**: run `python3
    synth/rtl_flat/gen_single_module_flat.py` from the project root
    after any change to a hierarchical RTL file or to the multimodule
    stitch-up.  The script wraps non-trivial port-connection
    expressions in parentheses to avoid Verilog precedence pitfalls
    (notably the FCS feedback expression in the CRC-32 instance --
    see commit history).

  - **Power analysis**: existing flow uses `tb/saif.tcl` with
    `xrun -access +rwc -input tb/saif.tcl`.  Output `*.saif` is
    consumed by the synthesis tool's `read_saif`.

---

## 11. Pre-tape-out caveats

These are open items that do not block the digital sign-off but should
be tracked:

  1. **Constellation axis rotation**.  `phase_to_iq` emits +/- pi/4 /
     +/- 3pi/4 instead of the 802.11 axis-aligned 0 / pi/2 / pi /
     3pi/2.  DPSK demodulators with carrier recovery handle this, but
     the matched-filter EVM is degraded by ~10 degrees (~3 dB SNR
     margin at 1 Mbps).  Confirm with the analog/RF team that the
     mixer either rotates back or the receiver budget tolerates this.

  2. **Sticky `invalid_mode`**.  Cleared only by `rst_n`.  If the MCU
     expects write-1-to-clear or auto-clear-on-valid-config, this is
     an RTL change.

  3. **MCU CCK firmware**.  Not in this repo.  Spec compliance for
     5.5 / 11 Mbps is conditional on the firmware encoding correctly
     per IEEE 802.11-2016 sec 16.4.6.  Validate against MATLAB
     `wlanWaveformGenerator` (DSSS option) or equivalent before going
     on the air.

  4. **No `default_nettype none`**.  Cosmetic, but a typo would
     silently infer a 1-bit wire.  Add a global declaration in the
     flat file for sign-off lint.

  5. **Async FIFO read data is unregistered**.  Functionally fine at
     11 MHz; may want a registered-output option at higher chip
     clocks, depending on memory cell timing.

  6. **No bit-level CCK golden vectors**.  Current CCK regression is
     streamer-correctness only.  When the firmware reference exists,
     extend the bench to drop in the firmware's MATLAB / ns-3
     golden vectors via the existing `pack_cck` / `load_cck_word`
     harness.

  7. **Existing scrambler test (`tb_scrambler_x7x4`) overrides the
     seed to `7'h00`**.  That is the one seed sec 16.2.4 forbids.
     Keep it as a structural test only; add a non-zero-seed
     regression alongside before sign-off.

---

## 12. Bring-up checklist (post-fab)

  1. Logic-analyser capture of `chip_i` / `chip_q` / `chip_valid`
     during a 1 Mbps DBPSK packet with known payload.  Decode offline
     in Python: descramble, despread Barker, undo DBPSK, compare to
     payload.

  2. Repeat for 2 Mbps DQPSK.

  3. Repeat for 5.5 Mbps CCK and 11 Mbps CCK with the firmware
     pre-encoder running.  Decode offline against the firmware's own
     encoder output (or against a MATLAB reference).

  4. Spectrum-analyser sweep on `chip_i` / `chip_q` after the analog
     mixer.  Confirm sec 16.3 spectral mask compliance.

  5. Wired loopback through an attenuator into a commercial 802.11b
     NIC in monitor mode (e.g. AR9271 + Wireshark).  Confirm at all
     four rates that frames are decoded with correct destination MAC,
     payload, and FCS.

  6. Stress: random payload lengths 1..1500 bytes, back-to-back
     packets, random `tx_enable` jitter.  Confirm `underrun` never
     fires when MCU keeps the FIFO non-empty.

  7. Air test inside a shielded enclosure to a real AP / STA.

  8. Compliance lab (FCC Part 15 conducted + radiated, EN 300 328 if
     EU) for spectral mask, OOB emissions, and TX power.
