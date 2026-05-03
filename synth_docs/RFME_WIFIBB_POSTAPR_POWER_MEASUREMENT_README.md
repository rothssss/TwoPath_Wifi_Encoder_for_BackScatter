# wifiBB_POSTAPR Netlist Power Flow

This note documents the reusable netlist-based power measurement flow for the
trimmed Wi-Fi-only `wifiBB_POSTAPR` block in RFME session `:21`.

## Goal

Measure average supply current and average supply power for the current
commercial-Wi-Fi-compatible `wifiBB` controller using the exported netlist flow,
not a long interactive ADE run.

Supported compliant modes:

- `1 Mbps DBPSK` via `mod_config = 4'b0000`
- `2 Mbps DQPSK` via `mod_config = 4'b0001`

The runner is:

- [run_wifiBB_postapr_power_v21.py](C:\Users\nav\Box\Student-Naveed\Paper\RFME\run_wifiBB_postapr_power_v21.py)

## Flow

### 1. Ensure the post-APR symbol exists

The script first regenerates `RFME/wifiBB_POSTAPR/symbol` from the imported
post-APR schematic so it can build a temporary schematic TB cleanly.

### 2. Create a temporary schematic testbench

The temporary TB instantiates `RFME/wifiBB_POSTAPR/symbol` and drives:

- `clk_b_chip`
- `clk_custom`
- `clk_mcu`
- `rst_n`
- `tx_enable`
- `payload_write`
- `mod_config<3:0>`
- `payload_len<15:0>`
- `length_us<15:0>`
- `payload_in<7:0>`

The DUT power is driven through:

- `VDD0` source
- `RSENSE = 1m`

Current is measured through `VDD0:p`.

### 3. Reuse a known-good Maestro configuration

The script copies the reference Spectre/Maestro environment from:

- library: `2023_PLL`
- cell: `DIV_TB`
- test: `2023_PLL_DIV_TB_1`

It reuses:

- model files
- switch view list
- stop view list
- `temp`, `tnom`, `reltol`, `vabstol`, `iabstol`

### 4. Export the batch netlist through Virtuoso

The script launches a short batch Virtuoso job that calls:

- `maeCreateNetlistForCorner("TRAN" "Nominal" ...)`

This creates a temporary exported netlist directory under `/tmp`.

### 5. Patch the exported Spectre deck for fast power runs

Before simulation, the script patches `input.scs` so the exported run only
saves the branch current of the supply source:

- `saveOptions options save=selected currents=selected`
- `save VDD0:p`

### 6. Run Spectre X directly on the exported netlist

The script runs Spectre X from the exported netlist directory using:

- multithreading
- low-accuracy fast preset
- direct batch launch over SSH

### 7. Measure average current and power

The final measurement is:

- `avgI = average(clip(i("VDD0:p") t_start t_stop))`
- `avgP = abs(avgI) * VDD`

Power is reported in `uW`.

## Defaults

Default runner settings:

- session: `V21` / direct port `5953`
- DUT: `RFME/wifiBB_POSTAPR`
- supply: `0.8 V`
- default rate: `2 Mbps DQPSK`
- default payload length: `8 bytes`
- default payload pattern: `0xA5`
- Spectre preset: `vx`
- requested threads: `32`

## Useful Commands

Setup only:

```powershell
py -3 C:\Users\nav\Box\Student-Naveed\Paper\RFME\run_wifiBB_postapr_power_v21.py --setup-only
```

Export only:

```powershell
py -3 C:\Users\nav\Box\Student-Naveed\Paper\RFME\run_wifiBB_postapr_power_v21.py --export-only
```

Run `1 Mbps` at `0.8 V`:

```powershell
py -3 C:\Users\nav\Box\Student-Naveed\Paper\RFME\run_wifiBB_postapr_power_v21.py --rate 1m --vdd 0.8
```

Run `2 Mbps` at `0.8 V`:

```powershell
py -3 C:\Users\nav\Box\Student-Naveed\Paper\RFME\run_wifiBB_postapr_power_v21.py --rate 2m --vdd 0.8
```

## Outputs

Each run writes:

- `C:\Users\nav\Box\Student-Naveed\Paper\RFME\_tmp_wifiBB_postapr_power_v21_<tag>.json`
- `C:\Users\nav\Box\Student-Naveed\Paper\RFME\_tmp_wifiBB_postapr_power_v21_<tag>_summary.txt`

The `<tag>` encodes the chosen rate, payload length, and supply.
