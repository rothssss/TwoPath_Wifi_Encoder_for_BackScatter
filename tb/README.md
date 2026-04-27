# Testbenches

This repository now targets the cut-down Wi-Fi-only transmitter:

- `1 Mbps` DBPSK + Barker
- `2 Mbps` DQPSK + Barker

Removed from the active top-level verification scope:

- `5.5 / 11 Mbps` CCK
- custom Path B modulation

## Top-level bench

`tb_multi_mode_tx_baseband.sv` exercises the supported top-level modes and
control plumbing:

- illegal `mod_config` rejection
- `1 Mbps` DBPSK packet flow
- `2 Mbps` DQPSK packet flow
- back-to-back packet cleanup

## Focused Path A bench

`tb_mac_fsm_80211b_checks.sv` is the focused Path A regression bench for:

- Barker payload-byte alignment against the FWFT FIFO contract
- 2 Mbps DQPSK phase-step mapping with a legal scrambler seed
- on-chip PLCP LENGTH generation for `1 Mbps`
- on-chip PLCP LENGTH generation for `2 Mbps`

## Legacy Path B bench

`tb_mac_fsm_custom_checks.sv` is retained only as a historical/unit-level file
for the deprecated custom datapath. It is no longer part of the active
top-level architecture.

## Running (Xcelium)

From the repository root:

```text
xrun -sv -f tb/filelist.f +define+ASSERT_ON -top tb_multi_mode_tx_baseband
```

Append `+define+WAVES` to produce `tb_multi_mode_tx_baseband.vcd`.

For the focused Path A checks:

```text
xrun -sv -f tb/filelist_mac_fsm_80211b_checks.f -top tb_mac_fsm_80211b_checks
```

## Test matrix

| Test | Mode               | `mod_config` | `payload_len` | Expected count            |
|------|--------------------|--------------|---------------|---------------------------|
| T_C1 | Illegal mode       | `0010`, `1000` | -           | `invalid_mode`; no tx     |
| T_A1 | 1 Mbps DBPSK       | `0000`       | 4 bytes       | 2816 `chip_valid`         |
| T_A2 | 2 Mbps DQPSK       | `0001`       | 4 bytes       | 2464 `chip_valid`         |
| T_C2 | Back-to-back DBPSK | `0000`       | 4 bytes x2    | 2 x 2816 chips, 2 done    |

### Path A chip formula

Preamble + header is always 1 Mbps DBPSK/Barker:

```text
HDR_SYMS  = 128(SYNC) + 16(SFD) + 32(HEAD) + 16(HEC) = 192
HDR_CHIPS = HDR_SYMS * 11                            = 2112
```

PSDU + FCS chips depend on rate (`N = payload_len`):

| Rate          | PSDU+FCS symbols | chips/sym | PSDU chips   |
|---------------|------------------|-----------|--------------|
| 1 Mbps DBPSK  | `8N + 32`        | 11        | `11*(8N+32)` |
| 2 Mbps DQPSK  | `(8N + 32) / 2`  | 11        | `11*(4N+16)` |

## Known residual integration issue

The design still uses an async FIFO between `clk_mcu` and `clk_b_chip`, so
system-level testing should still validate the MCU write-rate assumptions after
the FIFO-depth cut.
