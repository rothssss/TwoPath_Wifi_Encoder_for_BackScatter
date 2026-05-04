# Testbenches

This repository targets the four-PSDU-rate Wi-Fi-only transmitter:

- `1   Mbps` DBPSK + Barker (chip computes everything)
- `2   Mbps` DQPSK + Barker (chip computes everything)
- `5.5 Mbps` CCK            (MCU pre-computes; chip streams)
- `11  Mbps` CCK            (MCU pre-computes; chip streams)

## Top-level bench

`tb_multi_mode_tx_baseband.sv` exercises supported top-level modes and control
plumbing:

- illegal `mod_config` rejection (codes outside `0000..0011`)
- `1 Mbps` DBPSK packet flow
- `2 Mbps` DQPSK packet flow
- `5.5 Mbps` CCK chip-count geometry (MCU-stub words)
- `11 Mbps` CCK chip-count geometry (MCU-stub words)
- back-to-back DBPSK packet cleanup

## Focused Path A bench

`tb_mac_fsm_80211b_checks.sv` is the focused Path A regression for:

- Barker payload-byte alignment against the FWFT FIFO contract
- 2 Mbps DQPSK phase-step mapping with a legal scrambler seed
- on-chip PLCP header construction for 1 Mbps and 2 Mbps

## CCK golden-vector bench

`tb_mac_fsm_80211b_cck_golden.sv` validates the MCU-offload CCK streamer at
the MAC -> rotator interface.  For each test it pushes a hand-crafted
sequence of CCK symbol words into the behavioural FIFO, runs a packet end
to end, and confirms chip-by-chip that:

- `base_phase` matches `cck_word[2*k+2 +: 2]` for chip `k` of every symbol
- `update_phi1` pulses exactly once per symbol, on chip 0
- `delta_phi1` at that pulse matches `cck_word[1:0]`
- exactly `cck_symbol_count` symbols emit (`8` chips each)
- exactly `4 * cck_symbol_count` FIFO bytes are consumed
- `done_pulse` fires once and `busy` returns low
- the prefetch buffer does not leak the next symbol's data into the
  current symbol's chips

What this bench is **not**: it does not validate the MCU-side CCK encoder
against IEEE 802.11-2016 sec 16.4.6 reference vectors.  When MATLAB- or
ns-3-derived golden vectors land, drop them into the same `pack_cck` /
`load_cck_word` harness to extend the bench.

## Legacy Path B bench

`tb_mac_fsm_custom_checks.sv` is retained only as a historical/unit-level
file for the deprecated custom datapath.  It is no longer part of the
active top-level architecture.

## Running (Xcelium)

From the repository root:

```text
xrun -sv -f tb/filelist.f +define+ASSERT_ON \
     -top tb_multi_mode_tx_baseband
```

Append `+define+WAVES` to dump `tb_multi_mode_tx_baseband.vcd`.

For the focused Path A checks:

```text
xrun -sv -f tb/filelist_mac_fsm_80211b_checks.f \
     -top tb_mac_fsm_80211b_checks
```

For the CCK golden-vector regression:

```text
xrun -sv -f tb/filelist_mac_fsm_80211b_cck_golden.f \
     -top tb_mac_fsm_80211b_cck_golden
```

## Test matrix

| Test | Mode               | `mod_config` | Inputs                          | Expected count        |
|------|--------------------|--------------|---------------------------------|-----------------------|
| T_C1 | Illegal mode       | `0100`, `1000` | -                             | `invalid_mode`; no tx |
| T_A1 | 1   Mbps DBPSK     | `0000`       | 4-byte payload                  | 2816 `chip_valid`     |
| T_A2 | 2   Mbps DQPSK     | `0001`       | 4-byte payload                  | 2464 `chip_valid`     |
| T_A3 | 5.5 Mbps CCK stub  | `0010`       | 2 CCK symbols (8 FIFO bytes)    | 2128 `chip_valid`     |
| T_A4 | 11  Mbps CCK stub  | `0011`       | 2 CCK symbols (8 FIFO bytes)    | 2128 `chip_valid`     |
| T_C2 | Back-to-back DBPSK | `0000`       | 4-byte payload x2               | 2 x 2816 chips, 2 done |

### Path A chip formula

Preamble + header is always 1 Mbps DBPSK / Barker:

```text
HDR_SYMS  = 128(SYNC) + 16(SFD) + 32(HEAD) + 16(HEC) = 192
HDR_CHIPS = HDR_SYMS * 11                            = 2112
```

PSDU + FCS chips depend on rate:

| Rate          | PSDU+FCS region count | chips/sym | PSDU chips        |
|---------------|-----------------------|-----------|-------------------|
| 1   Mbps DBPSK| `8N + 32` symbols     | 11        | `11 * (8N + 32)`  |
| 2   Mbps DQPSK| `(8N + 32) / 2` syms  | 11        | `11 * (4N + 16)`  |
| 5.5/11 Mbps   | `cck_symbol_count`    |  8        | `8 * cck_symbol_count` |

(`N` = `payload_len` for Barker rates.)

## Known residual integration item

System-level testing should validate MCU write-rate assumptions against
the (post-revision-2) 16-byte FIFO depth, especially for the 5.5 MB/s
sustained CCK byte rate.
