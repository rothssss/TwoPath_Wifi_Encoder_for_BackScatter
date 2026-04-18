# Wifi Doc

---

# Micro-Architecture Specification (MAS): Multi-Mode Backscatter Baseband

## 1. Module Overview

The `multi_mode_tx_baseband` is a digital IP block for an ultra-low-power backscatter transmitter. It retrieves payload data from an MCU/Sensor, performs MAC/PHY formatting, and outputs **logical baseband symbols** to an external analog combinational decoder.

It supports two mutually exclusive datapaths:

- **Path A (Standard 802.11b):** 1 Mbps throughput. Uses Direct Sequence Spread Spectrum (DSSS) with an 11-chip Barker sequence and DBPSK modulation.
- **Path B (Custom Variable-QAM):** High-speed throughput up to 100 Mbaud. Supports OOK, QPSK, 16-QAM, 64-QAM, and 256-QAM using a variable Serial-to-Parallel (S2P) grouper.

## 2. Clocking & Reset Strategy

This is a **Multi-Clock Domain** design relying on externally supplied, gated clocks.

- `clk_b_data` (1 MHz): Drives the MAC/Scrambler for 802.11b.
- `clk_b_chip` (11 MHz): Drives the Barker spreader and output for 802.11b. Must be phase-aligned with `clk_b_data`.
- `clk_custom` (up to 100 MHz): Drives the entirety of the Custom QAM datapath.
- **Reset:** A single active-low, asynchronous reset (`rst_n`) initializes all sequential elements.
- **Power/Clock Gating Requirement:** The analog/mixed-signal domain *must* gate off the clocks for the inactive datapath to prevent dynamic power drain in the digital block.

## 3. I/O Port Definitions

| **Port Name** | **Direction** | **Width** | **Description** |
| --- | --- | --- | --- |
| `clk_b_data` | Input | 1 | 802.11b baseband clock (1 MHz). |
| `clk_b_chip` | Input | 1 | 802.11b DSSS chip clock (11 MHz). |
| `clk_custom` | Input | 1 | Custom QAM baseband clock (max 100 MHz). |
| `clk_mcu` | Input | 1 | Sensor/MCU system clock for writing payload. |
| `rst_n` | Input | 1 | Asynchronous active-low reset. |
| `tx_enable` | Input | 1 | Trigger to start transmission (synchronized to `clk_mcu`). |
| `mod_config` | Input | 3 | Static configuration: `000`=802.11b, `001`=OOK, `010`=QPSK, `011`=16-QAM, `100`=64-QAM, `101`=256-QAM. |
| `payload_len` | Input | 16 | Number of bytes in the payload. |
| `payload_in` | Input | 8 | Parallel payload data bus from the MCU. |
| `payload_write` | Input | 1 | Write-enable from the MCU to push data into the FIFO. |
| `tx_busy` | Output | 1 | Goes HIGH when transmission begins, LOW when complete. |
| `fifo_full` | Output | 1 | Signals to the MCU to pause writing. |
| `symbol_out` | Output | 8 | The logical symbol driving the external analog decoder. |
| `symbol_valid` | Output | 1 | Pulses HIGH to indicate a new symbol is on the bus. |

---

## 4. Sub-Module Architecture

### Block A: Asynchronous CDC Input FIFO

- **Function:** Bridges the user's data from the MCU clock domain into the active transmission clock domain.
- **Write Domain:** Driven by `clk_mcu` and `payload_write`.
- **Read Domain:** Driven by a read-enable signal multiplexed from either the 802.11b MAC FSM or the Custom QAM FSM, depending on `mod_config`.
- **Depth:** 32 bytes (sufficient to prevent underflow without wasting silicon area).

### Block B: Datapath 1 (802.11b DSSS Mode)

*Active when `mod_config == 000`.*

This path spans two clocks. Data flows from `clk_b_data` into `clk_b_chip`.

- **MAC Engine (`clk_b_data`):**
    - **FSM:** Manages packet state (`IDLE` $\rightarrow$ `PREAMBLE` $\rightarrow$ `HEADER` $\rightarrow$ `PAYLOAD` $\rightarrow$ `FCS`). Generates the 128-bit SYNC and 16-bit SFD.
    - **CRC-32:** Standard IEEE 802.11 polynomial. Calculates over the MAC header and payload.
    - **Scrambler:** 7-bit LFSR (polynomial $x^7 + x^4 + 1$). XORs the bitstream.
- **Phase-Aligned Handshake:** Passes the 1 MHz scrambled bit into the 11 MHz domain.
- **PHY Engine (`clk_b_chip`):**
    - **Barker Spreader:** Combinational logic. Inputs 1 bit. If `1`, streams `10110111000`. If `0`, streams the inverse.
    - **DBPSK Mapper:** `current_phase <= prev_phase ^ incoming_chip`.
    - **Register:** Stores the 1-bit result in `path_a_symbol[0]`, leaving `[7:1]` as zeros.

### Block C: Datapath 2 (Custom Variable-QAM Mode)

*Active when `mod_config > 000`.*

This path runs entirely on `clk_custom` (up to 100 MHz).

- **MAC Engine (`clk_custom`):**
    - **FSM:** Manages states (`IDLE` $\rightarrow$ `CUSTOM_PREAMBLE` $\rightarrow$ `PAYLOAD` $\rightarrow$ `FCS`).
    - **CRC-32 & Scrambler:** Functions identically to the 802.11b block but instantiated separately to run at 100 MHz.
- **PHY Engine (`clk_custom`):**
    - **Variable S2P Grouper:** A shift register that observes `mod_config`.
        - If `001` (OOK), it shifts 1 bit and fires `valid`.
        - If `011` (16-QAM), it shifts 4 bits, fires `valid`, and outputs to `path_b_symbol[3:0]`.
        - If `101` (256-QAM), it shifts 8 bits, fires `valid`, and outputs to `path_b_symbol[7:0]`.
    - **Zero-Padding:** Explicitly forces all unused upper bits of `path_b_symbol` to `0` to prevent the analog decoder from seeing floating gates.

### Block D: Output Multiplexer

- **Function:** Statically routes the correct datapath to the physical output pins based on the user configuration.
- **Logic:**
    - Combinational MUX controlled by `mod_config`.
    - If `000`, `symbol_out = path_a_symbol`.
    - Else, `symbol_out = path_b_symbol`.
    - `symbol_valid` is similarly multiplexed from the active path.

---

## 5. Verification & Simulation Expectations

When writing testbenches, the Verification Engineer should confirm the following behaviors:

1. **Configuration Isolation:** When simulating Datapath A, all registers in Datapath B should remain static (no toggling) because the external `clk_custom` is assumed gated.
2. **Bit-to-Chip Expansion (Path A):** For every 1 bit pulled from the FIFO, the `symbol_out` bus must toggle 11 times (at the `clk_b_chip` rate), only transitioning `symbol_out[0]`.
3. **S2P Grouping (Path B):** If set to 16-QAM, the `symbol_valid` signal must only pulse HIGH once for every 4 bits processed by the Scrambler. The output must reliably reflect the accumulated 4-bit word on `symbol_out[3:0]`.
4. **CRC Flushing:** In both modes, once `payload_len` expires, the FSM must smoothly transition to shifting out the 32-bit CRC remainder before dropping `tx_busy`.