# Testbenches

`tb_multi_mode_tx_baseband.sv` exercises every datapath of the top-level
`multi_mode_tx_baseband` module and prints a pass/fail report at the end.

`tb_mac_fsm_80211b_checks.sv` is a focused Path A regression bench for:
- Barker payload-byte alignment against the FWFT FIFO contract
- 2 Mbps DQPSK phase-step mapping with a legal scrambler seed
- 11 Mbps SERVICE length-extension encoding
- CCK low/high byte assembly into `cck_word`

`tb_mac_fsm_custom_checks.sv` is a focused Path B regression bench for:
- FWFT FIFO byte alignment into the custom payload stream

## Running (Xcelium)

From the repository root:

```
xrun -sv -f tb/filelist.f +define+ASSERT_ON -top tb_multi_mode_tx_baseband
```

Append `+define+WAVES` to produce `tb_multi_mode_tx_baseband.vcd`.

For the focused Path A checks:

```
xrun -sv -f tb/filelist_mac_fsm_80211b_checks.f -top tb_mac_fsm_80211b_checks
```

For the focused Path B checks:

```
xrun -sv -f tb/filelist_mac_fsm_custom_checks.f -top tb_mac_fsm_custom_checks
```

The testbenches do **not** invoke a licensed simulator on their own; the user is
expected to drive `xrun`.

## Test matrix

| Test | Mode                     | `mod_config` | `payload_len` | Expected count             |
|------|--------------------------|--------------|---------------|----------------------------|
| T_C1 | Illegal mod_config       | `0111`, `1101` | –           | `invalid_mode` latches; no tx |
| T_A1 | 1 Mbps DBPSK             | `0000`       | 4 bytes       | 2816 `chip_valid`          |
| T_A2 | 2 Mbps DQPSK             | `0001`       | 4 bytes       | 2464 `chip_valid`          |
| T_A3 | 5.5 Mbps CCK             | `0010`       | 3 bytes       | 2224 `chip_valid`          |
| T_A4 | 11  Mbps CCK             | `0011`       | 3 bytes       | 2168 `chip_valid`          |
| T_B1 | OOK (custom)             | `1000`       | 4 bytes       | 96  `symbol_valid`         |
| T_B2 | QPSK (custom)            | `1001`       | 4 bytes       | 48  `symbol_valid`         |
| T_B3 | 16-QAM (custom)          | `1010`       | 4 bytes       | 24  `symbol_valid`         |
| T_B4 | 64-QAM (custom)          | `1011`       | 4 bytes       | 16  `symbol_valid`         |
| T_B5 | 256-QAM (custom)         | `1100`       | 4 bytes       | 12  `symbol_valid`         |
| T_B6 | 64-QAM partial flush     | `1011`       | 2 bytes       | 14  `symbol_valid`         |
| T_C2 | Back-to-back DBPSK       | `0000`       | 4 bytes x2    | 2×2816 chips, 2 `tx_done`  |

### Path A chip formula

Preamble + header is always 1 Mbps DBPSK/Barker:

```
HDR_SYMS  = 128(SYNC) + 16(SFD) + 32(HEAD) + 16(HEC) = 192
HDR_CHIPS = HDR_SYMS * 11                            = 2112
```

PSDU + FCS chips depend on rate (`N = payload_len`):

| Rate          | PSDU+FCS symbols            | chips/sym | PSDU chips        |
|---------------|-----------------------------|-----------|-------------------|
| 1 Mbps DBPSK  | `8N + 32`                   | 11        | `11*(8N+32)`      |
| 2 Mbps DQPSK  | `(8N + 32) / 2`             | 11        | `11*(4N+16)`      |
| 5.5 Mbps CCK  | `2N + 8`                    | 8         | `8*(2N+8)`        |
| 11  Mbps CCK  | `N + 4`                     | 8         | `8*(N+4)`         |

### Path B symbol formula

```
total_bits = CUSTOM_PREAMBLE_LEN(32) + 8*N + 32(FCS)
symbols    = ceil(total_bits / bits_per_sym)
```

## Known pre-existing RTL issues the TB will surface

1. **`clock_mux_static` is a combinational MUX placeholder.**
   Simulation will produce the correct result, but the TB cannot model
   the glitch risk that is the reason to replace it with a foundry
   glitch-free clock-mux cell before GDS.

## Extending

- Add per-module random-payload tests under [tests/module/](./tests/module/)
  (not yet created) for CRC-32, CRC-16 HEC, scrambler, async FIFO.
- A conformance checker that replays `chip_i`/`chip_q` through a
  reference 802.11b demodulator would catch bit-level encoding bugs
  that this counts-based TB cannot.
