# synth/ — flattened single-file RTL + systematic test suite

This subfolder is a self-contained view of the TX baseband for logic
synthesis and systematic regression:

```
synth/
├── rtl_flat/
│   └── multi_mode_tx_baseband_flat.v     # every module inlined, one file
└── tb/
    ├── timescale.v
    ├── filelist_rtl.f                    # flat RTL only
    ├── filelist_tb_<name>.f               # per-test compile list
    ├── tb_phase_to_iq.sv
    ├── tb_scrambler_x7x4.sv
    ├── tb_crc16_hec.sv
    ├── tb_crc32_80211.sv
    ├── tb_sync_2ff.sv
    ├── tb_reset_sync.sv
    ├── tb_pulse_sync.sv
    ├── tb_async_fifo.sv
    ├── tb_phy_a_rotator.sv
    ├── tb_phy_qam_custom.sv
    ├── tb_mac_fsm_custom.sv
    ├── tb_mac_fsm_80211b.sv
    └── tb_top_flat.sv
```

Nothing elsewhere in the repository has been changed.  The original
hierarchical sources under `rtl/`, `tb/`, and `design-docs/` are still the
authoritative copy.  `synth/` is a parallel, synthesis-friendly cut.

## 1. Flattened RTL

`rtl_flat/multi_mode_tx_baseband_flat.v` contains every module from the
hierarchical tree inlined in bottom-up dependency order so a synthesis
tool can be pointed at exactly one source file:

| Layer     | Modules (top-of-file first)                                    |
|-----------|----------------------------------------------------------------|
| leaf/CDC  | `sync_2ff`, `reset_sync`, `pulse_sync`, `async_fifo`           |
| common    | `clock_mux_static`, `scrambler_x7x4`, `crc16_80211_hec`, `crc32_80211`, `phase_to_iq` |
| Path A    | `phy_a_rotator`, `mac_fsm_80211b`                              |
| Path B    | `mac_fsm_custom`, `phy_qam_custom`                             |
| top       | `multi_mode_tx_baseband`                                       |

All features are preserved verbatim from the hierarchical sources:

- Four 802.11b rates (1/2/5.5/11 Mbps) + 1-Mbps Long-PLCP preamble/header
  framing (SYNC 128, SFD 16, SIGNAL 8, SERVICE 8, LENGTH 16, HEC 16).
- Five Path B custom QAM modes (OOK / QPSK / 16-QAM / 64-QAM / 256-QAM).
- On-chip CRC-16 HEC (poly 0x1021, init/xor 0xFFFF) and CRC-32 FCS
  (reflected poly 0xEDB88320, init/xor 0xFFFFFFFF).
- x^7 + x^4 + 1 self-synchronous scrambler (separate per path).
- Dual-clock async FIFO with Gray-coded pointers and 2FF synchronizers.
- Per-domain reset synchronizers, pulse synchronizer for `start_pulse`
  and `tx_done`, and a 2FF synchronizer for `busy`.
- Sticky `invalid_mode` latching on illegal `mod_config` encodings.
- Top-level parameters (`PREAMBLE_SYNC_LEN_A`, `SFD_PATTERN_A`,
  `SERVICE_FIELD_A`, `SCRAMBLER_SEED_A`, `BARKER_PATTERN`,
  `CUSTOM_PREAMBLE_LEN`, `CUSTOM_PREAMBLE_PAT`, `SCRAMBLER_SEED_B`,
  `FIFO_DEPTH`, `FIFO_ADDR_W`) kept with the original defaults.
- Sim-only SystemVerilog assertions (`mod_config`/`payload_len`/
  `length_us` stability, `tx_enable` vs. `tx_busy` non-overlap,
  `invalid_mode` latched on illegal config) are preserved under the
  existing `` `ifdef ASSERT_ON `` guard, so synthesis ignores them and
  simulation can opt in with `+define+ASSERT_ON`.

`clock_mux_static` is still the behavioural 2:1 mux placeholder — swap
it for the foundry glitch-free clock-mux cell before GDS.

### Invoking synthesis

The only Verilog source needed is the one file:

```
synth/rtl_flat/multi_mode_tx_baseband_flat.v
```

Top module: `multi_mode_tx_baseband`.  Example (Synopsys DC):

```tcl
read_file -format sverilog synth/rtl_flat/multi_mode_tx_baseband_flat.v
current_design multi_mode_tx_baseband
link
```

or for Cadence Genus:

```tcl
read_hdl -sv synth/rtl_flat/multi_mode_tx_baseband_flat.v
elaborate multi_mode_tx_baseband
```

## 2. Testbenches

Each testbench exercises one unit or integration aspect and prints a
terminal-friendly `[PASS] / [FAIL]` line for every assertion it runs.
Every test ends with a summary block of the form:

```
 total=<N>  failed=<F>  result=*** PASS ***   (or *** FAIL ***)
```

so regressions are obvious to the eye and easy to grep.  When a check
fails, the line carries both the `got=` and `exp=` values, so debugging
does not require re-running with waves.

| Testbench                  | Unit / scope                          | Key expected outputs |
|----------------------------|----------------------------------------|----------------------|
| `tb_phase_to_iq.sv`        | Gray QPSK phase → (I,Q) truth table    | 4-row truth table    |
| `tb_scrambler_x7x4.sv`     | x^7 + x^4 + 1 self-synchronous scrambler | step-by-step stream |
| `tb_crc16_hec.sv`          | CRC-16 HEC `"123456789"`               | `0xD64E`             |
| `tb_crc32_80211.sv`        | Reflected CRC-32 `"123456789"`         | `0xCBF43926`         |
| `tb_sync_2ff.sv`           | 2FF synchronizer latency               | 2-edge latency       |
| `tb_reset_sync.sv`         | Async-assert / sync-deassert reset     | 2-edge deassert      |
| `tb_pulse_sync.sv`         | Level-toggle pulse CDC                 | 3 pulses in → 3 out  |
| `tb_async_fifo.sv`         | Dual-clock 8-deep FIFO                 | order, full, drain   |
| `tb_phy_a_rotator.sv`      | phi1 accumulator + phase→IQ            | 6 phase steps        |
| `tb_phy_qam_custom.sv`     | Variable S2P grouper                   | OOK/QPSK/16QAM/flush |
| `tb_mac_fsm_custom.sv`     | Path B MAC w/ seed=0                   | 80-bit stream, FCS   |
| `tb_mac_fsm_80211b.sv`     | Path A MAC chip totals                 | DBPSK/DQPSK/CCK-11   |
| `tb_top_flat.sv`           | Top-level end-to-end smoke             | Path A + Path B + C1 |

### Invoking simulation (Cadence Xcelium example)

Each test has its own filelist to keep compile-time concerns localized.
From the repo root:

```
xrun -sv -f synth/tb/filelist_tb_phase_to_iq.f     -top tb_phase_to_iq
xrun -sv -f synth/tb/filelist_tb_scrambler_x7x4.f  -top tb_scrambler_x7x4
xrun -sv -f synth/tb/filelist_tb_crc16_hec.f       -top tb_crc16_hec
xrun -sv -f synth/tb/filelist_tb_crc32_80211.f     -top tb_crc32_80211
xrun -sv -f synth/tb/filelist_tb_sync_2ff.f        -top tb_sync_2ff
xrun -sv -f synth/tb/filelist_tb_reset_sync.f      -top tb_reset_sync
xrun -sv -f synth/tb/filelist_tb_pulse_sync.f      -top tb_pulse_sync
xrun -sv -f synth/tb/filelist_tb_async_fifo.f      -top tb_async_fifo
xrun -sv -f synth/tb/filelist_tb_phy_a_rotator.f   -top tb_phy_a_rotator
xrun -sv -f synth/tb/filelist_tb_phy_qam_custom.f  -top tb_phy_qam_custom
xrun -sv -f synth/tb/filelist_tb_mac_fsm_custom.f  -top tb_mac_fsm_custom
xrun -sv -f synth/tb/filelist_tb_mac_fsm_80211b.f  -top tb_mac_fsm_80211b
xrun -sv -f synth/tb/filelist_tb_top_flat.f        -top tb_top_flat
```

Or all in one go (one compile per test):

```
for t in phase_to_iq scrambler_x7x4 crc16_hec crc32_80211 sync_2ff \
         reset_sync pulse_sync async_fifo phy_a_rotator phy_qam_custom \
         mac_fsm_custom mac_fsm_80211b top_flat; do
  xrun -sv -f synth/tb/filelist_tb_${t}.f -top tb_${t} | tee run_${t}.log
done
```

Each log contains a `*** PASS ***` or `*** FAIL ***` line the reader
can grep for to aggregate results.  Because every check line reports
both `got=` and `exp=`, a failing test is immediately debuggable from
the log alone.
